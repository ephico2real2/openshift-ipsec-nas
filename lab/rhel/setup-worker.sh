#!/bin/bash
# Stand-in for an OpenShift worker node on a RHEL 10 (or CentOS Stream 10) host.
# It configures libreswan with the same keys the guide's NNCP sets, then mounts the NAS over IPsec.
# Run as root.
#
#   WORKER_FQDN=... NAS_FQDN=... NAS_IP=... PKI_DIR=/root/ipsec-pki ./setup-worker.sh
#
# PKI_DIR must hold ca.pem and left_server.p12 (empty password, friendly name "left_server").
set -euo pipefail

WORKER_FQDN="${WORKER_FQDN:?set WORKER_FQDN (must be in the certificate SAN)}"
NAS_FQDN="${NAS_FQDN:?set NAS_FQDN}"
NAS_IP="${NAS_IP:?set NAS_IP}"
PKI_DIR="${PKI_DIR:-/root/ipsec-pki}"
EXPORT_DIR="${EXPORT_DIR:-/export}"
MOUNT_DIR="${MOUNT_DIR:-/mnt/nas}"
# transport is what the guide's NNCP uses. tunnel is only for a host that reaches the NAS through NAT.
IPSEC_TYPE="${IPSEC_TYPE:-transport}"
NSS_DB=/var/lib/ipsec/nss

step() { echo; echo "== $*"; }

step "1. Packages"
dnf -y -q install libreswan nfs-utils nss-tools

step "2. Certificates into the libreswan NSS database (same commands as the guide's nodes)"
ipsec checknss
certutil -A -n CA -t 'CT,C,C' -d "${NSS_DB}" -i "${PKI_DIR}/ca.pem"
pk12util -W '' -i "${PKI_DIR}/left_server.p12" -d "${NSS_DB}"
certutil -M -n left_server -t 'u,u,u' -d "${NSS_DB}"
certutil -L -d "${NSS_DB}"

step "3. libreswan connection: the keys of the guide's NNCP, in the same order"
cat > /etc/ipsec.d/ipsec-nas.conf <<CONF
conn ipsec-nas
    left=${WORKER_FQDN}
    leftid=%fromcert
    leftrsasigkey=%cert
    leftcert=left_server
    leftmodecfgclient=no
    right=${NAS_FQDN}
    rightid=%fromcert
    rightrsasigkey=%cert
    rightsubnet=${NAS_IP}/32
    ikev2=insist
    type=${IPSEC_TYPE}
    auto=start
CONF
# libreswan 5 resolves left=/right= host names through libunbound. On the lab VMs that resolver
# fails to initialise while DNSSEC validation is on, so the names never resolve.
# dnssec-enable=no makes pluto use the system resolver instead.
grep -q '^\s*dnssec-enable=' /etc/ipsec.conf \
  || sed -i '/^config setup/a\\tdnssec-enable=no' /etc/ipsec.conf
systemctl enable ipsec
systemctl restart ipsec

step "4. Wait for the tunnel"
for _ in $(seq 1 30); do
  ipsec trafficstatus | grep -q '"ipsec-nas"' && break
  sleep 1
done
ipsec trafficstatus | grep '"ipsec-nas"' || { echo "tunnel did not come up; see: journalctl -u ipsec"; exit 1; }

step "5. Mount the NAS over the tunnel"
mkdir -p "${MOUNT_DIR}"
mountpoint -q "${MOUNT_DIR}" || mount -t nfs4 "${NAS_FQDN}:${EXPORT_DIR}" "${MOUNT_DIR}"
grep " ${MOUNT_DIR} " /proc/mounts

echo
echo "Worker ready: ${WORKER_FQDN} mounted ${NAS_FQDN}:${EXPORT_DIR} on ${MOUNT_DIR}."
