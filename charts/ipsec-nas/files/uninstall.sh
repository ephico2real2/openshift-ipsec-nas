#!/bin/bash
# Runs before the release is removed (helm uninstall, or an Argo CD application delete).
# Deleting the chart's objects does not undo what they did: the tunnels stay on the nodes, and each
# node keeps its certificate and private key. Kyverno cannot clean up either, because the uninstall
# takes its policies and permissions away at the same moment. So this does it first, in order.
set -uo pipefail

NS="${POD_NAMESPACE}"
NSS_DB=/var/lib/ipsec/nss
log() { echo "$(date -u +%FT%TZ) $*"; }

log "1. Stop Kyverno from creating NNCPs and Certificates again"
oc delete clusterpolicy ipsec-nncp-per-node ipsec-node-certificate --ignore-not-found

log "2. Remove the tunnel from every node (an NNCP with state: absent), then the NNCPs"
nncps=$(oc get nncp -l generate.kyverno.io/policy-name=ipsec-nncp-per-node -o jsonpath='{.items[*].metadata.name}')
for nncp in ${nncps}; do
  node=$(oc get nncp "${nncp}" -o jsonpath='{.spec.nodeSelector.kubernetes\.io/hostname}')
  cat <<EOF | oc apply -f -
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${nncp}
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
# An NNCP still says Available from before the change for a moment, so its status cannot be
# trusted here. Ask each node itself, through its cert-sync pod, until the connection is gone.
for nncp in ${nncps}; do
  node=$(oc get nncp "${nncp}" -o jsonpath='{.spec.nodeSelector.kubernetes\.io/hostname}')
  pod=$(oc get pods -n "${NS}" -l app=ipsec-cert-sync --field-selector="spec.nodeName=${node},status.phase=Running" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  gone=no
  for _ in $(seq 1 60); do
    if [[ -n "${pod}" ]] && ! oc exec -n "${NS}" "${pod}" -c sync -- chroot /host nmcli -t -f NAME connection show 2>/dev/null | grep -qx ipsec-nas; then
      gone=yes; break
    fi
    sleep 2
  done
  [[ "${gone}" == yes ]] && log "   tunnel removed from ${node}" || log "WARNING: could not confirm that the tunnel is gone from ${node}"
  oc delete nncp "${nncp}" --ignore-not-found
done

log "3. Remove each node's certificate and private key from its NSS database"
for pod in $(oc get pods -n "${NS}" -l app=ipsec-cert-sync --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}'); do
  oc exec -n "${NS}" "${pod}" -c sync -- bash -c "
    touch /tmp/ipsec-nas-teardown
    chroot /host bash -c '
      certutil -F -n left_server -d ${NSS_DB} 2>/dev/null
      certutil -D -n KCS-IPSEC-CA -d ${NSS_DB} 2>/dev/null
      rm -rf /etc/pki/certs/kcs-ipsec
      true'" && log "   cleaned the node of pod ${pod}" || log "WARNING: could not clean the node of pod ${pod}"
done

log "4. Remove the cert-ready label from the nodes"
oc label nodes -l ipsec.kcs.io/cert-ready ipsec.kcs.io/cert-ready-

log "5. Delete the Certificates first (while one exists, cert-manager puts its Secret back), then the Secrets"
oc delete certificate -n "${NS}" -l generate.kyverno.io/policy-name=ipsec-node-certificate --ignore-not-found
oc delete secret -n "${NS}" -l controller.cert-manager.io/fao=true --ignore-not-found

log "Done. Ask the CA team to revoke the node certificates."
