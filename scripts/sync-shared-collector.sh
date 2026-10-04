#!/bin/bash
# Copies the shared collector code (shared/collector/) to every place that ships it:
#   charts/ipsec-nas/files/ and charts/ipsec-nas-option-c-metrics/files/ (Helm cannot read outside a chart),
#   manifests/option-b-per-node-certs/25-metrics-scripts.yaml and 29-prometheus-rule.yaml (Option B's plain manifests).
# Edit shared/collector/ first, then run this from the repository root, then the tests:
#   tests/test-shared-collector.sh && tests/test-chart.sh && tests/test-option-c-chart.sh
# With --check it changes nothing: it fails, naming the file, when any copy differs from what it would write.
set -euo pipefail

SRC=shared/collector
FILES=(collect.sh serve.py prometheus-rule-groups.yaml)
CHARTS=(charts/ipsec-nas charts/ipsec-nas-option-c-metrics)
SCRIPTS_MANIFEST=manifests/option-b-per-node-certs/25-metrics-scripts.yaml
RULES_MANIFEST=manifests/option-b-per-node-certs/29-prometheus-rule.yaml

check=false
[[ "${1:-}" == "--check" ]] && check=true
[[ -d "${SRC}" ]] || { echo "run from the repository root: ${SRC} not found" >&2; exit 1; }

# The ConfigMap's keys indent each line by four spaces; blank lines stay empty.
scripts_manifest() {
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: ipsec-metrics-scripts\n  namespace: kcs-ipsec\ndata:\n'
  for f in collect.sh serve.py; do
    printf '  %s: |\n' "${f}"
    sed -e 's/^/    /' -e 's/^    $//' "${SRC}/${f}"
  done
}

# The rule groups under spec:, indented by two spaces, without the shared-code banner (its lines start "# ***").
rules_manifest() {
  cat <<'EOF'
# Alerts on the per-node IPsec tunnel to the NAS. They appear under Observe > Alerting.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ipsec-nas
  namespace: kcs-ipsec
  labels:
    app: ipsec-cert-sync
spec:
EOF
  grep -v '^# \*\*\*' "${SRC}/prometheus-rule-groups.yaml" | sed -e 's/^/  /' -e 's/^  $//'
}

# put <generator> <target>: writes the target, or with --check compares it.
failed=0
put() {
  local tmp; tmp="$(mktemp)"
  "$1" > "${tmp}"
  if ${check}; then
    cmp -s "${tmp}" "$2" && echo "ok    $2" || { echo "FAIL  $2 differs from ${SRC}/ (run scripts/sync-shared-collector.sh)"; failed=1; }
    rm -f "${tmp}"
  else
    mv "${tmp}" "$2"; chmod 644 "$2"; echo "wrote $2"
  fi
}

for chart in "${CHARTS[@]}"; do
  for f in "${FILES[@]}"; do
    copy() { cat "${SRC}/${f}"; }
    put copy "${chart}/files/${f}"
  done
done
put scripts_manifest "${SCRIPTS_MANIFEST}"
put rules_manifest "${RULES_MANIFEST}"
exit "${failed}"
