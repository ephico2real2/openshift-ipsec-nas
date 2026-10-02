# OpenShift → NAS IPsec (NMState + Kyverno)

Encrypts NFS traffic between OpenShift worker nodes and an external NAS with IPsec
(libreswan, IKEv2, transport mode), configured through the **NMState Operator** and
automated per node with **Kyverno**.

📖 **Full step-by-step procedure:** [`docs/ipsec-nas-guide.md`](docs/ipsec-nas-guide.md)

| Guide | What it is for |
|---|---|
| [`docs/ipsec-nas-guide.md`](docs/ipsec-nas-guide.md) | The OpenShift side: cluster preparation, certificates, NNCPs, verification |
| [`docs/test-nas-rhel-guide.md`](docs/test-nas-rhel-guide.md) | A test NAS on RHEL 10 (NFS behind IPsec with certificates), as a host or a container |
| [`docs/lab-lima-guide.md`](docs/lab-lima-guide.md) | Lima on a Mac, and a lab with that test NAS and two stand-in workers |
| [`docs/crc-integration-guide.md`](docs/crc-integration-guide.md) | Connecting OpenShift Local (CRC) on the same Mac to the test NAS: the NAT problem, the tunnel-mode fix, and the cluster steps (not run yet) |
| [`docs/nas-consumer-app-guide.md`](docs/nas-consumer-app-guide.md) | An application that stores data on the NAS: static PV and PVC with a demo app and Route, and dynamic provisioning with the NFS CSI driver |

## How it works

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/ipsec-nas/overview.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="docs/diagrams/ipsec-nas/overview.light.png">
  <img alt="Cluster settings put libreswan, a certificate and one tunnel definition on each worker node. The node and the NAS authenticate each other with certificates over IKEv2, and NFS traffic to the NAS IP travels as ESP in transport mode. Pod-to-pod traffic is not encrypted." src="docs/diagrams/ipsec-nas/overview.light.png">
</picture>

*Cluster settings put libreswan, a certificate and one tunnel definition on each worker. The node and the NAS then authenticate each other with certificates over IKEv2, and NFS traffic to the NAS IP travels as ESP in transport mode. Pod-to-pod traffic is not encrypted. The guide has the same figure with a text version, plus one figure for each certificate option.*

## Choose one certificate option

| | Option A – shared certificate | Option B – per-node certificates (recommended) |
|---|---|---|
| Cert delivery | One `.p12` in a MachineConfig | cert-manager per node + import DaemonSet |
| Red Hat documented | Yes | NMState/IPsec part yes; cert delivery is custom |
| Adding a worker | Manual re-issue + full worker reboot | Automatic, no reboot |
| Renewal | Manual, disruptive | Automatic |
| Revoke one node | No | Yes |

> ⚠️ Never run Option A and Option B on the same cluster — both write the NSS nickname `left_server`.

## Layout

```
docs/ipsec-nas-guide.md              the guide (source of truth)
docs/test-nas-rhel-guide.md          a test NAS on RHEL 10
docs/lab-lima-guide.md               Lima on a Mac and the lab
docs/nas-consumer-app-guide.md       an application that uses the NAS through a PVC
docs/crc-integration-guide.md        OpenShift Local (CRC) to the test NAS
docs/diagrams/ipsec-nas/             the figures shown in the guide (source.html + rendered PNGs)
docs/diagrams/lima-lab/              the lab figure (source.html + rendered PNGs)
docs/diagrams/crc-nat/               the NAT figure (source.html + rendered PNGs)
docs/diagrams/mermaid/               Mermaid text versions of the same figures (not displayed)
docs/diagrams/render.py              re-renders the figures from source.html
manifests/common/                    Part 1: NMState Operator, NMState instance, Kyverno RBAC
manifests/option-a-shared-cert/      Part 2: Butane MachineConfig + NNCP generate policy
manifests/option-b-per-node-certs/   Part 3: namespace, Certificate/mount/NNCP policies, cert-sync DaemonSet,
                                     metrics scripts, ServiceMonitor, alert rules, Grafana dashboard
manifests/demo-app/                  demo application: namespace, NFS PV and PVC, Deployment, Service, Route
render.sh                            fills in the *.tmpl variables → rendered/
lab/lab.sh                           creates and verifies the Lima lab (runs on the Mac)
lab/lima/                            Lima templates: lab VMs, and a NAS VM that CRC can reach
lab/pki/                             throwaway test CA and certificates
lab/rhel/                            NAS, stand-in worker and verification scripts (run in the VMs)
lab/container/                       the test NAS as a container image
tests/                               unit tests: metrics parser, alert rules (promtool)
docs/images/                         screenshots
```

Files ending in `.tmpl` contain `${NODE_DOMAIN}`, `${NAS_FQDN}`, `${NAS_IP}`, `${NAS_EXPORT}`, `${CLUSTER_ISSUER}` or `${OCP_VERSION}`.

## Quick start

```bash
export NODE_DOMAIN="ocp.example.com" NAS_FQDN="nas01.example.com" NAS_IP="10.10.10.50"
export CLUSTER_ISSUER="company-issuer-rnd"   # placeholder: the enterprise CA ClusterIssuer your cluster already has
./render.sh
```

Then follow the guide. The cluster-level patches (`routingViaHost`, `ipsecConfig.mode: External`),
the Kyverno Helm install and the cert/CA steps are commands in the guide, not manifests here.
Apply the files in numeric order **only as the guide tells you** — e.g. in Option B,
`24-kyverno-cert-sync-mount.yaml` must be Ready before `26-cert-sync-daemonset.yaml`.

## Requirements (summary)

- OpenShift 4.19 (design target), RHCOS workers, bare metal / vSphere / RHOSP / GCP
- Kyverno ≥ 1.13 (community software, not Red Hat supported)
- Option B: cert-manager Operator and the cluster's **existing** enterprise CA `ClusterIssuer`, Ready. Nothing here creates an issuer; `company-issuer-rnd` in the guide is a placeholder for its name (`CLUSTER_ISSUER`).
- NAS supporting IKEv2 transport mode with PKI auth, chaining to the same enterprise root CA

## Security

Never commit private keys, CSRs, `.p12` bundles or CA files — `.gitignore` blocks the common extensions.
