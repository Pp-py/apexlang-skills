#!/usr/bin/env bash
# The CI example (docs/examples/ci/apexlang-static-gates.yml) runs as written: its scan step,
# taken verbatim from the file, over a scratch project built from the runnable examples, with
# this checkout standing in for the pinned release.
#   * every script it names exists, and the five scans PASS on the examples (exit 0);
#   * each writes its result into the run's task dir; a planted defect fails the job.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
YML="$REPO/docs/examples/ci/apexlang-static-gates.yml"
EX="$REPO/skills/apexlang-architecture/examples"
PY=$(command -v python3 || command -v python || true)
[[ -n "$PY" ]] || { echo "ci-example: BLOCKED — python3 is required" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ci-example-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); sed 's/^/       | /' "$WORK/log" 2>/dev/null | tail -12; }

# The step's script: the lines under `run: |` of the scan step, de-indented.
"$PY" - "$YML" > "$WORK/step.sh" <<'PY'
import sys
lines, out, on = open(sys.argv[1], encoding="utf-8").read().split("\n"), [], False
for ln in lines:
    if ln.strip().startswith("- name: the five static scans"):
        on = "name"
    elif on == "name" and ln.strip() == "run: |":
        on = "run"
    elif on == "run":
        if ln.strip().startswith("- name:"):
            break
        out.append(ln[10:] if ln.startswith(" " * 10) else ln.strip())
print("\n".join(out))
PY
# shellcheck disable=SC2016   # the step's own text, matched literally
if grep -q 'sec-scan.py' "$WORK/step.sh" && grep -q 'exit "$worst"' "$WORK/step.sh"; then ok "the scan step is read from the example"; else bad "the scan step was not found in the example"; fi
# shellcheck disable=SC2016   # `$K` is the step's variable, matched literally
grep -o '\$K/[A-Za-z0-9_/.-]*\.py' "$WORK/step.sh" | sed 's#\$K/##' | sort -u > "$WORK/scripts"
while IFS= read -r s; do
  if [[ -f "$REPO/skills/$s" ]]; then ok "it names an existing script: $s"; else bad "it names a missing script: $s"; fi
done < "$WORK/scripts"

# A project as the example expects it: apex/hr, db/, apex-sync.json; the release beside it.
P="$WORK/proj"; mkdir -p "$P/apex/hr" "$P/db" "$P/.apexlang-skills"
find "$EX" -name '*.apx' -exec cp {} "$P/apex/hr/" \;
find "$EX" -name '*.sql' -exec cp {} "$P/db/" \;
cp -r "$REPO/skills" "$REPO/framework" "$P/.apexlang-skills/"
printf '{ "appId": 100, "appAlias": "hr", "apexlangDir": "apex", "sqlclConnection": "dev" }\n' > "$P/apex-sync.json"
printf '.apexlang-skills/\n' > "$P/.gitignore"
git -C "$P" init -q && git -C "$P" add -A && git -C "$P" -c user.name=ci -c user.email=ci@example.invalid commit -qm init

job() { (cd "$P" && APEX_APP=hr APEX_SRC=apex/hr PLSQL_SRC=db GITHUB_RUN_ID=7 bash "$WORK/step.sh") > "$WORK/log" 2>&1; }
rc=0; job || rc=$?
if [[ $rc -eq 0 ]] && [[ $(grep -c ': exit 0$' "$WORK/log") -eq 5 ]]; then ok "the five scans PASS on the examples (job exit 0)"; else bad "the job exited $rc on the examples"; fi
T="$P/.apex-evidence/ci-7"
for f in arch-scan.json security-hr-static.json security-hr-plsql.json security-hr-secrets.json ui-hr-static.json; do
  if [[ -s "$T/$f" ]]; then ok "its result lands in the task dir: $f"; else bad "no $f in the task dir"; fi
done

# A defect in the source fails the job: an editable column with escaping turned off.
printf 'page 99 (\n    name: Bad\n    alias: BAD\n    security {\n        authorizationScheme: mustNotBePublicUser\n        pageAccessProtection: argumentsMustHaveChecksum\n    }\n    region r (\n        name: R\n        type: classicReport\n        column C (\n            type: plainText\n            security {\n                escapeSpecialChars: false\n            }\n        )\n    )\n)\n' > "$P/apex/hr/p00099-bad.apx"
rc=0; job || rc=$?
if [[ $rc -eq 1 ]] && grep -q '^sec-scan: exit 1$' "$WORK/log"; then ok "a planted defect fails the job (sec-scan exit 1)"; else bad "the planted defect: job exit $rc"; fi

echo "ci-example: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
