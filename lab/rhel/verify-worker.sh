#!/bin/bash
# Proves on a worker (or stand-in) that NFS to the NAS really travels through IPsec:
# writes data to the mount and checks that the tunnel's byte counter grew by at least that much.
# Run as root after setup-worker.sh.
set -euo pipefail

MOUNT_DIR="${MOUNT_DIR:-/mnt/nas}"
SIZE_MB="${SIZE_MB:-5}"

out_bytes() { ipsec trafficstatus | sed -n 's/.*"ipsec-nas".*outBytes=\([0-9]*\).*/\1/p' | head -1; }

mountpoint -q "${MOUNT_DIR}" || { echo "FAIL: ${MOUNT_DIR} is not mounted"; exit 1; }
before="$(out_bytes)"
[[ -n "${before}" ]] || { echo "FAIL: no established ipsec-nas tunnel"; exit 1; }

file="${MOUNT_DIR}/verify-$(hostname -s).bin"
dd if=/dev/urandom of="${file}" bs=1M count="${SIZE_MB}" conv=fsync status=none
sum_local="$(sha256sum < "${file}" | cut -d' ' -f1)"

after="$(out_bytes)"
grew=$(( after - before ))
want=$(( SIZE_MB * 1024 * 1024 ))

echo "tunnel outBytes: before=${before} after=${after} grew=${grew} (wrote ${want})"
echo "kernel SAs to the NAS:"
ip xfrm state | grep -E '^src|proto esp|encap' | sed 's/^/  /'

[[ "${grew}" -ge "${want}" ]] || { echo "FAIL: the tunnel counter grew less than the data written"; exit 1; }
echo "PASS: ${SIZE_MB} MiB written to ${file} went through the IPsec tunnel (sha256 ${sum_local:0:16}...)"
