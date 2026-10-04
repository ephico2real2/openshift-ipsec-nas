#!/bin/bash
# Option C: the wildcard certificate and its MachineConfig, for the first install and every renewal.
# docs/50-option-c-wildcard-certificate.md walks through it.
#
#   scripts/option-c-certificate.sh csr <dir>
#       A new private key and a CSR for "*.${NODE_DOMAIN}" in <dir>. Send the CSR to the enterprise
#       CA; ask for 2 years (or what the CA allows), key usages digital signature and key
#       encipherment, extended key usages server auth and client auth.
#
#   scripts/option-c-certificate.sh machineconfig <dir> <signed.pem> <root-ca.pem> [<intermediate.pem>]
#       Checks the certificate the CA sent back against the key in <dir>, builds left_server.p12
#       and renders the MachineConfig <dir>/99-${MCP_ROLE}-ipsec-wildcard-cert.yaml.
#       Applying it reboots every node of the pool, one at a time.
#
#   scripts/option-c-certificate.sh from-secret <dir> <namespace>/<secret> <root-ca.pem> [<intermediate.pem>]
#       The same as machineconfig, for a certificate cert-manager issued into a Secret (the chart
#       ipsec-nas-option-c-metrics with certificate.enabled): copies the Secret's tls.key and tls.crt
#       into <dir> (needs oc and read access to the Secret), then runs every check of machineconfig.
#
# Environment: NODE_DOMAIN (required), MCP_ROLE (default worker), OCP_VERSION (default: the
# cluster's x.y.0, read with oc). Needs openssl and butane.
#
# The private key is in <dir> and, inside left_server.p12, in the MachineConfig. Keep <dir> out of
# Git (.gitignore blocks *.key, *.p12, *.csr) and delete it once the MachineConfig is applied.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="${HERE}/manifests/option-c-wildcard-cert/99-ipsec-wildcard-cert.bu.tmpl"
MCP_ROLE="${MCP_ROLE:-worker}"
WARN_DAYS=30

die()  { echo "ERROR: $*" >&2; exit 1; }
ok()   { echo "ok    $*"; }

cmd_csr() {
  local dir="${1:?usage: option-c-certificate.sh csr <dir>}"
  : "${NODE_DOMAIN:?set NODE_DOMAIN, e.g. ocp.example.com}"
  mkdir -p "${dir}"
  [[ ! -e "${dir}/wildcard.key" ]] || die "${dir}/wildcard.key exists: use a new directory for a new key"
  ( umask 077
    openssl req -new -newkey rsa:3072 -nodes \
      -keyout "${dir}/wildcard.key" -out "${dir}/wildcard.csr" \
      -subj "/CN=ocp-ipsec-workers/O=KCS" \
      -addext "subjectAltName=DNS:*.${NODE_DOMAIN}" 2>/dev/null )
  openssl req -in "${dir}/wildcard.csr" -noout -subject
  openssl req -in "${dir}/wildcard.csr" -noout -text | grep -A1 "Subject Alternative Name" | tail -1 | sed "s/^ */SAN: /"
  echo "CSR: ${dir}/wildcard.csr   (the key stays in ${dir}/wildcard.key)"
}

cmd_machineconfig() {
  local dir="${1:?usage: option-c-certificate.sh machineconfig <dir> <signed.pem> <root-ca.pem> [<intermediate.pem>]}"
  local crt="${2:?the signed certificate}" root="${3:?the enterprise root CA}" inter="${4:-}"
  local san chain=() certfile=() mc
  : "${NODE_DOMAIN:?set NODE_DOMAIN, e.g. ocp.example.com}"
  [[ -s "${dir}/wildcard.key" ]] || die "no ${dir}/wildcard.key: run csr first, in the same directory"
  command -v butane >/dev/null || die "butane not found (Mac: brew install butane)"
  [[ -n "${OCP_VERSION:-}" ]] || OCP_VERSION="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1,2).0"

  # 1. The certificate is the one the CSR asked for, for the key in <dir>
  san="$(openssl x509 -in "${crt}" -noout -ext subjectAltName | tail -n +2 | tr -d ' ')"
  [[ "${san}" == "DNS:*.${NODE_DOMAIN}" ]] || die "SAN is '${san}', expected DNS:*.${NODE_DOMAIN}"
  ok "SAN ${san}"
  [[ "$(openssl x509 -in "${crt}" -noout -pubkey | openssl sha256)" == "$(openssl pkey -in "${dir}/wildcard.key" -pubout | openssl sha256)" ]] \
    || die "${crt} does not belong to ${dir}/wildcard.key"
  ok "the certificate belongs to ${dir}/wildcard.key"
  openssl x509 -in "${crt}" -noout -ext extendedKeyUsage | grep -q 'TLS Web Client Authentication' \
    || die "the certificate has no client auth extended key usage"
  ok "extended key usage includes client auth"

  # 2. It chains to the root the NAS trusts, and it is valid long enough
  [[ "$(openssl x509 -in "${root}" -noout -subject | cut -d= -f2-)" == "$(openssl x509 -in "${root}" -noout -issuer | cut -d= -f2-)" ]] \
    || die "${root} is not a root certificate (subject differs from issuer)"
  if [[ -n "${inter}" ]]; then chain=(-untrusted "${inter}"); fi
  openssl verify -CAfile "${root}" ${chain[@]+"${chain[@]}"} "${crt}" >/dev/null || die "${crt} does not chain to ${root}"
  ok "chains to $(openssl x509 -in "${root}" -noout -subject | cut -d= -f2-)"
  openssl x509 -in "${crt}" -noout -checkend $(( WARN_DAYS * 86400 )) >/dev/null \
    || die "the certificate expires within ${WARN_DAYS} days: $(openssl x509 -in "${crt}" -noout -enddate)"
  ok "valid from $(openssl x509 -in "${crt}" -noout -startdate | cut -d= -f2) until $(openssl x509 -in "${crt}" -noout -enddate | cut -d= -f2)"

  # 3. The bundle the node imports: friendly name left_server, empty password (imported unattended)
  cp "${root}" "${dir}/ca.pem"
  if [[ -n "${inter}" ]]; then certfile=(-certfile "${inter}"); fi
  ( umask 077
    openssl pkcs12 -export -in "${crt}" -inkey "${dir}/wildcard.key" ${certfile[@]+"${certfile[@]}"} \
      -name left_server -out "${dir}/left_server.p12" -passout pass: )
  openssl pkcs12 -in "${dir}/left_server.p12" -nokeys -passin pass: 2>/dev/null | grep -q 'friendlyName: left_server' \
    || die "the bundle has no friendly name left_server"
  ok "${dir}/left_server.p12"

  # 4. The MachineConfig
  OCP_VERSION="${OCP_VERSION}" MCP_ROLE="${MCP_ROLE}" \
    perl -pe 's/\$\{(OCP_VERSION|MCP_ROLE)\}/$ENV{$1}/g' "${TEMPLATE}" > "${dir}/99-ipsec-wildcard-cert.bu"
  mc="${dir}/99-${MCP_ROLE}-ipsec-wildcard-cert.yaml"
  butane --files-dir "${dir}" "${dir}/99-ipsec-wildcard-cert.bu" -o "${mc}"
  ok "${mc} (Butane ${OCP_VERSION}, pool ${MCP_ROLE})"
  echo
  echo "Apply it with: oc apply -f ${mc}"
  echo "Every node of the ${MCP_ROLE} pool then reboots, one at a time (watch oc get mcp ${MCP_ROLE})."
}

cmd_from_secret() {
  local dir="${1:?usage: option-c-certificate.sh from-secret <dir> <namespace>/<secret> <root-ca.pem> [<intermediate.pem>]}"
  local ref="${2:?the Secret cert-manager wrote, as <namespace>/<name>}" root="${3:?the enterprise root CA}"
  local ns="${ref%%/*}" name="${ref#*/}"
  [[ "${ns}" != "${ref}" ]] || die "give the Secret as <namespace>/<name>, not '${ref}'"
  [[ -e "${dir}/wildcard.key" ]] && die "${dir}/wildcard.key exists: use a new directory for every certificate"
  ( umask 077; mkdir -p "${dir}"
    oc get secret -n "${ns}" "${name}" -o jsonpath='{.data.tls\.key}' | base64 -d > "${dir}/wildcard.key"
    oc get secret -n "${ns}" "${name}" -o jsonpath='{.data.tls\.crt}' | base64 -d > "${dir}/signed.pem" )
  [[ -s "${dir}/wildcard.key" && -s "${dir}/signed.pem" ]] || die "Secret ${ref} has no tls.key or tls.crt (is the Certificate Ready?)"
  ok "${dir}/wildcard.key and ${dir}/signed.pem from Secret ${ref}"
  shift 3
  cmd_machineconfig "${dir}" "${dir}/signed.pem" "${root}" "$@"
}

case "${1:-}" in
  csr)           shift; cmd_csr "$@" ;;
  machineconfig) shift; cmd_machineconfig "$@" ;;
  from-secret)   shift; cmd_from_secret "$@" ;;
  *)             sed -n '2,25p' "$0"; exit 2 ;;
esac
