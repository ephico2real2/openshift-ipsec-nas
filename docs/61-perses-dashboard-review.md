# Perses — The IPsec Dashboard in the OpenShift Console

The *IPsec to the NAS* dashboard lives in the **OpenShift console**: **Observe → Dashboards (Perses)**. It runs on Perses, the dashboard tool Red Hat ships with the Cluster Observability Operator (COO). The ipsec chart installs it **by default**. The Grafana version is **off** by default and kept for clusters that run Grafana.

The dashboard was measured on CRC 4.22.7 with COO 1.5.3 on 2026-10-03 and 2026-10-04 ([evidence 41](evidence/crc/41-perses-dashboard-review.txt), [42](evidence/crc/42-console-perses-capture.txt), [43](evidence/crc/43-dashboard-sections.txt)); the Grafana prerequisite on kind ([evidence kind/03](evidence/kind/03-grafana-dashboard-prerequisite.txt)). The metrics, the alerts and the collector are described in [doc 60](60-monitoring-per-node.md). COO itself is installed by its own chart, [openshift-coo-helm](https://github.com/ephico2real2/openshift-coo-helm).

## At a glance

<!-- markdownlint-disable MD033 -->
<img alt="The OpenShift console, Observe, Dashboards, project kcs-ipsec, dashboard IPsec to the NAS, node filter All, last 30 minutes, in five sections. Summary: tunnels up 1, down 0, workers reporting 1, soonest certificate expiry 12.1 months. Tunnels per node: tunnel state UP in green, certificate time left 12.1 months as a bar, traffic through the tunnel at about 3.8 MiB/s during two load runs, tunnel age 2.33h, metrics age 39s, libreswan version 5.3. Checks (all should be 0): nodes reported twice 0, pods reporting the wrong node 0, kernel IPsec errors last hour 0. Per-node detail: one row for crc (UP, YES, PRESENT, YES, YES, 2 NFS mounts, 39.8 requests/sec, 0 drops, certificate imported 10.1h ago), and the NAS identity table showing crc, ipsec-cert-sync-5mvdc and O=KCS OpenShift lab, CN=crc-nas.lab.internal. History: tunnel re-establishments 0 under a dashed threshold at 4, and kernel IPsec errors per node showing No data." src="images/crc/42-console-perses-ipsec-nas.light.png">
<!-- markdownlint-enable MD033 -->

*Capture 6. **Observe → Dashboards (Perses)**, project `kcs-ipsec`: the dashboard the chart ships, in its five sections, on CRC's data. "No data" on the last panel means no kernel IPsec errors: it shows only error counters above 0. The console shell here is the community (OKD) build of the same console, `quay.io/openshift/origin-console:4.22`, run on a laptop against CRC with sign-in turned off (hence the `okd` logo and "Auth disabled"). The Perses plugin, the Perses server, the dashboard and the data are CRC's own ([evidence 42](evidence/crc/42-console-perses-capture.txt)).*

The dashboard has six sections, top to bottom (Capture 6 was taken before the sixth). Each answers one question:

| Section | Panels | The question it answers |
|---|---|---|
| **Summary** | Tunnels up, tunnels down, workers reporting, soonest certificate expiry | Is anything wrong? |
| **Tunnels per node** | Tunnel state, certificate time left, traffic to and from the NAS, tunnel age, metrics age, libreswan version, certificate source (B, C or A) | Which node, and how is it doing? A young tunnel age means a recent restart; an old metrics age, a stopped collector |
| **Checks (all should be 0)** | Nodes reported twice, pods reporting the wrong node, kernel IPsec errors in the last hour | Can these numbers be trusted? (doc 60, *How each node's data stays its own*) |
| **Per-node detail** | **Per node** table: one row per node; NAS identity per node | **Why** a tunnel is down (no certificate, no connection, no IKE SA, libreswan not answering), NFS mounts and requests, IPsec drops, last certificate import; which pod reports each node, and for each node whose tunnel is up the identity the NAS presented (from `ipsec_nas_tunnel_info`, which the collector writes only while the tunnel is up) |
| **History** | Tunnel re-establishments in the last hour, kernel IPsec errors per node | Is a tunnel flapping (alert above 3 an hour), and are errors growing? "No data" there means no errors: it shows only counters above 0 |
| **Storage on the NAS (csi-driver-nfs)** | Namespaces using the NAS, claims on the NAS, claims not Bound, NAS pods without a working tunnel; **Claims on the NAS** table; **Pods using NAS claims, and their node's tunnel** table | Who stores data on the NAS, where (NAS IP, export, directory), and is each of their pods on a node whose tunnel works? ([doc 60](60-monitoring-per-node.md#storage-on-the-nas-the-dashboards-sixth-section)) |

Each section folds with the arrow beside its title; all are open when the dashboard loads.

## How it works

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/ipsec-nas/perses-dashboard.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="diagrams/ipsec-nas/perses-dashboard.light.png">
  <img alt="Collecting: each ipsec-cert-sync pod reports its own node's metrics, the user workload Prometheus scrapes them every 30 seconds, and Thanos Querier serves them on port 9091. Viewing: you open the dashboard in the OpenShift console; Perses, run by the Cluster Observability Operator, reads the PersesDashboard and PersesDatasource the ipsec chart puts in kcs-ipsec and queries Thanos with your own token. A viewer needs view in kcs-ipsec to open the dashboard and cluster-monitoring-view to see its data." src="diagrams/ipsec-nas/perses-dashboard.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Figure 1. How the dashboard reaches you.*

```text
COLLECTING (always on)
  ipsec-cert-sync pod, one per worker ──scrape──▶ user workload Prometheus ──read by──▶ Thanos Querier :9091
  (kcs-ipsec, :9754/metrics, node=itself)          (ServiceMonitor, every 30 s)       (all namespaces, checks the caller's token)

VIEWING (with your own login)
  You, in the console ──your login──▶ Perses (COO) ──query, with your token──▶ Thanos Querier :9091
  Observe → Dashboards (Perses)          │
                                         └──reads──▶ PersesDashboard ipsec-nas + PersesDatasource ipsec-nas-thanos (kcs-ipsec, from the ipsec chart)

A viewer needs: view in kcs-ipsec (open the dashboard) + cluster-monitoring-view (see its data).
No password or token is stored anywhere.
```

1. **Each worker's `ipsec-cert-sync` pod reports its own node**, labelled with that node's name.
2. **OpenShift's user workload Prometheus scrapes every pod** (the chart's ServiceMonitor). **Thanos Querier** serves those metrics together with the platform's own.
3. **You open the dashboard in the console.** The console passes your login (your token) to Perses.
4. **Perses reads the dashboard and its data source from `kcs-ipsec`**, both put there by the ipsec chart.
5. **Perses queries Thanos with your token.** Thanos answers if you hold `cluster-monitoring-view`. Nothing is stored: each viewer sees what OpenShift lets them see.

## Turn it on (or off)

It is **on by default** in the ipsec chart (`metrics.persesDashboard.enabled: true`). The Grafana dashboard is **off** (`metrics.grafanaDashboard: false`).

**Prerequisites:**

| Needs | Why | How |
|---|---|---|
| COO 1.5 or later, with Perses enabled | It runs Perses and its console page | The [openshift-coo chart](https://github.com/ephico2real2/openshift-coo-helm/tree/main/charts/openshift-coo) installs it, hands-free, on OpenShift 4.19 or later. The ipsec chart refuses to install without the API `perses.dev/v1alpha2`, and says so |
| User workload monitoring | It collects the metrics | [doc 20, Step B.12](20-option-b-per-node-certificates.md#step-b12--metrics-in-observe-alerts-and-a-dashboard) |

**What the chart creates**, in its own namespace, `perses.dev/v1alpha2`:

| Object | What |
|---|---|
| `PersesDatasource` `ipsec-nas-thanos` | Thanos Querier on port 9091 (`metrics.persesDashboard.thanosURL`), TLS with the service CA |
| `PersesDashboard` `ipsec-nas` | The dashboard: `charts/ipsec-nas/files/ipsec-nas.perses.json`, generated from the Grafana one |

It creates **no RoleBindings**: see [Who can see it](#who-can-see-it).

A cluster without COO sets `metrics.persesDashboard.enabled: false`, and can turn the Grafana dashboard on instead. With the plain manifests, apply `manifests/option-b-per-node-certs/33-perses-dashboard.yaml`.

**Check it:**

```bash
oc -n kcs-ipsec get persesdatasource ipsec-nas-thanos -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"\n"}'
oc -n kcs-ipsec get persesdashboard ipsec-nas -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"\n"}'
```

✅ **Expected:** `True` twice.

## Open it

**Observe → Dashboards (Perses)**, project **`kcs-ipsec`**, dashboard **IPsec to the NAS** (Capture 6). The **Node** filter at the top narrows every panel to the nodes you pick (default: all).

## Who can see it

| To | You need | Who usually has it |
|---|---|---|
| Open the dashboard | **`view`** in `kcs-ipsec` (or `edit` / `admin`) | The namespace's team. OLM aggregates the per-kind roles of COO's Perses CRDs into OpenShift's `view`, `edit` and `admin` (for example `persesdashboards.perses.dev-v1alpha2-view`: [openshift-coo-helm evidence 12](https://github.com/ephico2real2/openshift-coo-helm/blob/main/docs/evidence/crc/12-review-reads.txt)), so no extra role is needed (measured: `view` alone reads the dashboard, and cannot change it) |
| See its data | **`cluster-monitoring-view`** | Granted by the platform: the [openshift-coo chart](https://github.com/ephico2real2/openshift-coo-helm/tree/main/charts/openshift-coo) binds it to the groups in `metricsAccess.groups`, for example `system:authenticated` (everyone who logs in) |
| Change the dashboard | Edit the Grafana JSON in Git and regenerate: [Change the dashboard](#change-the-dashboard) | — |

### Decision: one data source on Thanos port 9091; metrics readable by namespace owners

**Decided 2026-10-03.** The metrics contain **no PHI and no PII**. Self-service and metrics accessibility come first: a namespace owner must see their own metrics **without technical gymnastics**. So the data source uses Thanos's cluster-wide port **9091**, and viewers hold `cluster-monitoring-view`.

**Why not a namespace-only data source** (measured; details in [Appendix A](#appendix-a--how-we-got-here)):

1. **Perses sends each viewer's own token** to Thanos.
2. **The Perses UI sends its data queries as `POST`**, and has no setting to send `GET`.
3. **Thanos's per-namespace port, 9092, checks a `POST` as `create pods`** in the namespace: the right to run workloads, which cannot be handed out for viewing a dashboard. A namespace-only reader got `Forbidden` on every panel (Capture 3).
4. **Port 9091 checks a `POST` as `create` on `prometheuses/api`.** That is what `cluster-monitoring-view` grants. Its rules are `get` on namespaces, and `get`/`create`/`update` on `prometheuses/api`: read access to metrics, nothing else.
5. **Port 9091 also serves platform metrics.** The *NFS requests/s* column needs them.

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/crc/41-perses-reader-9091.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="images/crc/41-perses-reader-9091.light.png">
  <img alt="The IPsec to the NAS dashboard as the namespace reader holding cluster-monitoring-view, on Thanos port 9091: every panel answers, with tunnels up 1, down 0, UP in green, traffic around 3.8 MiB/s under load, tunnel age 7.22h, and the per-node table showing NFS requests/s of 30 requests/sec." src="images/crc/41-perses-reader-9091.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Capture 4. The same reader as in Capture 3, now also holding `cluster-monitoring-view`, on port 9091: every panel answers (this capture predates the panel fixes of Appendix A.5).*

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/crc/41-perses-chart.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="images/crc/41-perses-chart.light.png">
  <img alt="The IPsec to the NAS dashboard as a namespace reader holding cluster-monitoring-view: tunnels up 1, down 0, workers reporting 1, soonest certificate expiry 12.1 months, tunnel state UP in green, traffic around 3.8 MiB/s under load, tunnel age 7.5h, metrics age 50s, libreswan version 5.3, nodes reported twice 0, pods reporting the wrong node 0, kernel IPsec errors 0, a per-node table with one row for crc (UP, YES, PRESENT, YES, YES, 2 NFS mounts, 39.8 requests/sec, 0 drops, imported 7.5h), a NAS identity per node table showing crc, ipsec-cert-sync-5mvdc and O=KCS OpenShift lab, CN=crc-nas.lab.internal, tunnel re-establishments 0 under a dashed threshold at 4, and kernel IPsec errors per node with no data." src="images/crc/41-perses-chart.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Capture 5. The finished dashboard (after Appendix A.5) as the same reader, before it had sections. Taken in the upstream Perses 0.54.0 UI, the Perses version in COO 1.5.2's and `release-1.5`'s `go.mod` (COO's own server reports no version), signed in as that reader.*

A namespace-only data source becomes possible only if Perses learns to query with `GET`.

## Change the dashboard

The Grafana dashboard, `charts/ipsec-nas/files/ipsec-nas.json`, is the **one source**. The Perses dashboard is **generated** from it; never edit `ipsec-nas.perses.json` by hand. Since 2026-10-07 nothing is repaired after the conversion: whatever the Perses dashboard shows is written in the Grafana file, and the two dashboards have the same 24 panels ([evidence 61](evidence/crc/61-dashboard-from-diagram-kit.txt)).

1. Edit `charts/ipsec-nas/files/ipsec-nas.json`, for example in a Grafana, and export the JSON. The sections are Grafana **rows**: put a new panel under the row whose question it answers, and add a row for a new question. Keep rows expanded; a row saved collapsed becomes a folded section in Perses too. Follow [What the Grafana file must look like](#what-the-grafana-file-must-look-like).
2. Regenerate, from the repository root:

   ```bash
   scripts/perses-dashboard.sh
   ```

   It writes `charts/ipsec-nas/files/ipsec-nas.perses.json` and `manifests/option-b-per-node-certs/33-perses-dashboard.yaml`, refreshes the Grafana ConfigMap `manifests/option-b-per-node-certs/30-grafana-dashboard.yaml`, and writes Option C's two files, `charts/ipsec-nas-option-c-metrics/files/ipsec-nas-option-c.json` and `ipsec-nas-option-c.perses.json`. When a check or a step fails it says what is wrong, naming the panel where one is at fault, and no file of the repository has changed: the five are moved into place together at the end, as the last step. (Only a move that itself fails, or a kill between two of the moves, can leave the first files new and the others old; running the script again puts that right.)
3. Run `tests/test-chart.sh` and `tests/test-option-c-chart.sh`, which keep the charts and the manifests identical, and commit all of them with the Grafana one.

### What the conversion needs

| Need | How |
|---|---|
| [diagram-kit](https://github.com/ephico2real2/diagram-kit) (MPL-2.0) 0.2.1 or later: its `perses-dashboard` command | `python3 -m venv .venv && .venv/bin/pip install "diagram-kit @ git+https://github.com/ephico2real2/diagram-kit@v0.2.4"`. The script takes the command from `PERSES_DASHBOARD`, from the `PATH`, or from `.venv/bin` |
| `percli` 0.54.0, the Perses version in COO 1.5.2's and 1.5.3's `go.mod` | With podman or docker, nothing: the kit runs it from `docker.io/persesdev/perses:v0.54.0` (`PERSES_IMAGE` names another). Without a container engine, `PERCLI=<binary> PERSES_PLUGINS=<unpacked plugins>` ([how to install them](https://github.com/ephico2real2/openshift-coo-helm/blob/main/docs/percli.md)) |

Before 2026-10-07 the repository had its own `scripts/perses-dashboard-fix.py`, which rewrote five panels after `percli` (two units, two labels, the per-node table), added a sixth, and found them by title. The kit replaced it; the fixes it made are now either the kit's or rules for the Grafana file.

### What the Grafana file must look like

Four rules. The first three are things `percli` does not carry over by itself, measured in Appendix A.5; the fourth is for Grafana:

| In the Grafana file | Why | Otherwise |
|---|---|---|
| Every query of a table with several queries carries the **same labels**: the nine of **Per node** are all `... by (node) (...)` | A Perses table joins rows by all their labels; Grafana's merge joins on the labels they share | One query labelled `node, pod` and one labelled `node, peer_id` gave each node three rows. What carries other labels goes in a table of its own: **NAS identity per node** |
| A stat that shows a **label** has the legend `{{node}}: {{version}}`: who, then what (or one label, `{{version}}`) | A Perses stat shows one label. The kit reads the first as the series name and the second as the label shown | With any other legend that says something (three labels, a fixed text, a different one on a second query) the kit stops and names the panel. With an empty legend, or none, kit 0.2.2 lets the stat through, and it shows the value where Grafana shows the series' own name; kit 0.2.3 stops there too. (`percli` alone wrote a label no series has, and the panel showed `1`; kit 0.2.1 still let a fixed text and `{{ node }}`, with spaces, through, and 0.2.2 does not) |
| In a table, **one column has no width** (in **Per node**, *Node*) | Grafana gives that column what the others leave; with a width on every column the table stops short of its panel (it ended at about three quarters) | Perses spreads the columns either way |
| A count of days has the unit `suffix: days` | The kit turns it into the Perses unit `days` (the same for `milliseconds`, `seconds`, `minutes`, `hours`, `weeks`, `months` and `years`, spelled so) | Another suffix becomes a plain number, with a warning. With kit 0.2.1 this held only for a panel that also sets `decimals`, as the two here do: without them `percli` writes no unit at all, and 0.2.1 neither turned it nor warned. Kit 0.2.2 does both |

**What the kit does by itself:**

- every query and the **Node** filter name the data source `ipsec-nas-thanos`;
- the text on a coloured table cell is black or white, whichever reads better: in the console's dark theme it was white on green (2.2 to 1) and is now black (9.4 to 1);
- it **refuses** a panel that became a placeholder (plugins not unpacked, or a kind Perses does not draw), and a panel, section or query that differs from the Grafana one, taken in order. So the script holds no panel count and no panel titles: add, move and rename panels freely.

**What still differs between the two dashboards** (measured 2026-10-07, evidence 61):

| | Grafana | Perses |
|---|---|---|
| A table cell with no series | "–" (a mapping of `null`, which `percli` does not carry over) | empty |
| Certificate time left | 727.1 days | 2.0 years: Perses writes a duration in its largest fitting unit |
| *libreswan version per node*, *Certificate source per node* | `crc: 5.3`, `crc: C` | `5.3`, `C` |
| *Kernel IPsec errors per node* with no errors | "No drops" | "No data" |
| *Per node*, **IPsec drops (1h)** above zero | red, no decimals (`thresholds`, `color-text` and `decimals` on the column, which `percli` does not carry over) | the plain number as it comes, for example `1.0169`, in the ordinary text colour |

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/crc/61-console-perses-two-tables.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="images/crc/61-console-perses-two-tables.light.png">
  <img alt="The OpenShift console as the user developer, Observe, Dashboards (Perses), project kcs-ipsec, dashboard IPsec to the NAS (Option C), last 30 minutes, in six sections. Summary: tunnels up 1, down 0, workers reporting 1, soonest certificate expiry 2.0 years. Tunnels per node: tunnel state UP, certificate time left 2.0 years as a bar, traffic from the NAS falling from about 680 KiB/s to near zero, tunnel age 3.18h, metrics age 42s, libreswan version 5.3, certificate source C. Checks: nodes reported twice 0, pods reporting the wrong node 0, kernel IPsec errors last hour 0. Per-node detail: the Per node table with one row for crc (UP, YES, PRESENT, YES, YES in black on green, 3 NFS mounts, 5.72 requests/sec, 0 drops, certificate imported 2.92d ago), and under it the NAS identity per node table: crc, reporting pod ipsec-nas-metrics-tcmr8, O=KCS OpenShift lab, CN=crc-nas.lab.internal. History: tunnel re-establishments 0 under the dashed threshold at 4, and kernel IPsec errors per node showing No data. Storage on the NAS: 3 namespaces, 3 claims, 0 not Bound, 0 pods without a working tunnel, the three claims and the three pods, each on crc with its tunnel UP." src="images/crc/61-console-perses-two-tables.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Capture 8. The dashboard generated by the kit, in the lab's own console (CRC 4.22.7, COO 1.5.3) as a namespace reader, 2026-10-07.*

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/crc/61-grafana-two-tables.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="images/crc/61-grafana-two-tables.light.png">
  <img alt="The same dashboard in Grafana 12.3.1, kiosk mode, last 30 minutes, reading CRC's Thanos. Summary: tunnels up 1, down 0, workers reporting 1, soonest certificate expiry 727.1 days. Tunnel state UP, certificate 727.1 days, traffic from the NAS falling from about 690 kB/s to near zero, tunnel age 3.19 hours, metrics age 43.0 s, libreswan crc: 5.3, certificate source crc: C. Checks all 0. The Per node table: crc, UP, YES, PRESENT, YES, YES, 3 NFS mounts, 5.77 req/s, 0 drops, certificate imported 2.92 days ago; the Node column takes the width the others leave, so the table fills its panel, and every header is whole. Under it the NAS identity per node table, new in Grafana: crc, reporting pod ipsec-nas-metrics-tcmr8, O=KCS OpenShift lab, CN=crc-nas.lab.internal. History: tunnel re-establishments 0, kernel IPsec errors per node showing No drops. Storage on the NAS: 3 namespaces, 3 claims, 0 not Bound, 0 pods without a working tunnel, and the two tables." src="images/crc/61-grafana-two-tables.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Capture 9. The Grafana dashboard after the same change: the reporting pod and the NAS identity moved from the Per node table to a table of their own, as in Perses. Grafana 12.3.1 from its Helm chart 10.5.15, its sidecar loading the dashboard from a ConfigMap, 2026-10-07.*

## Troubleshooting

| You see | Why | Do |
|---|---|---|
| No **Dashboards (Perses)** under Observe | COO is missing, or its console plugin is off | Install COO with Perses: the [openshift-coo chart](https://github.com/ephico2real2/openshift-coo-helm/tree/main/charts/openshift-coo); its gate's log says what is missing |
| The install is refused: *prerequisite missing: the Cluster Observability Operator* | The cluster does not serve `perses.dev/v1alpha2` | Install COO first, or set `metrics.persesDashboard.enabled: false` |
| *IPsec to the NAS* is not in the list | No `view` in `kcs-ipsec`, or the dashboard is not `Available` | Ask for `view` in the namespace; run the checks in [Turn it on](#turn-it-on-or-off) |
| Every panel says `Forbidden (… resource=prometheuses, subresource=api)` | You lack `cluster-monitoring-view` | The platform grants it ([Who can see it](#who-can-see-it)) |
| Every panel says `Forbidden (… resource=pods …)` | The data source points at port 9092 | Keep `thanosURL` on port 9091 ([Decision](#decision-one-data-source-on-thanos-port-9091-metrics-readable-by-namespace-owners)) |
| The **Node** filter is empty | The data source `ipsec-nas-thanos` is not `Available`, or you lack `cluster-monitoring-view` (the filter queries Thanos too) | Run the checks in [Turn it on](#turn-it-on-or-off); see [Who can see it](#who-can-see-it) |
| Certificate expiry reads "12.1 months", not "364 days" | Perses writes a duration in its largest fitting unit | Expected; the alerts still fire at 14 days |
| *Kernel IPsec errors per node* says "No data" | There were no drops | Expected; the panel draws only counters that moved |

## Grafana, if you need it

The same dashboard is still available for Grafana: `metrics.grafanaDashboard: true` ships it as a ConfigMap labelled `grafana_dashboard: "1"`. Both flags may be on at once: they add data only (rendered: 48.5 KiB for the ConfigMap, 45.1 KiB for the two Perses objects, and no workload: [evidence 44](evidence/crc/44-dashboard-sizes.txt)), and both dashboards come from the same JSON.

**Prerequisite for the Grafana integration: a Grafana that loads the ConfigMap.** Measured on kind with the Grafana Helm chart and its dashboard sidecar ([evidence kind/03](evidence/kind/03-grafana-dashboard-prerequisite.txt)):

| Grafana | Its dashboard sidecar searches | Loads the dashboard? |
|---|---|---|
| **In the same namespace** (`kcs-ipsec`) | its own namespace | **yes**, measured |
| **Central**, in another namespace | all namespaces (`searchNamespace: ALL`) | **yes**, measured |
| In another namespace | only its own namespace | **no**, measured: the prerequisite is not met |
| grafana-operator, with a `GrafanaDashboard` pointing at the ConfigMap ([doc 20, Step B.12](20-option-b-per-node-certificates.md#step-b12--metrics-in-observe-alerts-and-a-dashboard), step 5) | — | **not measured** |

The chart **does not check** this: nothing on the cluster tells it a Grafana sidecar is there, and without a Grafana the ConfigMap is simply unused. Its install notes say so when the flag is on.

**On OpenShift**, measured on CRC with the Grafana Helm chart 10.5.15 (Grafana 12.3.1) in `kcs-ipsec` ([evidence 53](evidence/crc/53-grafana-on-openshift.txt)): the sidecar loaded the ConfigMap, and Grafana listed the dashboard. The chart's fixed IDs (`runAsUser`, `runAsGroup`, `fsGroup` 472) are refused by the `restricted-v2` SCC (`472 is not an allowed group`). Set them to `null`, not `{}`: Helm merges maps, so an empty map removes nothing.

```yaml
securityContext: {runAsUser: null, runAsGroup: null, fsGroup: null, runAsNonRoot: true}
containerSecurityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}
initChownData: {enabled: false}
sidecar:
  securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}
  dashboards: {enabled: true, label: grafana_dashboard, labelValue: "1"}
```

<!-- markdownlint-disable MD033 -->
<img alt="The IPsec to the NAS dashboard in Grafana 12.3.1 running on OpenShift (CRC), kiosk mode, light theme, last 30 minutes, reading Thanos Querier. Summary: tunnels up 1, down 0, workers reporting 1, soonest certificate expiry 730.0 days. Tunnel state UP, certificate 730.0 days, traffic through the tunnel around 1 kB/s to the NAS, tunnel age 46.6 mins, metrics age 40.4 s, libreswan crc: 5.3, certificate source crc: C. Checks: nodes reported twice 0, pods reporting the wrong node 0, kernel IPsec errors last hour 1.01. Per-node row: crc, reporting pod ipsec-nas-metrics-tcmr8, UP, YES, PRESENT, YES, YES, 1 NFS mount, 2.01 req/s, 1 drop, certificate imported 47.7 mins ago, NAS identity O=KCS OpenShift lab, CN=crc-nas.lab. History: tunnel re-establishments falling from 2 to 1, and kernel IPsec errors per node showing No drops." src="images/crc/53-grafana-openshift-option-c.light.png">
<!-- markdownlint-enable MD033 -->

*Capture 7. Option C's dashboard in Grafana running on OpenShift, loaded by its sidecar from the chart's ConfigMap. "Certificate source: crc: C" is the panel added with #40's mode detector. The one kernel IPsec error of the last hour came with the tunnel restarts of that afternoon (evidence 50, 51).*

## Appendix A — How we got here

The review that led to the setup above, kept for its measurements. Captures 1 to 4 show the dashboard **before** the fixes of A.5.

### A.1 Converting

```bash
percli migrate -f charts/ipsec-nas/files/ipsec-nas.json --format cr --project kcs-ipsec \
  --plugin.path <unpacked Perses plugins> --use-default-datasource -o yaml
```

- **The tool.** `percli` 0.54.0, the Perses version in COO 1.5.2's and `release-1.5`'s `go.mod` (1.5.0 and 1.5.1: 0.53.1). Its plugins must be **unpacked**; pointed at the packed archives it silently turns every panel into a placeholder.
- **The result.** 16 panels: 11 stat charts, 1 table, 3 time series and 1 bar chart (since 2026-10-04, 17: a 12th stat chart, *Certificate source per node*; since 2026-10-05, 23: the section *Storage on the NAS (csi-driver-nfs)*, 4 stat charts and 2 tables; since 2026-10-07, 24: *NAS identity per node* is a panel of the Grafana file). The `node` filter became a Perses variable over the `node` label of `ipsec_nas_tunnel_up`.
- **COO's own converter** (`POST /api/migrate` on its Perses) produces the same, except the table: it names the value columns `Value #A…` and drops value mappings and units.
- **The resource version.** `percli` writes `perses.dev/v1alpha1`, which the API server reports as deprecated. `v1alpha2` puts the dashboard under `spec.config`.

### A.2 The data, as an application team's reader

**The reader.** A ServiceAccount with `view`, `persesdashboard-viewer-role` and `persesdatasource-viewer-role` in `kcs-ipsec`. Perses passes the reader's own token to Thanos ([openshift-coo-helm findings §6](https://github.com/ephico2real2/openshift-coo-helm/blob/main/docs/manual-install-findings.md#6-how-perses-authenticates-and-reaches-thanos)), so the review started with a data source on Thanos's per-namespace port **9092** with `namespace=kcs-ipsec`.

**Every panel query, sent through COO's Perses as `GET`:**

| | Reader, port 9092 | kubeadmin, port 9091 |
|---|---|---|
| The `node` variable (label values) | `crc` | — |
| 26 of the 27 queries | same number of series | same number of series |
| *NFS requests/s* (table column) | **nothing** | 1 series |

The NFS column reads the platform's `node_nfs_requests_total`, which does not belong to `kcs-ipsec`, so a namespace data source cannot see it.

### A.3 What each panel showed

These captures are from the upstream Perses 0.54.0 UI run locally on CRC's data, with an identity that may query port 9092 (kubeadmin).

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/crc/41-perses-ipsec-nas.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="images/crc/41-perses-ipsec-nas.light.png">
  <img alt="The first conversion in Perses 0.54.0: tunnels up 1, down 0, workers reporting 1, soonest certificate expiry 364.1, tunnel state UP in green, certificate days left 364.1 as a bar, traffic rising steeply when the load starts, tunnel age 6.75h, metrics age 32s, libreswan version showing 1, nodes reported twice 0, pods reporting the wrong node 0, kernel IPsec errors 0, a per-node table with node crc in three rows, tunnel re-establishments 0 under a dashed threshold at 4, and kernel IPsec errors per node showing No data." src="images/crc/41-perses-ipsec-nas.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Capture 1. The first conversion, before the fixes.*

| Panel | In Perses | Same as Grafana? |
|---|---|---|
| Tunnels up / down, Workers reporting | 1 / 0 / 1 | yes |
| Tunnel state per node | UP in green | yes, the value mapping converted |
| Soonest certificate expiry | 364.1 | value yes; **the "days" unit is lost** |
| Certificate days left per node | a bar, `crc` 364.1 | yes |
| Traffic through the tunnel | to and from the NAS, rising steeply as the load starts (axis up to 3.34 MiB/s) | yes |
| Tunnel age / Metrics age | 6.75h / 32s | yes |
| libreswan version per node | **`1`** | **no**: Grafana showed the version label (`crc: 5.3`) |
| Nodes reported twice, Pods reporting the wrong node, Kernel IPsec errors | 0, 0, 0 in green | yes |
| **Per node** (table) | UP, YES, PRESENT, YES, YES in green; NFS mounts 2; drops 0; certificate imported 6.75h | **no**: node `crc` in three rows |
| Tunnel re-establishments | 0, under a dashed threshold at 4 | yes |
| Kernel IPsec errors per node | "No data" | the value is right (no drops); Grafana said "No drops" |

**Why the table split a node into three rows.** Perses merges series only when their labels are equal, and ours were not: the reporting pod came from a query labelled `node, pod`, the NAS identity from one labelled `node, peer_id`, and the other columns from queries labelled `node` only.

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/crc/41-perses-server-conversion.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="images/crc/41-perses-server-conversion.light.png">
  <img alt="The same dashboard converted by COO's Perses server: every panel is the same as the offline conversion except the per-node table, whose Tunnel, IKE SA, Certificate, Connection, libreswan, NFS and drops columns are empty while an extra column named value #1 shows 32." src="images/crc/41-perses-server-conversion.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Capture 2. COO's server conversion: the table's value columns are empty, because their names (`Value #B…`) do not match what the table plugin produces (`value #1…`). The other 15 panels match Capture 1. The chart uses the `percli` conversion.*

### A.4 A namespace-only reader on port 9092: every panel refused

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/crc/41-perses-reader-forbidden.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="images/crc/41-perses-reader-forbidden.light.png">
  <img alt="The same dashboard as the namespace reader: the node filter and the layout load, and every panel shows Forbidden (user=system:serviceaccount:kcs-ipsec:perses-viewer-test, verb=create, resource=pods, subresource=)." src="images/crc/41-perses-reader-forbidden.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Capture 3. The reader: every panel `Forbidden (… verb=create, resource=pods)`.*

**The cause, measured:**
- The Perses UI adds `namespace=kcs-ipsec` to all its requests (63 of 63).
- It sends the node lookup as `GET` (`200`), and every data query as **`POST /api/v1/query_range`** (`403`, 11 of 11).
- Thanos's per-namespace port treats the HTTP method as the permission it checks: a `POST` needs `create pods`, which `view` does not grant. The [openshift-grafana chart](https://github.com/ephico2real2/group-sync-dashboard/tree/main/charts/openshift-grafana) met the same rule and set Grafana to `GET`.
- **Perses has no such setting.** Its Prometheus data source accepts only the common HTTP settings, `scrapeInterval` and `queryParams` (plugin 0.58.0 schema). Red Hat's Perses fork and the console's monitoring plugin show nothing that changes this (a code search, not a test).

**Options considered:**
1. Give readers `cluster-monitoring-view` and use port 9091. **Chosen**: the [Decision](#decision-one-data-source-on-thanos-port-9091-metrics-readable-by-namespace-owners).
2. A shared data source on 9091 with a ServiceAccount's token: every reader would see through one account's rights. Rejected.
3. Ask upstream and Red Hat for a `GET` option in the Perses Prometheus data source: it would make namespace-only data sources possible later.

### A.5 The gaps, and how the generated dashboard fixes them

| Gap in the first conversion | In the dashboard the chart ships |
|---|---|
| The table split a node into three rows | **Fixed**: the table keeps the nine queries labelled by `node`; the reporting pod and the NAS identity are shown in *NAS identity per node*, from one query on `ipsec_nas_tunnel_info` (only nodes whose tunnel is up; since 2026-10-07 the query also lists the pod reporting a node whose tunnel is down, and the two tables are in the Grafana file) |
| libreswan version showed `1` | **Fixed**: shows `5.3` (`percli` had garbled the label to show) |
| The "days" unit was lost | **Fixed**, with a twist: Perses writes days in its largest fitting unit, so 364 days reads 12.1 months |
| NFS requests/s empty on a namespace data source | **Fixed** by port 9091: 39.8 requests/sec under load |
| Readers refused (A.4) | **Fixed** by the Decision: port 9091 and `cluster-monitoring-view` |
| `v1alpha1` deprecated | **Fixed**: `v1alpha2` |
| *(found in the second pass)* The node filter had no data source, so it used the namespace's default one, and the chart's is not the default | **Fixed**: the variables name `ipsec-nas-thanos`. Measured with no default data source: before, the filter sent no request; after, it queries `ipsec-nas-thanos` |
| "No data" where Grafana said "No drops" | Not fixed: the value is right (no drops) |

The generated dashboard carries 25 of the 27 Grafana expressions over verbatim; the table's two queries labelled `node, pod` and `node, peer_id` are replaced by one, `max by (node, pod, peer_id) (ipsec_nas_tunnel_info{node=~"$node"})`, in the identity panel. (Since 2026-10-07 the identity panel is a panel of the Grafana file, and all 33 expressions are carried over verbatim: the generator refuses a query that differs.) Applied on CRC, both objects are `Available`; a `POST` query through COO's Perses with the chart's data source answers (openshift-coo-helm evidence 11, section 10); Argo CD deploys them from Git.

## Not covered here

- COO itself, Perses' installation, `percli`: [openshift-coo-helm](https://github.com/ephico2real2/openshift-coo-helm).
- Granting `cluster-monitoring-view` to teams: `metricsAccess.groups` of the [openshift-coo chart](https://github.com/ephico2real2/openshift-coo-helm/tree/main/charts/openshift-coo).
- The figure's source: [`diagrams/ipsec-nas/source.html`](diagrams/ipsec-nas/source.html) (its fourth figure), rendered with [diagram-kit](https://github.com/ephico2real2/diagram-kit) (MPL-2.0); Mermaid text: [`diagrams/mermaid/perses-dashboard.mmd`](diagrams/mermaid/perses-dashboard.mmd). Figure, text version and source change together.
