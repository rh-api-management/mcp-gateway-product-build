# ADR-001: Nightly Nudge PR Auto-merge Strategy

## Context

Konflux opens "nudge" PRs against the `nightly` branch whenever it builds new images for `mcp-gateway` or `mcp-gateway-operator`. These PRs update image digests in pullspec files and regenerate the operator bundle CSVs. For a fully automated nightly pipeline, these PRs must merge without human intervention.

Several approaches were tried before arriving at the current solution.

---

## Approaches tried

### 1. `gh pr merge --auto --squash` (rejected)

The initial workflow approved the PR and then called `gh pr merge --auto --squash`, which enables GitHub's built-in auto-merge feature — it merges automatically once all required status checks pass.

**Why it failed:** `--auto` requires that the target branch has required status checks configured in a branch protection rule or ruleset. The `nightly` ruleset only enforces `deletion` and `non_fast_forward` — there are no required checks. Without required checks, GitHub has no signal to trigger the auto-merge, so the PR just sits open indefinitely.

The error: `GraphQL: Pull request Branch does not have required protected branch rules (enablePullRequestAutoMerge)`.

Adding required checks to the nightly ruleset was explored but ruled out — GitHub Actions (app ID 15368) cannot be added as a ruleset bypass actor (`Actor GitHub Actions integration must be part of the ruleset source or owner organization`), which means the nightly submodule update workflow (which pushes directly to `nightly`) would also be blocked by any required checks.

---

### 2. Renovate + `generate-bundle.yml` only, no custom workflow (rejected)

JJ suggested relying entirely on Renovate's built-in rebase and auto-merge, combined with the existing `generate-bundle.yml` workflow to regenerate CSVs after rebase.

Renovate is configured on `nightly` with:
```json
"automerge": true,
"platformAutomerge": true,
"rebaseWhen": "behind-base-branch",
"recreateWhen": "always"
```

**Why it failed:** `generate-bundle.yml` uses a `pull_request` trigger. GitHub treats Konflux (a bot/app account) as an external contributor, so any `pull_request` workflow triggered by a Konflux PR is marked `action_required` — meaning a human must explicitly approve the workflow run before it executes. This is a GitHub security policy for bot accounts and cannot be bypassed without changing the trigger.

With `action_required` on `generate-bundle.yml`, the PR's merge state becomes `UNSTABLE`, which blocks Renovate's `platformAutomerge` from proceeding. The PRs never merge automatically.

This issue affects `rhcl-operator-product-build` and any other repo that relies on `pull_request` triggered workflows for bot PRs.

---

### 3. `pull_request_target` with `--squash` but no check waiting (rejected)

Switching from `pull_request` to `pull_request_target` solves the `action_required` problem — `pull_request_target` runs in the context of the base branch and is not gated for bot accounts. The workflow was updated to use `--squash --delete-branch` instead of `--auto --squash`.

However, a race condition remained: `generate-bundle.yml` also triggers when the nudge PR is opened (the pullspec files change). Both workflows start simultaneously. The auto-merge workflow checks `mergeable == MERGEABLE` (true, because the bundle commit hasn't landed yet), approves, and immediately tries to merge. Meanwhile `generate-bundle.yml` commits a bundle regeneration to the PR branch. By the time the merge runs, the branch has moved and GitHub rejects it:

`GraphQL: Head branch is out of date. Review and try the merge again.`

---

## Current solution

`pull_request_target` with check-waiting before merge.

The workflow:
1. Checks if the PR has merge conflicts
2. If conflicting: checks out the PR branch, rebases onto `nightly` with `-X theirs`, runs `generate-bundle.sh` to regenerate CSVs from the (now-correct) pullspec files, force-pushes
3. Approves the PR
4. Waits for all checks: `timeout 900 gh pr checks --watch --fail-fast`
5. Merges: `gh pr merge --squash --delete-branch`

**Why `pull_request_target`:** Runs in the base branch context, so it is not gated by `action_required` for bot PRs. The workflow file is read from `rhcl-1.4` (the default branch), not from the PR branch — this is why the workflow must live on `rhcl-1.4` even though it only triggers on PRs targeting `nightly`.

**Why wait for checks:** By the time all checks pass (Konflux pipeline + `generate-bundle.yml`), the `generate-bundle.yml` workflow has already committed its bundle regeneration. The branch is in its final settled state when the merge runs, eliminating the race condition.

**Why `-X theirs` + regenerate:** When two nudge PRs are open simultaneously, the second PR's CSVs conflict with the first PR's merged CSVs. `-X theirs` resolves the conflict by taking `nightly`'s version of conflicting hunks — which is safe because CSVs are derived artifacts. `generate-bundle.sh` then regenerates them from the split pullspec files (`bundle-generation/image-pullspecs/mcp-gateway.yaml` and `mcp-gateway-operator.yaml`), which never conflict because each nudge PR only touches its own file.

**Why the concurrency group matters:** `cancel-in-progress: false` ensures that when two nudge PRs are open, the second workflow run queues rather than cancelling. The first PR merges, which updates `nightly`, which triggers Renovate to rebase the second PR — at which point the second workflow run proceeds.

---

## Files involved

| File | Branch | Purpose |
|------|--------|---------|
| `.github/workflows/auto-merge-nudge.yml` | `rhcl-1.4` | Core auto-merge workflow (`pull_request_target`, runs for PRs targeting `nightly`) |
| `.github/workflows/generate-bundle.yml` | `nightly`, `rhcl-1.4` | Regenerates bundle CSVs on push/PR; `nightly` branch added to triggers |
| `.github/workflows/nightly-submodule-update.yml` | `rhcl-1.4` | Scheduled: updates `mcp-gateway` submodule on `nightly` to latest `main` |
| `bundle-generation/image-pullspecs/mcp-gateway.yaml` | `nightly` | Split pullspec file for mcp-gateway (one per component, prevents conflicts) |
| `bundle-generation/image-pullspecs/mcp-gateway-operator.yaml` | `nightly` | Split pullspec file for mcp-gateway-operator |
| `renovate.json` | `nightly` | Renovate config with `rebaseWhen: "behind-base-branch"` |
