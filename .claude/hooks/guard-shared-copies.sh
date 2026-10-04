#!/bin/bash
# PreToolUse hook (Write|Edit): refuses a direct edit to a COPY of the shared collector code, or to a generated dashboard.
# The source is shared/collector/; scripts/sync-shared-collector.sh copies it to both charts and manifests 25 and 29.
# Input: the tool call as JSON on stdin. Exit 2 blocks the call and shows stderr to Claude.
set -euo pipefail

path="$(jq -r '.tool_input.file_path // empty')"
case "${path}" in
  */charts/*/files/collect.sh | */charts/*/files/serve.py | */charts/*/files/prometheus-rule-groups.yaml | \
  */manifests/option-b-per-node-certs/25-metrics-scripts.yaml | */manifests/option-b-per-node-certs/29-prometheus-rule.yaml)
    echo "BLOCKED: ${path} is a copy of shared/collector/. Edit shared/collector/ instead, then run" \
         "scripts/sync-shared-collector.sh and tests/test-shared-collector.sh." >&2
    exit 2 ;;
  */charts/*/files/*.perses.json | */charts/ipsec-nas-option-c-metrics/files/ipsec-nas-option-c.json | \
  */manifests/option-b-per-node-certs/30-grafana-dashboard.yaml | */manifests/option-b-per-node-certs/33-perses-dashboard.yaml)
    echo "BLOCKED: ${path} is generated from charts/ipsec-nas/files/ipsec-nas.json. Edit that file, then run" \
         "scripts/perses-dashboard.sh (it writes Option B's and Option C's dashboards)." >&2
    exit 2 ;;
esac
exit 0
