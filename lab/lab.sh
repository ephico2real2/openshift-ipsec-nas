#!/bin/bash
# Lima lab for the OpenShift -> NAS IPsec guide: one test NAS and two stand-in workers, as VMs on
# this Mac. docs/lab/lima-lab.md explains every step this script automates.
#
#   lab/lab.sh up [vm|container]   create the VMs, set up the NAS and both workers, verify
#   lab/lab.sh verify              write through both tunnels again and show the NAS counters
#   lab/lab.sh option-a            shared-certificate case: show the duplicate-ID problem and the fix
#   lab/lab.sh option-c            wildcard-certificate cases: which NAS identity settings work
#   lab/lab.sh status              list the VMs and the NAS tunnels
#   lab/lab.sh down                delete the lab VMs
#
# The VMs run CentOS Stream 10, the upstream of RHEL 10 (lab/lima/stream10.yaml).
# vm runs the NAS as a RHEL-style host (lab/rhel/setup-nas.sh); container runs it as a container
# on that VM (lab/container/run-nas.sh). Default vm.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NAS=lab-nas
WORKERS="lab-worker1 lab-worker2"
# Lima's user-v2 network: every lab VM gets an address here and a name lima-<vm>.internal
SUBNET=192.168.104.0/24

fqdn() { echo "lima-$1.internal"; }
say()  { echo; echo "### $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
# run a command as root in a VM
vm()   { local name="$1"; shift; limactl shell "${name}" sudo "$@"; }
exists() { limactl list -q 2>/dev/null | grep -qx "$1"; }

nas_mode() { limactl shell "${NAS}" cat /tmp/lab-nas-mode 2>/dev/null || echo vm; }

# (re)configure the NAS; $1 = yes to allow duplicate peer IDs (Options A and C),
# $2 = the peer identity it accepts (rightid), default %fromcert
nas_setup() {
  local allow_dup="$1" rightid="${2:-%fromcert}" mode
  mode="$(nas_mode)"
  if [[ "${mode}" == "container" ]]; then
    vm "${NAS}" WORKER_SUBNET="${SUBNET}" ALLOW_DUPLICATE_IDS="${allow_dup}" NAS_RIGHTID="${rightid}" bash /tmp/lab/container/run-nas.sh
  else
    vm "${NAS}" WORKER_SUBNET="${SUBNET}" ALLOW_DUPLICATE_IDS="${allow_dup}" NAS_RIGHTID="${rightid}" bash /tmp/lab/rhel/setup-nas.sh
  fi
}

# run an ipsec subcommand where the NAS's libreswan lives
nas_ipsec() {
  if [[ "$(nas_mode)" == "container" ]]; then
    vm "${NAS}" podman exec ipsec-test-nas ipsec "$@"
  else
    vm "${NAS}" ipsec "$@"
  fi
}

nas_tunnel_count() { nas_ipsec trafficstatus | grep -c '"workers"' || true; }

nas_counters() {
  nas_ipsec trafficstatus
  vm "${NAS}" nft list table inet nas_ipsec_only | grep counter
}

verify_workers() {
  local w
  for w in ${WORKERS}; do
    say "verify ${w}"
    vm "${w}" bash /tmp/lab/rhel/verify-worker.sh
  done
  say "NAS: tunnels and firewall counters"
  nas_counters
}

cmd_up() {
  local mode="${1:-vm}" v nas_ip
  [[ "${mode}" == "vm" || "${mode}" == "container" ]] || die "the argument must be vm or container"
  command -v limactl >/dev/null || die "limactl not found: brew install lima"

  say "create the VMs (CentOS Stream 10)"
  for v in ${NAS} ${WORKERS}; do
    if exists "${v}"; then
      echo "${v} already exists, reusing it"
    else
      limactl create --name="${v}" --tty=false "${HERE}/lima/stream10.yaml"
    fi
    limactl start "${v}" --tty=false 2>&1 | grep -E 'READY|already running|level=(error|fatal)' || true
    limactl shell "${v}" rm -rf /tmp/lab
    limactl copy -r "${HERE}" "${v}:/tmp/lab"
  done
  limactl shell "${NAS}" bash -c "echo ${mode} > /tmp/lab-nas-mode"
  nas_ip="$(limactl shell "${NAS}" getent hosts "$(fqdn "${NAS}")" | awk '{print $1}')"
  [[ -n "${nas_ip}" ]] || die "could not resolve $(fqdn "${NAS}") inside ${NAS}"
  echo "NAS: $(fqdn "${NAS}") = ${nas_ip}"

  say "throwaway test PKI, created inside ${NAS}"
  vm "${NAS}" dnf -y -q install openssl
  # shellcheck disable=SC2046
  limactl shell "${NAS}" /tmp/lab/pki/make-test-pki.sh /tmp/pki "$(fqdn "${NAS}")" $(for v in ${WORKERS}; do fqdn "${v}"; done)
  vm "${NAS}" install -D -m 0644 -t /root/ipsec-pki /tmp/pki/ca.pem /tmp/pki/nas.p12
  for v in ${WORKERS}; do
    limactl copy "${NAS}:/tmp/pki/ca.pem" "${v}:/tmp/ca.pem"
    limactl copy "${NAS}:/tmp/pki/$(fqdn "${v}").p12" "${v}:/tmp/left_server.p12"
    limactl copy "${NAS}:/tmp/pki/shared-workers.p12" "${v}:/tmp/shared-workers.p12"
    limactl copy "${NAS}:/tmp/pki/wildcard-workers.p12" "${v}:/tmp/wildcard-workers.p12"
    vm "${v}" install -D -m 0644 -t /root/ipsec-pki /tmp/ca.pem /tmp/left_server.p12 /tmp/shared-workers.p12 /tmp/wildcard-workers.p12
  done

  say "NAS setup (${mode})"
  [[ "${mode}" == "container" ]] && vm "${NAS}" dnf -y -q install podman
  nas_setup no

  say "before any tunnel exists: cleartext NFS from a worker must be dropped"
  v="${WORKERS%% *}"
  vm "${v}" dnf -y -q install nfs-utils
  if vm "${v}" bash -c "mkdir -p /mnt/cleartext && timeout 12 mount -t nfs4 -o retry=0,timeo=30,retrans=1 $(fqdn "${NAS}"):/export /mnt/cleartext" 2>/dev/null; then
    die "cleartext NFS was accepted by the NAS"
  fi
  echo "PASS: the cleartext mount got no answer"

  for v in ${WORKERS}; do
    say "worker setup: ${v}"
    vm "${v}" WORKER_FQDN="$(fqdn "${v}")" NAS_FQDN="$(fqdn "${NAS}")" NAS_IP="${nas_ip}" bash /tmp/lab/rhel/setup-worker.sh
  done

  verify_workers
  say "lab is up, NAS as ${mode}. Delete it with: lab/lab.sh down"
}

cmd_option_a() {
  local w first second max n
  first="${WORKERS%% *}"; second="${WORKERS##* }"

  say "Option A: both workers switch to the ONE shared certificate (NAS still on uniqueids=yes)"
  nas_setup no
  for w in ${first} ${second}; do
    echo "--- ${w}"
    vm "${w}" bash /tmp/lab/rhel/switch-worker-cert.sh /root/ipsec-pki/shared-workers.p12
  done

  say "expected problem: the NAS keeps only ONE tunnel for the shared identity"
  max=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    n="$(nas_tunnel_count)"
    [[ "${n}" -gt "${max}" ]] && max="${n}"
    sleep 1
  done
  nas_ipsec trafficstatus
  if [[ "${max}" -le 1 ]]; then
    echo "CONFIRMED: over 10 seconds the NAS never held both workers' tunnels at once (most: ${max})"
  else
    echo "NOTE: the NAS held ${max} tunnels at once; it did not treat the two workers as one peer"
  fi

  say "the fix on the NAS: allow duplicate peer IDs (uniqueids=no)"
  nas_setup yes
  for w in ${first} ${second}; do
    # shellcheck disable=SC2016  # expanded by the shell in the VM
    vm "${w}" bash -c 'systemctl restart ipsec; for i in $(seq 1 30); do ipsec trafficstatus | grep -q ipsec-nas && break; sleep 1; done'
  done
  echo "NAS tunnels now: $(nas_tunnel_count) (expected 2)"
  verify_workers
}

# set a worker's IKE identity (leftid) and reconnect. The restart matters: pluto keeps the loaded
# connection, so "ipsec down/up" alone would still send the old identity.
worker_id() {  # $1 = worker, $2 = leftid
  vm "$1" sed -i "s/^\(\s*leftid=\).*/\1$2/" /etc/ipsec.d/ipsec-nas.conf
  # shellcheck disable=SC2016  # expanded by the shell in the VM
  vm "$1" bash -c 'systemctl restart ipsec; for i in $(seq 1 20); do ipsec trafficstatus | grep -q ipsec-nas && break; sleep 1; done; ipsec status | grep -o "our id=[^;]*" | head -1'
}

# the NAS's tunnel count once a second for 15 s
sample_tunnels() {
  local samples="" _
  for _ in $(seq 1 15); do samples+=" $(nas_tunnel_count)"; sleep 1; done
  echo "NAS tunnels, once a second for 15 s:${samples}"
  nas_ipsec trafficstatus | cut -c1-150
}

# One wildcard certificate on both workers (Option C, docs/50-option-c-wildcard-certificate.md).
# Each case sets the identity the workers send and the NAS's rightid and uniqueids, then counts
# the NAS's tunnels. NFS is checked only where both tunnels hold: with fewer, a write to the hard
# NFS mount would hang.
option_c_case() {  # $1 = label, $2 = workers' leftid ("fqdn" = each its own name), $3 = NAS rightid, $4 = NAS allows duplicate IDs
  local w
  say "case $1: workers leftid=$2, NAS rightid=$3, uniqueids=$([[ "$4" == yes ]] && echo no || echo yes)"
  nas_setup "$4" "$3" >/dev/null
  for w in ${WORKERS}; do
    if [[ "$2" == "fqdn" ]]; then worker_id "${w}" "@$(fqdn "${w}")"; else worker_id "${w}" "$2"; fi
  done
  sample_tunnels
  if [[ "$(nas_tunnel_count)" -ge 2 ]]; then verify_workers; else echo "fewer than 2 tunnels: no NFS check"; fi
}

cmd_option_c() {
  local w domain
  domain="$(fqdn "${NAS}")"; domain="${domain#*.}"
  say "copy the lab scripts again, and issue the wildcard certificate *.${domain} if it is missing"
  for w in ${NAS} ${WORKERS}; do
    limactl shell "${w}" rm -rf /tmp/lab
    limactl copy -r "${HERE}" "${w}:/tmp/lab"
  done
  limactl shell "${NAS}" test -s /tmp/pki/wildcard-workers.p12 || vm "${NAS}" /tmp/lab/pki/issue-wildcard.sh /tmp/pki "${domain}"
  for w in ${WORKERS}; do
    limactl copy "${NAS}:/tmp/pki/wildcard-workers.p12" "${w}:/tmp/wildcard-workers.p12"
    vm "${w}" install -D -m 0644 -t /root/ipsec-pki /tmp/wildcard-workers.p12
    vm "${w}" bash /tmp/lab/rhel/switch-worker-cert.sh /root/ipsec-pki/wildcard-workers.p12 | grep -E 'Subject:|DNS name'
  done
  nas_ipsec --version

  option_c_case 1 %fromcert %fromcert no
  option_c_case 2 %fromcert %fromcert yes
  option_c_case 3 fqdn %fromcert no
  option_c_case 4 fqdn %any no
  option_c_case 5 fqdn "@*.${domain}" no
  option_c_case 6 fqdn "@*.${domain}" yes

  w="${WORKERS%% *}"
  say "negative: ${w} claims an identity outside *.${domain}, NAS as in case 6"
  worker_id "${w}" "@$(fqdn "${w}" | cut -d. -f1).example.org"
  sleep 5
  vm "${w}" bash -c 'ipsec trafficstatus | grep -c "\"ipsec-nas\"" | sed "s/^/tunnels on this worker: /"'
  nas_ipsec trafficstatus | cut -c1-150

  say "restore: the NAS defaults, each worker its own certificate and leftid=%fromcert"
  nas_setup no >/dev/null
  for w in ${WORKERS}; do
    vm "${w}" sed -i 's/^\(\s*leftid=\).*/\1%fromcert/' /etc/ipsec.d/ipsec-nas.conf
    vm "${w}" bash /tmp/lab/rhel/switch-worker-cert.sh /root/ipsec-pki/left_server.p12 >/dev/null
    # shellcheck disable=SC2016  # expanded by the shell in the VM
    vm "${w}" bash -c 'for i in $(seq 1 30); do ipsec trafficstatus | grep -q ipsec-nas && break; sleep 1; done'
  done
  verify_workers
}

cmd_status() {
  limactl list
  exists "${NAS}" || return 0
  say "NAS (${NAS}, mode $(nas_mode)): tunnels and firewall counters"
  nas_counters || true
}

cmd_down() {
  local v
  for v in ${NAS} ${WORKERS}; do
    exists "${v}" || continue
    limactl stop -f "${v}" >/dev/null 2>&1 || true
    limactl delete -f "${v}"
  done
}

case "${1:-}" in
  up)       shift; cmd_up "$@" ;;
  verify)   verify_workers ;;
  option-a) cmd_option_a ;;
  option-c) cmd_option_c ;;
  status)   cmd_status ;;
  down)     cmd_down ;;
  *)        sed -n '2,14p' "$0"; exit 2 ;;
esac
