# ipsec-nas Helm chart

Installs **per-node IPsec tunnels from OpenShift nodes to an external NAS**: Part 2 of [`docs/ipsec-nas-guide.md`](../../docs/ipsec-nas-guide.md), our standard setup, as one Helm release. Read that guide first; this page only covers what is different when you use the chart.

The chart creates exactly the objects of `manifests/option-b-per-node-certs/` and `manifests/common/03-kyverno-rbac.yaml`. `tests/test-chart.sh` renders both and compares every object, so the chart cannot drift from the manifests that were measured on a cluster.

## Prerequisites

These must **already be on the cluster**. They are prerequisites, not dependencies: the chart uses them, checks for them, and never installs or upgrades them. If one is missing, `helm install` stops with a message that names it.

| Prerequisite | Why | Main guide | Checked by the chart |
|---|---|---|---|
| **cert-manager**, with a `ClusterIssuer` for the enterprise CA | Issues one certificate per node. The chart never creates an issuer | Step B.1 | The API `cert-manager.io/v1` is served; the `ClusterIssuer` named in `clusterIssuer` exists |
| **Kyverno** 1.13 or later, which does **not** filter out Nodes | Creates the Certificate and the NNCP for each node, and gives each pod its node's secret | Steps 1.6 and 1.6.3 | The API `kyverno.io/v1` is served; `[Node,*,*]` is not in Kyverno's `resourceFilters` |
| **NMState Operator** with an `NMState` instance | Builds the tunnel on the node from the NNCP | Step 1.5 | The API `nmstate.io/v1` is served |
| **libreswan on the nodes** | The tunnel itself | Steps 1.3 and 1.4 (`routingViaHost`, `ipsecConfig.mode: External`) | Not checked |
| **The namespace**, with the privileged pod-security labels | The cert-sync pod runs privileged | Step B.2 | Not checked: create it before installing |
| **The NAS side** | Its own certificate from the same CA, and its IPsec settings | Section 3.1 | Not checked |
| User workload monitoring | Only for `metrics.serviceMonitor` and `metrics.prometheusRule` | Step B.12 | Not checked |

## Install

```bash
# 1. The namespace (main guide, Step B.2)
oc apply -f manifests/option-b-per-node-certs/20-namespace.yaml

# 2. Your values. Only these five are required.
cat <<'EOF' > my-values.yaml
nodeDomain: ocp.example.com          # worker-0 gets a certificate for worker-0.ocp.example.com
nas:
  fqdn: nas01.example.com
  ip: 10.0.0.50
clusterIssuer: company-issuer-rnd    # the EXISTING enterprise CA issuer: oc get clusterissuer
EOF

# 3. Install. enterprise-root.pem is the enterprise ROOT CA certificate (main guide, Step B.3).
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
> Helm creates the DaemonSet a moment before the Kyverno policies. The first cert-sync pod on each node is therefore created without its node's secret. It notices, logs `This pod mounts the placeholder secret`, and deletes itself after 60 seconds; the pod that replaces it gets the secret. Measured on CRC: the tunnel was up **101 seconds** after `helm install`.

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
| `kyvernoRBAC.create` | `true` | The two ClusterRoles of the main guide's Step 1.7 |
| `scc.bind` | `true` | Binds the `privileged` SCC to the cert-sync service account |
| `metrics.serviceMonitor` / `prometheusRule` / `grafanaDashboard` | `true` / `true` / `false` | Observe, the six alerts, the dashboard ConfigMap |
| `prerequisites.skipCheck` | `false` | Only for `helm template` without a cluster |
| `prerequisites.kyvernoNamespace` | `kyverno` | Where to look for Kyverno's configuration |

`values-crc.yaml` holds the values used on OpenShift Local in [`docs/crc-integration-guide.md`](../../docs/crc-integration-guide.md). Tunnel mode, `%defaultroute` and an IP as `right` are for that lab only.

## Uninstall

`helm uninstall` removes the objects the release created. It does **not** remove what those objects did on the nodes. Follow this order (measured on CRC):

```bash
# 1. The tunnel: remove the NNCP policy first, then tell NMState to take the tunnel away
oc delete clusterpolicy ipsec-nncp-per-node
for n in $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); do
cat <<EOF | oc apply -f -
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ipsec-nas-${n}
spec:
  nodeSelector:
    kubernetes.io/hostname: ${n}
  desiredState:
    interfaces:
    - name: ipsec-nas
      type: ipsec
      state: absent
EOF
done
oc get nnce | grep ipsec-nas            # wait for Available
oc get nncp -o name | grep ipsec-nas | xargs oc delete

# 2. The release
helm uninstall ipsec-nas -n kcs-ipsec

# 3. What stays behind: each node's Certificate and secret, its label, and the certificate with its key on the node.
#    The Certificates first: while one exists, cert-manager puts its secret back.
oc delete certificate -n kcs-ipsec -l generate.kyverno.io/policy-name=ipsec-node-certificate
oc delete secret -n kcs-ipsec -l controller.cert-manager.io/fao=true
for n in $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); do
  oc label node "${n}" ipsec.kcs.io/cert-ready-
  oc debug "node/${n}" -q -- chroot /host bash -c '
    certutil -F -n left_server -d /var/lib/ipsec/nss
    certutil -D -n KCS-IPSEC-CA -d /var/lib/ipsec/nss
    rm -rf /etc/pki/certs/kcs-ipsec'
done
```

`helm uninstall` deletes `ipsec-nncp-per-node` anyway; deleting it first in step 1 is what lets the `absent` NNCP take effect without Kyverno putting the old one back. Then ask the CA team to revoke the node certificates.

## Test

```bash
tests/test-chart.sh
```

It lints the chart, compares its output with the plain manifests for two sets of values, and checks that missing values and missing prerequisites are refused.
