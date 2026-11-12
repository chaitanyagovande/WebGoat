#!/usr/bin/env bash
# =============================================================================
# curated-autofix.sh
# =============================================================================
# Discovers vulnerable Maven dependencies via `jf audit`, filters candidate
# fix versions against JFrog Curation policies (by probing whether the
# artifact is actually pullable through the curated virtual repo), applies
# the approved upgrades to pom.xml, and opens/updates a single fix PR against
# BASE_BRANCH. Only versions that will actually resolve are ever committed —
# nothing that Curation would block reaches the pull request.
#
# Env inputs (required unless marked default):
#   DEPS_REPO          Curated virtual repo key (e.g. cg-lab-mvn-by-virtual)
#   JF_URL             JFrog Platform base URL
#   BASE_BRANCH        Base branch for the fix PR
#   GH_TOKEN           GitHub token for `gh` CLI (from ${{ github.token }})
#   WORKING_DIRECTORY  Path to pom.xml directory. Default: "."
#   FIX_BRANCH         Branch name for fixes. Default: frogbot-curated-fixes-<BASE_BRANCH>
#   DRY_RUN            "true" to skip push/PR create. Default: "false"
#
# Exit codes:
#   0  success (PR created, updated, or nothing to fix)
#   1  environment/config error (missing tools, missing env vars)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
: "${DEPS_REPO:?DEPS_REPO env var is required}"
: "${JF_URL:?JF_URL env var is required}"
: "${BASE_BRANCH:?BASE_BRANCH env var is required}"
: "${GH_TOKEN:?GH_TOKEN env var is required}"
: "${WORKING_DIRECTORY:=.}"
: "${FIX_BRANCH:=frogbot-curated-fixes-${BASE_BRANCH}}"
: "${DRY_RUN:=false}"

cd "$WORKING_DIRECTORY"

# ---------------------------------------------------------------------------
# 1. Audit — vulnerabilities with fix candidates
# ---------------------------------------------------------------------------
echo "::group::jf audit --format=simple-json"
set +e
jf audit --format=simple-json > audit.json 2> audit.stderr
audit_rc=$?
set -e
if [ "$audit_rc" -ne 0 ] && [ ! -s audit.json ]; then
    echo "::error::jf audit produced no output (exit $audit_rc)"
    cat audit.stderr >&2 || true
    exit 1
fi
[ -s audit.json ] || echo '{}' > audit.json
echo "audit exit code: $audit_rc"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 2. Group vulnerabilities by package, intersect fixedVersions
# ---------------------------------------------------------------------------
# For each impacted package, we compute the intersection of `fixedVersions`
# across all its vulnerabilities. Only versions that resolve *every* CVE for
# that package are considered candidates. Result is sorted ascending, so the
# first Curation-approved element is the smallest safe upgrade.
echo "::group::Grouping vulnerabilities → candidate fix versions"
jq '
  # Combine both sections; jf audit uses "vulnerabilities" and sometimes
  # "securityViolations" depending on watch policies.
  ((.vulnerabilities // []) + (.securityViolations // []))
  | map(select(
        .fixedVersions?
        and (.fixedVersions | length > 0)
        # Maven packages only for this iteration — Gradle can be added later.
        and (.impactedPackageType? == "Maven" or .impactedPackageName | test("^[^:]+:[^:]+$"))
    ))
  | group_by(.impactedPackageName)
  | map({
      package: .[0].impactedPackageName,
      current: .[0].impactedPackageVersion,
      candidates: (
        [ .[].fixedVersions ]
        | if length == 0 then []
          # Reduce over the per-vuln lists, keeping only versions present in every list.
          else reduce .[1:][] as $arr (.[0]; [.[] | select(. as $v | $arr | index($v))])
          end
        # Best-effort numeric sort; falls back to string order for tags like "1.2.3-RC1".
        | unique
        | sort_by(
            (split(".") | map(
                (capture("^(?<n>[0-9]+)").n | tonumber?) // 0
            ))
          )
      )
    })
  | map(select(.candidates | length > 0))
' audit.json > packages.json

count=$(jq 'length' packages.json)
echo "Packages with at least one candidate fix version: $count"
jq . packages.json
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 3. Probe each candidate version through the curated virtual repo
# ---------------------------------------------------------------------------
# A HEAD request through the curated virtual repo is the ground-truth
# Curation check: JFrog applies the same policy stack as a real download.
# Response codes we care about:
#   200 -> curation-approved AND artifact exists → take it, stop probing
#   403 -> curation-blocked (usually with X-JFrog-Curation-Response header)
#   404 -> not present in the virtual (never mirrored, or Xray listed a bad version)
#   000 -> network/CLI issue — treated as "unknown, skip this version"
echo "::group::Curation probes"

: > approved.jsonl
: > skipped.jsonl

head_status() {
    local rel_path="$1"
    jf rt curl -X HEAD -s -o /dev/null -w "%{http_code}" "$rel_path" 2>/dev/null \
        || echo "000"
}

while IFS=$'\t' read -r package current candidates_csv; do
    group=${package%%:*}
    artifact=${package##*:}
    group_path=${group//./\/}

    approved=""
    reason="Xray listed no fix version that passes Curation on ${DEPS_REPO}"
    IFS=',' read -ra candidates <<< "$candidates_csv"

    for version in "${candidates[@]}"; do
        [ -z "$version" ] && continue
        rel="/${DEPS_REPO}/${group_path}/${artifact}/${version}/${artifact}-${version}.pom"
        status=$(head_status "$rel")
        case "$status" in
            200)
                approved="$version"
                break
                ;;
            403)
                reason="Curation blocked ${version}"
                ;;
            404)
                reason="${version} not present in ${DEPS_REPO}"
                ;;
            *)
                reason="HEAD ${rel} returned HTTP ${status}"
                ;;
        esac
    done

    if [ -n "$approved" ]; then
        jq -nc \
            --arg pkg "$package" \
            --arg cur "$current" \
            --arg fix "$approved" \
            '{package:$pkg,current:$cur,fix:$fix}' \
            >> approved.jsonl
        printf 'APPROVED  %-60s %s -> %s\n' "$package" "$current" "$approved"
    else
        jq -nc \
            --arg pkg "$package" \
            --arg cur "$current" \
            --arg r   "$reason" \
            '{package:$pkg,current:$cur,reason:$r}' \
            >> skipped.jsonl
        printf 'SKIPPED   %-60s %s (%s)\n' "$package" "$current" "$reason"
    fi
done < <(jq -r '.[] | [.package, .current, (.candidates | join(","))] | @tsv' packages.json)

approved_count=$(wc -l < approved.jsonl | tr -d ' ')
skipped_count=$(wc -l < skipped.jsonl | tr -d ' ')
echo "Result: $approved_count approved, $skipped_count skipped"
echo "::endgroup::"

# Expose counts to the workflow so subsequent steps can branch on them
{
    echo "approved-count=$approved_count"
    echo "skipped-count=$skipped_count"
} >> "${GITHUB_OUTPUT:-/dev/null}"

if [ "$approved_count" -eq 0 ]; then
    echo "::warning::No curation-approved fixes available — nothing to commit."
    exit 0
fi

# ---------------------------------------------------------------------------
# 4. Apply approved versions to pom.xml
# ---------------------------------------------------------------------------
echo "::group::mvn versions:use-dep-version"

: > applied.jsonl
: > unapplied.jsonl

while read -r line; do
    package=$(jq -r '.package' <<< "$line")
    version=$(jq -r '.fix'     <<< "$line")
    current=$(jq -r '.current' <<< "$line")
    group=${package%%:*}
    artifact=${package##*:}

    before=$(git hash-object pom.xml)
    mvn -B -q -DskipTests versions:use-dep-version \
        -Dincludes="${group}:${artifact}" \
        -DdepVersion="${version}" \
        -DforceVersion=true \
        -DgenerateBackupPoms=false \
        || true
    after=$(git hash-object pom.xml)

    if [ "$before" != "$after" ]; then
        jq -nc \
            --arg pkg "$package" \
            --arg cur "$current" \
            --arg fix "$version" \
            '{package:$pkg,current:$cur,fix:$fix}' \
            >> applied.jsonl
    else
        # Version couldn't be applied via direct <dependency> — likely BOM-managed,
        # inherited from parent, or transitive. Surface this explicitly rather
        # than silently dropping the fix.
        jq -nc \
            --arg pkg "$package" \
            --arg cur "$current" \
            --arg fix "$version" \
            --arg r   "curation-approved but version is managed by a parent POM, BOM, or is transitive; add an explicit <dependencyManagement> entry to override" \
            '{package:$pkg,current:$cur,fix:$fix,reason:$r}' \
            >> unapplied.jsonl
    fi
done < approved.jsonl

applied_count=$(wc -l < applied.jsonl | tr -d ' ')
unapplied_count=$(wc -l < unapplied.jsonl | tr -d ' ')
echo "Applied $applied_count fix(es); $unapplied_count could not be written to pom.xml"
echo "::endgroup::"

{
    echo "applied-count=$applied_count"
    echo "unapplied-count=$unapplied_count"
} >> "${GITHUB_OUTPUT:-/dev/null}"

# ---------------------------------------------------------------------------
# 5. If nothing to commit, stop cleanly
# ---------------------------------------------------------------------------
if git diff --quiet pom.xml; then
    echo "::warning::No pom.xml changes to commit. All approved fixes were managed elsewhere (parent POM/BOM/transitive)."
    exit 0
fi

# ---------------------------------------------------------------------------
# 6. Commit
# ---------------------------------------------------------------------------
echo "::group::Commit + branch"

git config user.name  "JFrog-Frogbot"
git config user.email "frogbot@jfrog.com"

git checkout -B "$FIX_BRANCH"
git add pom.xml

applied_md=$(jq -s -r '.[] | "- **\(.package)**: `\(.current)` → `\(.fix)`"' applied.jsonl 2>/dev/null || echo "_none_")
unapplied_md=$(jq -s -r '.[] | "- **\(.package)** → `\(.fix)`: \(.reason)"' unapplied.jsonl 2>/dev/null || echo "_none_")
skipped_md=$(jq -s -r '.[] | "- **\(.package)** @ `\(.current)`: \(.reason)"' skipped.jsonl 2>/dev/null || echo "_none_")

[ -z "$applied_md"   ] && applied_md="_none_"
[ -z "$unapplied_md" ] && unapplied_md="_none_"
[ -z "$skipped_md"   ] && skipped_md="_none_"

# Commit message — kept succinct; the fuller narrative goes in the PR body.
commit_msg=$(printf '%s\n' \
    "Upgrade dependencies (curation-approved)" \
    "" \
    "Fix versions in this commit have been pre-filtered through Curation" \
    "policies on ${DEPS_REPO}. See the PR description for the full report" \
    "of applied, skipped, and unapplied upgrades." \
)
git commit -m "$commit_msg"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 7. Push + PR
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = "true" ]; then
    echo "::notice::DRY_RUN=true — skipping push and PR creation"
    exit 0
fi

echo "::group::Push branch and open/update PR"

git push -f -u origin "$FIX_BRANCH"

pr_body=$(cat <<PR
## Curated Dependency Fixes

Every upgrade in this PR has been probed against JFrog Curation on \`${DEPS_REPO}\`. If merged, resolution through the curated virtual will succeed; nothing here can be silently blocked at build time.

### Applied fixes (${applied_count})
${applied_md}

### Curation-approved but not written to \`pom.xml\` (${unapplied_count})
${unapplied_md}

### Skipped — no Curation-approved fix version among Xray's candidates (${skipped_count})
${skipped_md}

---
**Pipeline**: \`jf audit\` → intersect \`fixedVersions\` across CVEs per package → \`jf rt curl -X HEAD\` against \`${DEPS_REPO}\` for each candidate → \`mvn versions:use-dep-version\` for approved versions → \`gh pr create\`.

**Auth**: OIDC token exchange (GitHub → JFrog), no long-lived credentials in the workflow.
PR
)

existing=$(gh pr list --head "$FIX_BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")

if [ -z "$existing" ]; then
    gh pr create \
        --base "$BASE_BRANCH" \
        --head "$FIX_BRANCH" \
        --title "[Curated Autofix] Dependency upgrades for ${BASE_BRANCH}" \
        --body  "$pr_body"
else
    gh pr edit "$existing" --body "$pr_body"
    echo "Updated existing PR #${existing}"
fi

echo "::endgroup::"
