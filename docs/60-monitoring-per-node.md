# Monitoring — Every Node Reports Its Own IPsec State

On a real cluster there are many workers, and each must report its own tunnel: the right data, under the right node's name, once. This document says where the numbers come from, how they stay pinned to their node, what each metric and alert means, and what was measured. It covers Option B (the `ipsec-cert-sync` DaemonSet); the setup steps are in [20-option-b-per-node-certificates.md, Step B.12](20-option-b-per-node-certificates.md#step-b12--metrics-in-observe-alerts-and-a-dashboard).

## No extra aggregator: OpenShift's monitoring is the single plane

- Each worker runs one `ipsec-cert-sync` pod. Its `collector` container reads the host every 30 seconds; its `metrics` container serves the result on port 9754.
- The ServiceMonitor `ipsec-nas` makes the user workload Prometheus scrape **every pod as its own target**.
- **Thanos Querier** (console: Observe → Metrics) answers queries over the platform's metrics and the user-defined ones together. Red Hat: it "aggregates and optionally deduplicates core OpenShift Container Platform metrics and metrics for user-defined projects under a single, multi-tenant interface" ([Monitoring overview](https://docs.redhat.com/en/documentation/openshift_container_platform/4.13/html/monitoring/monitoring-overview)).
- Measured on CRC: one query joins our `ipsec_nas_tunnel_up` with the platform's `node_nfs_requests_total` per node (2.01 NFS requests/s on `crc`, tunnel up) ([evidence 39](evidence/crc/39-metrics-dashboard-queries.txt)).
- **Several clusters:** Red Hat Advanced Cluster Management Observability collects user metrics named in the ConfigMap `observability-metrics-custom-allowlist`, key `uwl_metrics_list.yaml` ([ACM 2.15 Observability](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html-single/observability)). Not tested: we have no second cluster.

## How each node's data stays its own

| Layer | What pins the data to a node | If it goes wrong |
|---|---|---|
| DaemonSet | One pod per selected node. A second pod with the same labels in the same namespace is deleted by the DaemonSet itself (measured on kind: `SuccessfulDelete`) | A second copy in another namespace is not removed (measured on kind, namespace `kcs-ipsec-second-install`): `IpsecNasDuplicateNode` |
| The collector | Reads the host it runs on (`chroot /host`, the host's `/proc/1/…`) and writes `node` from the downward API (`spec.nodeName`) | A pod that names another node: `IpsecNasNodeLabelMismatch` |
| Prometheus | Adds `pod` and `exporter_node` (from `__meta_kubernetes_pod_node_name`, where Kubernetes placed the pod), independently of the collector | — |
| Coverage | `kube_node_role` (platform kube-state-metrics) lists the workers that should report | A worker with no scraped pod: `IpsecNasExporterMissing` |

To pin any query to one node, filter on `node`, and check it against `exporter_node`:

```promql
ipsec_nas_tunnel_up{node="worker-3"}                                   # one node
count by (node) (ipsec_nas_collect_timestamp_seconds) > 1             # a node reported twice
ipsec_nas_collect_timestamp_seconds{exporter_node!=""}
  unless on (node, pod)
  label_replace(ipsec_nas_collect_timestamp_seconds, "node", "$1", "exporter_node", "(.+)")   # a pod naming the wrong node
```

## What is collected

Every metric carries `node`. All are read-only: the collector changes nothing on the host.

| Metric | Meaning | Source on the host |
|---|---|---|
| `ipsec_nas_tunnel_up` | 1 if an IPsec SA to the NAS is established | `ipsec trafficstatus` |
| `ipsec_nas_ike_sa_established` | 1 if the IKE SA (the login) is established; absent when libreswan does not answer | `ipsec status` |
| `ipsec_nas_connection_configured` | 1 if NetworkManager has the `ipsec-nas` connection, that is, the NNCP reached the node | `nmcli` |
| `ipsec_nas_certificate_present` | 1 if the node certificate is in the NSS database | `certutil -L` |
| `ipsec_nas_certificate_not_after_timestamp_seconds` | When that certificate expires | `certutil` + `openssl` |
| `ipsec_nas_certificate_import_timestamp_seconds` | When cert-sync last imported a certificate | cert-sync's stamp file |
| `ipsec_nas_tunnel_established_timestamp_seconds` | When the current tunnel was set up | `ipsec trafficstatus` |
| `ipsec_nas_tunnel_in_bytes_total`, `…_out_bytes_total` | Bytes through the current tunnel | `ipsec trafficstatus` |
| `ipsec_nas_tunnel_info{peer_id}` | The identity the NAS presented | `ipsec trafficstatus` |
| `ipsec_nas_xfrm_errors_total{counter}` | Packets the kernel IPsec code dropped, per reason (all IPsec traffic of the node) | the host netns `/proc/net/xfrm_stat` ([kernel docs](https://kernel.org/doc/Documentation/networking/xfrm_proc.rst)) |
| `ipsec_nas_nfs_mounts{server}` | NFS mounts on the node, per server | the host's `/proc/1/mounts` |
| `ipsec_nas_libreswan_info{version}` | The libreswan version | `ipsec --version` |
| `ipsec_nas_collect_success` | 1 if libreswan answered | exit code of `ipsec trafficstatus` |
| `ipsec_nas_collect_timestamp_seconds` | When the collector last ran | — |

## Alerts

| Alert | Fires when | For | Severity |
|---|---|---|---|
| `IpsecNasTunnelDown` | `tunnel_up == 0` | 5m | critical |
| `IpsecNasNfsWithoutTunnel` | The node sends NFS requests (platform node-exporter) while its tunnel is down | 5m | critical |
| `IpsecNasCertificateMissing` | No certificate in the node's NSS database | 10m | critical |
| `IpsecNasConnectionMissing` | The certificate is there but the `ipsec-nas` connection is not (the NNCP did not reach the node) | 15m | warning |
| `IpsecNasTunnelFlapping` | The tunnel was set up again more than 3 times in an hour | – | warning |
| `IpsecNasLibreswanNotAnswering` | `collect_success == 0` | 5m | warning |
| `IpsecNasNodeLabelMismatch` | A pod's `node` differs from where it runs | 5m | warning |
| `IpsecNasDuplicateNode` | More than one pod reports a node | 10m | warning |
| `IpsecNasExporterMissing` | A worker has no scraped pod | 15m | warning |
| `IpsecNasMetricsStale` | The collector has not written for 5 minutes | 5m | warning |
| `IpsecNasCertificateExpiringSoon`, `…Expired` | Less than 14 days left; expired | 1h; – | warning; critical |

Two of the waits are measured, not chosen:

- **`IpsecNasDuplicateNode`, 10 minutes.** When the ServiceMonitor changed on CRC, the old and the new series of the same pod both existed for one 15-second step (18:08:15Z); the alert went pending and cleared by 18:09:00Z ([evidence 39](evidence/crc/39-metrics-dashboard-queries.txt)). Without the wait, that change alone would have paged.
- **`IpsecNasCertificateMissing`, 10 minutes.** cert-sync puts a deleted certificate back at its next check (every 5 minutes). On CRC it was missing for 72 seconds and the alert never fired ([evidence 38](evidence/crc/38-metrics-certificate-removed.txt)).

## The cluster settings: `user-workload-monitoring-config`

Two settings, both in the ConfigMap `user-workload-monitoring-config` in `openshift-user-workload-monitoring`. Nothing in `openshift-monitoring` is changed.

- **`namespacesWithoutLabelEnforcement: [ kcs-ipsec ]`**: `IpsecNasExporterMissing` and `IpsecNasNfsWithoutTunnel` fire on OpenShift only with it (OpenShift 4.18 or later).
- **`alertmanager: {enabled: true, enableAlertmanagerConfig: true}`**: the alerts are delivered to a dedicated Alertmanager in `openshift-user-workload-monitoring`, not to the platform's in `openshift-monitoring`, and a project may route its own alerts with an `AlertmanagerConfig`. As Red Hat designed it, that Alertmanager serves all user projects.

No Helm chart manages that ConfigMap yet (planned: [openshift-coo-helm#5](https://github.com/ephico2real2/openshift-coo-helm/issues/5)): a cluster administrator sets it once, by hand.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
    # keep every key already here and merge these in (or add the namespace to an existing list)
    namespacesWithoutLabelEnforcement: [ kcs-ipsec ]
    alertmanager:
      enabled: true
      enableAlertmanagerConfig: true
```

```bash
# Read it first: the ConfigMap may already hold other settings. Merge, never replace.
oc -n openshift-user-workload-monitoring get configmap user-workload-monitoring-config -o yaml
oc -n openshift-user-workload-monitoring edit configmap user-workload-monitoring-config

# The operator applies it to user workload monitoring's Prometheus and Thanos Ruler, and starts the Alertmanager:
oc get thanosruler,prometheus user-workload -n openshift-user-workload-monitoring \
  -o jsonpath='{range .items[*]}{.kind}: {.spec.excludedFromEnforcement}{"\n"}{end}'
oc get alertmanager,pods -n openshift-user-workload-monitoring | grep -i alertmanager
```

✅ **Expected:** `ThanosRuler: [{"group":"monitoring.coreos.com","namespace":"kcs-ipsec","resource":"prometheusrules"}]`, and the same for `Prometheus` (on CRC 14 seconds after the change, [evidence 46](evidence/crc/46-option-c-metrics-chart.txt) §5a); the Alertmanager `user-workload` and its pod `alertmanager-user-workload-0` `Running` (on CRC 10 seconds after the change, §5c).

### Why: what OpenShift does to a project's rules

1. **Red Hat:** *"By default, when you create an alerting rule, the `namespace` label is enforced on it"*, and a project's rule *"can include metrics exposed by its own project in addition to the default metrics from core platform monitoring"* ([openshift-docs, enterprise-4.18, *Creating alerting rules for user-defined projects*](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/monitoring-about-creating-alerting-rules-for-user-defined-projects.adoc)).
2. **What enforcement does, measured:** user workload monitoring loads every rule in `kcs-ipsec` with `namespace="kcs-ipsec"` added to each selector. As loaded on CRC:

   ```text
   kube_node_role{namespace="kcs-ipsec",role="worker"} unless on (node) ipsec_nas_collect_timestamp_seconds{namespace="kcs-ipsec"}
   ```

   So the platform metrics a project's rule can read are those carrying that project's namespace label, such as the CPU and memory of its own pods.
3. **Two alerts need platform series that carry another namespace.** Measured through Thanos Querier on CRC ([evidence 46](evidence/crc/46-option-c-metrics-chart.txt) §5):

   | Alert | Platform series it needs | Why it needs it | The series' namespace | With enforcement |
   |---|---|---|---|---|
   | `IpsecNasExporterMissing` | `kube_node_role` (kube-state-metrics) | The list of nodes that should report. Only the platform knows a node that has **no** collector pod at all | `openshift-monitoring` | no series: the alert can never fire |
   | `IpsecNasNfsWithoutTunnel` | `node_nfs_requests_total` (node-exporter) | NFS traffic per node, to find NFS on a node whose tunnel is down | `openshift-monitoring` | no series: the alert can never fire |

   Both fired in the kind run ([evidence kind/02](evidence/kind/02-exporter-missing.txt)), where kube-prometheus-stack enforces no namespace, so the defect showed only on OpenShift.
4. **The setting Red Hat provides for this:** *"Defines the list of namespaces for which Prometheus and Thanos Ruler in user-defined monitoring don't enforce the `namespace` label value in `PrometheusRule` objects"* ([cluster-monitoring-operator, release-4.18, `api.md`](https://github.com/openshift/cluster-monitoring-operator/blob/release-4.18/Documentation/api.md); not in release-4.17). Red Hat's own example of such a rule queries a kube-state-metrics series, `kube_namespace_labels` ([openshift-docs, enterprise-4.18, *Creating cross-project alerting rules*](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/monitoring-creating-cross-project-alerting-rules-for-user-defined-projects.adoc)).
5. **Measured with the setting:** both rules loaded without the added label. The NFS rule's left side returned `node=crc` at 2.011 requests/s. With the collector removed from `crc`, `IpsecNasExporterMissing` went pending at 15:59:12Z, fired at 16:14:14Z (its `for: 15m`), reached Alertmanager as `namespace=kcs-ipsec node=crc role=worker severity=warning`, and resolved when the collector was back ([evidence 46](evidence/crc/46-option-c-metrics-chart.txt) §5b). `IpsecNasNfsWithoutTunnel` was not driven to firing: that needs NFS traffic while the tunnel is down. Its platform input and its labels are covered by §5a and `tests/test-alert-rules.sh`.

### Why the two rules set their own `namespace` label

Red Hat: *"To make the resulting alerts and metrics visible to project users, the query expressions should return a `namespace` label with a non-empty value"* (`api.md`, above). Without it, measured on CRC, `IpsecNasExporterMissing` came out with kube-state-metrics' labels, `namespace=openshift-monitoring` among them ([evidence 46](evidence/crc/46-option-c-metrics-chart.txt) §5b): an alert of `openshift-monitoring`, not of this project. `IpsecNasNfsWithoutTunnel`'s `sum by (node)` keeps no namespace at all. So `IpsecNasExporterMissing` keeps only `node` and `role` (`max by (node, role)`), and both rules set `namespace` themselves; each chart writes its release namespace there.

### The alternatives, and why not

| Alternative | Why not |
|---|---|
| Rewrite both rules over series that carry `kcs-ipsec` (kube-state-metrics' `kube_pod_info`, `kube_daemonset_status_*` for our DaemonSet: measured with `namespace="kcs-ipsec"`) | Those series exist only for nodes where the DaemonSet places a pod. A node where it places none (a taint the pod does not tolerate, a wrong selector) is exactly what `IpsecNasExporterMissing` must find. There is no per-node NFS traffic among them either |
| The label `openshift.io/prometheus-rule-evaluation-scope: leaf-prometheus` | Red Hat: with it, *"your alerting rule can use only those metrics exposed by your user-defined project. Alerting rules you create based on default platform metrics might not trigger alerts"* (*Creating alerting rules for user-defined projects*, above) |
| A platform `AlertingRule` (`monitoring.openshift.io/v1`) in `openshift-monitoring` | Red Hat: it is for *"new alerting rules based on platform metrics"*, and *"You must create the `AlertingRule` object in the `openshift-monitoring` namespace"* ([openshift-docs, enterprise-4.18, *Creating new alerting rules*](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/monitoring-creating-new-alerting-rules.adoc)). Our series are user-defined (on CRC labelled `prometheus=openshift-user-workload-monitoring/user-workload`), and the rule would leave the project |

### Why the user workload Alertmanager

The rules live in `kcs-ipsec` and are evaluated in `openshift-user-workload-monitoring`; the alerts should be delivered there too, not into `openshift-monitoring`.

- **Without it.** Red Hat: if `alertmanager.enabled` is `false` or omitted, *"user-defined alerts are routed to the default platform Alertmanager instance"*, which is `alertmanager-main` in `openshift-monitoring` ([openshift-docs, enterprise-4.18, *Enabling a separate Alertmanager instance for user-defined alert routing*](https://github.com/openshift/openshift-docs/blob/enterprise-4.18/modules/monitoring-enabling-a-separate-alertmanager-instance-for-user-defined-alert-routing.adoc)). On CRC, user workload Prometheus sent its alerts to `alertmanager-main` before the change.
- **With `enabled: true`.** Red Hat: *"a dedicated instance of the Alertmanager for user-defined projects"*. On CRC `alertmanager-user-workload-0` was running 10 seconds after the change, and both user workload Prometheus and Thanos Ruler, which evaluates our rules, send to it.
- **With `enableAlertmanagerConfig: true`.** Red Hat: it lets *"users to define their own alert routing configurations with `AlertmanagerConfig` objects"*. A team routes the IPsec alerts to its receiver with an `AlertmanagerConfig` in `kcs-ipsec`; the charts create none.
- **Measured.** With the collector kept off `crc`, `IpsecNasExporterMissing` arrived in the user workload Alertmanager at 17:03:09Z as `namespace=kcs-ipsec node=crc role=worker severity=warning`, and `alertmanager-main` had nothing; it resolved there at 17:03:56Z once the collector was back ([evidence 46](evidence/crc/46-option-c-metrics-chart.txt) §5c).
- **One Alertmanager for all user projects, by Red Hat's design.** Red Hat: *"you can optionally enable a separate instance of Alertmanager to send alerts for user-defined projects only"* (same page). Every user project's alerts go there, each project routing its own with an `AlertmanagerConfig` in its namespace; on CRC that includes `group-sync-dashboard`, `modernize-demo` and `mongodb-poc`. openshift-coo-helm#5 puts the ConfigMap under a chart.

### What the exemption changes, and the care it needs

- **Only the rules of the listed namespaces.** The rules of every other project stay enforced, and the setting grants no one access to metrics.
- **The rules in `kcs-ipsec` can read every project's metrics.** Red Hat: these `PrometheusRule` objects *"are then applicable to all projects"*. Whoever can create or edit a `PrometheusRule` in `kcs-ipsec` gets that reach, so keep that right to the platform team. Red Hat lists the `monitoring-rules-edit` cluster role for the project as the one that creates such rules.
- **One copy of each rule.** Red Hat: *"If you create the same cross-project alerting rule in multiple projects, it results in repeated alerts."* Install the rules in one namespace only. That is also why Option B and Option C are never deployed together.
- **Who can set it:** `cluster-admin`, or a user with `user-workload-monitoring-config-edit` in `openshift-user-workload-monitoring`. An administrator can turn the whole feature off with `rulesWithoutLabelEnforcementAllowed: false` in `cluster-monitoring-config` (default `true`); then these two alerts are silent again.
- **Not managed by a chart yet.** Neither chart writes this ConfigMap: it is one object for the whole cluster's user workload monitoring, and other settings live in it beside ours. Both charts' install notes and READMEs repeat the step.

## The dashboard

**Where you see it:** in the OpenShift console, **Observe → Dashboards (Perses)**, project `kcs-ipsec`. The ipsec chart installs it there by default; how it works, who can see it and how to change it: [doc 61](61-perses-dashboard-review.md). The same dashboard ships to Grafana only if asked (`metrics.grafanaDashboard: true`). Both come from one source, `charts/ipsec-nas/files/ipsec-nas.json`, and show the same five sections.

It has five sections, each answering one question ([doc 61, *At a glance*](61-perses-dashboard-review.md#at-a-glance)):

- **Summary**: is anything wrong? Tunnels up and down, workers reporting, the soonest certificate expiry.
- **Tunnels per node**: tunnel state, certificate time left, traffic, tunnel age, metrics age, libreswan version.
- **Checks (all should be 0)**: **Nodes reported twice**, **Pods reporting the wrong node**, **Kernel IPsec errors, last hour**.
- **Per-node detail**: one row per node with tunnel, IKE SA, certificate, connection, libreswan answering, NFS mounts and requests, IPsec drops and last certificate import; under it in Perses, the NAS identity and the reporting pod of each node whose tunnel is up (Grafana's table shows the reporting pod of every node, and the NAS identity of each node whose tunnel is up). A node in two rows there is reported by two pods. In Grafana **"–" means unknown** (no series), never healthy (Capture 1); the Perses table maps only 0 and 1, and how it shows a missing value was not measured.
- **History**: tunnel re-establishments in the last hour, with the alert's threshold; kernel IPsec errors per node and counter over time.

<!-- markdownlint-disable MD033 -->
<img alt="The OpenShift console, Observe, Dashboards, project kcs-ipsec, dashboard IPsec to the NAS, node filter All, last 30 minutes, in five sections. Summary: tunnels up 1, down 0, workers reporting 1, soonest certificate expiry 12.1 months. Tunnels per node: tunnel state UP in green, certificate time left 12.1 months as a bar, traffic through the tunnel at about 3.8 MiB/s during two load runs, tunnel age 2.33h, metrics age 39s, libreswan version 5.3. Checks (all should be 0): nodes reported twice 0, pods reporting the wrong node 0, kernel IPsec errors last hour 0. Per-node detail: one row for crc (UP, YES, PRESENT, YES, YES, 2 NFS mounts, 39.8 requests/sec, 0 drops, certificate imported 10.1h ago), and the NAS identity table showing crc, ipsec-cert-sync-5mvdc and O=KCS OpenShift lab, CN=crc-nas.lab.internal. History: tunnel re-establishments 0 under a dashed threshold at 4, and kernel IPsec errors per node showing No data." src="images/crc/42-console-perses-ipsec-nas.light.png">
<!-- markdownlint-enable MD033 -->

*Capture 3. The dashboard today, in the OpenShift console on CRC, in its five sections. How it was captured: [doc 61, Capture 6](61-perses-dashboard-review.md#at-a-glance) and [evidence 42](evidence/crc/42-console-perses-capture.txt).*

The two Grafana captures below were taken earlier, before the sections and before Perses was adopted. Each shows a test of its own, recorded in its evidence file.

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/kind/dashboard-faults.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="images/kind/dashboard-faults.light.png">
  <img alt="The IPsec to the NAS dashboard on a three-node kind cluster with two faults injected: Nodes reported twice 1, Pods reporting the wrong node 1, and the per-node table with ipsec-metrics-worker in two rows (pods ipsec-cert-sync-df2w4 and dup-on-worker) and a row for ghost-node reported by ghost-on-worker2. Every node shows tunnel DOWN, certificate MISSING and connection MISSING because kind nodes have no libreswan, and the IKE SA column shows – (unknown)." src="images/kind/dashboard-faults.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Capture 1. The dashboard (in Grafana, before the sections) on kind with a duplicate pod (`dup-on-worker`) and a pod naming the wrong node (`ghost-on-worker2`), the same two faults as in [`evidence/kind/01-per-node-metrics-faults.txt`](evidence/kind/01-per-node-metrics-faults.txt), applied again at 18:27Z after the tests of [evidence kind/02](evidence/kind/02-exporter-missing.txt) (hence other pod names). kind nodes have no libreswan, NSS database or NNCP, so the IPsec columns are DOWN or MISSING by design; what the capture shows is that each pod's data lands in its own row, and that unknown (the IKE SA) shows as –.*

With real IPsec, on CRC: the same dashboard in Grafana 13.2.3, run locally as a stand-in and reading CRC's Thanos Querier (CRC has no Grafana of ours; the console's Perses now shows the same dashboard, doc 61), while a bounded Job in `ipsec-nas-demo` wrote and read back 8 MiB on the NAS volume every 2 seconds:

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/crc/40-grafana-dashboard-crc-data.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="images/crc/40-grafana-dashboard-crc-data.light.png">
  <img alt="The IPsec to the NAS dashboard with CRC's real data: 1 tunnel up, 0 down, 364.3 days of certificate left, traffic through the tunnel rising from 0 to about 4 MB/s in each direction when the load starts, tunnel age 1.73 hours, libreswan 5.3, nodes reported twice 0, pods reporting the wrong node 0, kernel IPsec errors 0, and the per-node table for crc: UP, IKE SA YES, certificate PRESENT, connection YES, libreswan YES, 2 NFS mounts, 39.7 NFS requests per second, 0 drops, certificate imported 1.73 hours ago, NAS identity O=KCS OpenShift lab, CN=crc-nas.lab.internal. The re-establishment panel shows the 18:11Z restart until it leaves the one-hour window; the drops panel reads No drops." src="images/crc/40-grafana-dashboard-crc-data.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Capture 2. Every panel populated from CRC (in Grafana, before the sections). Traffic: 4.13 MB/s out and 4.09 MB/s in (five-minute rates), 39.5 NFS requests/s; NFS mounts reads 2 because the load Job mounts the same export as the demo application. Text and the Job: [evidence 40](evidence/crc/40-grafana-dashboard-crc-data.txt).*

## What was tested, and where

| Where | What it proves | Result |
|---|---|---|
| `tests/test-metrics-collector.sh` | The parsers on recorded libreswan 4, libreswan 5 and CRC output; `collect()` end to end against a stubbed host: healthy, no NNCP, no certificate, libreswan not answering | All pass |
| `tests/test-alert-rules.sh` (promtool) | Six nodes, one fault each: every new alert fires for its node and only that node | All pass; a swapped node makes it fail |
| **kind, 3 nodes** (1 control plane, 2 workers), kube-prometheus-stack, the chart's real collector, ServiceMonitor, rules and dashboard | 2 targets, each `node == exporter_node`, the control plane excluded; a duplicate pod and a pod naming `ghost-node` each caught on its node only; one pod deleted changes only its node; a worker without a pod raises `IpsecNasExporterMissing` for that worker only | [evidence kind/01](evidence/kind/01-per-node-metrics-faults.txt), [kind/02](evidence/kind/02-exporter-missing.txt) |
| **CRC** (OpenShift 4.22.7, real IPsec), deployed from Git by Argo CD | Every new series with real values; every dashboard query answers; the certificate deleted from NSS and put back by cert-sync | [evidence 38](evidence/crc/38-metrics-certificate-removed.txt), [39](evidence/crc/39-metrics-dashboard-queries.txt) |
| **CRC**, Option C with the `ipsec-nas-option-c-metrics` chart | The same 41 series without cert-sync; with `namespacesWithoutLabelEnforcement: [ kcs-ipsec ]`, `IpsecNasExporterMissing` fires for a node without a collector, labelled `namespace=kcs-ipsec`, and resolves when it is back | [evidence 46](evidence/crc/46-option-c-metrics-chart.txt) |
| A real multi-node OpenShift cluster | — | **Not tested yet**: tracked in issue #20 |

What the tests showed, beyond pass or fail:

1. **`tunnel_up` does not see a tunnel restart.** On CRC, cert-sync restarted the tunnel at 18:11:44Z; `tunnel_up` stayed 1 in every sample. Only `tunnel_established_timestamp_seconds` moved (12:39:20Z to 18:11:44Z) and `changes()` counted 1 ([evidence 38](evidence/crc/38-metrics-certificate-removed.txt)). A tunnel that keeps restarting looks up on every other panel; `IpsecNasTunnelFlapping` is the only alert for it, and the tunnel age panel the only other place it shows.
2. **A stray pod is removed by the DaemonSet** when it is in the DaemonSet's namespace with its labels (measured). A duplicate that lasts comes from elsewhere, such as the second copy in another namespace that was measured here.
3. **The NFS join needs OpenShift's node-exporter.** There, `instance` is the node's name (`crc`, measured). In the kube-prometheus-stack on kind it is `IP:9100`, so `IpsecNasNfsWithoutTunnel` and the NFS column find nothing outside OpenShift.
4. **On OpenShift, a project's rules see only that project's series** unless the project is in `namespacesWithoutLabelEnforcement`. kind enforces nothing, which is why `IpsecNasExporterMissing` fired there ([evidence kind/02](evidence/kind/02-exporter-missing.txt)) but could not on CRC before the setting ([evidence 46](evidence/crc/46-option-c-metrics-chart.txt)).
5. **kind is not OpenShift.** The kind run used `ubi9/ubi` for the collector (the `openshift/cli` image is amd64 only), had no `sync` container, and no IPsec. It proves the per-node plumbing; CRC proves the IPsec values.

## Not covered here

- **The dashboard in the console (Perses)**: [doc 61](61-perses-dashboard-review.md).
- **Option C** gets the same collector and alerts from a separate chart, [`ipsec-nas-option-c-metrics`](../charts/ipsec-nas-option-c-metrics/README.md), without cert-sync and without `ipsec_nas_certificate_import_timestamp_seconds` ([evidence 46](evidence/crc/46-option-c-metrics-chart.txt)). Its dashboards: issue #43.
- **Per-flow encryption** (was this NFS packet encrypted?) is out of reach of a collector that reads counters. Issue #35 evaluates the Network Observability Operator's eBPF agent and its IPsec feature, as a read-only probe that must run beside OVN-Kubernetes without touching its datapath.
