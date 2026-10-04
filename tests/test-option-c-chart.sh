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
graf="$(render --set metrics.grafanaDashboard=true)"
ruby -ryaml -rjson -e '
  cm = YAML.load_stream(ARGV[0]).compact.find { |d| d["kind"] == "ConfigMap" && d["metadata"]["name"] == "ipsec-nas-grafana-dashboard" }
  exit 1 unless cm && cm["metadata"]["labels"]["grafana_dashboard"] == "1"
  d = JSON.parse(cm["data"]["ipsec-nas-option-c.json"])
  exit(d["uid"] == "ipsec-nas-option-c" ? 0 : 1)' -- "$graf" \
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

# The collector script inside the rendered ConfigMap parses.
tmp="$(mktemp)"; trap 'rm -f "${tmp}"' EXIT
sed -n '/^  collect\.sh: |$/,/^  serve\.py: |$/p' <<<"$out" | sed '1d;$d' | sed 's/^    //' > "${tmp}"
bash -n "${tmp}" && ok "collect.sh in the ConfigMap parses" || bad "collect.sh in the ConfigMap"

[[ ${fails} == 0 ]] && echo "all Option C chart tests passed" || { echo "${fails} failed"; exit 1; }
