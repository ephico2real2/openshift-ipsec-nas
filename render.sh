#!/usr/bin/env bash
# Renders every *.tmpl under manifests/ into rendered/, substituting ONLY
# NODE_DOMAIN, NAS_FQDN, NAS_IP, NAS_EXPORT, CLUSTER_ISSUER and OCP_VERSION (Kyverno {{ }} expressions are left untouched).
# Non-template manifests are copied as-is so rendered/ is a complete, apply-ready set.
set -euo pipefail
: "${NODE_DOMAIN:?set NODE_DOMAIN (e.g. ocp.example.com)}"
: "${NAS_FQDN:?set NAS_FQDN}"
: "${NAS_IP:?set NAS_IP}"
# The ClusterIssuer the cluster already has for the enterprise CA. This repo never creates one.
: "${CLUSTER_ISSUER:?set CLUSTER_ISSUER to the existing enterprise CA ClusterIssuer (oc get clusterissuer)}"
# The path the NAS exports (demo app only)
export NAS_EXPORT="${NAS_EXPORT:-/export}"
OCP_VERSION="${OCP_VERSION:-$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1,2).0}"
export OCP_VERSION
command -v perl >/dev/null || { echo "perl not found"; exit 1; }

rm -rf rendered
while IFS= read -r f; do
  out="rendered/${f#manifests/}"; mkdir -p "$(dirname "$out")"
  if [[ "$f" == *.tmpl ]]; then
    perl -pe 's/\$\{(NODE_DOMAIN|NAS_FQDN|NAS_IP|NAS_EXPORT|CLUSTER_ISSUER|OCP_VERSION)\}/$ENV{$1}/g' "$f" > "${out%.tmpl}"
  else
    cp "$f" "$out"
  fi
done < <(find manifests -type f | sort)
echo "Rendered into ./rendered (NODE_DOMAIN=${NODE_DOMAIN} NAS=${NAS_FQDN}/${NAS_IP} Issuer=${CLUSTER_ISSUER} Butane=${OCP_VERSION})"
