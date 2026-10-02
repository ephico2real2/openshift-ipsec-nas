#!/bin/bash
# ipsec-nas metrics collector: runs on every worker, beside the cert-sync container.
# Every COLLECT_EVERY seconds it asks the HOST's libreswan about the ipsec-nas connection and
# the HOST's NSS database about the node certificate, and writes the answers as Prometheus
# metrics into a file. The unprivileged "metrics" container serves that file.
# It only reads: nothing on the host is changed.
set -uo pipefail

NSS_DB=/var/lib/ipsec/nss
CERT_NICK=left_server
CONN_NAME=ipsec-nas
# written by sync.sh after each successful certificate import
STAMP=/host/etc/pki/certs/kcs-ipsec/.installed-sha256
OUT_FILE=/metrics/ipsec_nas.prom
COLLECT_EVERY=30

# The name libreswan knows our connection by. NetworkManager hands a connection to libreswan
# under its UUID, so on a node "ipsec trafficstatus" shows the UUID and not "ipsec-nas".
# Falls back to the plain name, which is what a hand-written libreswan connection uses.
libreswan_conn_name() {
  local uuid
  uuid=$(chroot /host nmcli -g connection.uuid connection show "${CONN_NAME}" 2>/dev/null | head -1)
  echo "${uuid:-${CONN_NAME}}"
}

# Reads "ipsec trafficstatus" on stdin and prints, for the newest tunnel of the connection
# named $1 (default: CONN_NAME):
#   <add_time> <inBytes> <outBytes> <peer id>
# libreswan 4 starts each line with "006 ", libreswan 5 does not. Both are matched, because
# the fields are found by name and not by position.
tunnel_fields() {
  awk -v conn="\"${1:-${CONN_NAME}}\"" -v q="'" '
    index($0, conn) {
      t = ""; i = ""; o = ""; id = ""
      if (match($0, /add_time=[0-9]+/)) t = substr($0, RSTART + 9, RLENGTH - 9)
      if (match($0, /inBytes=[0-9]+/))  i = substr($0, RSTART + 8, RLENGTH - 8)
      if (match($0, /outBytes=[0-9]+/)) o = substr($0, RSTART + 9, RLENGTH - 9)
      if (match($0, "id=" q "[^" q "]*" q)) id = substr($0, RSTART + 4, RLENGTH - 5)
      if (t != "" && i != "" && o != "" && t + 0 >= best + 0) { best = t; line = t " " i " " o " " id }
    }
    END { if (line != "") print line }'
}

# Prometheus label values: backslash, double quote and newline must be escaped
label_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' <<<"$1"; }

collect() {
  local now status rc fields up=0 add_time="" in_bytes="" out_bytes="" peer="" end not_after="" imported="" version node
  now=$(date +%s)
  node=$(label_escape "${NODE_NAME}")

  status=$(chroot /host ipsec trafficstatus 2>/dev/null)
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    fields=$(tunnel_fields "$(libreswan_conn_name)" <<<"${status}")
    if [[ -n "${fields}" ]]; then
      up=1
      read -r add_time in_bytes out_bytes peer <<<"${fields}"
    fi
  fi

  end=$(chroot /host bash -c "certutil -L -n ${CERT_NICK} -d ${NSS_DB} -a 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null" | cut -d= -f2)
  [[ -n "${end}" ]] && not_after=$(date -u -d "${end}" +%s 2>/dev/null)
  [[ -e "${STAMP}" ]] && imported=$(stat -c %Y "${STAMP}" 2>/dev/null)
  version=$(chroot /host ipsec --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)

  {
    echo "# HELP ipsec_nas_collect_success 1 if libreswan on the node answered the collector, 0 if it did not."
    echo "# TYPE ipsec_nas_collect_success gauge"
    echo "ipsec_nas_collect_success{node=\"${node}\"} $(( rc == 0 ? 1 : 0 ))"
    echo "# HELP ipsec_nas_collect_timestamp_seconds When the collector last ran."
    echo "# TYPE ipsec_nas_collect_timestamp_seconds gauge"
    echo "ipsec_nas_collect_timestamp_seconds{node=\"${node}\"} ${now}"
    echo "# HELP ipsec_nas_tunnel_up 1 if the node has an established IPsec tunnel to the NAS, 0 if not."
    echo "# TYPE ipsec_nas_tunnel_up gauge"
    echo "ipsec_nas_tunnel_up{node=\"${node}\",connection=\"${CONN_NAME}\"} ${up}"
    if [[ ${up} -eq 1 ]]; then
      echo "# HELP ipsec_nas_tunnel_info The identity the NAS presented, from its certificate."
      echo "# TYPE ipsec_nas_tunnel_info gauge"
      echo "ipsec_nas_tunnel_info{node=\"${node}\",connection=\"${CONN_NAME}\",peer_id=\"$(label_escape "${peer}")\"} 1"
      echo "# HELP ipsec_nas_tunnel_established_timestamp_seconds When the current tunnel was established."
      echo "# TYPE ipsec_nas_tunnel_established_timestamp_seconds gauge"
      echo "ipsec_nas_tunnel_established_timestamp_seconds{node=\"${node}\",connection=\"${CONN_NAME}\"} ${add_time}"
      echo "# HELP ipsec_nas_tunnel_in_bytes_total Bytes received through the current tunnel. Starts again from 0 when the tunnel is re-established."
      echo "# TYPE ipsec_nas_tunnel_in_bytes_total counter"
      echo "ipsec_nas_tunnel_in_bytes_total{node=\"${node}\",connection=\"${CONN_NAME}\"} ${in_bytes}"
      echo "# HELP ipsec_nas_tunnel_out_bytes_total Bytes sent through the current tunnel. Starts again from 0 when the tunnel is re-established."
      echo "# TYPE ipsec_nas_tunnel_out_bytes_total counter"
      echo "ipsec_nas_tunnel_out_bytes_total{node=\"${node}\",connection=\"${CONN_NAME}\"} ${out_bytes}"
    fi
    if [[ -n "${not_after}" ]]; then
      echo "# HELP ipsec_nas_certificate_not_after_timestamp_seconds When the node certificate in the NSS database expires."
      echo "# TYPE ipsec_nas_certificate_not_after_timestamp_seconds gauge"
      echo "ipsec_nas_certificate_not_after_timestamp_seconds{node=\"${node}\",nickname=\"${CERT_NICK}\"} ${not_after}"
    fi
    if [[ -n "${imported}" ]]; then
      echo "# HELP ipsec_nas_certificate_import_timestamp_seconds When cert-sync last imported a certificate into the NSS database."
      echo "# TYPE ipsec_nas_certificate_import_timestamp_seconds gauge"
      echo "ipsec_nas_certificate_import_timestamp_seconds{node=\"${node}\"} ${imported}"
    fi
    if [[ -n "${version}" ]]; then
      echo "# HELP ipsec_nas_libreswan_info The libreswan version on the node."
      echo "# TYPE ipsec_nas_libreswan_info gauge"
      echo "ipsec_nas_libreswan_info{node=\"${node}\",version=\"$(label_escape "${version}")\"} 1"
    fi
  } > "${OUT_FILE}.tmp"
  # rename, so the metrics container never serves a half-written file
  mv "${OUT_FILE}.tmp" "${OUT_FILE}"
}

main() {
  echo "$(date -u +%FT%TZ) [${NODE_NAME}] collecting every ${COLLECT_EVERY}s into ${OUT_FILE}"
  while true; do
    collect
    sleep "${COLLECT_EVERY}"
  done
}

# Run only when executed, so that the tests can load the functions above without starting the loop
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
