# OpenShift → NAS IPsec (NMState + Kyverno)

Encrypts NFS traffic between OpenShift worker nodes and an external NAS with IPsec
(libreswan, IKEv2, transport mode), configured through the **NMState Operator** and
automated per node with **Kyverno**.

📖 **Start here:** [`docs/README.md`](docs/README.md): the setup options, which doc to read, the prerequisites and the examples. **Option B, one certificate per node, is our enterprise north star.**

| Doc | What it is for |
|---|---|
| [`docs/00-prepare-the-cluster.md`](docs/00-prepare-the-cluster.md) | Every option starts here: cluster preparation, Kyverno, the NAS side, verification, troubleshooting |
| [`docs/20-option-b-per-node-certificates.md`](docs/20-option-b-per-node-certificates.md) | **Option B, our standard:** one certificate per node, step by step, and its run on CRC |
| [`docs/30-option-b-automated-helm-argocd.md`](docs/30-option-b-automated-helm-argocd.md) | Option B as a Helm chart, installed with Helm or from Git with Argo CD; Kyverno's CEL or legacy policies |
| [`docs/10-option-a-shared-certificate.md`](docs/10-option-a-shared-certificate.md) | Option A, the shared certificate Red Hat documents: documented, measured and costed, not used |
| [`docs/40-lab-crc-and-nas.md`](docs/40-lab-crc-and-nas.md) | The lab: OpenShift Local (CRC) and a NAS VM on one Mac, testing with an application, gotchas |
| [`docs/lab/`](docs/lab/) | A test NAS on RHEL 10, the Lima lab, and an application that uses the NAS |
| [`charts/ipsec-nas/README.md`](charts/ipsec-nas/README.md) | The Helm chart: every value, the prerequisites it checks, cleanup on node deletion and uninstall |

## How it works

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/ipsec-nas/overview.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="docs/diagrams/ipsec-nas/overview.light.png">
  <img alt="Cluster settings put libreswan, a certificate and one tunnel definition on each worker node. The node and the NAS authenticate each other with certificates over IKEv2, and NFS traffic to the NAS IP travels as ESP in transport mode. Pod-to-pod traffic is not encrypted." src="docs/diagrams/ipsec-nas/overview.light.png">
</picture>

*Cluster settings put libreswan, a certificate and one tunnel definition on each worker. The node and the NAS then authenticate each other with certificates over IKEv2, and NFS traffic to the NAS IP travels as ESP in transport mode. Pod-to-pod traffic is not encrypted. The docs have the same figure with a text version, plus one figure for each certificate option.*

## Certificate delivery: one certificate per node

Our standard for a production cluster, and the enterprise north star, is **one certificate per node** (Option B): cert-manager issues it from the cluster's enterprise CA and a DaemonSet imports it. The shared-certificate method Red Hat documents (Option A) is kept for reference and is not used.

| | Per-node certificates (Option B, our standard) | Shared certificate (Option A, not used) |
|---|---|---|
| Cert delivery | cert-manager per node + import DaemonSet | One `.p12` in a MachineConfig |
| Red Hat documented | NMState/IPsec part yes; cert delivery is custom | Yes |
| Adding a worker | Automatic, no reboot | Manual re-issue + full worker reboot |
| Renewal | Automatic | Manual, disruptive |
| Revoke one node | Yes | No |
| Monitoring | Per-node metrics, alerts, Grafana dashboard | None |

> ⚠️ Never run both on the same cluster — both write the NSS nickname `left_server`.

## Layout

```
docs/README.md                       start page: the options, reading order, prerequisites, examples
docs/00-prepare-the-cluster.md       cluster preparation, Kyverno, the NAS side, verification, troubleshooting
docs/10-option-a-shared-certificate.md  Option A (documented, not used), measured on CRC
docs/20-option-b-per-node-certificates.md  Option B, our standard, measured on CRC
docs/30-option-b-automated-helm-argocd.md  Option B with Helm and Argo CD; CEL or legacy Kyverno policies
docs/40-lab-crc-and-nas.md           the CRC lab, testing with an application, gotchas
docs/lab/                            a test NAS on RHEL 10, the Lima lab, an application that uses the NAS
docs/diagrams/                       the figures (source.html + rendered PNGs) and their Mermaid text versions
docs/evidence/crc/                   saved command output behind the captures
docs/images/crc/                     those captures as images (render-terminal.py makes them)
manifests/common/                    NMState Operator, NMState instance, Kyverno RBAC
manifests/option-a-shared-cert/      Option A: Butane MachineConfig + NNCP generate policy
manifests/option-b-per-node-certs/   Option B: namespace, Kyverno CEL policies, cert-sync DaemonSet, metrics,
                                     ServiceMonitor, alert rules, Grafana dashboard, orphaned-Secret cleanup
manifests/option-b-per-node-certs/kyverno-legacy/  the same Kyverno policies as legacy ClusterPolicy/CleanupPolicy
manifests/demo-app/                  demo application: namespace, NFS PV and PVC, Deployment, Service, Route
render.sh                            fills in the *.tmpl variables → rendered/
charts/ipsec-nas/                    Helm chart of Option B (the same objects as the manifests)
lab/                                 the Lima lab, CRC's libreswan extension, test PKI, NAS scripts, NAS container
tests/                               chart equals manifests, metrics parser, alert rules, doc links
```

Files ending in `.tmpl` contain `${NODE_DOMAIN}`, `${NAS_FQDN}`, `${NAS_IP}`, `${NAS_EXPORT}`, `${CLUSTER_ISSUER}` or `${OCP_VERSION}`.

## Quick start

```bash
export NODE_DOMAIN="ocp.example.com" NAS_FQDN="nas01.example.com" NAS_IP="10.10.10.50"
export CLUSTER_ISSUER="company-issuer-rnd"   # placeholder: the enterprise CA ClusterIssuer your cluster already has
./render.sh
```

Then follow [`docs/00-prepare-the-cluster.md`](docs/00-prepare-the-cluster.md). The cluster-level patches
(`routingViaHost`, `ipsecConfig.mode: External`), the Kyverno Helm install and the cert/CA steps are commands
in the docs, not manifests here. Apply the files **only in the order the docs give**: for example
`24-kyverno-cert-sync-mount.yaml` must be Ready before `26-cert-sync-daemonset.yaml`.

## Requirements (summary)

- OpenShift 4.19 (design target), RHCOS workers, bare metal / vSphere / RHOSP / GCP
- Kyverno 1.19 or later for the CEL policies (1.13 or later with the legacy ones; community software, not Red Hat supported)
- cert-manager Operator and the cluster's **existing** enterprise CA `ClusterIssuer`, Ready. Nothing here creates an issuer; `company-issuer-rnd` in the docs is a placeholder for its name (`CLUSTER_ISSUER`).
- NAS supporting IKEv2 transport mode with PKI auth, chaining to the same enterprise root CA

## Security

Never commit private keys, CSRs, `.p12` bundles or CA files — `.gitignore` blocks the common extensions.
