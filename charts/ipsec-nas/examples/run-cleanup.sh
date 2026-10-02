#!/bin/bash
# Runs the chart's cleanup (files/uninstall.sh) as a one-off Job and shows its log.
# For the cases where no hook runs it: an Argo CD that does not run PreDelete hooks (measured:
# Argo CD 3.4.7), or objects that were applied without Helm. Run it BEFORE the chart's objects are
# deleted: it needs the cert-sync pods to clean the nodes.
#
#   run-cleanup.sh <namespace> [--set uninstallCleanup.removeCertificates=false]
set -euo pipefail

NS="${1:?usage: run-cleanup.sh <namespace> [helm --set arguments]}"; shift
CHART="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$(mktemp)"
trap 'rm -f "${manifest}"' EXIT

# Only the hook's own objects, as plain objects: the hook annotations are taken out.
# The required values are not used by these objects, so placeholders do.
helm template ipsec-nas "${CHART}" -n "${NS}" --set prerequisites.skipCheck=true \
  --set nas.fqdn=unused --set nas.ip=192.0.2.1 --set clusterIssuer=unused --set nodeDomain=unused \
  --set trustCA.existingConfigMap=unused "$@" -s templates/uninstall-hook.yaml \
  | grep -v -E '^ +(helm\.sh/hook|argocd\.argoproj\.io/)' > "${manifest}"

oc apply -f "${manifest}"
oc wait -n "${NS}" job/ipsec-nas-uninstall --for=condition=Complete --timeout=10m
oc logs -n "${NS}" job/ipsec-nas-uninstall
oc delete -f "${manifest}"
