# Frogbot Curation Gate — Option B

Post-PR safety net that runs `jf curation-audit` on every Frogbot-generated fix PR (and any other dependency PR you choose to gate) and reports blocked packages back on the pull request before a human clicks *Merge*.

**One-line summary:** *Frogbot proposes → the gate audits against Curation → if blocked packages are found, the check goes red and a sticky PR comment lists what's wrong.*

---

## Why this exists

Frogbot v3 selects fix versions from **Xray's vulnerability database**. It has no visibility into **JFrog Curation** policies. Those are two independent systems:

- **Xray** tells Frogbot: *"jose4j 0.9.4 has CVE-YYYY-NNNNN; the lowest safe version is 0.9.6."*
- **Curation** decides at *resolution time* whether jose4j 0.9.6 is even allowed into your builds (license risk, operational risk, malware indicators, custom org policy).

Result: Frogbot happily proposes a version that your Curation policy will 403 the moment a developer tries to build the merged PR. This gate closes that loop by making the mismatch visible on the PR itself.

If you'd rather prevent the bad PRs from ever being opened, see the sister action [`curated-autofix`](../curated-autofix/README.md) (Option C). Both can coexist — Option B then serves as the safety net for any dependency PR authored *outside* the curated pipeline (humans, Renovate, Dependabot).

---

## How it works

```text
┌────────────────────────────────────────────────────────────────────┐
│  Frogbot opens fix PR  (branch: frogbot-…)                          │
│                                                                     │
│  ↓ triggers                                                         │
│                                                                     │
│  frogbot-curation-gate.yml                                          │
│    └── .github/actions/curation-check                               │
│          1. setup JDK 21 + Maven cache                              │
│          2. setup JFrog CLI via OIDC                                │
│          3. jf mvn-config → resolve through curated virtual         │
│          4. jf curation-audit --format=json                         │
│          5. walk JSON tree, collect status=="blocked" entries       │
│          6. emit ::error annotations (Checks tab)                   │
│          7. post/update sticky PR comment (marker: <!-- … -->)      │
│          8. exit 1 if any blocked package (advisory mode)           │
└────────────────────────────────────────────────────────────────────┘
```

The gate is deliberately *idempotent* and *sticky*: re-runs on the same PR (e.g., after a `synchronize` event) find the existing comment via a hidden HTML marker and update it in place rather than piling up.

---

## Files

| Path | Purpose |
|---|---|
| `.github/actions/curation-check/action.yml` | Composite action — sets up tooling, runs the audit, writes the PR comment |
| `.github/workflows/frogbot-curation-gate.yml` | Workflow that fires on `pull_request` for `frogbot-*` branches |

---

## Prerequisites

- **JFrog Curation entitlement** on the target platform (paid add-on to Xray). Without it, `jf curation-audit` returns unauthorized and the gate degrades to a "tool error" comment.
- **OIDC provider** configured in JFrog with an identity mapping that grants Curation read + Xray audit permissions to the GitHub Actions issuer. In the WebGoat setup this is `github-frogbot` on `psazuse.jfrog.io`.
- **Repository secret `JF_URL`** pointing to the JFrog Platform base URL (e.g. `https://psazuse.jfrog.io/`).
- **Frogbot already installed and running** — the gate audits Frogbot's output, it doesn't replace anything.

---

## Configuration

### Composite action inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `working-directory` | no | `.` | Directory containing the `pom.xml` to audit |
| `deps-repo` | **yes** | — | Curated virtual Artifactory repo (e.g. `cg-lab-mvn-by-virtual`) |
| `jf-url` | **yes** | — | JFrog Platform base URL |
| `oidc-provider-name` | **yes** | — | OIDC provider used by `jfrog/setup-jfrog-cli@v4` |
| `fail-on-blocked` | no | `true` | Exit non-zero if any blocked packages are found |
| `comment-on-pr` | no | `true` | Post/update a sticky PR comment with the summary |

### Composite action outputs

| Output | Description |
|---|---|
| `blocked-count` | Number of packages blocked by Curation policies |

### Workflow trigger

`frogbot-curation-gate.yml` is scoped to Frogbot PRs via a branch-name filter:

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened]
    branches: [main, frogbotv3]
jobs:
  curation-check:
    if: startsWith(github.head_ref, 'frogbot-')
```

The `if:` condition is why regular developer PRs don't pay the price of a Curation audit on every push. Widen it (or drop it) if you want to gate every dependency-touching PR, not just Frogbot's.

---

## Enforcement modes

The action always fails the check (red X on the PR) when blocked packages are found. What varies is whether the failing check *blocks* the merge:

| Mode | Setup | Behavior |
|---|---|---|
| **Advisory** *(default)* | Do nothing extra | Red X + PR comment. Merge remains possible for reviewers who override. Good for the first weeks while you calibrate policies. |
| **Hard gate** | Add `Frogbot Curation Gate / curation-check` to required status checks under *Settings → Branches → Branch protection rules → main* | Merge button is disabled until the check passes. Recommended once the false-positive rate is understood. |

Switching between the two is a GitHub Settings change only — no code change is required.

---

## Example PR comment shapes

**Green case:**

> ## Frogbot Curation Gate — passed
> All dependencies in this PR pass Curation policies on `cg-lab-mvn-by-virtual`.

**Blocked case (real example format):**

> ## Frogbot Curation Gate — 2 blocked package(s)
>
> This PR includes package versions that violate Curation policies on `cg-lab-mvn-by-virtual`. Merging will break dependency resolution.
>
> | Package | Version | Policy | Reason |
> |---|---|---|---|
> | `org.bitbucket.b_c:jose4j` | `0.9.6` | operational-risk-critical | Package inactive for > 12 months |
> | `com.thoughtworks.xstream:xstream` | `1.4.20` | license-review-required | GPL family; needs legal sign-off |
>
> **Options:**
> - Adjust the Xray watch to prefer a different fix version
> - Update the Curation policy if this is a false positive
> - Close this PR and let Frogbot regenerate with fresh candidates

Each blocked package also emits `::error` annotations that appear on the *Checks* tab.

---

## Testing

1. **Trigger it manually** by opening a dummy PR with a version bump:
   ```bash
   git checkout -b frogbot-manual-test frogbotv3
   # edit pom.xml to bump some dep to a version you know Curation blocks
   git commit -am "test: trigger curation gate"
   git push -u origin frogbot-manual-test
   gh pr create --base frogbotv3 --head frogbot-manual-test \
     --title "test: curation gate" --body "verifying gate behavior"
   ```
   The `startsWith(github.head_ref, 'frogbot-')` filter matches, and the workflow fires.

2. **Verify a real Frogbot PR** — every time Frogbot's own workflow (or the [curated-autofix pipeline](../curated-autofix/README.md)) opens a PR, this gate runs alongside the normal CI. Look at the *Checks* tab for `Frogbot Curation Gate / curation-check` and the PR conversation for the sticky comment.

3. **Confirm annotations attach.** Blocked packages should appear as red-triangle annotations in the *Checks* tab under this workflow's job.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Comment says *"audit tool error"* | OIDC token doesn't have Curation read permission | Widen the identity mapping in JFrog to include the Curation permission group |
| Gate always passes on visibly-blocked packages | Local `.jfrog/projects/maven.yaml` points to a non-curated repo, overriding the fresh config | The composite action already overwrites this — check the *Point Maven at the curated virtual repo* step logs for an error |
| Gate never runs on Frogbot PRs | Frogbot's branch prefix changed, or the workflow is looking at the wrong `branches:` | Check `github.head_ref` in the failing run and adjust the `if:` filter |
| Comment posted twice on the same PR | Sticky marker was manually stripped by an earlier comment edit | The marker is `<!-- frogbot-curation-gate -->` — leave it in place |

---

## Limitations

1. **Reactive, not preventive.** The PR is already open by the time this runs. If Curation blocks a package, the developer sees the red X but the PR itself exists and takes up notification bandwidth. Use [`curated-autofix`](../curated-autofix/README.md) (Option C) if you'd rather never see the bad PR.
2. **Depends on Frogbot's fix branch naming.** If Frogbot changes its branch prefix in a future major version, the `if:` filter will need updating. As of Frogbot v3.1.2 the prefix is stable as `frogbot-`.
3. **Maven only in this repo.** Add a parallel step for Gradle (`jf gradle-config` + `jf curation-audit`) if you want to gate Gradle-based Frogbot PRs too.

---

## See also

- [Curated Autofix (Option C)](../curated-autofix/README.md) — replaces Frogbot's fix-PR path so only Curation-approved PRs are ever opened
- [Frogbot v3 workflow](../../workflows/frogbot-v3.yml) — the upstream that produces the PRs this gate audits
- [`jf curation-audit` docs](https://jfrog.com/help/r/jfrog-security-user-guide/jfrog-curation) — official reference for the audit command
