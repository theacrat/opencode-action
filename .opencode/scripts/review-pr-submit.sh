#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}
state_dir="${HOME}/.config/opencode/review-state"
context_file="${state_dir}/context.json"
initial_payload="${state_dir}/initial.json"
validated_payload="${state_dir}/validated-initial.json"
update_payload="${state_dir}/update.json"
review_id_file="${state_dir}/review_id"
session_file="${HOME}/.config/opencode/review-session-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
submission_attempt_file="${state_dir}/submission-attempted"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trusted_context_lib="${script_dir}/review-pr-context.sh"
[[ -f "${trusted_context_lib}" ]] || fail "Trusted review context helper is unavailable."
# shellcheck source=/dev/null
source "${trusted_context_lib}"

load_token_lib() {
  local opencode_app_token_lib="${HOME}/.config/opencode/scripts/resolve-app-token.sh"
  [[ -f "${opencode_app_token_lib}" ]] || fail "OpenCode App token resolver is unavailable."
  # shellcheck source=/dev/null
  source "${opencode_app_token_lib}"
}

validate_initial_payload() {
  local comment_count index
  jq -e . "${initial_payload}" > /dev/null 2>&1 \
    || fail "Invalid initial review payload: expected valid JSON."
  jq -e 'type == "object"' "${initial_payload}" > /dev/null \
    || fail "Invalid initial review payload: top level must be an object."
  jq -e 'keys == ["body", "comments"]' "${initial_payload}" > /dev/null \
    || fail "Invalid initial review payload: top level must contain exactly body and comments."
  jq -e '.body | type == "string" and length > 0' "${initial_payload}" > /dev/null \
    || fail "Invalid initial review payload: body must be a nonempty string."
  jq -e '.comments | type == "array"' "${initial_payload}" > /dev/null \
    || fail "Invalid initial review payload: comments must be an array."

  comment_count="$(jq '.comments | length' "${initial_payload}")"
  for ((index = 0; index < comment_count; index++)); do
    jq -e --argjson index "${index}" '.comments[$index] | type == "object"' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} must be an object."
    jq -e --argjson index "${index}" '.comments[$index].body | type == "string" and length > 0' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} body must be a nonempty string."
    jq -e --argjson index "${index}" '
      .comments[$index].body
      | test("^\\*\\*(critical|important|suggestion) · [^*\\r\\n]+\\*\\*\\n\\n."; "s")
    ' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} body must begin with a severity and reviewer source."
    jq -e --argjson index "${index}" '.comments[$index].path | type == "string" and length > 0' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} path must be a nonempty string."
    jq -e --argjson index "${index}" '
      .comments[$index].line | type == "number" and floor == . and . > 0
    ' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} line must be a positive integer."
    jq -e --argjson index "${index}" '
      .comments[$index].side == "LEFT" or .comments[$index].side == "RIGHT"
    ' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} side must be LEFT or RIGHT."
    jq -e --argjson index "${index}" '
      .comments[$index] as $comment
      | ($comment | has("start_line")) == ($comment | has("start_side"))
    ' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} must include both start_line and start_side or neither."
    jq -e --argjson index "${index}" '
      .comments[$index] as $comment
      | if ($comment | has("start_line")) then
          ($comment.start_line | type == "number" and floor == . and . > 0)
          and $comment.start_line <= $comment.line
          and $comment.start_side == $comment.side
        else
          true
        end
    ' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} range must use positive ordered lines on the same side."
    jq -e --argjson index "${index}" '
      .comments[$index] as $comment
      | if ($comment | has("start_line")) then
          ($comment | keys == ["body", "line", "path", "side", "start_line", "start_side"])
        else
          ($comment | keys == ["body", "line", "path", "side"])
        end
    ' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} contains unsupported or missing fields."
  done
}

# Post the pinned review with the given event, capturing stderr so a
# self-review rejection can be detected. Uses globals current_payload,
# head_sha, repo, pr_number, request; sets globals response and review_error.
post_review_with_event() {
  local event="${1}" status err_file
  err_file="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review-err.XXXXXX")"
  jq --arg commit_id "${head_sha}" --arg event "${event}" \
    '. + {commit_id: $commit_id, event: $event}' <<< "${current_payload}" > "${request}"
  set +e
  response="$(gh api --method POST "repos/${repo}/pulls/${pr_number}/reviews" --input "${request}" 2> "${err_file}")"
  status=$?
  set -e
  review_error="$(cat "${err_file}")"
  rm -f "${err_file}"
  return "${status}"
}

operation="${1:-}"
[[ "$#" -eq 1 ]] || fail "Review helper operations take exactly one operation name and no additional arguments."

case "${operation}" in
  prepare)
    mkdir -p "${HOME}/.config/opencode"
    if ! (
      set -o noclobber
      : > "${session_file}"
    ) 2> /dev/null; then
      fail "Review submission state was already prepared for this run."
    fi
    rm -rf "${state_dir}"
    (
      umask 077
      mkdir -p "${state_dir}"
      : > "${context_file}"
      : > "${initial_payload}"
      : > "${update_payload}"
    )
    ;;
  validate-initial)
    [[ ! -e "${submission_attempt_file}" ]] \
      || fail "Initial review submission was already attempted for this run."
    [[ ! -e "${validated_payload}" ]] \
      || fail "Initial review payload already passed validation and is sealed."
    validate_initial_payload
    validated_payload_tmp="$(mktemp "${state_dir}/validated-initial.XXXXXX.json")"
    trap 'rm -f "${validated_payload_tmp}"' EXIT
    jq -cS . "${initial_payload}" > "${validated_payload_tmp}"
    mv "${validated_payload_tmp}" "${validated_payload}"
    trap - EXIT
    ;;
  submit-initial)
    [[ -s "${validated_payload}" ]] \
      || fail "Initial review payload must pass validate-initial before submission."
    validate_initial_payload
    current_payload="$(jq -cS . "${initial_payload}")" \
      || fail "Initial review payload changed to invalid JSON after validation."
    [[ "${current_payload}" == "$(cat "${validated_payload}")" ]] \
      || fail "Initial review payload changed after validation; submission must stop."
    if ! (
      set -o noclobber
      : > "${submission_attempt_file}"
    ) 2> /dev/null; then
      fail "Initial review submission was already attempted for this run."
    fi
    rm -f "${validated_payload}"
    load_token_lib
    opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}" || true
    context="$(opencode_review_trusted_context)" || fail "Pinned PR context is unavailable or the PR head changed."
    IFS=$'\t' read -r repo pr_number head_sha <<< "${context}"
    request="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review.XXXXXX.json")"
    trap 'rm -f "${request}"' EXIT
    # Findings request changes; a clean review approves. The event is derived
    # from the sealed payload, not chosen by the model at submission time.
    if [[ "$(jq '.comments | length' <<< "${current_payload}")" -gt 0 ]]; then
      review_event="REQUEST_CHANGES"
    else
      review_event="APPROVE"
    fi
    opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}"
    opencode_review_verify_head "${repo}" "${pr_number}" "${head_sha}" \
      || fail "Pinned PR context is unavailable or the PR head changed during token verification."
    if ! post_review_with_event "${review_event}"; then
      # GitHub blocks a verdict review (APPROVE/REQUEST_CHANGES) when the review
      # identity is the PR author, or when the repo/org has not enabled
      # "Allow GitHub Actions to create and approve pull requests". In either
      # case, degrade to a plain comment review instead of failing the run.
      if [[ "${review_event}" != "COMMENT" ]] \
        && grep -qiE "your own pull request|not permitted to (approve|create)" <<< "${review_error}"; then
        echo "::warning::Cannot submit a ${review_event} review (self-review, or GitHub Actions approval is not enabled); posting a comment review instead." >&2
        post_review_with_event "COMMENT" \
          || fail "Failed to submit the review after the verdict fallback: ${review_error}"
      else
        fail "Failed to submit the review: ${review_error}"
      fi
    fi
    review_id="$(jq -r '.id // empty' <<< "${response}")"
    [[ "${review_id}" =~ ^[1-9][0-9]*$ ]] || fail "Review ID was not returned."
    printf '%s' "${review_id}" > "${review_id_file}"
    printf '%s\n' "${response}"
    ;;
  update)
    load_token_lib
    opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}" || true
    context="$(opencode_review_trusted_context)" || fail "Pinned PR context is unavailable or the PR head changed."
    IFS=$'\t' read -r repo pr_number head_sha <<< "${context}"
    jq -e 'keys == ["body"] and (.body | type == "string" and length > 0)' "${update_payload}" > /dev/null \
      || fail "Invalid review update payload."
    [[ -f "${review_id_file}" ]] || fail "This run has no recorded review ID."
    review_id="$(cat "${review_id_file}")"
    [[ "${review_id}" =~ ^[1-9][0-9]*$ ]] || fail "Recorded review ID is invalid."
    opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}"
    opencode_review_verify_head "${repo}" "${pr_number}" "${head_sha}" \
      || fail "Pinned PR context is unavailable or the PR head changed during token verification."
    gh api --method PUT "repos/${repo}/pulls/${pr_number}/reviews/${review_id}" --input "${update_payload}" \
      || fail "Failed to submit the review update."
    ;;
  *) fail "Unsupported review submission operation." ;;
esac
