#!/bin/bash
# Template tests for charts/ipsec-nas-option-c-metrics, no cluster needed. Run from the repository root.
# It must render Option B's collector and alerts, and nothing of Option B's certificate path.
set -uo pipefail
CHART=charts/ipsec-nas-option-c-metrics
fails=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
render() { helm template m "${CHART}" -n kcs-ipsec --kube-version 1.35.0 "$@" 2>&1; }

helm lint "${CHART}" >/dev/null 2>&1 && ok "helm lint" || bad "helm lint"

out="$(render)"
kinds="$(grep -E '^kind:' <<<"$out" | sort | tr '\n' ' ')"
[[ "$kinds" == "kind: ConfigMap kind: DaemonSet kind: PersesDashboard kind: PersesDatasource kind: PrometheusRule kind: RoleBinding kind: Service kind: ServiceAccount kind: ServiceMonitor " ]] \
  && ok "exactly the collector's objects and the Perses dashboard: ${kinds}" || bad "unexpected kinds: ${kinds}"
grep -q -E 'kind: (Certificate|GeneratingPolicy|MutatingPolicy|ClusterPolicy|NodeNetworkConfigurationPolicy)$' <<<"$out" \
  && bad "an Option B certificate or tunnel object is rendered" || ok "no Certificate, Kyverno policy or NNCP"
containers="$(ruby -ryaml -e 'YAML.load_stream(STDIN.read).compact.each { |d| puts d["spec"]["template"]["spec"]["containers"].map { |c| c["name"] }.join(" ") if d["kind"] == "DaemonSet" }' <<<"$out")"
[[ "$containers" == "collector metrics" ]] && ok "the DaemonSet's containers: ${containers} (no cert-sync)" || bad "the DaemonSet's containers: ${containers}"
grep -q 'ipsec-cert-sync' <<<"$out" && bad "a reference to ipsec-cert-sync remains" || ok "no reference to ipsec-cert-sync"

grep -A1 '^      nodeSelector:' <<<"$out" | grep -q 'node-role.kubernetes.io/worker: ""' && ok "default: worker nodes" || bad "default nodeSelector"
grep -A1 'alert: IpsecNasExporterMissing' -A3 <<<"$out" | grep -q 'kube_node_role{role="worker"}' && ok "default: the alert watches workers" || bad "default watched role"
grep -q 'kube_node_role{role=~"control-plane|master|ingress"}' <<<"$out" && ok "default: excluded roles left out of the alert" || bad "default exclusion"
# The two alerts built on platform metrics carry the release's namespace, not kube-state-metrics' or node-exporter's.
labelled="$(helm template m "${CHART}" -n ipsec-other --kube-version 1.35.0 2>&1 | ruby -ryaml -e '
  YAML.load_stream(STDIN.read).compact.select { |d| d["kind"] == "PrometheusRule" }.each do |d|
    d["spec"]["groups"].flat_map { |g| g["rules"] }.each { |r| ns = (r["labels"] || {})["namespace"]; puts "#{r["alert"]}=#{ns}" if ns }
  end')"
[[ "$(tr '\n' ' ' <<<"$labelled")" == "IpsecNasExporterMissing=ipsec-other IpsecNasNfsWithoutTunnel=ipsec-other " ]] \
  && ok "the platform-metric alerts carry the release namespace: $(tr '\n' ' ' <<<"$labelled")" || bad "alert namespace labels: ${labelled}"

crc="$(render -f "${CHART}/values-crc.yaml")"
sel="$(sed -n '/^      nodeSelector:/,/^      [a-z]/p' <<<"$crc" | grep 'node-role')"
[[ "$(wc -l <<<"$sel" | tr -d ' ')" == 1 && "$sel" == *worker* ]] && ok "CRC: the worker selector (the single node has every role)" || bad "CRC nodeSelector: ${sel}"
grep -q 'affinity:' <<<"$crc" && bad "CRC: no role may be excluded" || ok "CRC: no node affinity exclusion"
grep -q 'kube_node_role{role="worker"}' <<<"$crc" && ok "CRC: the alert watches workers" || bad "CRC watched role"
grep -q 'exclude-nodes:begin' <<<"$crc" && bad "CRC: the exclusion clause must be gone" || ok "CRC: no exclusion clause"

render --set scc.bind=false | grep -q 'kind: RoleBinding' && bad "scc.bind=false renders no SCC binding" || ok "scc.bind=false renders no SCC binding"
render --set metrics.serviceMonitor=false | grep -qE 'kind: (Service|ServiceMonitor)$' && bad "serviceMonitor=false" || ok "metrics.serviceMonitor=false renders no Service or ServiceMonitor"
render --set metrics.prometheusRule=false | grep -q 'kind: PrometheusRule' && bad "prometheusRule=false" || ok "metrics.prometheusRule=false renders no PrometheusRule"
render --set nodeselector.x=1 >/dev/null 2>&1 && bad "the schema refuses an unknown key" || ok "the schema refuses an unknown key"

# The dashboards (#43): the same two switches and defaults as Option B, and generated files that are current.
render --set metrics.persesDashboard.enabled=false | grep -qE 'kind: Perses(Dashboard|Datasource)$' \
  && bad "persesDashboard.enabled=false" || ok "metrics.persesDashboard.enabled=false renders no Perses object"
grep -q 'name: ipsec-nas-grafana-dashboard' <<<"$out" && bad "grafanaDashboard is off by default" || ok "the Grafana ConfigMap is off by default"
# On stdin: with both dashboards the rendering is larger than Linux allows for one argument (128 KiB; macOS takes it).
render --set metrics.grafanaDashboard=true | ruby -ryaml -rjson -e '
  cm = YAML.load_stream($stdin.read).compact.find { |d| d["kind"] == "ConfigMap" && d["metadata"]["name"] == "ipsec-nas-grafana-dashboard" }
  exit 1 unless cm && cm["metadata"]["labels"]["grafana_dashboard"] == "1"
  d = JSON.parse(cm["data"]["ipsec-nas-option-c.json"])
  exit(d["uid"] == "ipsec-nas-option-c" ? 0 : 1)' \
  && ok "grafanaDashboard=true: the labelled ConfigMap with the Option C dashboard (uid ipsec-nas-option-c)" || bad "Grafana ConfigMap"
python3 scripts/option-c-dashboard.py < charts/ipsec-nas/files/ipsec-nas.json | cmp -s - "${CHART}/files/ipsec-nas-option-c.json" \
  && ok "files/ipsec-nas-option-c.json is current (scripts/option-c-dashboard.py of Option B's)" || bad "files/ipsec-nas-option-c.json is stale: run scripts/perses-dashboard.sh"
python3 - "${CHART}/files/ipsec-nas-option-c.perses.json" <<'PY' && ok "the Perses dashboard: Option C's title, every query on ipsec-nas-thanos" || bad "the Perses dashboard"
import json, sys
d = json.load(open(sys.argv[1]))
qs = [q for p in d["panels"].values() for q in p["spec"].get("queries", [])]
ok = d["display"]["name"] == "IPsec to the NAS (Option C)" and qs and all(
    q["spec"]["plugin"]["spec"]["datasource"]["name"] == "ipsec-nas-thanos" for q in qs)
sys.exit(0 if ok else 1)
PY

# Option C's tunnel and certificate (off by default). The tunnel objects must equal what render.sh makes from
# manifests/option-c-wildcard-cert/ (C1 and C2, each pool); labels and comments may differ.
render | grep -qE 'kind: (NodeNetworkConfigurationPolicy|GeneratingPolicy|Certificate)$' \
  && bad "defaults render no tunnel and no certificate" || ok "defaults render no tunnel and no certificate"
opt=(--set nodeDomain=ocp.example.com --set nas.fqdn=nas01.example.com --set nas.ip=10.0.0.50 --set prerequisites.skipCheck=true)
same_objects() {  # $1 = chart rendering, $2 = render.sh file: every object of the file, by kind and name, equal in spec/rules
  ruby -ryaml -e '
    key = ->(d) { "#{d["kind"]}/#{d["metadata"]["name"]}" }
    body = ->(d) { d.reject { |k, _| %w[metadata].include?(k) } }
    chart = YAML.load_stream(ARGV[0]).compact.to_h { |d| [key.(d), body.(d)] }
    want  = YAML.load_stream(File.read(ARGV[1])).compact
    bad = want.reject { |d| chart[key.(d)] == body.(d) }.map { |d| key.(d) }
    puts bad.join(" ") unless bad.empty?
    exit(bad.empty? && !want.empty? ? 0 : 1)' -- "$1" "$2"
}
for pool in worker master; do
  ( export NODE_DOMAIN=ocp.example.com NAS_FQDN=nas01.example.com NAS_IP=10.0.0.50 CLUSTER_ISSUER=x OCP_VERSION=4.19.0 MCP_ROLE=${pool}
    ./render.sh >/dev/null )
  same_objects "$(render "${opt[@]}" --set tunnel.enabled=true --set tunnel.variant=c1 --set "tunnel.pools={${pool}}")" \
    rendered/option-c-wildcard-cert/10-nncp-all-workers.yaml && ok "C1, ${pool} pool: the NNCP equals render.sh's" || bad "C1 ${pool}"
  same_objects "$(render "${opt[@]}" --set tunnel.enabled=true --set tunnel.variant=c2 --set "tunnel.pools={${pool}}")" \
    rendered/option-c-wildcard-cert/11-kyverno-nncp-per-node-fqdn.yaml && ok "C2, ${pool} pool: the policy equals render.sh's" || bad "C2 ${pool}"
done
# Kyverno's roles: the manifest's NNCP rule and node reading; not its cert-manager rule, which only Option B needs.
ruby -ryaml -e '
  roles = ->(t) { YAML.load_stream(t).compact.select { |d| d["kind"] == "ClusterRole" }.to_h { |d| [d["metadata"]["name"], d["rules"]] } }
  chart, want = roles.(ARGV[0]), roles.(File.read(ARGV[1]))
  nncp = want["kyverno:ipsec-nas-generate"].select { |r| r["apiGroups"] == ["nmstate.io"] }
  exit(chart["kyverno:ipsec-nas-generate"] == nncp && chart["kyverno:ipsec-nas-read-nodes"] == want["kyverno:ipsec-nas-read-nodes"] ? 0 : 1)' \
  -- "$(render "${opt[@]}" --set tunnel.enabled=true --set tunnel.variant=c2)" manifests/common/03-kyverno-rbac.yaml \
  && ok "C2: Kyverno's roles as manifests/common/03-kyverno-rbac.yaml, without its cert-manager rule (Option B only)" || bad "C2 Kyverno RBAC"
both="$(render "${opt[@]}" --set tunnel.enabled=true --set 'tunnel.pools={worker,master}' | grep '^  name: ipsec-nas-wildcard-' | tr -d ' ' | tr '\n' ' ')"
[[ "$both" == "name:ipsec-nas-wildcard-worker name:ipsec-nas-wildcard-master " ]] && ok "both pools: one NNCP each (${both})" || bad "both pools: ${both}"
cert="$(render "${opt[@]}" --set certificate.enabled=true --set clusterIssuer=enterprise-ca)"
ruby -ryaml -e '
  c = YAML.load_stream(ARGV[0]).compact.find { |d| d["kind"] == "Certificate" } or exit 1
  s = c["spec"]
  ok = s["dnsNames"] == ["*.ocp.example.com"] && s["commonName"] == "ocp-ipsec-workers" && s["subject"]["organizations"] == ["KCS"] &&
       s["privateKey"]["size"] == 3072 && s["usages"].include?("client auth") && s["issuerRef"]["name"] == "enterprise-ca" && s["duration"] == "17520h"
  exit(ok ? 0 : 1)' -- "$cert" && ok "the Certificate: *.ocp.example.com, CN=ocp-ipsec-workers, O=KCS, RSA 3072, client auth, 2 years" || bad "the Certificate"
grep -q 'kind: MachineConfig' <<<"$cert$(render "${opt[@]}" --set tunnel.enabled=true)" && bad "the chart never renders a MachineConfig" || ok "the chart never renders a MachineConfig"
# helm exits non-zero on these by design: capture first (with pipefail, a pipe would fail even on the right message).
refused="$(render --set tunnel.enabled=true --set nas.ip=10.0.0.50 --set nas.fqdn=n --set prerequisites.skipCheck=true)"
grep -q 'nodeDomain is required' <<<"$refused" && ok "tunnel without nodeDomain is refused" || bad "nodeDomain check: ${refused}"
refused="$(render "${opt[@]}" --set certificate.enabled=true)"
grep -q 'clusterIssuer is required by certificate' <<<"$refused" && ok "certificate without clusterIssuer is refused" || bad "clusterIssuer check: ${refused}"
refused="$(render --api-versions nmstate.io/v1 --set nodeDomain=d --set nas.fqdn=n --set nas.ip=1.2.3.4 --set tunnel.enabled=true --set tunnel.variant=c2)"
grep -q 'prerequisite missing: Kyverno 1.19' <<<"$refused" && ok "c2 on a cluster without Kyverno's API is refused" || bad "Kyverno API check: ${refused}"
refused="$(render --set nodeDomain=d --set nas.fqdn=n --set nas.ip=1.2.3.4 --set tunnel.enabled=true)"
grep -q 'prerequisite missing: the NMState Operator' <<<"$refused" && ok "the tunnel on a cluster without NMState's API is refused" || bad "NMState API check: ${refused}"
render "${opt[@]}" --set tunnel.enabled=true --set tunnel.variant=c3 >/dev/null 2>&1 && bad "the schema refuses an unknown variant" || ok "the schema refuses an unknown variant"
render "${opt[@]}" --set tunnel.enabled=true --set 'tunnel.pools={infra}' >/dev/null 2>&1 && bad "the schema refuses a pool other than worker and master" || ok "the schema refuses a pool other than worker and master"

# Dynatrace's annotated Prometheus exporters (#46): off by default; on, the four annotations with Dynatrace's filter JSON.
render | grep -q 'metrics.dynatrace.com/' && bad "no Dynatrace annotation by default" || ok "no Dynatrace annotation by default"
ruby -ryaml -rjson -e '
  svc = YAML.load_stream(ARGV[0]).compact.find { |d| d["kind"] == "Service" } or exit 1
  a = svc["metadata"]["annotations"]
  ok = a["metrics.dynatrace.com/scrape"] == "true" && a["metrics.dynatrace.com/port"] == "9754" && a["metrics.dynatrace.com/path"] == "/metrics" &&
       JSON.parse(a["metrics.dynatrace.com/filter"]) == {"mode" => "include", "names" => ["ipsec_nas_*"]}
  exit(ok ? 0 : 1)' -- "$(render --set metrics.dynatrace.scrape=true)" \
  && ok "metrics.dynatrace.scrape=true: scrape, port 9754, path /metrics, filter {mode: include, names: [ipsec_nas_*]}" || bad "Dynatrace annotations"

# The collector script inside the rendered ConfigMap parses.
tmp="$(mktemp)"; trap 'rm -f "${tmp}"' EXIT
sed -n '/^  collect\.sh: |$/,/^  serve\.py: |$/p' <<<"$out" | sed '1d;$d' | sed 's/^    //' > "${tmp}"
bash -n "${tmp}" && ok "collect.sh in the ConfigMap parses" || bad "collect.sh in the ConfigMap"

[[ ${fails} == 0 ]] && echo "all Option C chart tests passed" || { echo "${fails} failed"; exit 1; }
