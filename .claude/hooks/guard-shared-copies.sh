#!/bin/bash
# PreToolUse hook (Write|Edit): refuses a direct edit to a COPY of the shared collector code.
# The source is shared/collector/; scripts/sync-shared-collector.sh copies it to both charts and manifest 25.
# Input: the tool call as JSON on stdin. Exit 2 blocks the call and shows stderr to Claude.
set -euo pipefail

path="$(jq -r '.tool_input.file_path // empty')"
case "${path}" in
  */charts/*/files/collect.sh | */charts/*/files/serve.py | */charts/*/files/prometheus-rule-groups.yaml | \
  */manifests/option-b-per-node-certs/25-metrics-scripts.yaml)
    echo "BLOCKED: ${path} is a copy of shared/collector/. Edit shared/collector/ instead, then run" \
         "scripts/sync-shared-collector.sh and tests/test-shared-collector.sh." >&2
    exit 2 ;;
esac
exit 0
