# IPsec from OpenShift Nodes to the NAS — Documentation

These docs encrypt NFS traffic between OpenShift nodes and an external NAS with IPsec (libreswan, IKEv2, certificate authentication), configured through the **NMState Operator** and automated per node with **Kyverno** and **cert-manager**. Every procedure here was run end to end on OpenShift Local (CRC) against a NAS that refuses NFS unless it arrives through IPsec; each measured result links to its saved output.

<!-- markdownlint-disable MD033 -->
<img alt="Cluster settings put libreswan, a certificate and one tunnel definition on each worker node. The node and the NAS authenticate each other with certificates over IKEv2, and NFS traffic to the NAS IP travels as ESP in transport mode. Pod-to-pod traffic is not encrypted." src="diagrams/ipsec-nas/overview.light.png">
<!-- markdownlint-enable MD033 -->

*Figure 1. Cluster settings put libreswan, a certificate and one tunnel definition on each worker. The node and the NAS authenticate each other with certificates over IKEv2, and NFS traffic to the NAS IP travels as ESP in transport mode. Pod-to-pod traffic is not encrypted. The figure as text is in [00-prepare-the-cluster.md](00-prepare-the-cluster.md#overview--how-ipsec-to-the-nas-works).*

## Option B is our enterprise north star

There are two ways to get a certificate onto every node. **Option B, one certificate per node, is our standard and the enterprise north star**: it is what we deploy on every cluster. Option A, one shared certificate, is the procedure Red Hat documents; it is kept for reference and for the measurements that made us choose B.

| Setup option | How a node gets its certificate | A new node | Renewal | Revoke one node | Status | Doc |
|---|---|---|---|---|---|---|
| **B – per-node certificates** | cert-manager issues one per node from the enterprise CA; a DaemonSet imports it | Automatic, no reboot | Automatic (cert-manager); the tunnel restarts by itself | Yes | **Our standard** | [20-option-b-per-node-certificates.md](20-option-b-per-node-certificates.md) |
| **B, automated** | The same objects as one Helm release, installed with Helm or from Git by Argo CD | Automatic, no reboot | Automatic | Yes | **How we deploy it** | [30-option-b-automated-helm-argocd.md](30-option-b-automated-helm-argocd.md) |
| C – wildcard certificate | One `.p12` for `*.<domain>`, in a MachineConfig, valid 2 years | Automatic: it gets the MachineConfig and the NNCP (by design) | By hand every 2 years; every node reboots once | No: one key everywhere | Evaluated, measured; the NAS must allow shared identities | [50-option-c-wildcard-certificate.md](50-option-c-wildcard-certificate.md) |
| A – shared certificate | One `.p12` for every node, in a MachineConfig | New certificate by hand; every node reboots | By hand, on a deadline; every node reboots | No: one key everywhere | Documented, not used | [10-option-a-shared-certificate.md](10-option-a-shared-certificate.md) |

Measured on CRC: Option B went from the first policy to an established tunnel in 47 seconds with no reboot, and from Git through Argo CD in 12 seconds to `Synced` and `Healthy`. Option A needed six hand steps on a workstation and a reboot to install, and another reboot to remove. [10-option-a-shared-certificate.md](10-option-a-shared-certificate.md#f8--what-option-a-costs-and-why-it-is-not-our-standard) lists its costs for many nodes and many clusters.

Side by side:

| | **Option B: per-node certificates (our standard)** | **Option A: shared certificate (not used)** |
|---|---|---|
| How certs get to nodes | cert-manager issues one cert per node; a DaemonSet imports it | One `.p12` baked into a MachineConfig |
| Red Hat documented? | NMState/IPsec part is documented; **cert delivery is our own design** | **Yes**, this is the documented procedure |
| Adding a worker node | **Automatic**: no manual steps, no reboots | **Manual**: re-issue cert, re-roll MachineConfig → **every worker reboots** |
| Certificate renewal | **Automatic** (cert-manager), short tunnel restart per node | **Manual**: same as above, on a deadline |
| Revoke a single node | Yes | **Not possible**: one key everywhere |
| Several workers against one NAS | Works with the NAS defaults (measured in the lab) | The NAS keeps only one tunnel unless duplicate IDs are allowed (measured in the lab) |
| Monitoring | Per-node metrics, alerts ([60](60-monitoring-per-node.md)) and a dashboard in the console ([61](61-perses-dashboard-review.md)) | None |
| Extra components | Kyverno, cert-manager, one privileged DaemonSet | None |

> [!CAUTION]
> Never run two options on the same cluster: all of them import a certificate into each node's NSS database under the nickname `left_server`.

## The docs, in reading order

| Doc | What it covers |
|---|---|
| [00-prepare-the-cluster.md](00-prepare-the-cluster.md) | **Every option starts here.** How it works, requirements and variables, cluster preparation (`routingViaHost`, IPsec `External` mode, NMState, Kyverno and its permissions), the NAS side for the storage team, verification and troubleshooting |
| [20-option-b-per-node-certificates.md](20-option-b-per-node-certificates.md) | **Option B, step by step:** which nodes get a tunnel, the three Kyverno policies, the cert-sync DaemonSet, metrics and alerts, node removal, teardown; then the run on CRC with captures |
| [30-option-b-automated-helm-argocd.md](30-option-b-automated-helm-argocd.md) | **Option B from Git:** the Helm chart's prerequisites, install with Helm and with Argo CD in sync waves, removal both ways, Kyverno's CEL policies or the legacy ones |
| [60-monitoring-per-node.md](60-monitoring-per-node.md) | **Monitoring:** what every node reports, the alerts, how each node's data stays its own on a multi-node cluster, and what was measured |
| [61-perses-dashboard-review.md](61-perses-dashboard-review.md) | **The dashboard in the console (Perses):** what it shows, how it works, how to turn it on and open it, who can see it, how to change it, troubleshooting |
| [10-option-a-shared-certificate.md](10-option-a-shared-certificate.md) | Option A: the documented procedure, its risks, its run on CRC, and what it costs |
| [50-option-c-wildcard-certificate.md](50-option-c-wildcard-certificate.md) | Option C: one wildcard certificate in a MachineConfig, two variants (C1 with Red Hat components only, C2 with per-node identities), what the NAS team must configure, the renewal tool, and its measured run on CRC |
| [70-review-enterprise-linux-ipsec-config.md](70-review-enterprise-linux-ipsec-config.md) | **Review:** our enterprise IPsec configuration for regular Linux hosts, setting by setting against the NNCP, and which option (A, B or C) matches it |
| [71-option-b-nas-team-engagement.md](71-option-b-nas-team-engagement.md) | **Summary for the NAS team:** where we stand, what we bring and ask, the certificate profile for Venafi, what is left for us to specify |
| [72-option-b-implementation-plan.md](72-option-b-implementation-plan.md) | **Implementation plan for Option B:** why there is no turnkey solution on OpenShift, the case for each component, end-to-end automation with workflow diagrams, the engineering PoC and its acceptance criteria |
| [73-runbook-node-certificate-revocation.md](73-runbook-node-certificate-revocation.md) | **Runbook:** revoking a removed node's certificate; cert-manager does not revoke on deletion; the plan first, finding orphaned certificates, revoking by thumbprint |
| [40-lab-crc-and-nas.md](40-lab-crc-and-nas.md) | **The lab:** OpenShift Local and a NAS VM on one Mac, how it differs from production, how it was built, testing with an application, and the gotchas met on the way |

Which to read:

| You are | Read |
|---|---|
| New to this setup | 00, then 20 (to learn each object), then 30 |
| Deploying it on a cluster | 00 (Parts 0, 1 and 3), then 30 |
| On the storage team | 00, Part 3.1: the NAS certificate and IPsec settings |
| Weighing the shared certificate | 10, especially its cost table; 50 for the wildcard variant |
| Comparing with our Linux hosts' IPsec standard | 70 |
| Preparing the NAS-team meeting, or the enterprise PoC | 71, then 72 |
| On the storage team, for Option C | 50, "For the NAS team" |
| Watching the tunnels, or on call | 61 (the dashboard: Observe → Dashboards (Perses)), then 60 (every metric and alert) |
| Trying it on a laptop | 40, with the supporting guides below |

Supporting guides, in [`lab/`](lab/):

| Guide | What it is for |
|---|---|
| [lab/test-nas-rhel.md](lab/test-nas-rhel.md) | A test NAS on RHEL 10: NFSv4 that accepts only IPsec, certificate login, as a host or a container |
| [lab/lima-lab.md](lab/lima-lab.md) | Lima on a Mac, and a lab with that NAS and two stand-in workers: the cases that need two nodes |
| [lab/nas-consumer-app.md](lab/nas-consumer-app.md) | An application that stores data on the NAS: a static PV and PVC with a demo app and Route |
| [lab/nas-csi-dynamic-provisioning.md](lab/nas-csi-dynamic-provisioning.md) | Storage on demand from the NAS: csi-driver-nfs, the StorageClass `ipsec-nas-csi`, a claim per application, all over IPsec |

## Prerequisites, in short

| Prerequisite | Needed by | Installed by these docs? |
|---|---|---|
| OpenShift 4.19 or later on bare metal, vSphere, RHOSP or GCP, RHCOS nodes | All | No |
| cert-manager, and the cluster's **existing** enterprise CA `ClusterIssuer` | B (A uses the same CA by hand) | No. Nothing here creates an issuer; `company-issuer-rnd` is a placeholder for its name |
| Kyverno 1.19 or later, not filtering out Nodes (1.13 or later with the legacy policies) | A and B | Yes, with its two settings for OpenShift (00, Step 1.6) |
| NMState Operator with an `NMState` instance | A and B | Yes (00, Step 1.5) |
| libreswan on the nodes, from `ipsecConfig.mode: External` | A and B | Yes (00, Step 1.4) |
| A NAS with IKEv2, transport mode and certificate authentication, chaining to the same root CA | A and B | No: the storage team (00, Part 3.1) |

Kyverno 1.19 deprecates the `ClusterPolicy` and `CleanupPolicy` kinds and plans to remove them in 1.20. Option B's policies use the CEL kinds that replace them; the previous ones are kept in [`manifests/option-b-per-node-certs/kyverno-legacy/`](../manifests/option-b-per-node-certs/kyverno-legacy/) and behind the chart value `kyverno.legacyPolicies`. [30-option-b-automated-helm-argocd.md](30-option-b-automated-helm-argocd.md#kyverno-policies-cel-or-legacy) has the switch, measured on a running cluster.

## Examples

| Example | What it is |
|---|---|
| [`charts/ipsec-nas/examples/argocd-application.yaml`](../charts/ipsec-nas/examples/argocd-application.yaml) | An Argo CD Application for the chart, with the values to change |
| [`charts/ipsec-nas/examples/run-cleanup.sh`](../charts/ipsec-nas/examples/run-cleanup.sh) | Runs the chart's cleanup as a one-off Job: removes the tunnels and keys before the objects are deleted (Argo CD removal, or objects applied without Helm) |
| [`charts/ipsec-nas/values-crc.yaml`](../charts/ipsec-nas/values-crc.yaml) | The chart's values for the CRC lab: tunnel mode, `%defaultroute`, the NAS IP |
| [`manifests/demo-app/`](../manifests/demo-app/) | A demo application that writes to the NAS through a PV and PVC, with a Route to its page |
| [`render.sh`](../render.sh) | Fills your values into the `*.tmpl` manifests, into `rendered/` |
| [`lab/lab.sh`](../lab/lab.sh) | Builds and checks the Lima lab on a Mac |
| [`lab/crc/ipsec-sysext.sh`](../lab/crc/ipsec-sysext.sh) | CRC only: libreswan on the node as a system extension |
| [`lab/pki/make-test-pki.sh`](../lab/pki/make-test-pki.sh) | A throwaway test CA and certificates, for the lab only |

## Evidence and tests

- [`evidence/crc/`](evidence/crc/): the saved output of every measured step, as text. The captures in [`images/crc/`](images/crc/) are rendered from these files by [`images/render-terminal.py`](images/render-terminal.py).
- [`../tests/`](../tests/): the chart equals the manifests for both Kyverno policy sets (`test-chart.sh`), the metrics collector (`test-metrics-collector.sh`), the alert rules with `promtool` (`test-alert-rules.sh`), the dashboard script writing all its files or none (`test-perses-dashboard-script.sh`), that what a test or the CI downloads is named by digest or commit (`test-pinned-downloads.sh`), and every link in these docs (`test-doc-links.sh`). CI runs them all on every pull request (`.github/workflows/ci.yml`).
