#!/bin/bash
# The collector, the metrics server and the alert rules are SHARED CODE: shared/collector/ is the source. Each Helm
# chart carries a byte-identical copy (Helm cannot read files outside a chart), and Option B's manifests 25 and 29
# embed them. Fails when any copy differs from what scripts/sync-shared-collector.sh would write, so a change made in
# one copy only cannot pass. Run from the repository root: tests/test-shared-collector.sh
set -uo pipefail
if scripts/sync-shared-collector.sh --check; then
  echo "all shared-collector copies identical"
else
  echo "change shared/collector/ only, then run scripts/sync-shared-collector.sh"
  exit 1
fi
