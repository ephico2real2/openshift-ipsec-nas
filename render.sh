#!/usr/bin/env bash
# Renders every *.tmpl under manifests/ into rendered/, substituting ONLY
# NODE_DOMAIN, NAS_FQDN, NAS_IP, NAS_EXPORT, CLUSTER_ISSUER, OCP_VERSION and the four overrides below
# (Kyverno's {{ }} and CEL (( )) expressions are left untouched).
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
# Overrides for a cluster that differs from the guide's (docs/crc-integration-guide.md uses all four).
# Left unset, they give the guide's values: worker pool, transport mode, left = the node's FQDN, right = the NAS FQDN.
export MCP_ROLE="${MCP_ROLE:-worker}"
export IPSEC_TYPE="${IPSEC_TYPE:-transport}"
export NAS_RIGHT="${NAS_RIGHT:-${NAS_FQDN}}"
# Left unset, "left" is the node's FQDN, written in the syntax of each policy set: CEL for the
# default policies, Kyverno's {{ }} for kyverno-legacy/.
if [[ -n "${NODE_LEFT:-}" ]]; then
  NODE_LEFT_LEGACY="${NODE_LEFT}"
else
  NODE_LEFT="(( object.metadata.name )).${NODE_DOMAIN}"
  NODE_LEFT_LEGACY="{{ request.object.metadata.name }}.${NODE_DOMAIN}"
fi
export NODE_LEFT NODE_LEFT_LEGACY
# Which nodes are left out is written in the manifests between "# exclude-nodes:begin" and
# "# exclude-nodes:end" (control-plane, master and ingress nodes). EXCLUDE_NODES=none takes those
# blocks out, for a cluster whose only node is control plane and worker at once (CRC).
EXCLUDE_NODES="${EXCLUDE_NODES:-default}"
command -v perl >/dev/null || { echo "perl not found"; exit 1; }

rm -rf rendered
while IFS= read -r f; do
  out="rendered/${f#manifests/}"; mkdir -p "$(dirname "$out")"
  if [[ "$f" == *.tmpl ]]; then
    left=NODE_LEFT; [[ "$f" == */kyverno-legacy/* ]] && left=NODE_LEFT_LEGACY
    LEFT_VAR="${left}" perl -pe 's/\$\{(NODE_DOMAIN|NAS_FQDN|NAS_IP|NAS_EXPORT|CLUSTER_ISSUER|OCP_VERSION|MCP_ROLE|IPSEC_TYPE|NAS_RIGHT)\}/$ENV{$1}/g; s/\$\{NODE_LEFT\}/$ENV{$ENV{LEFT_VAR}}/g' "$f" > "${out%.tmpl}"
  else
    cp "$f" "$out"
  fi
  if [[ "${EXCLUDE_NODES}" == "none" ]]; then
    perl -0pi -e 's/^[ \t]*# exclude-nodes:begin\n.*?^[ \t]*# exclude-nodes:end\n//msg' "${out%.tmpl}"
  fi
done < <(find manifests -type f | sort)
echo "Rendered into ./rendered (NODE_DOMAIN=${NODE_DOMAIN} NAS=${NAS_FQDN}/${NAS_IP} Issuer=${CLUSTER_ISSUER} Butane=${OCP_VERSION})"
