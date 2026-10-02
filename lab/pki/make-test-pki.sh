#!/bin/bash
# Creates a THROWAWAY certificate authority and the certificates the test NAS needs.
# Never use these outside a test: the CA private key sits next to the certificates.
#
#   make-test-pki.sh <out-dir> <nas-fqdn> <worker-fqdn> [<worker-fqdn> ...]
#
# Writes into <out-dir>:
#   ca.pem                   the test root CA (what both sides trust)
#   nas.p12                  NAS certificate + key, friendly name "nas"
#   <worker-fqdn>.p12        one per worker, friendly name "left_server"   (Option B: one cert per node)
#   shared-workers.p12       ONE cert whose SAN lists every worker         (Option A: shared cert)
# Every .p12 has an empty password, as in the guide (it is imported unattended).
set -euo pipefail

[[ $# -ge 3 ]] || { sed -n '2,12p' "$0"; exit 2; }
OUT="$1"; NAS_FQDN="$2"; shift 2
WORKERS=("$@")

mkdir -p "${OUT}"
cd "${OUT}"

# Same key type, key usage and extended key usage the guide asks the enterprise CA for.
issue() {  # $1 = file base name, $2 = subject CN, $3 = SAN list, $4 = PKCS#12 friendly name
  openssl req -new -newkey rsa:3072 -nodes -keyout "$1.key" -out "$1.csr" \
    -subj "/CN=$2/O=IPsec NAS test" -addext "subjectAltName=$3" 2>/dev/null
  openssl x509 -req -in "$1.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -out "$1.crt" \
    -extfile <(printf 'subjectAltName=%s\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\nbasicConstraints=critical,CA:FALSE\n' "$3") 2>/dev/null
  openssl pkcs12 -export -in "$1.crt" -inkey "$1.key" -name "$4" -out "$1.p12" -passout pass:
  openssl verify -CAfile ca.pem "$1.crt"
}

openssl req -x509 -new -newkey rsa:3072 -nodes -keyout ca.key -out ca.pem -days 30 \
  -subj "/CN=IPsec NAS test root CA/O=IPsec NAS test" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

issue nas "${NAS_FQDN}" "DNS:${NAS_FQDN}" nas

san_all=""
for w in "${WORKERS[@]}"; do
  issue "${w}" "${w}" "DNS:${w}" left_server
  san_all+="${san_all:+,}DNS:${w}"
done

issue shared-workers ocp-ipsec-workers "${san_all}" left_server

chmod 0644 ./*.p12 ca.pem
echo "test PKI written to ${OUT}"
