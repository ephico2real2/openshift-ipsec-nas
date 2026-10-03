#!/bin/bash
# Entrypoint for the containerized test NAS: an NFSv4 server that only accepts NFS arriving
# through IPsec (libreswan, IKEv2, transport mode, certificate authentication).
# It does the same five steps as lab/rhel/setup-nas.sh, without systemd.
#
# Run it privileged and on the host network: ESP (IP protocol 50) cannot be published like a port.
#   WORKER_SUBNET   required, the subnet the workers connect from
#   PKI_DIR         /pki, must hold ca.pem and nas.p12 (empty password, friendly name "nas")
#   EXPORT_DIR      /export, mount a real filesystem here (a volume or a host directory)
#   ALLOW_DUPLICATE_IDS  yes for Options A and C (every worker presents the same certificate identity)
#   NAS_RIGHTID     the peer identity the NAS accepts, default %fromcert (the certificate's subject DN)
#   NAS_LEFT        the address the workers connect to, on a host with several network interfaces
set -euo pipefail

WORKER_SUBNET="${WORKER_SUBNET:?set WORKER_SUBNET, e.g. 192.168.104.0/24}"
PKI_DIR="${PKI_DIR:-/pki}"
EXPORT_DIR="${EXPORT_DIR:-/export}"
ALLOW_DUPLICATE_IDS="${ALLOW_DUPLICATE_IDS:-no}"
NAS_RIGHTID="${NAS_RIGHTID:-%fromcert}"
NAS_LEFT="${NAS_LEFT:-%defaultroute}"
NSS_DB=/var/lib/ipsec/nss
NFS_ROOT=/srv/nfs4

log() { echo "$(date -u +%FT%TZ) [nas] $*"; }
die() { log "ERROR: $*"; exit 1; }

import_certs() {
  [[ -s "${PKI_DIR}/ca.pem" ]] || die "missing ${PKI_DIR}/ca.pem"
  [[ -s "${PKI_DIR}/nas.p12" ]] || die "missing ${PKI_DIR}/nas.p12"
  ipsec checknss
  certutil -A -n CA -t 'CT,C,C' -d "${NSS_DB}" -i "${PKI_DIR}/ca.pem"
  pk12util -W '' -i "${PKI_DIR}/nas.p12" -d "${NSS_DB}"
  certutil -M -n nas -t 'u,u,u' -d "${NSS_DB}"
  certutil -L -d "${NSS_DB}"
}

write_ipsec_conf() {
  local uniqueids=yes
  [[ "${ALLOW_DUPLICATE_IDS}" == "yes" ]] && uniqueids=no
  cat > /etc/ipsec.conf <<EOF
config setup
    uniqueids=${uniqueids}

include /etc/crypto-policies/back-ends/libreswan.config
include /etc/ipsec.d/*.conf
EOF
  cat > /etc/ipsec.d/nas-workers.conf <<EOF
# The NAS answers any peer that holds a certificate from our CA.
# Which peers may connect at all is limited by the firewall (worker subnet), not here.
conn workers
    left=${NAS_LEFT}
    leftid=%fromcert
    leftcert=nas
    leftrsasigkey=%cert
    right=%any
    rightid=${NAS_RIGHTID}
    rightrsasigkey=%cert
    rightca=%same
    ikev2=insist
    type=transport
    auto=add
EOF
}

start_pluto() {
  mkdir -p /run/pluto
  # --stderrlog sends pluto's log to the container log
  /usr/libexec/ipsec/pluto --config /etc/ipsec.conf --nofork --stderrlog &
  PLUTO_PID=$!
  for _ in $(seq 1 30); do
    ipsec status 2>/dev/null | grep -q '"workers":.*%any' && { log "pluto is up (pid ${PLUTO_PID})"; return 0; }
    kill -0 "${PLUTO_PID}" 2>/dev/null || die "pluto exited during start"
    sleep 1
  done
  die "pluto did not load the workers connection within 30s"
}

# IKE and ESP from the workers; NFS only when it arrived through IPsec.
load_firewall() {
  nft -f - <<EOF
table inet nas_ipsec_only
delete table inet nas_ipsec_only
table inet nas_ipsec_only {
    chain input {
        type filter hook input priority filter; policy accept;
        ip saddr ${WORKER_SUBNET} udp dport { 500, 4500 } counter accept comment "ike"
        ip saddr ${WORKER_SUBNET} meta l4proto esp counter accept comment "esp-in"
        ip saddr ${WORKER_SUBNET} tcp dport 2049 meta ipsec exists counter accept comment "nfs-over-ipsec"
        tcp dport 2049 counter drop comment "nfs-cleartext-dropped"
    }
}
EOF
  log "firewall: NFS (tcp/2049) is accepted only when it arrives through IPsec"
}

start_nfs_server() {
  mkdir -p "${EXPORT_DIR}"
  chmod 0777 "${EXPORT_DIR}"

  # NFSv4 needs a root it can export. A container's own root filesystem is overlayfs, which the
  # kernel NFS server refuses, so the root is a small tmpfs with the real export bound under it.
  # Clients mount <nas>:${EXPORT_DIR}, the same path as on a RHEL host.
  mkdir -p "${NFS_ROOT}"
  mountpoint -q "${NFS_ROOT}" || mount -t tmpfs -o mode=0755 tmpfs "${NFS_ROOT}"
  mkdir -p "${NFS_ROOT}${EXPORT_DIR}"
  mountpoint -q "${NFS_ROOT}${EXPORT_DIR}" || mount --bind "${EXPORT_DIR}" "${NFS_ROOT}${EXPORT_DIR}"
  cat > /etc/exports <<EOF
${NFS_ROOT} ${WORKER_SUBNET}(ro,fsid=0,no_subtree_check)
${NFS_ROOT}${EXPORT_DIR} ${WORKER_SUBNET}(rw,sync,no_subtree_check)
EOF

  # Mounting the nfsd filesystem makes the kernel load the nfsd module if the host allows it.
  if [[ ! -d /proc/fs/nfsd ]]; then
    mkdir -p /run/nfsd-probe
    mount -t nfsd nfsd /run/nfsd-probe 2>/dev/null && umount /run/nfsd-probe || true
  fi
  [[ -d /proc/fs/nfsd ]] || die "kernel NFS server not available: run 'modprobe nfsd' on the container host"
  mountpoint -q /proc/fs/nfsd || mount -t nfsd nfsd /proc/fs/nfsd

  # NFSv4 client tracking daemon (nfs-server.service starts it on a RHEL host). Without it the
  # kernel cannot tell that no client needs to recover, and holds every write for a 90-second
  # grace period after each start.
  mkdir -p /var/lib/nfs/rpc_pipefs
  mountpoint -q /var/lib/nfs/rpc_pipefs || mount -t rpc_pipefs sunrpc /var/lib/nfs/rpc_pipefs
  nfsdcld

  exportfs -ra
  # NFSv4 only: no rpcbind, no NFSv3 side protocols, one TCP port (2049)
  rpc.mountd --no-nfs-version 2 --no-nfs-version 3
  rpc.nfsd --no-nfs-version 3 --nfs-version 4 --no-udp 8
  log "NFSv4 server is up, exporting:"
  exportfs -v
}

shutdown() {
  log "shutting down"
  rpc.nfsd 0 || true
  exportfs -ua || true
  nft delete table inet nas_ipsec_only 2>/dev/null || true
  ipsec whack --shutdown 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

import_certs
write_ipsec_conf
start_pluto
load_firewall
start_nfs_server

log "ready: exporting ${EXPORT_DIR} to ${WORKER_SUBNET}, IPsec only"
wait "${PLUTO_PID}"
