#!/bin/bash
# Checks and unit-tests the alert rules with promtool, run from a container image so nothing has
# to be installed. Run from the repository root: tests/test-alert-rules.sh
# CONTAINER_ENGINE picks podman (default) or docker.
set -euo pipefail

ENGINE="${CONTAINER_ENGINE:-podman}"
# By digest (the index: each platform takes its own image): "latest" is whatever was pushed last, and a release of
# Prometheus must not be able to fail, or pass, a pull request that did not touch the rules. v3.15.0, 2026-10-07.
IMAGE="quay.io/prometheus/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e"
RULE_MANIFEST="manifests/option-b-per-node-certs/29-prometheus-rule.yaml"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# A PrometheusRule's spec is a plain Prometheus rule file: take everything under "spec:"
sed -n '/^spec:$/,$p' "${RULE_MANIFEST}" | sed '1d' | sed 's/^  //' > "${work}/ipsec-nas.rules.yaml"
cp tests/ipsec-nas-alerts.test.yaml "${work}/"
chmod -R a+rX "${work}"

"${ENGINE}" run --rm -v "${work}:/w:ro" --workdir /w --entrypoint promtool "${IMAGE}" check rules ipsec-nas.rules.yaml
"${ENGINE}" run --rm -v "${work}:/w:ro" --workdir /w --entrypoint promtool "${IMAGE}" test rules ipsec-nas-alerts.test.yaml
