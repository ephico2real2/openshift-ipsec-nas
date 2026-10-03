#!/bin/bash
# Issues ONE wildcard certificate for every worker (Option C) from the throwaway test CA that
# make-test-pki.sh created in <pki-dir>. Test use only, like the rest of lab/pki.
#
#   issue-wildcard.sh <pki-dir> <domain>      e.g. issue-wildcard.sh /tmp/pki internal
#
# Writes <pki-dir>/wildcard-workers.p12: SAN DNS:*.<domain>, friendly name "left_server", empty
# password. "*." covers exactly one label: worker-0.<domain>, not a.worker-0.<domain>.
set -euo pipefail

PKI="${1:?usage: issue-wildcard.sh <pki-dir> <domain>}"
DOMAIN="${2:?usage: issue-wildcard.sh <pki-dir> <domain>}"
cd "${PKI}"
[[ -s ca.pem && -s ca.key ]] || { echo "no test CA in ${PKI}: run make-test-pki.sh first" >&2; exit 1; }

san="DNS:*.${DOMAIN}"
openssl req -new -newkey rsa:3072 -nodes -keyout wildcard-workers.key -out wildcard-workers.csr \
  -subj "/CN=ocp-ipsec-workers-wildcard/O=IPsec NAS test" -addext "subjectAltName=${san}" 2>/dev/null
openssl x509 -req -in wildcard-workers.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -out wildcard-workers.crt \
  -extfile <(printf 'subjectAltName=%s\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\nbasicConstraints=critical,CA:FALSE\n' "${san}") 2>/dev/null
openssl pkcs12 -export -in wildcard-workers.crt -inkey wildcard-workers.key -name left_server \
  -out wildcard-workers.p12 -passout pass:
openssl verify -CAfile ca.pem wildcard-workers.crt
chmod 0644 wildcard-workers.p12
