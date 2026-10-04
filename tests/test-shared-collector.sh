#!/bin/bash
# The collector, the metrics server and the alert rules are SHARED CODE: shared/collector/ is the source, and each
# Helm chart carries a byte-identical copy (Helm cannot read files outside a chart). Fails when a copy differs, so a
# change made in one chart only cannot pass. Run from the repository root: tests/test-shared-collector.sh
set -uo pipefail
fail=0
for f in collect.sh serve.py prometheus-rule-groups.yaml; do
  for chart in charts/ipsec-nas charts/ipsec-nas-option-c-metrics; do
    if cmp -s "shared/collector/${f}" "${chart}/files/${f}"; then
      echo "ok    ${chart}/files/${f} = shared/collector/${f}"
    else
      echo "FAIL  ${chart}/files/${f} differs from shared/collector/${f}: change shared/collector/${f}, then copy it to both charts"
      fail=1
    fi
  done
done
[[ ${fail} == 0 ]] && echo "all shared-collector copies identical" || exit 1
