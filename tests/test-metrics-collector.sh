#!/bin/bash
# Unit test for the parser in the ipsec-nas metrics collector
# (manifests/option-b-per-node-certs/25-metrics-scripts.yaml, key collect.sh).
# It feeds recorded "ipsec trafficstatus" output from libreswan 4 and libreswan 5 to the
# collector's own functions. Run from the repository root: tests/test-metrics-collector.sh
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

check "label escaping of quote and backslash" 'a\\b\"c' "$(label_escape 'a\b"c')"

[[ ${fail} -eq 0 ]] && echo "all parser tests passed" || exit 1
