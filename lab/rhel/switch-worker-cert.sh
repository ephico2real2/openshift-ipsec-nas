#!/bin/bash
# Replaces the worker's certificate (NSS nickname left_server) with another PKCS#12 bundle and
# reconnects. Used by the lab to move a worker between a per-node certificate (Option B) and the
# shared certificate (Option A). Run as root.
#
#   switch-worker-cert.sh /root/ipsec-pki/shared-workers.p12
set -euo pipefail

P12="${1:?path to the .p12 bundle (friendly name left_server, empty password)}"
MOUNT_DIR="${MOUNT_DIR:-/mnt/nas}"
NSS_DB=/var/lib/ipsec/nss

systemctl stop ipsec
# -F removes the certificate together with its private key
certutil -F -n left_server -d "${NSS_DB}"
pk12util -W '' -i "${P12}" -d "${NSS_DB}"
certutil -M -n left_server -t 'u,u,u' -d "${NSS_DB}"
certutil -L -n left_server -d "${NSS_DB}" | grep -E 'Subject:|DNS name'
systemctl start ipsec

# No wait for the tunnel here: with a shared certificate and a NAS on uniqueids=yes the tunnel is
# expected to be unstable, and that is what the lab then measures.
sleep 5
ipsec trafficstatus | grep '"ipsec-nas"' || echo "no established ipsec-nas tunnel at this moment"
