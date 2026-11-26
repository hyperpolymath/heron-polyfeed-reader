#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Firing/silence fixtures for the inlined step "Run enforcing cicd-suite
# governance, hygiene, and language gates" in .github/workflows/main-estate-audit.yml.
#
# Offline. The step's own `run:` block is extracted with yq (never copied), the
# pinned cicd-suite tree is staged at .cicd-suite-tmp as the checkout step does,
# and each case runs it in a throwaway git repository.
#   silence: a compliant repository must pass and print the success line.
#   firing:  one planted defect each must make the step fail, with the message
#            of the gate that owns it, so a gate that stops firing is caught.
# Usage: heron-estate-audit-fixtures.sh WORKFLOW.yml SUITE_ACTIONS_DIR
set -uo pipefail

wf=$(readlink -f "$1"); suite=$(readlink -f "$2")
command -v yq >/dev/null || { echo "yq required" >&2; exit 2; }
step=$(yq -r '.jobs["estate-audit"].steps[] | select(.name | test("^Run enforcing")) | .run' "$wf")
[ -n "$step" ] || { echo "step not found in $wf" >&2; exit 2; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0; planned=0; ran=0

mkrepo() { # dir: a compliant repository
  local d=$1; mkdir -p "$d/src/app" "$d/docs"; cd "$d" || exit 2
  git init -q . && git config user.email t@example.invalid && git config user.name t
  : > .editorconfig; : > .gitignore; : > .gitattributes; echo 'toolchain 1' > .tool-versions
  printf '# owners\n* @octo\n' > CODEOWNERS
  printf 'LICENSE text\n' > LICENSE
  printf 'Governance\n==========\nThe owner decides.\nChanges need review.\nReleases are tagged.\nIssues are public.\n' > GOVERNANCE.adoc
  printf 'Architecture\n============\nCode lives in src/app/.\nDocs live in docs/.\nTests are in src/app/.\nNothing else.\nDone.\n' > ARCHITECTURE.adoc
  printf 'Maintainers\n===========\nowner: octo\nsecond: octo\ncontact: octo\nrole: octo\nrole2: octo\n' > MAINTAINERS.adoc
  printf 'x\n' > src/app/a.txt
  git add -A && git commit -q -m init
}
run_case() { # name expect(0|1) mutator-function expected-text [VAR=value ...]
  local name=$1 expect=$2 mut=$3 text=$4 d="$work/$1" out rc; shift 4
  planned=$((planned+1))
  mkrepo "$d"; ( cd "$d" && $mut )
  cd "$d" || exit 2
  rm -rf .cicd-suite-tmp; mkdir .cicd-suite-tmp; cp -r "$suite" .cicd-suite-tmp/actions
  mkdir -p "$work/rt-$name"
  out=$(env "$@" GITHUB_WORKSPACE="$d" RUNNER_TEMP="$work/rt-$name" REPO_OWNER=octo REPO_NAME=octo/demo \
        bash --noprofile --norc -e -o pipefail -c "$step" 2>&1); rc=$?
  ran=$((ran+1))
  if { [ "$expect" = 0 ] && [ "$rc" -eq 0 ]; } || { [ "$expect" = 1 ] && [ "$rc" -ne 0 ]; }; then
    if [ "$expect" = 1 ] && printf '%s' "$out" | grep -qF 'Central Estate CI/CD Audit passed.'; then
      echo "FAIL $name: failed step still printed the success line"; fail=$((fail+1)); return
    fi
    if printf '%s' "$out" | grep -qF -- "$text"; then
      echo "ok   $name (rc=$rc, saw: $text)"; pass=$((pass+1)); return
    fi
    echo "FAIL $name: rc=$rc ok but text '$text' missing"
  else
    echo "FAIL $name: expected rc=$expect got $rc"
  fi
  printf '%s\n' "$out" | tail -8 | sed 's/^/     | /'; fail=$((fail+1))
}

m_none()      { :; }
m_pem()       { printf -- '-----BEGIN RSA PRIV%s KEY-----\nabc\n' ATE > key.pem; }
m_nogov()     { git rm -q GOVERNANCE.adoc; }
m_placeholder() { printf 'Governance\n==========\nTO%s: update this\na\nb\nc\nd\n' DO > GOVERNANCE.adoc; }
m_badcff()    { printf 'cff-version: 1.2.0\n' > CITATION.cff; }
m_zig()       { printf 'const x = std.fs;\n' > src/app/a.zig; git add -A; }
m_nolicense() { git rm -q LICENSE; }
m_badowner()  { printf 'Maintainers\n===========\nowner: someone\nb\nc\nd\ne\nf\n' > MAINTAINERS.adoc; }
m_shortaff()  { printf 'Affirmation\nonly one\n' > AFFIRMATION.adoc; }
m_debt()      { printf '# TO%s fix this\n' DO > src/app/a.py; git add -A; }
m_sorry()     { printf 'theorem t : True := sorry\n' > src/app/p.lean; git add -A; }
m_abi()       { : > abi.ipkg; mkdir -p src; printf 'f : IO ()\n' > src/Abi.idr; git add -A; }
m_cartridge()  { printf '{}\n' > cartridge.json; git add -A; }

run_case silence-compliant     0 m_none        'Central Estate CI/CD Audit passed.'
run_case fire-private-key      1 m_pem         'Private-key material detected'
run_case fire-missing-governance 1 m_nogov     'Missing required file: GOVERNANCE'
run_case fire-placeholder      1 m_placeholder 'template placeholders'
run_case fire-bad-citation     1 m_badcff      "missing the required top-level 'title' field"
run_case fire-zig-side-effect  1 m_zig         'Zig FFI modules contain prohibited side-effects'
run_case fire-no-licence       1 m_nolicense   '=== cicd-suite: spdx-license-check ==='
run_case fire-maintainer-owner 1 m_badowner    'never mentions the repository owner'
run_case fire-affirmation-stub 1 m_shortaff    'is a stub, not an affirmation'
run_case fire-debt-marker      1 m_debt        'Untracked debt markers found'
run_case fire-proof-sorry      1 m_sorry       'Undeclared proof circumventions found'
run_case fire-idris2-abi-io    1 m_abi         'prohibited side-effects (IO/unsafe)'
# boj-cartridge-check: CI never sets BOJ_CARTRIDGE_REQUIRED and heron has no cartridge,
# so the gate is a no-op there. These cases pin its behaviour in both modes, so a
# regression in the pinned check.sh is caught here.
run_case silence-boj-not-applicable 0 m_none      'BoJ cartridge is not applicable'
run_case silence-boj-cartridge-present 0 m_cartridge 'BoJ cartridge present at cartridge.json' BOJ_CARTRIDGE_REQUIRED=true
run_case fire-boj-cartridge-required 1 m_none     'A BoJ cartridge is required' BOJ_CARTRIDGE_REQUIRED=true

echo "cases planned=$planned ran=$ran pass=$pass fail=$fail"
[ "$ran" -eq "$planned" ] || { echo "FAIL: a planned case did not run"; exit 1; }
[ "$fail" -eq 0 ]
