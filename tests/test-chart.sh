#!/bin/bash
# The Helm chart must create exactly the objects of the plain manifests, which are the ones that
# were measured on a cluster. This renders both, for the guide's values and for the CRC values,
# and compares every object. Run from the repository root: tests/test-chart.sh
# Needs helm and ruby. It rewrites ./rendered (render.sh does).
set -euo pipefail

CHART=charts/ipsec-nas
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
printf -- '-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----\n' > "${tmp}/root.pem"

helm lint "${CHART}" --set nas.fqdn=x --set nas.ip=1.2.3.4 --set clusterIssuer=x --set nodeDomain=x \
  --set trustCA.pem=x --set prerequisites.skipCheck=true >/dev/null
echo "ok    helm lint"

compare() {  # $1 = label; the rest = helm --set arguments. The matching render.sh values are in the environment.
  local label="$1"; shift
  ./render.sh >/dev/null
  helm template ipsec-nas "${CHART}" -n kcs-ipsec --set prerequisites.skipCheck=true \
    --set-file trustCA.pem="${tmp}/root.pem" --set metrics.grafanaDashboard=true "$@" > "${tmp}/chart.yaml"
  cat rendered/common/03-kyverno-rbac.yaml > "${tmp}/manifests.yaml"
  for f in rendered/option-b-per-node-certs/*.yaml; do
    printf -- '---\n' >> "${tmp}/manifests.yaml"; cat "$f" >> "${tmp}/manifests.yaml"
  done
  ruby -ryaml -e '
    key = ->(d) { [d["kind"], d.dig("metadata", "namespace").to_s, d.dig("metadata", "name")].join("/") }
    load = ->(f) { YAML.load_stream(File.read(f)).compact.to_h { |d| [key.(d), d] } }
    chart, manifests = load.(ARGV[0]), load.(ARGV[1])
    # in the manifests only: the namespace (created before the chart is installed)
    manifests.delete("Namespace//kcs-ipsec")
    # in the chart only: what the guide creates with "oc create configmap" and "oc adm policy"
    chart.delete("ConfigMap/kcs-ipsec/ipsec-trust-ca")
    chart.delete("RoleBinding/kcs-ipsec/system:openshift:scc:privileged")
    # in the chart only: the uninstall hook (it exists only while a release is being removed)
    hooks = chart.select { |_, d| d["metadata"]["annotations"]&.key?("helm.sh/hook") || d["metadata"]["annotations"]&.key?("argocd.argoproj.io/hook") }
    abort "      expected the 7 uninstall hook objects, found #{hooks.size}" unless hooks.size == 7
    hooks.each_key { |k| chart.delete(k) }
    # in the chart only: the checksum that restarts the pods when a script changes
    sum = chart["DaemonSet/kcs-ipsec/ipsec-cert-sync"]["spec"]["template"]["metadata"].delete("annotations")
    abort "      the DaemonSet has no script checksum" unless sum&.key?("checksum/scripts")
    # every chart object carries an Argo CD sync wave; the manifests do not
    waves = chart.values.map { |d| d["metadata"]["annotations"]&.delete("argocd.argoproj.io/sync-wave") }
    abort "      an object has no sync wave" if waves.any?(&:nil?)
    chart.each_value { |d| d["metadata"].delete("annotations") if d["metadata"]["annotations"] == {} }
    bad = (chart.keys | manifests.keys).reject { |k| chart[k] == manifests[k] }
    bad.each { |k| puts "      differs or missing: #{k}" }
    exit(bad.empty? ? 0 : 1)
    ' "${tmp}/chart.yaml" "${tmp}/manifests.yaml" \
    && echo "ok    ${label}: $(grep -c '^kind:' "${tmp}/chart.yaml") chart objects, identical to the manifests" \
    || { echo "FAIL  ${label}"; return 1; }
}

export CLUSTER_ISSUER=company-issuer-rnd OCP_VERSION=4.22.0
unset MCP_ROLE IPSEC_TYPE NAS_RIGHT NODE_LEFT

export NODE_DOMAIN=ocp.example.com NAS_FQDN=nas01.example.com NAS_IP=10.0.0.50
compare "the guide's values (transport mode)" \
  --set nodeDomain=ocp.example.com --set nas.fqdn=nas01.example.com --set nas.ip=10.0.0.50 --set clusterIssuer=company-issuer-rnd

export NODE_DOMAIN=crc.testing NAS_FQDN=crc-nas.lab.internal NAS_IP=192.168.64.8 CLUSTER_ISSUER=enterprise-ca
export IPSEC_TYPE=tunnel NAS_RIGHT=192.168.64.8 NODE_LEFT='%defaultroute'
compare "values-crc.yaml (tunnel mode, as measured on CRC)" -f "${CHART}/values-crc.yaml"

# The checks for missing values and prerequisites must stop the install with a plain message
expect_fail() {  # $1 = label, $2 = text the error must contain; the rest = helm arguments
  local label="$1" want="$2"; shift 2
  if out="$(helm template ipsec-nas "${CHART}" -n kcs-ipsec "$@" 2>&1)"; then
    echo "FAIL  ${label}: rendered although it should not"; return 1
  elif grep -q -- "${want}" <<<"${out}"; then
    echo "ok    ${label}"
  else
    echo "FAIL  ${label}: wrong message"; echo "${out}" | tail -2; return 1
  fi
}
expect_fail "no values at all is refused" "nas.fqdn is required"
expect_fail "a missing issuer name is refused" "clusterIssuer is required" --set nas.fqdn=x --set nas.ip=1.2.3.4
expect_fail "a cluster without Kyverno is refused" "prerequisite missing: Kyverno" \
  -f "${CHART}/values-crc.yaml" --set trustCA.pem=x --api-versions cert-manager.io/v1 --api-versions nmstate.io/v1
expect_fail "a cluster without cert-manager is refused" "prerequisite missing: cert-manager" \
  -f "${CHART}/values-crc.yaml" --set trustCA.pem=x --api-versions kyverno.io/v1 --api-versions nmstate.io/v1
expect_fail "a cluster without NMState is refused" "prerequisite missing: the NMState Operator" \
  -f "${CHART}/values-crc.yaml" --set trustCA.pem=x --api-versions kyverno.io/v1 --api-versions cert-manager.io/v1

# Argo CD order: what the DaemonSet depends on must be in an earlier wave than the DaemonSet
helm template ipsec-nas "${CHART}" -n kcs-ipsec --set prerequisites.skipCheck=true --set trustCA.pem=x \
  -f "${CHART}/values-crc.yaml" > "${tmp}/chart.yaml"
ruby -ryaml -e '
  wave = YAML.load_stream(File.read(ARGV[0])).compact.to_h { |d| [d["kind"] + "/" + d["metadata"]["name"], d["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"].to_i] }
  ds = wave.fetch("DaemonSet/ipsec-cert-sync")
  before = %w[ClusterPolicy/ipsec-cert-sync-mount ClusterPolicy/ipsec-node-certificate ConfigMap/ipsec-cert-sync-script
              ConfigMap/ipsec-metrics-scripts ConfigMap/ipsec-trust-ca ServiceAccount/ipsec-cert-sync
              ClusterRole/kyverno:ipsec-nas-generate ClusterRole/kyverno:ipsec-nas-read-nodes]
  late = before.reject { |k| wave.fetch(k) < ds }
  abort "      not before the DaemonSet: #{late.join(", ")}" unless late.empty?
  abort "      the RBAC for Kyverno must come before its policies" unless wave["ClusterRole/kyverno:ipsec-nas-read-nodes"] < wave["ClusterPolicy/ipsec-node-certificate"]
  ' "${tmp}/chart.yaml" && echo "ok    Argo CD sync waves: RBAC and ConfigMaps, then the policies, then the DaemonSet"

echo "all chart tests passed"
