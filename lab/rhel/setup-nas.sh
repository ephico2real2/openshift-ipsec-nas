#!/bin/bash
# Turns a RHEL 10 (or CentOS Stream 10) host into the test NAS:
# an NFSv4 server that only accepts NFS arriving through IPsec (libreswan, IKEv2, transport mode,
# certificate authentication). Run as root. docs/lab/test-nas-rhel.md walks through each step.
#
#   WORKER_SUBNET=192.168.104.0/24 PKI_DIR=/root/ipsec-pki ./setup-nas.sh
#
# On a host with more than one network interface, also set NAS_LEFT to the address the workers
# connect to; the default picks the interface that holds the default route.
#
# For ONE client that reaches the NAS through NAT (a CRC node on the same Mac), also set NAT_CLIENT
# to that client's own address. libreswan refuses IKEv2 transport mode behind NAT
# (TS_UNACCEPTABLE), so the connection is then built in tunnel mode and NFS arrives from the
# client's own address instead of the address the NAT shows. NAS_LEFT must be an IP in that case.
#
# PKI_DIR must hold ca.pem and nas.p12 (empty password, friendly name "nas").
set -euo pipefail

WORKER_SUBNET="${WORKER_SUBNET:?set WORKER_SUBNET, e.g. 192.168.104.0/24}"
PKI_DIR="${PKI_DIR:-/root/ipsec-pki}"
EXPORT_DIR="${EXPORT_DIR:-/export}"
NAS_LEFT="${NAS_LEFT:-%defaultroute}"
NAT_CLIENT="${NAT_CLIENT:-}"

# Who NFS is accepted from and exported to, and how the connection carries it
if [[ -n "${NAT_CLIENT}" ]]; then
  [[ "${NAS_LEFT}" != "%defaultroute" ]] || { echo "NAT_CLIENT needs NAS_LEFT set to the NAS IP"; exit 1; }
  NFS_CLIENTS="${NAT_CLIENT}"
  MODE_LINES="    leftsubnet=${NAS_LEFT}/32
    rightsubnet=${NAT_CLIENT}/32
    type=tunnel"
else
  NFS_CLIENTS="${WORKER_SUBNET}"
  MODE_LINES="    type=transport"
fi
# yes only for Option A, where every worker presents the same certificate identity
ALLOW_DUPLICATE_IDS="${ALLOW_DUPLICATE_IDS:-no}"
NSS_DB=/var/lib/ipsec/nss

step() { echo; echo "== $*"; }

step "1. Packages"
dnf -y -q install libreswan nfs-utils nss-tools nftables

step "2. Certificates into the libreswan NSS database"
ipsec checknss
certutil -A -n CA -t 'CT,C,C' -d "${NSS_DB}" -i "${PKI_DIR}/ca.pem"
pk12util -W '' -i "${PKI_DIR}/nas.p12" -d "${NSS_DB}"
certutil -M -n nas -t 'u,u,u' -d "${NSS_DB}"
certutil -L -d "${NSS_DB}"

step "3. libreswan connection for the workers"
cat > /etc/ipsec.d/nas-workers.conf <<CONF
# The NAS answers any peer that holds a certificate from our CA.
# Which peers may connect at all is limited by the firewall (worker subnet), not here.
conn workers
    left=${NAS_LEFT}
    leftid=%fromcert
    leftcert=nas
    leftrsasigkey=%cert
    right=%any
    rightid=%fromcert
    rightrsasigkey=%cert
    rightca=%same
    ikev2=insist
${MODE_LINES}
    auto=add
CONF
# uniqueids belongs to "config setup", which lives in /etc/ipsec.conf. Always write it, so that
# running this script again with the other value really switches it back.
uniqueids=yes
[[ "${ALLOW_DUPLICATE_IDS}" == "yes" ]] && uniqueids=no
sed -i '/^\s*uniqueids=/d' /etc/ipsec.conf
sed -i "/^config setup/a\\\\tuniqueids=${uniqueids}" /etc/ipsec.conf
systemctl enable ipsec
systemctl restart ipsec
# pluto loads connections a moment after the service reports ready
for _ in $(seq 1 20); do
  ipsec status | grep -q '"workers":.*%any' && break
  sleep 1
done
ipsec status | grep -E '"workers":.*%any|uniqueids='

step "4. Firewall: IKE and ESP from the workers, NFS only through IPsec"
cat > /etc/nftables/nas-ipsec-only.nft <<CONF
# NFS (tcp/2049) is accepted only when the packet arrived through IPsec.
table inet nas_ipsec_only
delete table inet nas_ipsec_only
table inet nas_ipsec_only {
    chain input {
        type filter hook input priority filter; policy accept;
        ip saddr ${WORKER_SUBNET} udp dport { 500, 4500 } counter accept comment "ike"
        ip saddr ${WORKER_SUBNET} meta l4proto esp counter accept comment "esp-in"
        ip saddr ${NFS_CLIENTS} tcp dport 2049 meta ipsec exists counter accept comment "nfs-over-ipsec"
        tcp dport 2049 counter drop comment "nfs-cleartext-dropped"
    }
}
CONF
grep -q 'nas-ipsec-only.nft' /etc/sysconfig/nftables.conf \
  || echo 'include "/etc/nftables/nas-ipsec-only.nft"' >> /etc/sysconfig/nftables.conf
systemctl enable --now nftables
systemctl reload nftables
nft list table inet nas_ipsec_only

step "5. NFSv4 server"
mkdir -p "${EXPORT_DIR}"
chmod 0777 "${EXPORT_DIR}"
echo "${EXPORT_DIR} ${NFS_CLIENTS}(rw,sync,no_subtree_check)" > /etc/exports.d/ipsec-nas.exports
# NFSv4 only: one TCP port (2049), no rpcbind and no NFSv3 side protocols
nfsconf --set nfsd vers3 n
systemctl enable --now nfs-server
exportfs -ra
exportfs -v
cat /proc/fs/nfsd/versions

echo
echo "NAS ready: $(hostname -f) exports ${EXPORT_DIR} to ${NFS_CLIENTS}, IPsec only."
