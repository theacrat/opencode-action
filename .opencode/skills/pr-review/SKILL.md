---
name: code-review
description: "Review a GitHub pull request along two axes: Standards (does the code follow this repo's documented coding standards?) and Spec (does the code match what the originating issue/spec asked for?). Runs both reviews in parallel sub-agents and collates them into a review to be left on the PR.
metadata:
  opencode/slash: "false"
  opencode/autoinvoke: "false"
---

Two-axis review of the diff between `HEAD` and a fixed point the user supplies:

- **Standards**: does the code conform to this repo's documented coding standards?
- **Spec**: does the code faithfully implement the originating issue / spec?

Both axes run as **parallel sub-agents** so they don't pollute each other's context, then this skill aggregates their findings.

The issue tracker should have been provided to you. If `docs/agents/issue-tracker.md` is missing, tell the user to run `/setup-matt-pocock-skills`.

## Why two axes

A change can pass one axis and fail the other:

- Code that follows every standard but implements the wrong thing → **Standards pass, Spec fail.**
- Code that does exactly what the issue asked but breaks the project's conventions → **Spec pass, Standards fail.**

Reporting them separately stops one axis from masking the other.

## Setup

Before any analysis, invoke `"$HOME/.config/opencode/scripts/review-pr-submit.sh" prepare` once, followed by `"$HOME/.config/opencode/scripts/review-pr-gh.sh" context`. The context is persisted outside the checkout and pins one repository, PR number, and head SHA for the entire review. If `prepare` fails, stop. If `context` reports `Trusted pull request number is unavailable.`, continue in local mode; for every other `context` failure, stop.

The context helper derives the PR number from `.pull_request.number` or `.issue.number`. For `issue_comment`, it fetches and pins the current head SHA through the trusted PR API. Metadata, diff, submission, and update revalidate that the current head still matches the pinned SHA and fail closed otherwise. Obtain metadata and the diff only through these fixed operations:

```sh
"$HOME/.config/opencode/scripts/review-pr-gh.sh" metadata
"$HOME/.config/opencode/scripts/review-pr-gh.sh" diff
```

If no PR context can be established, use local mode: `git status --short`, `git diff --name-only HEAD`, and `git diff --no-ext-diff`; do not infer a PR from the current branch. Once `context` succeeds, any later metadata, diff, or validation failure must abort the review rather than falling back to local mode.

Capture the full diff, changed-file list, PR title/body, base and head branch names, head SHA, and relevant source context using the read, glob, and grep tools. Retain the full diff locally for anchoring and final normalisation.

## Process

### 1. Pin the fixed point

Whatever the user said is the fixed point (a commit SHA, branch name, tag, `main`, `HEAD~5`, etc.). If they didn't specify one, ask for it.

Capture the diff command once: `git diff <fixed-point>...HEAD` (three-dot, so the comparison is against the merge-base). Also note the list of commits via `git log <fixed-point>..HEAD --oneline`.

Before going further, confirm the fixed point resolves (`git rev-parse <fixed-point>`) and the diff is non-empty. A bad ref or empty diff should fail here, not inside two parallel sub-agents.

### 2. Identify the spec source

Look for the originating spec, in this order:

1. Issue references in the commit messages (`#123`, `Closes #45`, GitLab `!67`, etc.), fetched via the workflow in `docs/agents/issue-tracker.md`.
2. A path the user passed as an argument.
3. A spec file under `docs/`, `specs/`, or `.scratch/` matching the branch name or feature.
4. If nothing is found, ask the user where the spec is. If they say there isn't one, the **Spec** sub-agent will skip and report "no spec available".

### 3. Identify the standards sources

Anything in the repo that documents how code should be written, such as `CODING_STANDARDS.md` or `CONTRIBUTING.md`.

On top of whatever the repo documents, the Standards axis always carries the **smell baseline** below: a fixed set of Fowler code smells (_Refactoring_, ch.3) that applies even when a repo documents nothing. Two rules bind it:

- **The repo overrides.** A documented repo standard always wins; where it endorses something the baseline would flag, suppress the smell.
- **Always a judgement call.** Each smell is a labelled heuristic ("possible Feature Envy"), never a hard violation. Like any standard here, skip anything tooling already enforces.

Each smell reads *what it is* → *how to fix*; match it against the diff:

- **Mysterious Name**: a function, variable, or type whose name doesn't reveal what it does or holds. → rename it; if no honest name comes, the design's murky.
- **Duplicated Code**: the same logic shape appears in more than one hunk or file in the change. → extract the shared shape, call it from both.
- **Feature Envy**: a method that reaches into another object's data more than its own. → move the method onto the data it envies.
- **Data Clumps**: the same few fields or params keep travelling together (a type wanting to be born). → bundle them into one type, pass that.
- **Primitive Obsession**: a primitive or string standing in for a domain concept that deserves its own type. → give the concept its own small type.
- **Repeated Switches**: the same `switch`/`if`-cascade on the same type recurs across the change. → replace with polymorphism, or one map both sites share.
- **Shotgun Surgery**: one logical change forces scattered edits across many files in the diff. → gather what changes together into one module.
- **Divergent Change**: one file or module is edited for several unrelated reasons. → split so each module changes for one reason.
- **Speculative Generality**: abstraction, parameters, or hooks added for needs the spec doesn't have. → delete it; inline back until a real need shows.
- **Message Chains**: long `a.b().c().d()` navigation the caller shouldn't depend on. → hide the walk behind one method on the first object.
- **Middle Man**: a class or function that mostly just delegates onward. → cut it, call the real target direct.
- **Refused Bequest**: a subclass or implementer that ignores or overrides most of what it inherits. → drop the inheritance, use composition.

### 4. Spawn both sub-agents in parallel

**Both sub-agents prompts** should include instructions that they **must** end by returning a JSON array in the following format:

```json
{
  "candidate": "<stable identifier>",
  "severity": "critical | important | suggestion",
  "confidence": "<0-100>",
  "rationale": "<why the evidence establishes the claim>",
  "counterevidence_checked": "<guards, callers, tests, framework guarantees, config, or prior behavior checked>",
  "file": "<final changed path when confirmed or needs-human>",
  "line": "<final head-file line number when safely identifiable>",
  "impact": "<publishable concrete impact when confirmed>",
  "remediation": "<smallest coherent fix direction when confirmed>"
}
```

**Standards sub-agent prompt** should include:

- The full diff command and commit list.
- The list of standards-source files you found in step 3, **plus the smell baseline from step 3** pasted in full (the sub-agent has no other access to it).
- The brief: "Report, per file/hunk where relevant, (a) every place the diff violates a documented standard: cite the standard (file + the rule); and (b) any baseline smell you spot: name it and quote the hunk. Distinguish hard violations from judgement calls: documented-standard breaches can be hard, but baseline smells are always judgement calls, and a documented repo standard overrides the baseline. Skip anything tooling enforces. Under 400 words."

**Spec sub-agent prompt** should include:

- The diff command and commit list.
- The path or fetched contents of the spec.
- The brief: "Report: (a) requirements the spec asked for that are missing or partial; (b) behaviour in the diff that wasn't asked for (scope creep); (c) requirements that look implemented but where the implementation looks wrong. Quote the spec line for each finding. Under 400 words."

If the spec is missing, skip the Spec sub-agent and note this in the final report.

### 5. Aggregate

Re-check validated findings against the exact captured diff and repository evidence. Remove duplicates, stale or speculative claims, low-confidence issues, style-only feedback, unrelated pre-existing issues, and findings already clearly covered by current review feedback when that feedback is available. Prefer one finding per root cause and keep remediation proportional to the defect.

Classify each remaining confirmed finding as inline when its file and head-side changed line can be anchored in the captured diff; adjust only to a nearby relevant changed line. When a finding's own reported line is not itself the changed line used for its anchor, strip any `suggestion` block from its message before submission because GitHub would apply the block to the moved anchor rather than the line the finding actually describes. Put genuine but unanchorable confirmed findings in `summary_only` with a short reason.

Before returning any top-level text in PR mode, including no-finding and summary-only fallback results, invoke `bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" validate`. If validation fails, stop. If there are no confirmed findings or material verification notes, return exactly `No noteworthy issues found.` Do not post an empty review.

For findings, the `prepare` and `context` operations in section 1 have already created the empty payload files and pinned the review context. Do not run them again. Use the edit tool only for `$HOME/.config/opencode/review-state/initial.json`, writing exactly `{body, comments}` with a nonempty body and inline comments array. Every single-line comment must have exactly `body`, `line`, `path`, and `side`; `line` is a positive integer and `side` is `LEFT` or `RIGHT`. A multiline comment additionally has exactly `start_line` and `start_side`; `start_line` is a positive integer no greater than `line`, and `start_side` equals `side`.

```json
{
  "body": "OpenCode PR Review: 1 inline finding(s).",
  "comments": [
    {
      "body": "**important · authorization-boundary**\n\nFinding text.",
      "line": 12,
      "path": "path/to/file",
      "side": "RIGHT"
    }
  ]
}
```

The helper adds the trusted `commit_id` and `event` itself. Preserve each confirmed finding message's Markdown, including paragraph breaks and fenced code or `suggestion` blocks, except for a `suggestion` block stripped for a relocated anchor. Each inline body is `**<severity> · <dynamic-role>**`, followed by a blank line and the finding message.

Every confirmed finding with a valid diff anchor must be included in the `comments` array and submitted as an inline review comment. Never return anchorable findings only as top-level assistant text. If structured submission fails, fail the run instead of emitting the findings as a top-level completion comment.

When there are summary-only findings, the body begins `OpenCode PR Review: <N> inline finding(s), <M> summary-only finding(s).` and lists them. Otherwise it begins `OpenCode PR Review: <N> inline finding(s).` Never use issue comments or `gh pr comment`.

## 6. Submit through the constrained helper

Use only these exact commands:

```sh
"$HOME/.config/opencode/scripts/review-pr-submit.sh" validate-initial
"$HOME/.config/opencode/scripts/review-pr-submit.sh" submit-initial
"$HOME/.config/opencode/scripts/review-pr-submit.sh" update
```

After the single `prepare` in section 1, write the initial payload only to `$HOME/.config/opencode/review-state/initial.json`, then run `validate-initial`. Validation is non-mutating and reports the exact invalid field. Correct validation failures only in `initial.json` and rerun `validate-initial`; never create diagnostic or test findings. Once validation succeeds, the payload is sealed: do not modify it or run validation again. Run `submit-initial` exactly once. Any submission failure must immediately terminate the review and fail the run. Before `update`, write exactly `{body}` only to `$HOME/.config/opencode/review-state/update.json`. Never add arguments, redirections, pipelines, or process substitutions to helper commands.

You never pass a repository, PR number, target commit, or review ID: the helper derives the repository and PR number from the trusted GitHub Actions context, pins the write to the head commit from the same context, and updates only the review ID it recorded when the initial submission succeeded in this run. It validates the trusted event context, Git identity and authentication, temporary payload, target commit, HTTP method, and exact pull-request-review endpoint.

After successful inline submission, do not repeat findings in the final assistant output. Update the submitted review with final status and the run URL when available; the helper targets the review it recorded, so no review ID is passed. If GitHub rejects inline anchors, fail the run without retrying or posting a fallback. If no inline anchors remain before validation, return the concise markdown fallback instead of submitting an empty comments array.

Do not clean, reset, restore, stash, commit, or push anything.
