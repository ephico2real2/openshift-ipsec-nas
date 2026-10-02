# OpenShift → NAS IPsec (NMState + Kyverno)

Encrypts NFS traffic between OpenShift worker nodes and an external NAS with IPsec
(libreswan, IKEv2, transport mode), configured through the **NMState Operator** and
automated per node with **Kyverno**.

📖 **Full step-by-step procedure:** [`docs/ipsec-nas-guide.md`](docs/ipsec-nas-guide.md)

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
docs/diagrams/ipsec-nas/             the figures shown in the docs (source.html + rendered PNGs)
docs/diagrams/mermaid/               Mermaid text versions of the same figures (not displayed)
docs/diagrams/render.py              re-renders the figures from source.html
manifests/common/                    Part 1: NMState Operator, NMState instance, Kyverno RBAC
manifests/option-a-shared-cert/      Part 2: Butane MachineConfig + NNCP generate policy
manifests/option-b-per-node-certs/   Part 3: namespace, Certificate/mount/NNCP policies, cert-sync DaemonSet
render.sh                            fills in the *.tmpl variables → rendered/
```

Files ending in `.tmpl` contain `${NODE_DOMAIN}`, `${NAS_FQDN}`, `${NAS_IP}` or `${OCP_VERSION}`.

## Quick start

```bash
export NODE_DOMAIN="ocp.example.com" NAS_FQDN="nas01.example.com" NAS_IP="10.10.10.50"
./render.sh
```

Then follow the guide. The cluster-level patches (`routingViaHost`, `ipsecConfig.mode: External`),
the Kyverno Helm install and the cert/CA steps are commands in the guide, not manifests here.
Apply the files in numeric order **only as the guide tells you** — e.g. in Option B,
`24-kyverno-cert-sync-mount.yaml` must be Ready before `25-cert-sync-daemonset.yaml`.

## Requirements (summary)

- OpenShift 4.19 (design target), RHCOS workers, bare metal / vSphere / RHOSP / GCP
- Kyverno ≥ 1.13 (community software, not Red Hat supported)
- Option B: cert-manager Operator with a Ready `ClusterIssuer` (`company-issuer-rnd` in the guide)
- NAS supporting IKEv2 transport mode with PKI auth, chaining to the same enterprise root CA

## Security

Never commit private keys, CSRs, `.p12` bundles or CA files — `.gitignore` blocks the common extensions.
