# ipsec-nas Helm chart

Installs **per-node IPsec tunnels from OpenShift nodes to an external NAS**: Option B, our standard setup and the enterprise north star ([`docs/20-option-b-per-node-certificates.md`](../../docs/20-option-b-per-node-certificates.md)), as one Helm release. [`docs/30-option-b-automated-helm-argocd.md`](../../docs/30-option-b-automated-helm-argocd.md) has the install and removal steps as measured; this page is the reference for the chart's values and behaviour.

The chart creates exactly the objects of `manifests/option-b-per-node-certs/` (with `kyverno.legacyPolicies: true`, those of its `kyverno-legacy/` in place of their namesakes) and `manifests/common/03-kyverno-rbac.yaml`. `tests/test-chart.sh` renders both and compares every object, for both policy sets, so the chart cannot drift from the manifests that were measured on a cluster.

## Prerequisites

These must **already be on the cluster**. They are prerequisites, not dependencies: the chart uses them, checks for them, and never installs or upgrades them. If one is missing, `helm install` stops with a message that names it.

| Prerequisite | Why | Where it is set up | Checked by the chart |
|---|---|---|---|
| **cert-manager**, with a `ClusterIssuer` for the enterprise CA | Issues one certificate per node. The chart never creates an issuer | 00, Part 0.2; 20, Step B.1 | The API `cert-manager.io/v1` is served; the `ClusterIssuer` named in `clusterIssuer` exists |
| **Kyverno** 1.19 or later (or 1.13 or later with `kyverno.legacyPolicies: true`), which does **not** filter out Nodes | Creates the Certificate and the NNCP for each node, gives each pod its node's secret, removes a deleted node's Secret | 00, Steps 1.6 and 1.7 | The API `policies.kyverno.io/v1` is served (`kyverno.io/v1`, and `kyverno.io/v2` for the cleanup, with the legacy policies); `[Node,*,*]` is not in Kyverno's `resourceFilters` |
| **NMState Operator** with an `NMState` instance | Builds the tunnel on the node from the NNCP | 00, Step 1.5 | The API `nmstate.io/v1` is served |
| **libreswan on the nodes** | The tunnel itself | 00, Steps 1.3 and 1.4 (`routingViaHost`, `ipsecConfig.mode: External`) | Not checked |
| **The namespace**, with the privileged pod-security labels | The cert-sync pod runs privileged | 20, Step B.2 | Not checked: create it before installing |
| **The NAS side** | Its own certificate from the same CA, and its IPsec settings | 00, Part 3.1 | Not checked |
| User workload monitoring | Only for `metrics.serviceMonitor` and `metrics.prometheusRule` | 20, Step B.12 | Not checked |
| Grafana | Only for `metrics.grafanaDashboard: true` (off by default): it loads the dashboard ConfigMap | A Grafana with a dashboard sidecar on the label `grafana_dashboard: "1"`, in the release's namespace or **central and searching it** (both measured: [evidence kind/03](../../docs/evidence/kind/03-grafana-dashboard-prerequisite.txt)). grafana-operator with a `GrafanaDashboard` (docs/20, Step B.12): not measured | **Not checked**: no API tells a Grafana sidecar is there, and without a Grafana the ConfigMap is simply unused. The install notes repeat it |
| **Cluster Observability Operator** 1.5 or later, with Perses | The dashboard in the console. Required by default; not needed with `metrics.persesDashboard.enabled: false` | [openshift-coo-helm](https://github.com/ephico2real2/openshift-coo-helm) | The API `perses.dev/v1alpha2` is served |

## Install

```bash
# 1. The namespace (docs/20-option-b-per-node-certificates.md, Step B.2)
oc apply -f manifests/option-b-per-node-certs/20-namespace.yaml

# 2. Your values. Only these five are required.
cat <<'EOF' > my-values.yaml
nodeDomain: ocp.example.com          # worker-0 gets a certificate for worker-0.ocp.example.com
nas:
  fqdn: nas01.example.com
  ip: 10.0.0.50
clusterIssuer: company-issuer-rnd    # the EXISTING enterprise CA issuer: oc get clusterissuer
EOF

# 3. Install. enterprise-root.pem is the enterprise ROOT CA certificate (docs/20-option-b-per-node-certificates.md, Step B.3).
helm install ipsec-nas charts/ipsec-nas -n kcs-ipsec -f my-values.yaml \
  --set-file trustCA.pem=enterprise-root.pem
```

Then, for every node that has the labels in `nodeSelector`, with nothing more to do:

1. Kyverno creates a `Certificate`, and cert-manager issues it.
2. The cert-sync pod on that node imports it and labels the node `ipsec.kcs.io/cert-ready=true`.
3. Kyverno creates the NNCP, and NMState brings up the tunnel.

```bash
oc get certificate -n kcs-ipsec
oc get pods -n kcs-ipsec -o wide
oc get nncp,nnce | grep ipsec-nas
oc debug node/<node> -q -- chroot /host ipsec trafficstatus
```

> [!NOTE]
> Helm creates the DaemonSet a moment before the Kyverno policies. The first cert-sync pod on each node is therefore created without its node's secret. It notices, logs `This pod mounts the placeholder secret`, and deletes itself after 60 seconds; the pod that replaces it gets the secret. Measured on CRC: the tunnel was up about **100 seconds** after `helm install`.

## Install with Argo CD

`examples/argocd-application.yaml` is an Application for this chart. Every object carries a sync wave, so Argo CD creates the permissions and ConfigMaps first, then the two Kyverno policies the DaemonSet depends on, then the DaemonSet, then the NNCP policy and the monitoring. The first pod then already has its node's secret.

```bash
oc create configmap ipsec-trust-ca -n kcs-ipsec --from-file=ca.pem=enterprise-root.pem   # or put the PEM in the Application's values
oc apply -f charts/ipsec-nas/examples/argocd-application.yaml                            # after editing its values
oc get application -n openshift-gitops ipsec-nas
```

Measured on CRC with Argo CD 3.4.7: `Synced` and `Healthy` 12 seconds after the sync started, tunnel up within 23 seconds of applying the Application. [`docs/30-option-b-automated-helm-argocd.md`](../../docs/30-option-b-automated-helm-argocd.md#step-i3--install-with-argo-cd-from-git) has the steps, the diagram and screenshots of the application.

Argo CD renders the chart without a cluster connection, so the checks that read objects (the `ClusterIssuer`, Kyverno's Node filter) do not run there; the checks for the served APIs do.

## Values

| Value | Default | Meaning |
|---|---|---|
| `nodeDomain` | – (required) | DNS domain of the nodes |
| `nas.fqdn` | – (required) | DNS name of the NAS; must be in the NAS certificate |
| `nas.ip` | – (required) | NAS address that carries NFS; only traffic to it is encrypted |
| `clusterIssuer` | – (required) | Name of the **existing** enterprise CA `ClusterIssuer` |
| `trustCA.pem` | – (required) | Enterprise root CA, PEM. Use `--set-file` |
| `trustCA.existingConfigMap` | `""` | Use an existing ConfigMap (key `ca.pem`) instead of `trustCA.pem` |
| `ipsec.type` | `transport` | `tunnel` only when there is NAT between the nodes and the NAS |
| `ipsec.left` | `""` | Empty means `<node>.<nodeDomain>` |
| `ipsec.right` | `""` | Empty means `nas.fqdn` |
| `nodeSelector` | `node-role.kubernetes.io/worker: ""` | Which nodes get a certificate, a pod and a tunnel |
| `tolerations` | `[]` | For the cert-sync DaemonSet |
| `certificate.duration` / `renewBefore` / `keySize` | `8760h` / `720h` / `3072` | The per-node certificate |
| `images.cli`, `images.python` | OpenShift `cli`, UBI 9 Python 3.12 | Mirror them on a disconnected cluster |
| `kyverno.legacyPolicies` | `false` | `false`: Kyverno's CEL policies (`policies.kyverno.io/v1`), `templates/kyverno/`. `true`: the legacy `ClusterPolicy` and `CleanupPolicy`, `templates/kyverno-legacy/`, deprecated in Kyverno 1.19. See [Kyverno policies: CEL or legacy](#kyverno-policies-cel-or-legacy) |
| `kyvernoRBAC.create` | `true` | The two ClusterRoles of `docs/00-prepare-the-cluster.md`, Step 1.7 |
| `scc.bind` | `true` | Binds the `privileged` SCC to the cert-sync service account |
| `metrics.serviceMonitor` / `prometheusRule` / `grafanaDashboard` | `true` / `true` / `false` | Observe, the alert rules, the Grafana dashboard ConfigMap (off: the dashboard ships for Perses) |
| `metrics.persesDashboard.enabled` / `thanosURL` | **`true`** / Thanos Querier, port 9091 | The dashboard in the OpenShift console: a `PersesDashboard` and its `PersesDatasource`, `perses.dev/v1alpha2`. Viewers need `view` in the namespace and `cluster-monitoring-view`. `files/ipsec-nas.perses.json` is generated by `scripts/perses-dashboard.sh` from the Grafana dashboard. Guide and why port 9091: [doc 61](../../docs/61-perses-dashboard-review.md) |
| `nodeCleanup.deleteCertificate` / `deleteOrphanedSecrets` / `schedule` | `true` / `true` / `*/5 * * * *` | What is removed when a Node is deleted |
| `uninstallCleanup.enabled` / `hook` / `removeCertificates` | `true` / `helm` / `true` | The cleanup before the release is removed |
| `prerequisites.skipCheck` | `false` | Only for `helm template` without a cluster |
| `prerequisites.kyvernoNamespace` | `kyverno` | Where to look for Kyverno's configuration |

`values-crc.yaml` holds the values used on OpenShift Local in [`docs/30-option-b-automated-helm-argocd.md`](../../docs/30-option-b-automated-helm-argocd.md). Tunnel mode, `%defaultroute` and an IP as `right` are for that lab only.

## What is cleaned up, and when

| Event | What happens | Controlled by |
|---|---|---|
| A node **reboots** | Nothing is removed. The Node object stays, so its `Certificate`, its Secret and the certificate on the node stay; the tunnel comes back by itself (measured) | – |
| A Node is **deleted** | Kyverno deletes that node's `Certificate`. A Kyverno `NamespacedDeletingPolicy` (legacy: `CleanupPolicy`) then deletes the Secret that cert-manager leaves behind, in this namespace only (measured with a stand-in Node) | `nodeCleanup.deleteCertificate`, `nodeCleanup.deleteOrphanedSecrets`, `nodeCleanup.schedule` |
| `helm uninstall` | `files/uninstall.sh` runs first, as a pre-delete hook: tunnels off the nodes, node labels, the certificate and key on each node, the `Certificate` objects, then the Secrets (measured: 12 seconds, nothing left) | `uninstallCleanup.enabled`, `uninstallCleanup.removeCertificates` |
| An Argo CD Application is deleted | **Nothing is cleaned up** on Argo CD 3.4.7: it ran no hook (measured). Use the three steps below | `uninstallCleanup.hook: argocd` is there for an Argo CD that runs `PreDelete` hooks; not seen working |

To keep the certificates through a node deletion **and** an uninstall, set `nodeCleanup.deleteCertificate`, `nodeCleanup.deleteOrphanedSecrets` and `uninstallCleanup.removeCertificates` to `false`. The `false` settings were not tested on a cluster.

## Kyverno policies: CEL or legacy

Kyverno 1.19 deprecates the `kyverno.io/v1 ClusterPolicy` and `kyverno.io/v2 CleanupPolicy` kinds and plans to remove them in 1.20 ([migration guide](https://kyverno.io/docs/guides/migration-to-cel/)). The chart therefore creates the CEL kinds by default; `kyverno.legacyPolicies: true` creates the legacy ones. Both sets have the same names and make the same objects:

| Policy | CEL (default), `templates/kyverno/` | Legacy, `templates/kyverno-legacy/` |
|---|---|---|
| `ipsec-node-certificate`: a Certificate per node | `GeneratingPolicy` | `ClusterPolicy`, generate rule |
| `ipsec-cert-sync-mount`: the pod gets its node's secret | `MutatingPolicy` | `ClusterPolicy`, mutate rule |
| `ipsec-nncp-per-node`: an NNCP per node | `GeneratingPolicy` | `ClusterPolicy`, generate rule |
| `ipsec-orphaned-node-secrets`: a deleted node's Secret | `NamespacedDeletingPolicy` | `CleanupPolicy` |

Nothing here changes cert-manager or any other Certificate on the cluster: the deleting policy lists the Certificates of this namespace only and deletes only `ipsec-cert-*` Secrets in it. One difference: a legacy generate rule cannot change its node selection in place, so changing `nodeSelector` or `excludeNodeLabels` needs its policies deleted first; a `GeneratingPolicy` accepts the change (measured on Kyverno 1.19.1, `docs/evidence/crc/31-kyverno-cel-trial.txt`).

Switching from one to the other: Argo CD prunes the old kind only when the sync prunes. With `automated: {}` (no `prune`), sync once with prune, or delete the four old policies by name.

## Uninstall

With Helm:

```bash
helm uninstall ipsec-nas -n kcs-ipsec
```

With Argo CD (three steps, measured):

```bash
# 1. Detach: delete the Application and keep its objects
oc patch application -n openshift-gitops ipsec-nas --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'   # only if it has finalizers
oc delete application -n openshift-gitops ipsec-nas

# 2. Run the cleanup while the cert-sync pods are still there
charts/ipsec-nas/examples/run-cleanup.sh kcs-ipsec

# 3. Delete the chart's objects (the same values as the Application)
helm template ipsec-nas charts/ipsec-nas -n kcs-ipsec --set prerequisites.skipCheck=true -f my-values.yaml \
  --set trustCA.existingConfigMap=ipsec-trust-ca | oc delete --ignore-not-found -f -
```

Afterwards, ask the CA team to revoke the node certificates. The hook cannot do that.

What the cleanup does, in order, and why the order matters:

1. Deletes the NNCP policy, so Kyverno stops re-creating NNCPs. The list of nodes is read **before** this, because Kyverno deletes its NNCPs together with the policy.
2. Applies an NNCP with `state: absent` for each node, under its own name (`ipsec-nas-remove-<node>`), and waits for it. Deleting an NNCP does not remove a tunnel.
3. Removes the `ipsec.kcs.io/cert-ready` label from the nodes.
4. Removes the certificate and its private key from each node's NSS database, through that node's cert-sync pod.
5. Deletes the `Certificate` objects and then the Secrets. While a `Certificate` exists, cert-manager puts a deleted Secret back.

## Test

```bash
tests/test-chart.sh
```

It lints the chart, compares its output with the plain manifests for two sets of values, and checks that missing values and missing prerequisites are refused.
