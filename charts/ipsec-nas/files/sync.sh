#!/bin/bash
# ipsec-cert-sync: runs on every worker node.
# 1) Imports THIS node's certificate (mounted at /certs by Kyverno) into the
#    host's IPsec NSS database under the nickname "left_server".
# 2) Labels the node ipsec.kcs.io/cert-ready=true so Kyverno creates the NNCP.
# 3) Every 5 minutes, checks for a renewed cert and re-imports it.
set -uo pipefail

NSS_DB=/var/lib/ipsec/nss
CERT_NICK=left_server
CA_NICK=KCS-IPSEC-CA
CONN_NAME=ipsec-nas
READY_LABEL=ipsec.kcs.io/cert-ready
HOST_STAGE=/etc/pki/certs/kcs-ipsec     # path as the HOST sees it
STAGE=/host${HOST_STAGE}                # same path as this container sees it
STAMP=${STAGE}/.installed-sha256
CHECK_EVERY=300
# the secret name in the DaemonSet template, before Kyverno replaces it
PLACEHOLDER_SECRET=ipsec-cert-unassigned
RECREATE_AFTER=60

log() { echo "$(date -u +%FT%TZ) [${NODE_NAME}] $*"; }

# Kyverno policy ipsec-cert-sync-mount swaps this node's own secret into the pod when the pod
# is created. A pod created while that policy was missing, or while Kyverno was down, keeps the
# placeholder for life and can never get a certificate. Such a pod deletes itself, and the
# DaemonSet creates a new one for Kyverno to see. The wait keeps a Kyverno outage from
# turning into a fast delete loop.
recreate_if_unassigned() {
  local mounted
  mounted=$(oc get pod "${POD_NAME}" -n "${POD_NAMESPACE}" \
    -o jsonpath='{.spec.volumes[?(@.name=="node-cert")].secret.secretName}' 2>/dev/null)
  [[ "${mounted}" == "${PLACEHOLDER_SECRET}" ]] || return 0
  log "This pod mounts the placeholder secret: policy ipsec-cert-sync-mount did not run when it was created."
  log "Deleting this pod in ${RECREATE_AFTER}s so that it is created again."
  sleep "${RECREATE_AFTER}"
  oc delete pod "${POD_NAME}" -n "${POD_NAMESPACE}" --wait=false
  sleep "${CHECK_EVERY}"
}

import_cert() {
  mkdir -p "${STAGE}" &&
  install -m 0400 /certs/tls.crt "${STAGE}/tls.crt" &&
  install -m 0400 /certs/tls.key "${STAGE}/tls.key" &&
  install -m 0444 /ca/ca.pem     "${STAGE}/ca.pem" &&
  chroot /host /bin/bash -euo pipefail -c "
    cd ${HOST_STAGE}
    # never leave the private key or p12 on the host disk
    trap 'rm -f tls.key left_server.p12' EXIT
    openssl pkcs12 -export -in tls.crt -inkey tls.key -name ${CERT_NICK} \
      -out left_server.p12 -passout pass:
    # remove the previous cert + key (ignore errors on first run)
    certutil -F -n ${CERT_NICK} -d ${NSS_DB} >/dev/null 2>&1 || true
    certutil -D -n ${CERT_NICK} -d ${NSS_DB} >/dev/null 2>&1 || true
    certutil -A -n ${CA_NICK} -t 'CT,C,C' -d ${NSS_DB} -i ca.pem
    pk12util -W '' -i left_server.p12 -d ${NSS_DB}
    certutil -M -n ${CERT_NICK} -t 'u,u,u' -d ${NSS_DB}
  "
}

log "Starting"
recreate_if_unassigned
while true; do
  if [[ -s /certs/tls.crt && -s /certs/tls.key && -s /ca/ca.pem ]]; then
    want=$(cat /certs/tls.crt /ca/ca.pem | sha256sum | cut -d' ' -f1)
    have=$(cat "${STAMP}" 2>/dev/null || echo none)
    # If the cert is missing from NSS (e.g. DB rebuilt), force a re-import
    chroot /host certutil -L -n "${CERT_NICK}" -d "${NSS_DB}" >/dev/null 2>&1 || have=missing

    if [[ "${want}" != "${have}" ]]; then
      log "New or renewed certificate detected - importing into NSS"
      if import_cert; then
        echo "${want}" > "${STAMP}"
        log "Import OK"
        # On renewal, restart the tunnel so libreswan loads the new cert
        if chroot /host nmcli -t -f NAME connection show --active | grep -qx "${CONN_NAME}"; then
          log "Restarting ${CONN_NAME} to load the new certificate"
          chroot /host nmcli connection up "${CONN_NAME}" || log "WARNING: restart of ${CONN_NAME} failed"
        fi
      else
        log "ERROR: import failed - retrying in 60s"
        sleep 60
        continue
      fi
    fi

    current=$(oc get node "${NODE_NAME}" -o jsonpath="{.metadata.labels.ipsec\.kcs\.io/cert-ready}" 2>/dev/null)
    if [[ "${current}" != "true" ]]; then
      oc label node "${NODE_NAME}" "${READY_LABEL}=true" --overwrite \
        && log "Node labelled ${READY_LABEL}=true"
    fi
  else
    log "Waiting for certificate files in /certs (is Certificate ipsec-${NODE_NAME} Ready?)"
    # the secret appears in the volume shortly after the Certificate is issued
    sleep 15
    continue
  fi
  sleep "${CHECK_EVERY}"
done
