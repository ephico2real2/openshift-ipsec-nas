#!/bin/bash
# The charts refuse the refined tunnel's keys on an OpenShift release that cannot carry them
# (docs/70-review-enterprise-linux-ipsec-config.md, "Which OpenShift versions carry rightca and the port selectors").
# The rule lives in templates/_openshift-floor.tpl, the same file in both charts. The charts call it only against a
# real cluster (it reads the ClusterVersion), so this test renders the rule on its own, in a throwaway chart, at
# each boundary of the version table. Run from the repository root: tests/test-openshift-floor.sh. Needs helm.
set -euo pipefail

A=charts/ipsec-nas/templates/_openshift-floor.tpl
B=charts/ipsec-nas-option-c-metrics/templates/_openshift-floor.tpl
cmp -s "${A}" "${B}" || { echo "FAIL  ${A} and ${B} differ: keep the two copies identical"; exit 1; }
echo "ok    both charts carry the same rule"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/templates"
printf 'apiVersion: v2\nname: floor\nversion: 0.0.0\n' > "${tmp}/Chart.yaml"
cp "${A}" "${tmp}/templates/"
printf '{{ include "ipsec-nas.openshiftFloor" (dict "ipsec" .Values.ipsec "version" .Values.version) }}\n' > "${tmp}/templates/check.yaml"

SELECTORS=(--set ipsec.rightca=%same --set ipsec.leftprotoport=tcp --set ipsec.rightprotoport=tcp/2049)
RIGHTCA=(--set ipsec.rightca=%same)

check() {  # $1 = pass|fail, $2 = OpenShift version; the rest = helm --set arguments
  local want="$1" version="$2"; shift 2
  local out
  if out="$(helm template floor "${tmp}" --set-string version="${version}" "$@" 2>&1)"; then
    [[ "${want}" == pass ]] || { echo "FAIL  ${version} $*: accepted, should be refused"; return 1; }
  else
    [[ "${want}" == fail ]] || { echo "FAIL  ${version} $*: refused, should be accepted"; echo "${out}" | tail -1; return 1; }
    grep -q "requires OpenShift" <<< "${out}" || { echo "FAIL  ${version} $*: wrong message"; echo "${out}" | tail -1; return 1; }
  fi
  echo "ok    ${want}  ${version}  $*"
}

# rightca and the port selectors: 4.19.22, 4.20.11, any 4.21 or later
check fail 4.18.30  "${SELECTORS[@]}"
check fail 4.19.18  "${SELECTORS[@]}"
check fail 4.19.21  "${SELECTORS[@]}"
check pass 4.19.22  "${SELECTORS[@]}"
check pass 4.19.49  "${SELECTORS[@]}"
check fail 4.20.10  "${SELECTORS[@]}"
check pass 4.20.11  "${SELECTORS[@]}"
check pass 4.21.0   "${SELECTORS[@]}"
check pass 4.22.7   "${SELECTORS[@]}"
check pass 4.22.0-0.nightly-2026-10-01-000000 "${SELECTORS[@]}"
check fail 4.19.21  --set ipsec.leftprotoport=tcp

# rightca alone: 4.19.19, 4.20.3, any 4.21 or later
check fail 4.17.9   "${RIGHTCA[@]}"
check fail 4.19.18  "${RIGHTCA[@]}"
check pass 4.19.19  "${RIGHTCA[@]}"
check fail 4.20.2   "${RIGHTCA[@]}"
check pass 4.20.3   "${RIGHTCA[@]}"
check pass 4.21.5   "${RIGHTCA[@]}"

# none of the keys, or not OpenShift (no version): nothing to check
check pass 4.14.0
check pass ""       "${SELECTORS[@]}"

echo "all OpenShift version floor tests passed"
