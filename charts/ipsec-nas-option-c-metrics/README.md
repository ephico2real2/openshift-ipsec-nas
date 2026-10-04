# ipsec-nas-option-c-metrics Helm chart

Per-node **IPsec metrics and alerts for Option C** ([`docs/50-option-c-wildcard-certificate.md`](../../docs/50-option-c-wildcard-certificate.md)): Option B's collector, metrics server and twelve alert rules, without cert-sync. Option C itself installs no pod, so without this chart it has no metrics (epic #42, story #39).

> [!CAUTION]
> **Never deploy this chart together with Option B's [`ipsec-nas`](../ipsec-nas/README.md) chart.** One option per cluster: both create the ServiceMonitor and PrometheusRule `ipsec-nas`, and both would report every node twice. Nothing in the chart refuses it; it is the operator's rule.

## Shared code

> [!IMPORTANT]
> **`files/collect.sh`, `files/serve.py` and `files/prometheus-rule-groups.yaml` are COPIES.** The source is [`shared/collector/`](../../shared/collector/). Change the shared file first, then copy it into **both** charts' `files/` (this one and `charts/ipsec-nas/files/`), and regenerate `manifests/option-b-per-node-certs/25-metrics-scripts.yaml`. Helm cannot read files outside a chart, hence the copies.
>
> `tests/test-shared-collector.sh` fails when a copy differs from its source. In Claude Code, a project hook (`.claude/settings.json`) blocks a direct edit to a copy.

## What it creates

| Object | Name | Purpose |
|---|---|---|
| ServiceAccount, RoleBinding | `ipsec-nas-metrics`, `system:openshift:scc:privileged` | The collector reads the host (`chroot /host`), privileged, as root |
| ConfigMap | `ipsec-metrics-scripts` | `collect.sh` and `serve.py` |
| DaemonSet | `ipsec-nas-metrics` | Two containers: `collector` (every 30 s) and `metrics` (port 9754, `restricted-v2`). No cert-sync |
| Service, ServiceMonitor | `ipsec-nas-metrics`, `ipsec-nas` | One scrape target per pod, with `exporter_node` from the pod's node |
| PersesDashboard, PersesDatasource | `ipsec-nas`, `ipsec-nas-thanos` | The dashboard in the console, Observe → Dashboards (Perses): "IPsec to the NAS (Option C)". `metrics.persesDashboard.enabled`, on by default |
| ConfigMap (optional) | `ipsec-nas-grafana-dashboard` | The same dashboard for a Grafana sidecar (label `grafana_dashboard: "1"`). `metrics.grafanaDashboard`, off by default |
| PrometheusRule | `ipsec-nas` | Option B's twelve rules; the descriptions name this DaemonSet, "exporter missing" watches the role of `nodeSelector`, and the two alerts on platform metrics carry the release's namespace |

## What differs from Option B

The same series, the same names, under the same `node` label. Measured on CRC with C1 before #40: 41 samples against Option B's 42; the one missing, `ipsec_nas_certificate_import_timestamp_seconds`, came only from cert-sync's stamp ([evidence 45](../../docs/evidence/crc/45-option-c-collector.txt)). Since #40 the collector reads it on Option C too: the journal's last successful run of `ipsec-nas-import.service` in the current boot, since Option C imports at every boot. `ipsec_nas_certificate_source_info{mode="C"}` names the option ([evidence 47](../../docs/evidence/crc/47-certificate-mode.txt)).

## Prerequisites

| Prerequisite | Why |
|---|---|
| Option C installed (doc 50, Steps C.1 to C.6) | The collector reads its tunnel and certificate |
| A namespace with the privileged pod-security labels | The collector runs privileged |
| User workload monitoring | For `metrics.serviceMonitor` and `metrics.prometheusRule` |
| Cluster Observability Operator 1.5 or later, with Perses ([openshift-coo chart](https://github.com/ephico2real2/openshift-coo-helm/tree/main/charts/openshift-coo)) | For `metrics.persesDashboard.enabled` (on by default) |
| A Grafana with a dashboard sidecar on the label `grafana_dashboard: "1"`, in this namespace or searching it | Only for `metrics.grafanaDashboard: true` |
| `namespacesWithoutLabelEnforcement` listing the release's namespace, in `user-workload-monitoring-config` (OpenShift 4.18 or later, a cluster administrator; [doc 20, Step B.12, 2](../../docs/20-option-b-per-node-certificates.md#step-b12--metrics-in-observe-alerts-and-a-dashboard)) | `IpsecNasExporterMissing` and `IpsecNasNfsWithoutTunnel` read platform metrics; without it they never fire ([evidence 46](../../docs/evidence/crc/46-option-c-metrics-chart.txt)) |
| **No** Option B release on the cluster | See the caution above |

## Install

```bash
# 1. The namespace, with the privileged pod-security labels
oc create namespace kcs-ipsec
oc label namespace kcs-ipsec pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged \
  security.openshift.io/scc.podSecurityLabelSync=false

# 2. Install
helm install ipsec-nas-metrics charts/ipsec-nas-option-c-metrics -n kcs-ipsec

# 3. One pod per IPsec node, and the series
oc get pods -n kcs-ipsec -l app=ipsec-nas-metrics -o wide
```

On OpenShift Local add `-f charts/ipsec-nas-option-c-metrics/values-crc.yaml`. The single node carries the worker, control-plane and master labels: the worker selector picks it, and the file only empties `excludeNodeLabels`, which would otherwise exclude it.

## Cluster settings: `user-workload-monitoring-config`

> [!IMPORTANT]
> **A cluster administrator sets this ConfigMap (namespace `openshift-user-workload-monitoring`) with the chart [`openshift-user-workload-monitoring`](https://github.com/ephico2real2/openshift-coo-helm/tree/main/charts/openshift-user-workload-monitoring)**, whose `examples/values-ipsec-nas.yaml` holds these settings, or by hand (OpenShift 4.18 or later). Nothing in `openshift-monitoring` is changed. Without `namespacesWithoutLabelEnforcement`, `IpsecNasExporterMissing` and `IpsecNasNfsWithoutTunnel` never fire: they read platform metrics (`kube_node_role`, `node_nfs_requests_total`), which user workload monitoring hides from a project's rules ([evidence 46](../../docs/evidence/crc/46-option-c-metrics-chart.txt)). The other ten alerts work without it. `alertmanager.enabled` delivers user workload alerts to a dedicated Alertmanager in `openshift-user-workload-monitoring` instead of the platform's; by Red Hat's design it serves all user projects, each routing its own alerts with an `AlertmanagerConfig`.

List only the namespace this chart is installed in (`kcs-ipsec` below, as in the install steps above). Option B uses the same setting.

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

The ConfigMap may already hold other settings: read it first (`oc -n openshift-user-workload-monitoring get configmap user-workload-monitoring-config -o yaml`) and merge, never replace it. Steps and the check: [doc 20, Step B.12, 2](../../docs/20-option-b-per-node-certificates.md#step-b12--metrics-in-observe-alerts-and-a-dashboard). Why it is needed, what it changes and the alternatives: [doc 60](../../docs/60-monitoring-per-node.md#the-cluster-settings-user-workload-monitoring-config).

## Option C itself: the certificate and the tunnel (optional)

Off by default; with them the chart sets up Option C with **cert-manager and Kyverno**, using the names and checks of Option B's chart. The whole procedure is [docs/53-option-c-cert-manager-kyverno.md](../../docs/53-option-c-cert-manager-kyverno.md).

| Value | Default | Meaning |
|---|---|---|
| `certificate.enabled` | `false` | A cert-manager `Certificate` for `*.<nodeDomain>` from `clusterIssuer`: `CN=ocp-ipsec-workers, O=KCS`, RSA `keySize`, server and client auth, `duration` 2 years, into Secret `certificate.secretName` |
| `tunnel.enabled` / `variant` / `pools` | `false` / `c1` / `[worker]` | C1: NNCP `ipsec-nas-wildcard-<pool>`. C2: Kyverno policy `ipsec-nncp-wildcard-<pool>`, one NNCP per node, with Kyverno's two ClusterRoles (`kyvernoRBAC.create`). The same objects as `render.sh` (the chart test compares them) |
| `nodeDomain`, `nas.fqdn`, `nas.ip`, `clusterIssuer` | – | As in Option B's chart |
| `ipsec.type` / `left` / `right` | `transport` / node FQDN (C2) / `nas.fqdn` | As in Option B's chart. OpenShift Local: `tunnel`, `%defaultroute`, the NAS's IP |
| `prerequisites.skipCheck` / `kyvernoNamespace` | `false` / `kyverno` | The checks: NMState (tunnel), Kyverno 1.19 (C2), cert-manager (certificate) served; the `ClusterIssuer` exists; Kyverno does not ignore Nodes |

**The chart never makes the MachineConfig.** It carries the private key and reboots its pool. `scripts/option-c-certificate.sh from-secret` builds each pool's MachineConfig from the certificate's Secret, with every check of the manual path, and you apply it.

## Values

| Value | Default | Meaning |
|---|---|---|
| `nodeSelector` | `node-role.kubernetes.io/worker: ""` | The nodes where Option C enables IPsec. Its role is the one "exporter missing" watches |
| `excludeNodeLabels` | control-plane, master, ingress | Label keys that exclude a node even when it matches; the roles among them are left out of "exporter missing" |
| `tolerations` | `[]` | For tainted nodes that mount the NAS |
| `images.cli`, `images.python` | OpenShift `cli`, UBI 9 Python 3.12 | The same images as Option B; mirror them on a disconnected cluster |
| `serviceAccount.name` | `ipsec-nas-metrics` | The DaemonSet's ServiceAccount |
| `scc.bind` | `true` | Binds the `privileged` SCC to it |
| `metrics.serviceMonitor` / `prometheusRule` | `true` / `true` | Observe and the alert rules |
| `metrics.persesDashboard.enabled` / `thanosURL` | `true` / Thanos Querier, port 9091 | The Perses dashboard; COO 1.5 or later is then a prerequisite. Viewers need `view` in the namespace and `cluster-monitoring-view` |
| `metrics.grafanaDashboard` | `false` | The Grafana ConfigMap |

The dashboards are generated: `scripts/perses-dashboard.sh` derives `files/ipsec-nas-option-c.json` from Option B's `charts/ipsec-nas/files/ipsec-nas.json` (`scripts/option-c-dashboard.py`: its own uid, title and reporting pod) and converts it to `files/ipsec-nas-option-c.perses.json`. Edit Option B's dashboard, then run the script; the chart test fails on a stale copy, and the Claude Code hook blocks hand edits.

`values.schema.json` refuses unknown values.

## Uninstall

```bash
helm uninstall ipsec-nas-metrics -n kcs-ipsec
```

The chart changes nothing on the nodes, so there is nothing else to clean up.

## Test

```bash
tests/test-option-c-chart.sh      # lint, the objects, no cert-sync, selectors, the alert's role, the schema
tests/test-shared-collector.sh    # the copies equal shared/collector/
```
