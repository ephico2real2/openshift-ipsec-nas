#!/bin/bash
# Copies the shared collector code (shared/collector/) to every place that ships it:
#   charts/ipsec-nas/files/ and charts/ipsec-nas-option-c-metrics/files/ (Helm cannot read outside a chart),
#   and manifests/option-b-per-node-certs/25-metrics-scripts.yaml (Option B's plain manifests).
# Edit shared/collector/ first, then run this from the repository root, then the tests:
#   tests/test-shared-collector.sh && tests/test-chart.sh && tests/test-option-c-chart.sh
set -euo pipefail

SRC=shared/collector
FILES=(collect.sh serve.py prometheus-rule-groups.yaml)
CHARTS=(charts/ipsec-nas charts/ipsec-nas-option-c-metrics)
MANIFEST=manifests/option-b-per-node-certs/25-metrics-scripts.yaml

[[ -d "${SRC}" ]] || { echo "run from the repository root: ${SRC} not found" >&2; exit 1; }

for chart in "${CHARTS[@]}"; do
  for f in "${FILES[@]}"; do
    cp "${SRC}/${f}" "${chart}/files/${f}"
  done
  echo "copied ${FILES[*]} to ${chart}/files/"
done

# The ConfigMap's keys indent each line by four spaces; blank lines stay empty.
{
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: ipsec-metrics-scripts\n  namespace: kcs-ipsec\ndata:\n'
  for f in collect.sh serve.py; do
    printf '  %s: |\n' "${f}"
    sed -e 's/^/    /' -e 's/^    $//' "${SRC}/${f}"
  done
} > "${MANIFEST}.tmp"
mv "${MANIFEST}.tmp" "${MANIFEST}"
echo "regenerated ${MANIFEST}"
