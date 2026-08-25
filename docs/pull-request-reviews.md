# Pull request reviews

The bundled `/review-pr` flow runs a strictly read-only, risk-driven multi-agent review and submits validated findings through GitHub's pull request review API. The command is the supported entrypoint: it selects the dedicated `review-pr-orchestrator` primary agent and loads the internal `pr-review` skill.

`pr-review` contains the review procedure, while `review-pr-orchestrator` contains the permission boundary. Loading the skill directly into another primary agent does not transfer those permissions, so direct skill loading must not be treated as an enforced read-only review path. The skill is marked non-slash and non-autoinvokable for OpenCode v2 discovery; the command remains the explicit review entrypoint.

## Setup

Review workflows require OpenCode 1.2.14 or newer, `use-bundled-toolkit: true`, `pull-requests: write`, and an API key for the selected model provider. The bundled Sakura provider's `chunkTimeout` setting requires OpenCode 1.2.25 or newer; pins between 1.2.14 and 1.2.24 fall back to the top-level request `timeout` instead of the inter-chunk timeout. Request, chunk, and action timeouts are safety limits, not substitutes for bounding request size, and `chunkTimeout` cannot guarantee that a provider-side gateway or inference timeout will not end a request sooner.

Start from the pinned workflow in the [README quick start](../README.md#quick-start), then grant pull-request write access and configure the OpenCode step for review mode. The copied job remains triggered by `/oc` or `/opencode`; the fixed `prompt` below makes either accepted mention run `/review-pr`.

Set the workflow permissions:

```yaml
permissions:
  contents: read
  pull-requests: write
  id-token: write
```

Then configure the `Run OpenCode` step from the README quick start:

```yaml
env:
  OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
  GITHUB_TOKEN: ${{ github.token }}
with:
  model: openrouter/openrouter/free
  prompt: /review-pr
```

For a smaller caller workflow, use the bundled [`opencode-review.yml` reusable workflow](reusable-workflows.md#pull-request-review).

When `use-github-token: true`, pass `GH_TOKEN` or `GITHUB_TOKEN` and grant the workflow token the required permissions.

## Review aspects

To select review aspects in this fixed-prompt setup, set `prompt` to `/review-pr` followed by one or more keywords:

| Command                           | Focus                                |
| --------------------------------- | ------------------------------------ |
| `/review-pr` or `/review-pr all`  | Full review                          |
| `/review-pr security performance` | Security and performance             |
| `/review-pr tests docs`           | Test coverage and documentation      |
| `/review-pr code`                 | Correctness and code quality         |
| `/review-pr quality`              | Code quality                         |
| `/review-pr coverage`             | Test coverage                        |
| `/review-pr documentation`        | Documentation accuracy               |
| `/review-pr errors`               | Silent failures and error handling   |
| `/review-pr comments`             | Comment and docstring accuracy       |
| `/review-pr types`                | Type design                          |
| `/review-pr simplify`             | Read-only simplification suggestions |

The review runs along two axes: **Standards** (the repo's documented conventions plus a fixed Fowler smell baseline) and **Spec** (does the diff match the originating issue/spec). Each axis is a fresh, read-only child session, and the two run in parallel so they don't share context. Explicit aspects are hard scope constraints, and the spec source is derived from the PR body, commit messages, or a spec path passed in the aspects.

The current OpenCode v1-compatible runtime uses one hidden `review-worker` subagent definition with read/glob/grep permissions only. Each axis launches a fresh worker session, and the parent validates every surviving candidate against the captured diff — actively seeking counterevidence — before publishing it. When OpenCode v2's built-in read-only `explore` contract becomes the action runtime boundary, this compatibility worker can be removed without changing the review procedure.

## Finding and submission behavior

The parent primary agent retains the full pull request context for anchoring and normalization while each child receives only a bounded packet for its axis. The review flow then:

1. dispatches the Standards and Spec axes as fresh read-only sessions with bounded context
2. deduplicates candidates by root cause
3. validates candidates independently as `confirmed`, `rejected`, or `needs-human`
4. arbitrates confirmed findings against the captured diff
5. posts anchorable confirmed findings as inline review comments and keeps genuine unanchorable findings in the review body

A successful run validates the complete payload without a GitHub write, then creates one structured GitHub review and updates its body with the workflow run link. The validated payload is sealed against later edits, and the live initial submission can be attempted only once per run. `/review-pr` does not post through `gh pr comment` or the issue comment API.

The helper derives the review verdict from the payload: confirmed findings (a non-empty `comments` array) submit as `REQUEST_CHANGES`; a clean review (empty `comments`) submits as `APPROVE`. If the review identity may not submit that verdict — a self-review on the author's own PR, or a repo/org that has not enabled GitHub Actions approvals — the helper degrades to a plain `COMMENT` review instead of failing. Approvals and change requests are attributed to the review token's identity: to let the bot act on PRs you authored, run with the default `github.token` (`github-actions[bot]`) and enable **Settings → Actions → General → Allow GitHub Actions to create and approve pull requests**; a personal access token belonging to the PR author cannot approve that author's own PR. Validation identifies missing or invalid fields before submission, and other submission failures fail the workflow without a retry.

`opencode github run` posts the command's final assistant message as a top-level comment. To avoid a comment that merely restates the submitted review, the skill produces an empty final response after submitting, so a successful run leaves only the structured review.

## Security

`opencode-action` treats the repository checkout, project OpenCode configuration, pull request content, and unverified git credentials as untrusted.

### Review isolation

When the effective prompt starts with `/review-pr`, the action installs a fresh bundled OpenCode configuration, disables project-provided configuration and externally discovered skills, removes inherited plugins and agents, and resolves the review command only from the action bundle.

The bundled global OpenCode config does not grant trusted review paths to every agent. External-directory access to the fixed review helpers and dedicated state directory under `~/.config/opencode/` is allowed only by the `review-pr-orchestrator` permission profile. The read-only worker has no shell or edit permission. The helpers source the trusted-context and token-resolution libraries only from their installed sibling paths; repository-controlled files never enter that execution path.

### Trusted pull request context

One shared trusted-context helper derives the repository and pull request number from the GitHub Actions event and validates the pinned pull request head SHA for both read and write helpers. The submission helper validates the same context immediately before the write and repeats the live-head check after token verification. If the pull request head changes after the diff is captured or while the token is being resolved, the run fails before submitting stale findings.

### Trusted host boundary

Review isolation assumes the runner host and its administrator-controlled OpenCode state are trusted. The action clears project/caller review configuration and inherited toolkit state, but it does not attempt to reproduce OpenCode's full external, managed, plugin, or remote configuration discovery. Variant prevalidation therefore uses the bundled registry only when the isolated environment is conservatively known to make that registry authoritative; otherwise the requested variant is passed through unchanged. Use trusted or ephemeral runners for review workflows.

### Token verification and precedence

The default OIDC flow supplies an OpenCode GitHub App installation token. Credentials discovered through git configuration remain untrusted until their identity is verified.

Before a structured review write, the action creates an empty pending review with each candidate, verifies that its author is `opencode-agent[bot]`, and immediately deletes it. The probe is not published, but it is a real create-and-delete API operation. Tokens and decoded authorization headers are never printed.

Structured writes use this precedence:

1. the first candidate verified as `opencode-agent[bot]`
2. the caller's existing `GH_TOKEN` or `GITHUB_TOKEN` only when `use-github-token: true`
3. otherwise, fail without submitting a review

The explicit workflow-token fallback may make reviews appear under `github-actions[bot]` or another identity associated with that token. Unverified candidates may be used for read-only metadata access but never pass the structured-write gate.

### Fail-closed behavior

Review-only mode fails rather than weakening its guarantees when:

- the bundled toolkit is disabled or the OpenCode version is unsupported
- trusted pull request context cannot be established
- the pull request head changes
- no App token verifies and workflow-token fallback was not explicitly enabled
- review payload validation or structured submission fails
- the `~/.opencode` state directory is a symlink, checked before the OpenCode binary is cached or installed, since cleaning or reusing it would otherwise write through the link
