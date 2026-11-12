# Frogbot Curated Autofix — Option C

Replacement for Frogbot v3's built-in fix-PR feature. Uses `jf audit` for vulnerability discovery, pre-validates every candidate fix version against JFrog Curation policies via HEAD probes, and opens or updates a single PR containing *only* upgrades that will actually resolve through the curated virtual repo.

**One-line summary:** *Xray finds vulns → we intersect fix candidates → HEAD-probe each through the curated repo → apply the approved versions with Maven → open one clean PR. No Curation-blocked upgrades ever leave the runner.*

---

## Why this exists

Frogbot v3 has no hook between "picked a fix version" and "opened the PR." It doesn't know your Curation policies exist, so it routinely proposes versions that Curation refuses to serve. Every such PR then costs a reviewer's attention: they either investigate why the build breaks after merge, or they run the [curation-gate](../curation-check/README.md) (Option B) and see the red X after the fact.

This action closes that loop *before* the PR gets created. It reuses Frogbot's underlying vulnerability engine (`jf audit`, same Xray backend Frogbot itself calls) but keeps the fix-selection step under our control so we can filter out blocked versions and only surface a PR when there's something clean to propose.

If you can't turn off Frogbot's built-in autofix, Option B is the fallback. Option C is the primary path when you have full control of the pipeline.

---

## How it works

```text
push to <base-branch>
   │
   ▼
frogbot-curated-autofix.yml
   └── .github/actions/curated-autofix
         ├── setup JDK 21 + Maven cache
         ├── setup JFrog CLI via OIDC
         ├── jf mvn-config → resolve through curated virtual
         └── scripts/curated-autofix.sh
              ┌─ 1. jf audit --format=simple-json          → audit.json
              ├─ 2. jq → group by package,                → packages.json
              │        intersect fixedVersions across CVEs,
              │        sort ascending
              ├─ 3. for each candidate version:            → approved.jsonl
              │        jf rt curl -X HEAD /<repo>/…/vX.pom   skipped.jsonl
              │          200 → approved, stop probing
              │          403 → curation-blocked, try next
              │          404 → not in repo, try next
              ├─ 4. mvn versions:use-dep-version           → applied.jsonl
              │        --hash pom.xml before/after           unapplied.jsonl
              │        to detect BOM/transitive cases
              ├─ 5. commit to frogbot-curated-fixes-<base>
              └─ 6. gh pr create / gh pr edit (idempotent)
```

Key design choices:

- **`jf audit` as the vuln source, not Frogbot.** Same Xray backend Frogbot uses, but without the fix-PR side effect.
- **HEAD-request through the curated virtual is the ground-truth Curation check.** Same request a Maven resolve would make — if it 403s here it'd 403 in a developer's build.
- **Intersection of `fixedVersions` across a package's CVEs.** If jose4j has three CVEs each listing different `fixedVersions`, we need the lowest version present in *all* lists — otherwise we'd fix one CVE and leave others open.
- **Version-hash before/after each `mvn` call.** Detects cases where a "successful" `versions:use-dep-version` didn't actually change the pom (BOM-managed, parent-inherited, or transitive). Those show up in the PR under "Curation-approved but not written to pom.xml" so nothing is silently dropped.
- **Deterministic branch name, force-pushed.** `frogbot-curated-fixes-<base-branch>`. Re-runs update the same PR instead of piling up new branches.

---

## Files

| Path | Purpose |
|---|---|
| `.github/actions/curated-autofix/action.yml` | Composite action — wires JDK, JFrog CLI (OIDC), Maven config, and the shell script |
| `.github/actions/curated-autofix/scripts/curated-autofix.sh` | Orchestration logic (~260 lines) |
| `.github/workflows/frogbot-curated-autofix.yml` | Push-triggered workflow (also `workflow_dispatch` with a `dry-run` toggle) |
| `.github/workflows/frogbot-v3.yml` | *Modified*: sets `JF_SKIP_AUTOFIX: "true"` so Frogbot's own fix PR doesn't race this one |

---

## Prerequisites

- **JFrog Curation entitlement** on the target platform. Without it, the HEAD probes return 200 for everything and the "filter" is a no-op.
- **OIDC provider** in JFrog with an identity mapping granting:
  - `jf audit` — Xray read + audit permissions on the target project/repo
  - HEAD requests through the curated virtual repo
- **Repository secret `JF_URL`** set to the JFrog Platform base URL.
- **`JF_SKIP_AUTOFIX: "true"`** in the existing `frogbot-v3.yml` so Frogbot's native autofix doesn't create a competing PR. Already applied on this branch.
- **Standard `github.token`** permissions on the workflow: `contents: write`, `pull-requests: write`, `id-token: write` (all declared in the workflow file).

---

## Configuration

### Composite action inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `working-directory` | no | `.` | Directory containing the `pom.xml` |
| `deps-repo` | **yes** | — | Curated virtual Artifactory repo (e.g. `cg-lab-mvn-by-virtual`) |
| `jf-url` | **yes** | — | JFrog Platform base URL |
| `oidc-provider-name` | **yes** | — | OIDC provider for `jfrog/setup-jfrog-cli@v4` |
| `base-branch` | **yes** | — | Base branch the fix PR targets (typically the branch being pushed to) |
| `fix-branch` | no | `frogbot-curated-fixes-<base>` | Override the deterministic fix branch name |
| `dry-run` | no | `false` | If `true`, print planned changes but do not push or open a PR |
| `github-token` | **yes** | — | Token for `gh` CLI (pass `${{ github.token }}`) |

### Composite action outputs

| Output | Description |
|---|---|
| `approved-count` | Packages with at least one curation-approved fix version |
| `skipped-count` | Packages where no candidate passed Curation |
| `applied-count` | Fixes actually written to `pom.xml` |
| `unapplied-count` | Approved fixes that couldn't be written (parent/BOM/transitive) |

### Workflow triggers

`frogbot-curated-autofix.yml` fires on:

- `push` to `main` or `frogbotv3` (the primary path)
- `workflow_dispatch` with a `dry-run` input (`true`/`false`), useful for smoke testing

The workflow does *not* run on `pull_request` — it's an author, not a validator. Validation is [`curation-check`](../curation-check/README.md)'s job.

---

## Example PR body

```markdown
## Curated Dependency Fixes

Every upgrade in this PR has been probed against JFrog Curation on
`cg-lab-mvn-by-virtual`. If merged, resolution through the curated
virtual will succeed; nothing here can be silently blocked at build time.

### Applied fixes (2)
- **org.bitbucket.b_c:jose4j**: `0.9.4` → `0.9.6`
- **com.thoughtworks.xstream:xstream**: `1.4.19` → `1.4.20`

### Curation-approved but not written to pom.xml (1)
- **org.apache.tomcat.embed:tomcat-embed-core** → `10.1.20`:
  curation-approved but version is managed by a parent POM, BOM, or is
  transitive; add an explicit <dependencyManagement> entry to override

### Skipped — no Curation-approved fix version among Xray's candidates (0)
_none_

---
Pipeline: jf audit → intersect fixedVersions across CVEs per package →
jf rt curl -X HEAD against cg-lab-mvn-by-virtual for each candidate →
mvn versions:use-dep-version → gh pr create.

Auth: OIDC token exchange (GitHub → JFrog), no long-lived credentials.
```

Every category is present even when empty, so reviewers always know exactly what fell into each bucket.

---

## Testing

### 1. Dry-run

Run without side effects to smoke-test the pipeline:

```
GitHub → Actions → Frogbot Curated Autofix → Run workflow → dry-run: true
```

Look for these log groups in order:

- `jf audit --format=simple-json` → non-zero exit is OK as long as `audit.json` has content
- `Grouping vulnerabilities → candidate fix versions` → shows packages + their candidate lists
- `Curation probes` → one line per candidate probed with HTTP code
- `mvn versions:use-dep-version` → per-fix apply attempt
- Final `DRY_RUN=true — skipping push and PR creation` notice

### 2. Live run

Push an empty commit:

```bash
git commit --allow-empty -m "trigger: curated autofix" && git push
```

Verify:

- Exactly one PR exists on the base branch, named `[Curated Autofix] Dependency upgrades for <base>`
- The PR body matches the template above with populated numbers
- No competing PR from Frogbot's built-in autofix (that path is disabled by `JF_SKIP_AUTOFIX: "true"`)

### 3. Force a Curation rejection

Add a stricter policy in JFrog (e.g., temporarily block `xstream:1.4.20`) and re-run. The PR body should now show xstream under *Skipped* with the specific reason and, if Xray listed higher fix versions, probe them next. Roll back the policy afterwards.

### 4. Verify idempotence

Push another empty commit without changing anything upstream. The existing PR should be *updated in place* (same branch, same PR number) rather than a duplicate being opened. The commit history on the fix branch will show a single rewritten commit because we force-push.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| PR body says "no curation-approved fixes" but you know there are vulns | HEAD probes all returning 403 → Curation is stricter than expected, or every proposed version predates a policy start date | Review JFrog Curation policies; whitelist known-good versions if needed |
| Approved fixes end up in "not written to pom.xml" | Version is inherited from `spring-boot-starter-parent` or a `<dependencyManagement>` BOM | Add an explicit `<dependencyManagement>` override in `pom.xml`, then re-run |
| `jf audit` returns "unauthorized" | OIDC identity mapping is missing Xray audit permissions | Widen the mapping in JFrog to include the Xray audit permission group |
| `jf rt curl -X HEAD` returns `000` for every probe | Network/CLI issue, or the OIDC token has no read permission on the virtual repo | Check the *Set up JFrog CLI (OIDC)* step log, verify `jf rt search` works from a manual run |
| A duplicate PR appears from real Frogbot | `JF_SKIP_AUTOFIX` toggle in `frogbot-v3.yml` was reverted | Re-enable `JF_SKIP_AUTOFIX: "true"` |
| PR body shows a version *lower* than the current one | Xray listed only older `fixedVersions` (rare, usually indicates the vuln was mis-scoped) | Investigate the specific CVE in Xray; the pipeline refuses to downgrade via Maven's default behavior, so this should manifest as an "unapplied" entry |
| GitHub complains "resource not accessible by integration" when opening the PR | `pull-requests: write` permission missing on the workflow | Verify the workflow's `permissions:` block matches what's in `frogbot-curated-autofix.yml` |

---

## Limitations

1. **BOM-managed and transitive dependencies.** WebGoat pulls many versions from `spring-boot-starter-parent`. `mvn versions:use-dep-version` can only rewrite direct `<dependency>` declarations. Approved fixes that couldn't be written land in the *Curation-approved but not written to pom.xml* section of the PR body — never silently dropped. Fixing them requires either adding `<dependencyManagement>` overrides or a v2 enhancement to the script that emits BOM overrides automatically.
2. **Xray fix recommendations bound the search.** If Xray only lists `[0.9.5, 0.9.6]` as fixed versions, we won't try `0.9.7` even if it exists — Xray hasn't validated it fixes the CVE. If every Xray-listed version is Curation-blocked, the package is skipped.
3. **Maven only.** Gradle can be added by branching on `impactedPackageType` in `packages.json` and calling `gradle versions:use-latest-versions` (or an equivalent Gradle plugin). Keeps the composite action extensible without changing its interface.
4. **`workflow_dispatch` UI won't appear until the workflow is on the default branch.** GitHub platform limitation. Push-triggered runs work fine on any branch listed in `branches:`.
5. **Single PR per base branch.** All approved fixes are aggregated. If you'd rather have one PR per package, split the script's step 5 into a loop and change the branch name to include `${package}-${version}`.

---

## Relationship to Option B (Curation Gate)

| | **Option B — Curation Gate** | **Option C — Curated Autofix (this)** |
|---|---|---|
| Placement | Runs on the PR after it opens | Runs on the base branch, then opens the PR |
| Frogbot native autofix | Left enabled | **Disabled** via `JF_SKIP_AUTOFIX: "true"` |
| Blocks bad PRs from being *created* | No | **Yes** |
| Blocks bad PRs from being *merged* | Yes (advisory or hard gate) | N/A — bad PRs never exist |
| Handles PRs from humans / Renovate / Dependabot | Yes (if `if:` filter widened) | No |
| Cost per run | ~1 min | ~2–3 min (audit + probes + mvn apply) |
| Depends on Xray | Indirectly (Frogbot uses it) | **Yes** (`jf audit`) |
| Depends on Curation | **Yes** (`jf curation-audit`) | **Yes** (HEAD probes) |

**Recommended posture:** run *both* in parallel. Option C prevents Frogbot-authored bad PRs from ever existing. Option B catches any dependency PR opened outside the curated pipeline (a developer, Renovate, a security team member manually bumping something).

---

## See also

- [Curation Gate (Option B)](../curation-check/README.md) — post-PR gate; safety net for non-Frogbot dependency PRs
- [Frogbot v3 workflow](../../workflows/frogbot-v3.yml) — configured with `JF_SKIP_AUTOFIX: "true"` when Option C is in play
- [`jf audit` docs](https://jfrog.com/help/r/jfrog-cli/audit) — official reference for the audit command
- [`versions-maven-plugin` docs](https://www.mojohaus.org/versions/versions-maven-plugin/) — reference for `versions:use-dep-version` and related goals
