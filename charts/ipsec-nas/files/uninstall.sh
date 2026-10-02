#!/bin/bash
# Runs before the release is removed (helm uninstall, or an Argo CD application delete).
# Deleting the chart's objects does not undo what they did: the tunnels stay on the nodes, and each
# node keeps its certificate and private key. Kyverno cannot clean up either, because the uninstall
# takes its policies and permissions away at the same moment. So this does it first, in order.
set -uo pipefail

NS="${POD_NAMESPACE}"
NSS_DB=/var/lib/ipsec/nss
# The kind of the two Node policies: generatingpolicy (the default) or clusterpolicy (kyverno.legacyPolicies).
POLICY_KIND="${POLICY_KIND:-generatingpolicy}"
log() { echo "$(date -u +%FT%TZ) $*"; }

# Which nodes have a tunnel. This must be read BEFORE the policy is deleted: Kyverno deletes the
# NNCPs together with their policy, and a deleted NNCP leaves its tunnel on the node.
nodes=$(oc get nncp -l generate.kyverno.io/policy-name=ipsec-nncp-per-node \
  -o jsonpath='{range .items[*]}{.spec.nodeSelector.kubernetes\.io/hostname}{"\n"}{end}')

log "1. Stop Kyverno from creating NNCPs again"
oc delete "${POLICY_KIND}" ipsec-nncp-per-node --ignore-not-found
# Whether Kyverno deletes the NNCPs with their policy depends on the kind; delete any that are left,
# so that only the removal NNCP below describes the interface.
oc delete nncp -l generate.kyverno.io/policy-name=ipsec-nncp-per-node --ignore-not-found

log "2. Remove the tunnel from every node, with an NNCP that says: absent"
# The removal NNCP has its own name. Kyverno deletes the NNCPs it generated a moment after their
# policy, so an NNCP that reused one of those names would be deleted before NMState acted on it.
for node in ${nodes}; do
  cat <<EOF | oc apply -f -
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ipsec-nas-remove-${node}
spec:
  nodeSelector:
    kubernetes.io/hostname: ${node}
  desiredState:
    interfaces:
    - name: ipsec-nas
      type: ipsec
      state: absent
EOF
done
for node in ${nodes}; do
  # a new object, so its Available condition can only come from this change
  if oc wait "nncp/ipsec-nas-remove-${node}" --for=condition=Available --timeout=180s; then
    log "   tunnel removed from ${node}"
  else
    log "WARNING: NMState did not confirm the removal on ${node}"
  fi
  oc delete nncp "ipsec-nas-remove-${node}" --ignore-not-found
done
[[ -n "${nodes}" ]] || log "   no tunnel NNCPs found"

log "3. Remove the cert-ready label from the nodes"
oc label nodes -l ipsec.kcs.io/cert-ready ipsec.kcs.io/cert-ready-

if [[ "${REMOVE_CERTIFICATES:-true}" != "true" ]]; then
  log "Done. The certificates were kept (uninstallCleanup.removeCertificates is false):"
  log "each node still has its certificate and key, and the Certificates and Secrets are still in ${NS}."
  exit 0
fi

log "4. Remove each node's certificate and private key from its NSS database"
for pod in $(oc get pods -n "${NS}" -l app=ipsec-cert-sync --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}'); do
  if oc exec -n "${NS}" "${pod}" -c sync -- bash -c "
    touch /tmp/ipsec-nas-teardown
    chroot /host bash -c '
      certutil -F -n left_server -d ${NSS_DB} 2>/dev/null
      certutil -D -n KCS-IPSEC-CA -d ${NSS_DB} 2>/dev/null
      rm -rf /etc/pki/certs/kcs-ipsec
      true'"; then
    log "   cleaned the node of pod ${pod}"
  else
    log "WARNING: could not clean the node of pod ${pod}"
  fi
done

log "5. Delete the Certificates first (while one exists, cert-manager puts its Secret back), then the Secrets"
oc delete "${POLICY_KIND}" ipsec-node-certificate --ignore-not-found
oc delete certificate -n "${NS}" -l generate.kyverno.io/policy-name=ipsec-node-certificate --ignore-not-found
oc delete secret -n "${NS}" -l controller.cert-manager.io/fao=true --ignore-not-found

log "Done. Ask the CA team to revoke the node certificates."
