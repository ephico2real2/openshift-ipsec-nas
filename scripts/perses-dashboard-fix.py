#!/usr/bin/env python3
"""Turns percli's conversion of the Grafana dashboard into the Perses dashboard the chart ships.

Input (stdin): the JSON of
    percli migrate -f charts/ipsec-nas/files/ipsec-nas.json --format native --plugin.path <unpacked plugins> \
      --use-default-datasource -o json
Output (stdout): the dashboard's spec (PersesDashboard v1alpha2 spec.config), as indented JSON.

Each fix answers a gap measured in docs/61-perses-dashboard-review.md (section 5); the panel keys are
percli's, which follow the order of the Grafana panels.
"""
import json
import sys

DATASOURCE = "ipsec-nas-thanos"   # the PersesDatasource the chart creates beside the dashboard


def fail(msg):
    sys.exit(f"perses-dashboard-fix: {msg}")


def queries(panel):
    return panel["spec"].get("queries", [])


def query_spec(q):
    return q["spec"]["plugin"]["spec"]


spec = json.load(sys.stdin)["spec"]
panels = spec["panels"]

# percli exits 0 even when it converted nothing (plugins not unpacked): refuse placeholders.
placeholders = [k for k, p in panels.items() if p["spec"]["plugin"]["kind"] == "Markdown"]
if placeholders:
    fail(f"panels {placeholders} are 'Migration from Grafana not supported' placeholders: "
         "give percli --plugin.path the UNPACKED plugins")
if len(panels) != 16:
    fail(f"expected the 16 panels of ipsec-nas.json, got {len(panels)}: update this script with the Grafana dashboard")

# Every query names our datasource. A namespace may hold several datasources, and the default one
# need not be ours.
for p in panels.values():
    for q in queries(p):
        query_spec(q)["datasource"] = {"kind": "PrometheusDatasource", "name": DATASOURCE}

# The Grafana datasource input is not used once the datasource is named.
spec["variables"] = [v for v in spec.get("variables", []) if v["spec"]["name"] != "DS_PROMETHEUS"]
# The variables query Prometheus too (the node filter reads the node label values). percli leaves them
# without a datasource, so they would use the namespace's default one, which a namespace need not have.
for v in spec["variables"]:
    plugin = v["spec"].get("plugin", {})
    if plugin.get("kind", "").startswith("Prometheus"):
        plugin["spec"]["datasource"] = {"kind": "PrometheusDatasource", "name": DATASOURCE}

# Panels 3 and 5 count days; percli kept the number and lost the unit.
for key in ("3", "5"):
    panels[key]["spec"]["plugin"]["spec"]["format"]["unit"] = "days"

# Panel 9 showed "1" (the info metric's value): percli wrote metricLabel "node}}: {{version".
lib = panels["9"]["spec"]
if not query_spec(queries(panels["9"])[0])["query"].startswith("ipsec_nas_libreswan_info"):
    fail("panel 9 is no longer the libreswan version panel")
lib["plugin"]["spec"]["metricLabel"] = "version"
query_spec(queries(panels["9"])[0])["seriesNameFormat"] = "{{node}}"

# Panel 13, the per-node table, split a node into three rows: its merge joins series by their labels,
# and two of its 11 queries carry more than "node" (the first, node+pod; the last, node+peer_id).
# They move to a table of their own (panel 16); the table keeps the nine queries labelled by node only.
table = panels["13"]["spec"]
tq = queries(panels["13"])
if len(tq) != 11 or "by (node, pod)" not in query_spec(tq[0])["query"] or "by (node, peer_id)" not in query_spec(tq[10])["query"]:
    fail("panel 13 is no longer the 11-query per-node table this script expects")
table["queries"] = tq[1:10]
# percli names a table's value columns "value #<query number>"; dropping the first query renumbers them.
settings = []
for c in table["plugin"]["spec"]["columnSettings"]:
    name = c["name"]
    if name in ("pod", "peer_id", "value #1", "value #11"):
        continue
    if name.startswith("value #"):
        c["name"] = f"value #{int(name.split('#')[1]) - 1}"
    settings.append(c)
table["plugin"]["spec"]["columnSettings"] = settings
table["display"]["description"] = (
    "One row per node. Why a tunnel is down: no certificate, no connection (NNCP), no IKE SA, or libreswan "
    "not answering. NFS requests/s comes from the platform's node-exporter. The reporting pod and the NAS "
    "identity are in the table below.")

panels["16"] = {
    "kind": "Panel",
    "spec": {
        "display": {
            "name": "NAS identity per node",
            "description": "The identity the NAS presented, from its certificate, and the ipsec-cert-sync pod that "
                           "reports the node. A node with no tunnel has no row here. A node in two rows is "
                           "reported by two pods.",
        },
        "plugin": {
            "kind": "Table",
            "spec": {
                "density": "compact",
                "columnSettings": [
                    {"name": "node", "header": "Node", "width": 170},
                    {"name": "pod", "header": "Reporting pod", "width": 220},
                    {"name": "peer_id", "header": "NAS identity"},
                    {"name": "value", "hide": True},
                    {"name": "timestamp", "hide": True},
                ],
            },
        },
        "queries": [{
            "kind": "TimeSeriesQuery",
            "spec": {"plugin": {"kind": "PrometheusTimeSeriesQuery", "spec": {
                "datasource": {"kind": "PrometheusDatasource", "name": DATASOURCE},
                "query": 'max by (node, pod, peer_id) (ipsec_nas_tunnel_info{node=~"$node"})',
                "seriesNameFormat": "",
            }}},
        }],
    },
}

# The identity table goes under the per-node table; the two time series move down by its height.
items = spec["layouts"][0]["spec"]["items"]
for it in items:
    if it["y"] >= 35:
        it["y"] += 5
below = [i for i, it in enumerate(items) if it["y"] >= 40]
if not below:
    fail("no panel below the per-node table: the layout of ipsec-nas.json changed; update this script")
items.insert(below[0], {"x": 0, "y": 35, "width": 24, "height": 5, "content": {"$ref": "#/spec/panels/16"}})

json.dump(spec, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
