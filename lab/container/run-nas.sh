#!/bin/bash
# Builds and starts the containerized test NAS on this Linux host. Run as root.
# The host needs podman or docker, and the kernel modules for NFS serving and IPsec (any RHEL-like
# host has them). docs/lab/lima-lab.md shows it running in a Lima VM.
#
#   WORKER_SUBNET=192.168.104.0/24 PKI_DIR=/root/ipsec-pki ./run-nas.sh
#
# PKI_DIR must hold ca.pem and nas.p12 (empty password, friendly name "nas").
set -euo pipefail

WORKER_SUBNET="${WORKER_SUBNET:?set WORKER_SUBNET, e.g. 192.168.104.0/24}"
PKI_DIR="${PKI_DIR:-/root/ipsec-pki}"
EXPORT_DIR="${EXPORT_DIR:-/export}"
ALLOW_DUPLICATE_IDS="${ALLOW_DUPLICATE_IDS:-no}"
NAS_RIGHTID="${NAS_RIGHTID:-%fromcert}"
NAS_LEFT="${NAS_LEFT:-%defaultroute}"
ENGINE="${CONTAINER_ENGINE:-podman}"
NAME=ipsec-test-nas
HERE="$(cd "$(dirname "$0")" && pwd)"

"${ENGINE}" build -t "${NAME}" "${HERE}"

mkdir -p "${EXPORT_DIR}"
"${ENGINE}" rm -f "${NAME}" >/dev/null 2>&1 || true

# --network host: IKE, ESP and NFS use the host's own address, as on a real NAS.
# --privileged:   libreswan programs the kernel's IPsec state, and the kernel NFS server is started.
"${ENGINE}" run -d --name "${NAME}" \
  --network host --privileged --security-opt label=disable \
  -e "WORKER_SUBNET=${WORKER_SUBNET}" \
  -e "ALLOW_DUPLICATE_IDS=${ALLOW_DUPLICATE_IDS}" \
  -e "NAS_RIGHTID=${NAS_RIGHTID}" \
  -e "NAS_LEFT=${NAS_LEFT}" \
  -v "${PKI_DIR}:/pki:ro" \
  -v "${EXPORT_DIR}:/export" \
  "${NAME}"

for _ in $(seq 1 60); do
  "${ENGINE}" logs "${NAME}" 2>&1 | grep -q '\[nas\] ready' && break
  [[ "$("${ENGINE}" inspect -f '{{.State.Running}}' "${NAME}")" == "true" ]] || break
  sleep 1
done
"${ENGINE}" logs "${NAME}" 2>&1 | grep '\[nas\]'
"${ENGINE}" logs "${NAME}" 2>&1 | grep -q '\[nas\] ready' || { echo "the NAS container did not become ready"; exit 1; }
