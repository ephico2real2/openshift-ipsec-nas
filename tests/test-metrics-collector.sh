#!/bin/bash
# Unit test for the parser in the ipsec-nas metrics collector
# (manifests/option-b-per-node-certs/25-metrics-scripts.yaml, key collect.sh).
# It feeds recorded "ipsec trafficstatus" output from libreswan 4 and libreswan 5 to the
# collector's own functions, then runs collect() against a stubbed host (a healthy node, no NNCP,
# no certificate, libreswan not answering). Run from the repository root: tests/test-metrics-collector.sh
set -euo pipefail

MANIFEST="manifests/option-b-per-node-certs/25-metrics-scripts.yaml"
script="$(mktemp)"
trap 'rm -f "${script}"' EXIT

# the script is the block between the two ConfigMap keys, indented by four spaces
sed -n '/^  collect\.sh: |$/,/^  serve\.py: |$/p' "${MANIFEST}" | sed '1d;$d' | sed 's/^    //' > "${script}"
[[ -s "${script}" ]] || { echo "could not extract collect.sh from ${MANIFEST}"; exit 1; }
bash -n "${script}"

export NODE_NAME=test-node
# shellcheck disable=SC1090
source "${script}"
set +u   # the collector runs without -e; keep its functions' behaviour

fail=0
check() {  # $1 = name, $2 = expected, $3 = actual
  if [[ "$2" == "$3" ]]; then
    echo "ok    $1"
  else
    echo "FAIL  $1"; echo "      expected: [$2]"; echo "      actual:   [$3]"; fail=1
  fi
}

check "libreswan 5.4 line (recorded in the lab)" \
  "1790967726 46572 15037832 CN=lima-lab-nas.internal, O=IPsec NAS test" \
  "$(tunnel_fields <<<"#2: \"ipsec-nas\", type=ESP, add_time=1790967726, inBytes=46572, outBytes=15037832, maxBytes=2^63B, id='CN=lima-lab-nas.internal, O=IPsec NAS test'")"

check "libreswan 4.15 line with the 006 prefix (recorded in the lab)" \
  "1790964715 4644 4712 CN=lima-lab-nas.internal, O=IPsec NAS test" \
  "$(tunnel_fields <<<"006 #2: \"ipsec-nas\", type=ESP, add_time=1790964715, inBytes=4644, outBytes=4712, maxBytes=2^63B, id='CN=lima-lab-nas.internal, O=IPsec NAS test'")"

check "two tunnels of the same connection: the newest wins" \
  "200 30 40 CN=nas" \
  "$(printf '%s\n' "#2: \"ipsec-nas\", type=ESP, add_time=100, inBytes=10, outBytes=20, maxBytes=2^63B, id='CN=nas'" "#4: \"ipsec-nas\", type=ESP, add_time=200, inBytes=30, outBytes=40, maxBytes=2^63B, id='CN=nas'" | tunnel_fields)"

check "another connection's line is ignored" \
  "" \
  "$(tunnel_fields <<<"#2: \"workers\"[1] 192.168.104.3, type=ESP, add_time=1790967726, inBytes=1, outBytes=2, maxBytes=2^63B, id='CN=lima-lab-worker1.internal'")"

check "no tunnels at all" "" "$(tunnel_fields <<<"")"

# On an OpenShift node NetworkManager names the libreswan connection by its UUID (recorded on CRC 4.22.7)
crc_line="#2: \"c5ccbae6-1377-43d4-8a6b-ae155d137023\", type=ESP, add_time=1790976853, inBytes=34492, outBytes=5477144, maxBytes=2^63B, id='O=KCS OpenShift lab, CN=crc-nas.lab.internal'"
check "a node's line is NOT found by the plain name" "" "$(tunnel_fields <<<"${crc_line}")"
check "a node's line is found by the UUID (libreswan 5.3, recorded on CRC)" \
  "1790976853 34492 5477144 O=KCS OpenShift lab, CN=crc-nas.lab.internal" \
  "$(tunnel_fields "c5ccbae6-1377-43d4-8a6b-ae155d137023" <<<"${crc_line}")"

check "label escaping of quote and backslash" 'a\\b\"c' "$(label_escape 'a\b"c')"

# "ipsec status" recorded on CRC 4.22.7 (libreswan 5.3), for the connection NetworkManager named by UUID
crc_status='#5: "55d87b5d-969e-4363-a2ac-1c60e80ab6b9":4500 ESTABLISHED_CHILD_SA (established Child SA); REKEY in 10284s; REPLACE in 11212s; newest; eroute owner; IKE SA #6; idle;
#6: "55d87b5d-969e-4363-a2ac-1c60e80ab6b9":4500 ESTABLISHED_IKE_SA (established IKE SA); REKEY in 10219s; REPLACE in 11255s; newest; idle;
IKE SAs: total(1), half-open(0), open(0), authenticated(1), anonymous(0)'
check "an established IKE SA for the connection (libreswan 5)" "1" "$(ike_sa_established "55d87b5d-969e-4363-a2ac-1c60e80ab6b9" <<<"${crc_status}")"
check "another connection's IKE SA does not count" "0" "$(ike_sa_established "11111111-2222-3333-4444-555555555555" <<<"${crc_status}")"
check "only a Child SA, no IKE SA" "0" "$(ike_sa_established "55d87b5d-969e-4363-a2ac-1c60e80ab6b9" <<<"$(head -1 <<<"${crc_status}")")"
check "an established IKE SA in libreswan 4's wording" "1" "$(ike_sa_established "ipsec-nas" <<<'000 #6: "ipsec-nas":500 STATE_V2_ESTABLISHED_IKE_SA (established IKE SA); REKEY in 27904s')"

# /proc/net/xfrm_stat of the host, recorded on CRC (kernel 5.14.0-687.29.1.el9_8), shortened
xfrm='XfrmInError             	0
XfrmInNoStates          	0
XfrmInTmplMismatch      	1
XfrmOutPolBlock         	0'
check "kernel IPsec counters, one per line" "$(printf 'XfrmInError 0\nXfrmInNoStates 0\nXfrmInTmplMismatch 1\nXfrmOutPolBlock 0')" "$(xfrm_counters <<<"${xfrm}")"
check "lines that are not counters are ignored" "XfrmInError 7" "$(printf 'garbage line here\nXfrmInError 7\n' | xfrm_counters)"

# The host's mounts, recorded on CRC (the demo application's NFS volume), plus an IPv6 server and a non-NFS line
mounts='192.168.64.8:/export /var/lib/kubelet/pods/f835/volumes/kubernetes.io~nfs/ipsec-nas-demo nfs4 rw,noatime,vers=4.1 0 0
192.168.64.8:/export/b /var/lib/kubelet/pods/aa11/volumes/kubernetes.io~nfs/other nfs4 rw 0 0
[fd00::5]:/data /mnt/v6 nfs rw 0 0
/dev/vda4 /sysroot xfs ro 0 0'
check "NFS mounts counted per server, IPv6 in brackets kept" "$(printf '192.168.64.8 2\n[fd00::5] 1')" "$(nfs_mount_servers <<<"${mounts}")"
check "no NFS mount: nothing printed" "" "$(nfs_mount_servers <<<'/dev/vda4 /sysroot xfs ro 0 0')"

# collect() end to end, with the host replaced by a stub of "chroot /host ...". The answers are the
# formats recorded on CRC above, under one UUID. Certificate expiry and import time are not checked:
# they need GNU date and stat, and this test also runs on macOS.
UUID="55d87b5d-969e-4363-a2ac-1c60e80ab6b9"
chroot() {
  shift   # /host
  case "$*" in
    *"connection.uuid connection show ipsec-nas"*) [[ -n "${FAKE_UUID}" ]] && echo "${FAKE_UUID}" ;;
    "ipsec trafficstatus")
      [[ "${FAKE_LIBRESWAN}" == up ]] || return 1
      echo "#4: \"${UUID}\", type=ESP, add_time=1791003326, inBytes=8384, outBytes=24672, maxBytes=2^63B, id='CN=crc-nas.lab.internal'" ;;
    "ipsec status") echo "${crc_status}" ;;
    "certutil -L -n left_server -d /var/lib/ipsec/nss") [[ "${FAKE_CERT}" == present ]] ;;
    "ipsec --version") echo "Libreswan 5.3" ;;
    *) return 1 ;;
  esac
}
host="$(mktemp -d)"
trap 'rm -f "${script}"; rm -rf "${host}"' EXIT
printf '%s\n' "${xfrm}" > "${host}/xfrm_stat"
printf '%s\n' "${mounts}" > "${host}/mounts"
XFRM_STAT="${host}/xfrm_stat" HOST_MOUNTS="${host}/mounts" OUT_FILE="${host}/ipsec_nas.prom" STAMP="${host}/none"
metric() { grep "^$1{" "${OUT_FILE}" || true; }
set +e   # as in the collector (set -uo pipefail): a failed host command must not stop collect()

FAKE_UUID="${UUID}" FAKE_LIBRESWAN=up FAKE_CERT=present
collect
check "healthy node: the tunnel is found under NetworkManager's UUID" 'ipsec_nas_tunnel_up{node="test-node",connection="ipsec-nas"} 1' "$(metric ipsec_nas_tunnel_up)"
check "healthy node: the connection is configured" 'ipsec_nas_connection_configured{node="test-node",connection="ipsec-nas"} 1' "$(metric ipsec_nas_connection_configured)"
check "healthy node: the certificate is present" 'ipsec_nas_certificate_present{node="test-node",nickname="left_server"} 1' "$(metric ipsec_nas_certificate_present)"
check "healthy node: the IKE SA is established" 'ipsec_nas_ike_sa_established{node="test-node",connection="ipsec-nas"} 1' "$(metric ipsec_nas_ike_sa_established)"
check "healthy node: the NAS identity" 'ipsec_nas_tunnel_info{node="test-node",connection="ipsec-nas",peer_id="CN=crc-nas.lab.internal"} 1' "$(metric ipsec_nas_tunnel_info)"
check "healthy node: one kernel counter per line" 'ipsec_nas_xfrm_errors_total{node="test-node",counter="XfrmInTmplMismatch"} 1' "$(metric ipsec_nas_xfrm_errors_total | grep TmplMismatch)"
check "healthy node: NFS mounts per server" "$(printf '%s\n' 'ipsec_nas_nfs_mounts{node="test-node",server="192.168.64.8"} 2' 'ipsec_nas_nfs_mounts{node="test-node",server="[fd00::5]"} 1')" "$(metric ipsec_nas_nfs_mounts)"

FAKE_UUID=""
collect
check "no NNCP on the node: the connection is not configured" 'ipsec_nas_connection_configured{node="test-node",connection="ipsec-nas"} 0' "$(metric ipsec_nas_connection_configured)"
check "no NNCP on the node: the plain name finds no tunnel" 'ipsec_nas_tunnel_up{node="test-node",connection="ipsec-nas"} 0' "$(metric ipsec_nas_tunnel_up)"

FAKE_UUID="${UUID}" FAKE_CERT=missing
collect
check "certificate removed from NSS" 'ipsec_nas_certificate_present{node="test-node",nickname="left_server"} 0' "$(metric ipsec_nas_certificate_present)"

FAKE_LIBRESWAN=down
collect
check "libreswan not answering: collect_success is 0" 'ipsec_nas_collect_success{node="test-node"} 0' "$(metric ipsec_nas_collect_success)"
check "libreswan not answering: the IKE SA state is unknown, so not written" "" "$(metric ipsec_nas_ike_sa_established)"
unset -f chroot

[[ ${fail} -eq 0 ]] && echo "all parser tests passed" || exit 1
