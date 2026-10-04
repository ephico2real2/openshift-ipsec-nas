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
| PrometheusRule | `ipsec-nas` | Option B's twelve rules; the descriptions name this DaemonSet, "exporter missing" watches the role of `nodeSelector`, and the two alerts on platform metrics carry the release's namespace |

## What differs from Option B

The same series, the same names, under the same `node` label. One series is missing: `ipsec_nas_certificate_import_timestamp_seconds`. Option B's collector reads cert-sync's stamp `/etc/pki/certs/kcs-ipsec/.installed-sha256`, which Option C does not have. Measured on CRC with C1: 41 samples against Option B's 42, all the others present ([evidence 45](../../docs/evidence/crc/45-option-c-collector.txt)). Issue #40 reads Option C's import time instead.

## Prerequisites

| Prerequisite | Why |
|---|---|
| Option C installed (doc 50, Steps C.1 to C.6) | The collector reads its tunnel and certificate |
| A namespace with the privileged pod-security labels | The collector runs privileged |
| User workload monitoring | For `metrics.serviceMonitor` and `metrics.prometheusRule` |
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
> **No Helm chart manages this ConfigMap (namespace `openshift-user-workload-monitoring`) yet: a cluster administrator sets it by hand** (OpenShift 4.18 or later). Nothing in `openshift-monitoring` is changed. Without `namespacesWithoutLabelEnforcement`, `IpsecNasExporterMissing` and `IpsecNasNfsWithoutTunnel` never fire: they read platform metrics (`kube_node_role`, `node_nfs_requests_total`), which user workload monitoring hides from a project's rules ([evidence 46](../../docs/evidence/crc/46-option-c-metrics-chart.txt)). The other ten alerts work without it. `alertmanager.enabled` delivers user workload alerts to a dedicated Alertmanager in `openshift-user-workload-monitoring` instead of the platform's; it applies to every user project's alerts, so agree it with the cluster's monitoring owners.

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
