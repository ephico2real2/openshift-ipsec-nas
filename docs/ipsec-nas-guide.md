# IPsec from OpenShift Worker Nodes to the NAS — Guide

**Team:** KCS OpenShift  **Audience:** junior/new platform engineers  **Tested design target:** OpenShift 4.19, RHCOS workers

This guide encrypts NFS traffic between every **worker node** and the **external NAS** using IPsec (libreswan, transport mode), configured through the **NMState Operator** and automated with **Kyverno**.

**Our standard is one certificate per node**, issued by the cluster's enterprise CA and delivered automatically (Part 2). It is what we use for a full cluster in a production or enterprise environment. File names and step numbers call it **Option B**.

The other way, one shared certificate for all workers (**Option A**), is the procedure Red Hat documents. It is kept in [Appendix A](#appendix-a--shared-certificate-documented-not-our-standard) for reference and is **not** what we deploy: every change to it is manual and reboots every worker.

| | **Per-node certificates (our standard, Part 2)** | **Shared certificate (Appendix A, not used)** |
|---|---|---|
| How certs get to nodes | cert-manager issues one cert per node; a DaemonSet imports it | One `.p12` baked into a MachineConfig |
| Red Hat documented? | NMState/IPsec part is documented; **cert delivery is our own design** | **Yes**, this is the documented procedure |
| Adding a worker node | **Automatic**: no manual steps, no reboots | **Manual**: re-issue cert, re-roll MachineConfig → **every worker reboots** |
| Certificate renewal | **Automatic** (cert-manager), short tunnel restart per node | **Manual**: same as above, on a deadline |
| Revoke a single node | Yes | **Not possible**: one key everywhere |
| Several workers against one NAS | Works with the NAS defaults (measured in the lab) | The NAS keeps only one tunnel unless duplicate IDs are allowed (measured in the lab) |
| Monitoring | Per-node metrics, alerts and a dashboard (Step B.12) | None |
| Extra components | Kyverno, cert-manager, one privileged DaemonSet | None |

> [!CAUTION]
> **Never run both on the same cluster.** Both import a certificate into each node's NSS database under the nickname `left_server`, and they will overwrite each other.

---

## Table of contents

- [Overview – how IPsec to the NAS works](#overview--how-ipsec-to-the-nas-works)
- [Part 0 – Before you start](#part-0--before-you-start)
- [Part 1 – Cluster preparation](#part-1--cluster-preparation)
- [Part 2 – Per-node certificates with cert-manager + Kyverno (our standard)](#part-2--per-node-certificates-with-cert-manager--kyverno-our-standard)
- [Part 3 – NAS side, verification, troubleshooting, teardown](#part-3--nas-side-verification-troubleshooting-teardown)
- [Appendix A – Shared certificate (documented, not our standard)](#appendix-a--shared-certificate-documented-not-our-standard)
- [Diagram sources](#diagram-sources)

---

## Overview – how IPsec to the NAS works

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/ipsec-nas/overview.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="diagrams/ipsec-nas/overview.light.png">
  <img alt="Cluster settings put libreswan, a certificate and one tunnel definition on each worker node. The node and the NAS authenticate each other with certificates over IKEv2, and NFS traffic to the NAS IP travels as ESP in transport mode. Pod-to-pod traffic is not encrypted." src="diagrams/ipsec-nas/overview.light.png">
</picture>

*Figure 1. Cluster settings put libreswan, a certificate and one tunnel definition on each worker. The node and the NAS then authenticate each other with certificates over IKEv2, and NFS traffic to the NAS IP travels as ESP in transport mode. The figure is drawn from this guide and its manifests; it has not been measured on a running cluster.*

```text
CLUSTER (what you apply)             WORKER NODE (RHCOS host)                      NAS (storage team)

Cluster network settings        -->  1. Node is prepared
  ipsecConfig.mode: External           libreswan added by MachineConfig (reboot)
  routingViaHost: true                 pod egress uses the host routing table
                                            |
Node certificate delivery       -->  2. Certificate in the node's NSS DB
  cert-manager: one cert per node      /var/lib/ipsec/nss
  cert-sync DaemonSet imports it       left_server (node) + enterprise root CA
                                            |
Kyverno: one NNCP per worker    -->  3. libreswan connection ipsec-nas            Prepared by storage team
  ipsec-nas-<node>                     left = node FQDN, right = NAS FQDN           key and CSR made on the NAS
  NMState applies it on the node       IKEv2 only, transport mode, cert auth        IPsec policy: worker subnet
                                            |                                            |
                                     4. IKEv2 negotiation          <-- IKEv2 -->  NAS IPsec endpoint
                                       node proves identity with    UDP 500/4500    NAS certificate (right)
                                       left_server, checks the      certificates    same enterprise root CA
                                       NAS cert against the CA      both ways            |
                                            |                                            |
Workload with an NFS volume     -->  5. NFS to NAS_IP is encrypted <--  ESP  -->  NFS data IP ${NAS_IP}
  PVC backed by the NAS                matches rightsubnet NAS_IP/32  IP proto 50   cleartext NFS is rejected
                                       sent as ESP, transport mode

Not encrypted: pod-to-pod traffic inside the cluster (External mode covers external hosts only).
Firewalls must allow UDP 500, UDP 4500 and ESP (IP protocol 50) between every worker and the NAS.
```

---

## Part 0 – Before you start

### 0.1 Words you will see

| Term | Meaning |
|---|---|
| **NNCP** | `NodeNetworkConfigurationPolicy`: tells the NMState Operator how to configure networking on a node. Here it creates the IPsec tunnel. |
| **NNCE** | `NodeNetworkConfigurationEnactment`: the per-node result of an NNCP. This is where you look for errors. |
| **NSS database** | The certificate store libreswan uses on each node: `/var/lib/ipsec/nss`. |
| **`left` / `right`** | libreswan terms. `left` = the OpenShift node, `right` = the NAS. |
| **Kyverno** | Policy engine. We use it to **generate** one object per node (NNCP, Certificate) and to **mutate** pods. |
| **cert-manager** | Issues and renews certificates from a `ClusterIssuer`. We use the one the cluster **already has** for the enterprise CA. This guide never creates an issuer; `company-issuer-rnd` is a placeholder for that issuer's name. |
| **MCO / MachineConfig** | Machine Config Operator. Changing a MachineConfig **reboots nodes one at a time**. |

### 0.2 Requirements checklist

- [ ] You are `cluster-admin` (`oc whoami` and `oc auth can-i '*' '*' --all-namespaces` returns `yes`).
- [ ] Platform is **bare metal, vSphere, RHOSP or Google Cloud**. External IPsec is not supported on other platforms, on **RHEL compute nodes**, or with **hosted control planes**.
- [ ] Every worker FQDN `<node-name>.<NODE_DOMAIN>` **resolves in DNS** to that node's IP. libreswan and the certificates use this name.
- [ ] Firewalls allow **UDP 500**, **UDP 4500** and **ESP (IP protocol 50)** between all workers and the NAS.
- [ ] The NAS supports **IKEv2, transport mode and certificate (PKI) authentication**, and trusts our enterprise root CA.
- [ ] The **storage team** has a ticket to create the **NAS (`right`) certificate** and IPsec policy (see [3.1](#31-nas-configuration-storage-team-not-us)). We do not create the NAS certificate.
- [ ] Tools on your workstation: `oc`, `openssl`, `helm` (Part 1). Appendix A also needs `butane`.
- [ ] A **change window** has been approved: Part 1 reboots every node at least once.
- [ ] The cert-manager Operator is installed and the cluster's **existing enterprise CA `ClusterIssuer`** is `Ready`. You know its name (`oc get clusterissuer`). This guide does not create one.

### 0.3 Open a shell and set variables

Every command below uses these variables. **Set them in every new terminal.**

```bash
# Stop bash from treating "!" specially, so the heredocs below paste cleanly
set +H

# ---- CHANGE THESE ----
export NODE_DOMAIN="ocp.example.com"   # worker FQDN = <node-name>.${NODE_DOMAIN}
export NAS_FQDN="nas01.example.com"    # NAS hostname (must match the NAS certificate)
export NAS_IP="10.10.10.50"            # NAS NFS data IP
# The ClusterIssuer your cluster ALREADY has for the enterprise CA (find it: oc get clusterissuer).
# "company-issuer-rnd" is only a placeholder. This guide does not create an issuer.
export CLUSTER_ISSUER="company-issuer-rnd"
# ----------------------

# Butane version = your cluster's x.y with .0 on the end (e.g. 4.19.0). Only Appendix A uses it.
export OCP_VERSION="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1,2).0"

# Working folder for files we create
mkdir -p ~/ipsec-nas && cd ~/ipsec-nas
echo "Domain=${NODE_DOMAIN} NAS=${NAS_FQDN}/${NAS_IP} Issuer=${CLUSTER_ISSUER} Butane=${OCP_VERSION}"
```

> [!TIP]
> **About `cat <<EOF` vs `cat <<'EOF'`:** with `<<EOF`, bash **replaces** `${VARIABLES}` inside the block. With `<<'EOF'` (quoted), the text is written **exactly as typed**. Each step uses the right one, so copy the blocks exactly.

---

## Part 1 – Cluster preparation

### Step 1.1 – Confirm platform and node OS

```bash
oc get clusterversion
oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}{"\n"}'
oc get nodes -o wide        # OS-IMAGE column must say "Red Hat Enterprise Linux CoreOS"
```

✅ **Expected:** a supported platform (`BareMetal`, `VSphere`, `OpenStack`, `GCP`), and all nodes on RHCOS.

### Step 1.2 – Check the cluster MTU

Red Hat lists **"cluster MTU reduced by 46 bytes"** (room for the IPsec ESP header) as a prerequisite for enabling IPsec.

```bash
oc get network.config cluster -o jsonpath='{.status.clusterNetworkMTU}{"\n"}'
```

If the MTU has **not** already been lowered, follow the Red Hat procedure **"Changing the MTU for the cluster network"** in a change window, with a senior engineer. It reboots nodes. Confirm with Red Hat whether this is required for **External-only** mode in our environment before scheduling it.

### Step 1.3 – Enable `routingViaHost`

External IPsec requires OVN-Kubernetes to route egress traffic through the **host's** routing table.

```bash
oc patch networks.operator.openshift.io cluster --type=merge -p \
'{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'
```

Verify:

```bash
oc get networks.operator.openshift.io cluster \
  -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}{"\n"}'
oc get pods -n openshift-ovn-kubernetes -w     # wait until ovnkube-node pods are all Running again, then Ctrl+C
```

✅ **Expected:** `true`.

> [!WARNING]
> `routingViaHost` changes how **all** pod egress leaves the node. If you use egress IPs, egress routers or custom host routes, review the impact before production.

### Step 1.4 – Enable IPsec in **External** mode

`External` = encrypt traffic to external hosts only. Pod-to-pod traffic is **not** encrypted.

```bash
oc patch networks.operator.openshift.io cluster --type=merge -p \
'{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"ipsecConfig":{"mode":"External"}}}}}'
```

This makes the Cluster Network Operator add the libreswan extension to every node (`80-ipsec-*-extensions` MachineConfigs), which **reboots each node once**.

Watch the rollout:

```bash
oc get mc | grep ipsec           # expect 80-ipsec-master-extensions and 80-ipsec-worker-extensions
watch oc get mcp                 # wait until UPDATED=True, UPDATING=False, DEGRADED=False for ALL pools
```

✅ **Expected:** both pools updated, and `mode` shows `External`:

```bash
oc get networks.operator.openshift.io cluster \
  -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.ipsecConfig.mode}{"\n"}'
```

### Step 1.5 – Install the NMState Operator

```bash
cat <<'EOF' > 01-nmstate-operator.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nmstate
  labels:
    name: openshift-nmstate
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nmstate
  namespace: openshift-nmstate
spec:
  targetNamespaces:
  - openshift-nmstate
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubernetes-nmstate-operator
  namespace: openshift-nmstate
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kubernetes-nmstate-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

oc apply -f 01-nmstate-operator.yaml
```

Wait for the operator:

```bash
watch oc get csv -n openshift-nmstate      # wait for PHASE=Succeeded, then Ctrl+C
```

Create the `NMState` instance, which starts the per-node handlers:

```bash
cat <<'EOF' > 02-nmstate-instance.yaml
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
EOF

oc apply -f 02-nmstate-instance.yaml
oc get pods -n openshift-nmstate           # nmstate-handler pod on every node, all Running
```

### Step 1.6 – Install Kyverno

Kyverno is installed with Helm. There are two ways to run the install (1.6.4 **or** 1.6.5), and both need the OpenShift SCC setting in 1.6.3.

> [!IMPORTANT]
> Kyverno is a **community project, not Red Hat-supported**. Use the chart version approved by our change process (`--version`), and the internal mirror if the cluster is disconnected. This guide needs **Kyverno 1.13 or later**.

#### 1.6.1 Pick the chart version

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm search repo kyverno/kyverno --versions | head     # CHART VERSION, and APP VERSION = the Kyverno version

# ---- CHANGE THIS to the approved chart version (chart 3.9.1 = Kyverno v1.19.1) ----
export KYVERNO_CHART_VERSION="3.9.1"
```

#### 1.6.2 Export the chart's default values

Save the chart's own `values.yaml` first. It is the basis for every setting we change: find the key in this file, then put **only that key** in our own override file.

```bash
helm show values kyverno/kyverno --version "${KYVERNO_CHART_VERSION}" > kyverno-values-default.yaml
# No access to the Helm repository? Read the values from a downloaded chart instead (see 1.6.5):
#   helm show values "./kyverno-${KYVERNO_CHART_VERSION}.tgz" > kyverno-values-default.yaml

grep -nE 'runAsUser|runAsGroup' kyverno-values-default.yaml     # the fixed IDs that 1.6.3 deals with
```

✅ **Expected:** a file of about 2,600 lines. For chart 3.8.0 or later, `grep` prints eight `runAsUser: 65534` / `runAsGroup: 65534` pairs.

> [!NOTE]
> `kyverno-values-default.yaml` is a **reference, not an input**. Do not edit it and do not pass it to `helm install`. Our changes go in the small `kyverno-openshift-values.yaml` in the next step, so a later chart upgrade still picks up the chart's new defaults. Attach the default file to the change ticket: comparing it with the next version's export shows what changed.

#### 1.6.3 OpenShift SCC setting

From chart **3.8.0** (Kyverno 1.18) every Kyverno container is set to run as user and group `65534`. OpenShift's default `restricted-v2` SCC only accepts a user ID from the namespace's own range, so the pods are never created and the ReplicaSet reports `unable to validate against any security context constraint`. Charts before 3.8.0 hardcode the ID only for the Helm hook Jobs and test pods.

**Option 1 (recommended): remove the fixed IDs.** The override file below sets the keys that the `grep` in 1.6.2 found to `null`. OpenShift then assigns the user ID and the pods run under `restricted-v2`. No extra SCC permission is needed.

```bash
cat <<'EOF' > kyverno-openshift-values.yaml
# Kyverno on OpenShift: do not hardcode a UID/GID.
# null removes the chart default (65534) so OpenShift assigns one from the namespace range.
admissionController:
  initContainer:
    securityContext:
      runAsUser: null
      runAsGroup: null
  container:
    securityContext:
      runAsUser: null
      runAsGroup: null
backgroundController:
  securityContext:
    runAsUser: null
    runAsGroup: null
cleanupController:
  securityContext:
    runAsUser: null
    runAsGroup: null
reportsController:
  securityContext:
    runAsUser: null
    runAsGroup: null
# Helm hook Jobs (upgrade / uninstall) and "helm test" pods
crds:
  migration:
    securityContext:
      runAsUser: null
      runAsGroup: null
webhooksCleanup:
  securityContext:
    runAsUser: null
    runAsGroup: null
test:
  securityContext:
    runAsUser: null
    runAsGroup: null
EOF
```

**Option 2: keep the fixed ID and grant an SCC that allows it.** Give Kyverno's service accounts the `nonroot-v2` SCC **before** installing, then leave the `-f kyverno-openshift-values.yaml` line out of the install command.

```bash
oc create namespace kyverno

for sa in kyverno-admission-controller kyverno-background-controller \
          kyverno-cleanup-controller kyverno-reports-controller kyverno-migrate-resources; do
  oc adm policy add-scc-to-user nonroot-v2 -z "${sa}" -n kyverno
done

oc get rolebinding system:openshift:scc:nonroot-v2 -n kyverno -o jsonpath='{.subjects[*].name}{"\n"}'   # the five names above
```

> [!WARNING]
> **Do not grant `anyuid`.** It does not help: `anyuid` rejects any pod that sets a seccomp profile, and every Kyverno container sets one. It would also allow running as root.

#### 1.6.4 Install method 1 – straight from the Helm repository

```bash
helm install kyverno kyverno/kyverno -n kyverno --create-namespace \
  --version "${KYVERNO_CHART_VERSION}" \
  -f kyverno-openshift-values.yaml \
  --set admissionController.replicas=3 \
  --set backgroundController.replicas=2 \
  --set cleanupController.replicas=2 \
  --set reportsController.replicas=2
```

#### 1.6.5 Install method 2 – download the chart, then install from the file

Use this when the machine that reaches the cluster cannot reach `kyverno.github.io`, or when the change process wants the exact chart file archived.

On a machine with internet access:

```bash
helm pull kyverno/kyverno --version "${KYVERNO_CHART_VERSION}"     # writes kyverno-${KYVERNO_CHART_VERSION}.tgz here
helm show chart "kyverno-${KYVERNO_CHART_VERSION}.tgz"             # check version and appVersion
```

Copy `kyverno-${KYVERNO_CHART_VERSION}.tgz` and `kyverno-openshift-values.yaml` to the machine that is logged in to the cluster, then install from the file:

```bash
helm install kyverno "./kyverno-${KYVERNO_CHART_VERSION}.tgz" -n kyverno --create-namespace \
  -f kyverno-openshift-values.yaml \
  --set admissionController.replicas=3 \
  --set backgroundController.replicas=2 \
  --set cleanupController.replicas=2 \
  --set reportsController.replicas=2
```

> [!NOTE]
> The chart file holds **no container images**. The cluster still pulls them from `reg.kyverno.io` and `ghcr.io`, so on a disconnected cluster mirror them first. List what the chart needs:
>
> ```bash
> helm template kyverno "./kyverno-${KYVERNO_CHART_VERSION}.tgz" -n kyverno | grep -E '^ +image: "?[a-z]' | sort -u
> ```

#### 1.6.6 Verify

```bash
oc get pods -n kyverno -o custom-columns='POD:.metadata.name,SCC:.metadata.annotations.openshift\.io/scc,STATUS:.status.phase'
oc get deploy -n kyverno -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

✅ **Expected:** every pod `Running`; `SCC` is `restricted-v2` (Option 1) or `nonroot-v2` (Option 2); image tags are `v1.13` or later.

### Step 1.7 – Give Kyverno permission to create NNCPs and Certificates

By default Kyverno cannot create these resource types. This ClusterRole is **aggregated** into Kyverno's own roles through the labels.

```bash
cat <<'EOF' > 03-kyverno-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:ipsec-nas-generate
  labels:
    rbac.kyverno.io/aggregate-to-background-controller: "true"
    rbac.kyverno.io/aggregate-to-admission-controller: "true"
rules:
# NMState policies
- apiGroups: ["nmstate.io"]
  resources: ["nodenetworkconfigurationpolicies"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# cert-manager Certificates
- apiGroups: ["cert-manager.io"]
  resources: ["certificates"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF

oc apply -f 03-kyverno-rbac.yaml
```

### ✅ Part 1 checklist

- [ ] MTU checked (and lowered if required)
- [ ] `routingViaHost: true`
- [ ] `ipsecConfig.mode: External`, all MCPs `UPDATED=True`
- [ ] NMState Operator `Succeeded`, `NMState` instance created
- [ ] Kyverno running (≥ 1.13), RBAC applied

**Now go to Part 2.**

---

## Part 2 – Per-node certificates with cert-manager + Kyverno (our standard)

### 2.0 How it works

This is our standard for every cluster. It is also called **Option B** in file names and step numbers.

Each worker gets **its own** certificate, issued automatically by the cluster's existing enterprise CA `ClusterIssuer` (`${CLUSTER_ISSUER}`; `company-issuer-rnd` is the placeholder name). No MachineConfig is used, so **nothing reboots** when nodes are added or certificates renew.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/ipsec-nas/option-b-per-node-certs.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="diagrams/ipsec-nas/option-b-per-node-certs.light.png">
  <img alt="Option B: when a worker joins, Kyverno requests a certificate for it, cert-manager issues it into a Secret, the cert-sync pod on that node imports it into the node's NSS database and labels the node, and only then Kyverno generates the NNCP that brings the tunnel up. No manual step and no reboot." src="diagrams/ipsec-nas/option-b-per-node-certs.light.png">
</picture>

*Figure 2. Our standard (Option B): when a worker joins, Kyverno requests a certificate for it, cert-manager issues it into a Secret, the cert-sync pod on that node imports it and labels the node, and only then Kyverno generates the NNCP that brings the tunnel up. No manual step and no reboot. This certificate delivery is the guide's own design, not a Red Hat procedure.*

```text
KYVERNO + CERT-MANAGER                   cert-sync POD (kcs-ipsec)                WORKER NODE

1. Policy 1: Certificate per worker  <------------ Node created ------------  A worker joins the cluster
   ipsec-<node>                                                                (no manual step from here on)
   signed by the enterprise CA issuer
        |
2. cert-manager writes the Secret    -->  3. cert-sync pod starts on the node
   ipsec-cert-<node>                         Policy 2 pointed it at ONLY this Secret
   this node's certificate and key          mounted at /certs, root CA at /ca
                                                  |
                                          4. Pod imports the certificate       -->  NSS DB on the node
                                             into the NSS DB as left_server          /var/lib/ipsec/nss
                                             then re-checks every 5 minutes          left_server + KCS-IPSEC-CA
                                                  |
6. Policy 3: NNCP for this node      <--  5. Pod labels the node
   ipsec-nas-<node>                          ipsec.kcs.io/cert-ready=true
   only when the label is present            only after a successful import
        |
        +------------------- NMState applies the NNCP -------------------->  7. Tunnel to the NAS is up
                                                                                libreswan connection ipsec-nas

Renewal is automatic: cert-manager renews 30 days before expiry; the pod re-imports and restarts the tunnel
for a few seconds. No node reboot.
If the Secret is missing, the pod waits in ContainerCreating; it never imports another node's certificate.
```

What each piece does:

| Piece | Job |
|---|---|
| **Policy 1** `ipsec-node-certificate` | For every worker, create a cert-manager `Certificate` named `ipsec-<node>`. |
| **cert-manager** | Signs it with the enterprise CA `ClusterIssuer` (`${CLUSTER_ISSUER}`), stores it in Secret `ipsec-cert-<node>`, renews it automatically. |
| **Policy 2** `ipsec-cert-sync-mount` | When the DaemonSet starts a pod on a node, mount **only that node's** Secret into it. |
| **DaemonSet** `ipsec-cert-sync` | Imports the cert into the node's NSS DB, labels the node `ipsec.kcs.io/cert-ready=true`, re-imports on renewal. |
| **Policy 3** `ipsec-nncp-per-node` | Only after the label appears, create the NNCP for that node. This prevents NNCPs failing because the cert isn't there yet. |
| **Metrics** (in the same DaemonSet) | Each pod reports whether its node's tunnel is up, how much traffic it carries and when the node's certificate expires. OpenShift's monitoring scrapes it, and alerts fire when a tunnel is down (Step B.12). |

> [!IMPORTANT]
> ### Risks and responsibilities
>
> 1. **Support:** the NMState/IPsec configuration is the Red Hat documented one, but the **certificate delivery (DaemonSet + Kyverno) is our own design**. Get Red Hat's support stance on it (open a case or ask our Red Hat contact) **before production**. Kyverno itself is community software.
> 2. **The DaemonSet is privileged** (it writes to the host's NSS database). Only the platform team may have access to namespace `kcs-ipsec`. Include it in the security review.
> 3. **Private keys are stored as Secrets** in `kcs-ipsec`. Restrict `get secrets` there to the platform team, and make sure etcd encryption is enabled.
> 4. **Renewal causes a short tunnel restart** on each node (seconds). Configure the NAS to **reject non-IPsec NFS** from the worker subnet, so a restart causes an NFS retry, never cleartext traffic.
> 5. **If Kyverno is down**, new nodes don't get IPsec until it is back. Existing tunnels keep working. The policies use `failurePolicy: Ignore`, so Kyverno can never block the cluster.
> 6. **DNS:** every node FQDN must resolve, as in Part 0.
> 7. **The NAS must authorize peers by CA + worker subnet, not by individual host.** Otherwise every scale-up still needs a NAS change.

### Step B.1 – Check cert-manager and the ClusterIssuer

```bash
oc get pods -n cert-manager
oc get clusterissuer                          # every issuer on this cluster; pick the enterprise CA one
oc get clusterissuer "${CLUSTER_ISSUER}"
```

✅ **Expected:** cert-manager pods `Running`, and `READY=True` on `${CLUSTER_ISSUER}`.

> [!IMPORTANT]
> **This guide does not create a certificate issuer.** An enterprise cluster already has a `ClusterIssuer` that signs with the enterprise CA. The per-node certificates must come from that issuer, so that they chain to the same root the NAS trusts. `company-issuer-rnd` is only a **placeholder** for its name.
>
> If the last command answers `NotFound`, `CLUSTER_ISSUER` is still the placeholder: set it to the real name in [0.3](#03-open-a-shell-and-set-variables) and run the check again. If your cluster has no enterprise CA issuer at all, stop and ask the team that owns the enterprise CA; do not create a self-signed one for this.

### Step B.2 – Create the namespace

```bash
cat <<'EOF' > 20-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kcs-ipsec
  labels:
    # The cert-sync DaemonSet must run privileged
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
    security.openshift.io/scc.podSecurityLabelSync: "false"
EOF

oc apply -f 20-namespace.yaml
```

### Step B.3 – Store the enterprise **root** CA

The nodes need the root CA to trust the NAS certificate. Put **only the root** certificate (PEM) in `enterprise-root.pem`.

```bash
openssl x509 -in enterprise-root.pem -noout -subject -issuer   # subject == issuer for a root

oc create configmap ipsec-trust-ca -n kcs-ipsec --from-file=ca.pem=enterprise-root.pem
```

### Step B.4 – Policy 1: one Certificate per worker

```bash
cat <<EOF > 21-kyverno-node-certificate.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ipsec-node-certificate
spec:
  failurePolicy: Ignore
  rules:
  - name: certificate-per-worker
    match:
      any:
      - resources:
          kinds:
          - Node
          selector:
            matchLabels:
              node-role.kubernetes.io/worker: ""
    generate:
      generateExisting: true
      synchronize: true          # Certificate is deleted when the Node is deleted
      apiVersion: cert-manager.io/v1
      kind: Certificate
      name: "ipsec-{{ request.object.metadata.name }}"
      namespace: kcs-ipsec
      data:
        spec:
          secretName: "ipsec-cert-{{ request.object.metadata.name }}"
          commonName: "{{ request.object.metadata.name }}.${NODE_DOMAIN}"   # max 64 chars, must not start with ovs_
          dnsNames:
          - "{{ request.object.metadata.name }}.${NODE_DOMAIN}"           # must equal the NNCP "left" value
          duration: 8760h          # 1 year (the CA may override this)
          renewBefore: 720h        # renew 30 days before expiry
          privateKey:
            algorithm: RSA         # NNCP uses leftrsasigkey: '%cert'
            size: 3072
            rotationPolicy: Always # new key on every renewal
          usages:
          - digital signature
          - key encipherment
          - server auth
          - client auth
          issuerRef:
            group: cert-manager.io
            kind: ClusterIssuer
            name: ${CLUSTER_ISSUER}       # the existing enterprise CA issuer, set in Part 0.3
EOF

oc apply -f 21-kyverno-node-certificate.yaml
oc get clusterpolicy ipsec-node-certificate      # READY must be True
```

Verify (give it a minute):

```bash
oc get certificate -n kcs-ipsec
```

✅ **Expected:** one `ipsec-<node>` per worker, all `READY=True`. If one is not ready, see [Troubleshooting](#33-troubleshooting).

### Step B.5 – The cert-sync script

This script runs in the DaemonSet pod on every worker. Read the comments to see what it does.

```bash
cat <<'EOF' > 22-cert-sync-script.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ipsec-cert-sync-script
  namespace: kcs-ipsec
data:
  sync.sh: |
    #!/bin/bash
    # ipsec-cert-sync: runs on every worker node.
    # 1) Imports THIS node's certificate (mounted at /certs by Kyverno) into the
    #    host's IPsec NSS database under the nickname "left_server".
    # 2) Labels the node ipsec.kcs.io/cert-ready=true so Kyverno creates the NNCP.
    # 3) Every 5 minutes, checks for a renewed cert and re-imports it.
    set -uo pipefail

    NSS_DB=/var/lib/ipsec/nss
    CERT_NICK=left_server
    CA_NICK=KCS-IPSEC-CA
    CONN_NAME=ipsec-nas
    READY_LABEL=ipsec.kcs.io/cert-ready
    HOST_STAGE=/etc/pki/certs/kcs-ipsec     # path as the HOST sees it
    STAGE=/host${HOST_STAGE}                # same path as this container sees it
    STAMP=${STAGE}/.installed-sha256
    CHECK_EVERY=300

    log() { echo "$(date -u +%FT%TZ) [${NODE_NAME}] $*"; }

    import_cert() {
      mkdir -p "${STAGE}" &&
      install -m 0400 /certs/tls.crt "${STAGE}/tls.crt" &&
      install -m 0400 /certs/tls.key "${STAGE}/tls.key" &&
      install -m 0444 /ca/ca.pem     "${STAGE}/ca.pem" &&
      chroot /host /bin/bash -euo pipefail -c "
        cd ${HOST_STAGE}
        # never leave the private key or p12 on the host disk
        trap 'rm -f tls.key left_server.p12' EXIT
        openssl pkcs12 -export -in tls.crt -inkey tls.key -name ${CERT_NICK} \
          -out left_server.p12 -passout pass:
        # remove the previous cert + key (ignore errors on first run)
        certutil -F -n ${CERT_NICK} -d ${NSS_DB} >/dev/null 2>&1 || true
        certutil -D -n ${CERT_NICK} -d ${NSS_DB} >/dev/null 2>&1 || true
        certutil -A -n ${CA_NICK} -t 'CT,C,C' -d ${NSS_DB} -i ca.pem
        pk12util -W '' -i left_server.p12 -d ${NSS_DB}
        certutil -M -n ${CERT_NICK} -t 'u,u,u' -d ${NSS_DB}
      "
    }

    log "Starting"
    while true; do
      if [[ -s /certs/tls.crt && -s /certs/tls.key && -s /ca/ca.pem ]]; then
        want=$(cat /certs/tls.crt /ca/ca.pem | sha256sum | cut -d' ' -f1)
        have=$(cat "${STAMP}" 2>/dev/null || echo none)
        # If the cert is missing from NSS (e.g. DB rebuilt), force a re-import
        chroot /host certutil -L -n "${CERT_NICK}" -d "${NSS_DB}" >/dev/null 2>&1 || have=missing

        if [[ "${want}" != "${have}" ]]; then
          log "New or renewed certificate detected - importing into NSS"
          if import_cert; then
            echo "${want}" > "${STAMP}"
            log "Import OK"
            # On renewal, restart the tunnel so libreswan loads the new cert
            if chroot /host nmcli -t -f NAME connection show --active | grep -qx "${CONN_NAME}"; then
              log "Restarting ${CONN_NAME} to load the new certificate"
              chroot /host nmcli connection up "${CONN_NAME}" || log "WARNING: restart of ${CONN_NAME} failed"
            fi
          else
            log "ERROR: import failed - retrying in 60s"
            sleep 60
            continue
          fi
        fi

        current=$(oc get node "${NODE_NAME}" -o jsonpath="{.metadata.labels.ipsec\.kcs\.io/cert-ready}" 2>/dev/null)
        if [[ "${current}" != "true" ]]; then
          oc label node "${NODE_NAME}" "${READY_LABEL}=true" --overwrite \
            && log "Node labelled ${READY_LABEL}=true"
        fi
      else
        log "Waiting for certificate files in /certs (is Certificate ipsec-${NODE_NAME} Ready?)"
      fi
      sleep "${CHECK_EVERY}"
    done
EOF

oc apply -f 22-cert-sync-script.yaml
```

### Step B.6 – ServiceAccount, permissions and SCC for the DaemonSet

The pod only needs to **read and label its node**. It gets **no** permission to read Secrets. Its own certificate is mounted by the kubelet (Step B.7).

```bash
cat <<'EOF' > 23-cert-sync-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ipsec-cert-sync
  namespace: kcs-ipsec
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ipsec-cert-sync-label-node
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ipsec-cert-sync-label-node
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ipsec-cert-sync-label-node
subjects:
- kind: ServiceAccount
  name: ipsec-cert-sync
  namespace: kcs-ipsec
EOF

oc apply -f 23-cert-sync-rbac.yaml
oc adm policy add-scc-to-user privileged -z ipsec-cert-sync -n kcs-ipsec
```

### Step B.7 – Policy 2: mount each node's own certificate into its pod

A DaemonSet has **one** pod template, but each node needs a **different** Secret. When the DaemonSet creates a pod for a node, this policy rewrites the pod's `node-cert` volume to point at **that node's** Secret.

> **How does Kyverno know the node?** The DaemonSet controller pins every pod to its node with `nodeAffinity` → `matchFields: metadata.name`. The policy reads the node name from there.

> [!IMPORTANT]
> Apply this policy **before** the DaemonSet (Step B.8). Otherwise pods start without the mutation and sit in `ContainerCreating` (that is the safe failure: delete the pods and they are recreated correctly).

```bash
cat <<'EOF' > 24-kyverno-cert-sync-mount.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ipsec-cert-sync-mount
  annotations:
    # Only mutate Pods, do not auto-generate rules for DaemonSets/Deployments
    pod-policies.kyverno.io/autogen-controllers: none
spec:
  failurePolicy: Ignore
  background: false
  rules:
  - name: mount-this-nodes-certificate
    match:
      any:
      - resources:
          kinds:
          - Pod
          namespaces:
          - kcs-ipsec
          operations:
          - CREATE
          selector:
            matchLabels:
              app: ipsec-cert-sync
    preconditions:
      all:
      - key: "{{ request.object.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchFields[0].values[0] || '' }}"
        operator: NotEquals
        value: ""
    mutate:
      patchStrategicMerge:
        spec:
          volumes:
          - name: node-cert
            secret:
              secretName: "ipsec-cert-{{ request.object.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchFields[0].values[0] }}"
EOF

oc apply -f 24-kyverno-cert-sync-mount.yaml
oc get clusterpolicy ipsec-cert-sync-mount       # READY must be True
```

### Step B.8 – Deploy the DaemonSet

Each pod has three containers:

| Container | Privileged? | Job |
|---|---|---|
| `sync` | Yes | Imports the node's certificate into the host's NSS database and labels the node (Step B.5). |
| `collector` | Yes, host mounted **read-only** | Every 30 seconds reads the tunnel and certificate state from the host and writes it as Prometheus metrics into a shared volume. |
| `metrics` | **No** | Serves that file on port 9754 (`/metrics`). It is the pod's only network listener and has no access to the host. |

The template's `node-cert` volume points at a placeholder Secret (`ipsec-cert-unassigned`) that **does not exist**. If the Kyverno mutation ever fails, the pod waits safely instead of importing the wrong certificate.

> [!NOTE]
> `sync` and `collector` use the OpenShift CLI image shipped with every cluster (`openshift/cli` image stream). If the internal image registry is disabled, replace it with our mirrored `ose-cli` image. `metrics` uses the Red Hat UBI Python image `registry.access.redhat.com/ubi9/python-312`; mirror it too on a disconnected cluster.

First the two scripts the `collector` and `metrics` containers run. They are long, and unit-tested in the repository, so apply the file from the repository instead of typing them:

```bash
oc apply -f manifests/option-b-per-node-certs/25-metrics-scripts.yaml     # run from the repository root
oc get configmap ipsec-metrics-scripts -n kcs-ipsec
```

Then the DaemonSet:

```bash
cat <<'EOF' > 26-cert-sync-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ipsec-cert-sync
  namespace: kcs-ipsec
spec:
  selector:
    matchLabels:
      app: ipsec-cert-sync
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: ipsec-cert-sync
    spec:
      serviceAccountName: ipsec-cert-sync
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      # Add tolerations here if some workers are tainted (e.g. infra nodes that mount the NAS)
      containers:
      - name: sync
        image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
        command: ["/bin/bash", "/scripts/sync.sh"]
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        securityContext:
          privileged: true
          runAsUser: 0
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            memory: 128Mi
        volumeMounts:
        - name: host
          mountPath: /host
        - name: node-cert
          mountPath: /certs
          readOnly: true
        - name: trust-ca
          mountPath: /ca
          readOnly: true
        - name: script
          mountPath: /scripts
          readOnly: true
      # Reads the tunnel and certificate state from the host every 30 seconds and writes it as
      # Prometheus metrics into the shared "metrics" volume. The host is mounted read-only.
      - name: collector
        image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
        command: ["/bin/bash", "/metrics-scripts/collect.sh"]
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        securityContext:
          privileged: true
          runAsUser: 0
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            memory: 64Mi
        volumeMounts:
        - name: host
          mountPath: /host
          readOnly: true
        - name: metrics
          mountPath: /metrics
        - name: metrics-scripts
          mountPath: /metrics-scripts
          readOnly: true
      # Serves the collector's file on :9754/metrics. Unprivileged: the only network listener in
      # this pod has no access to the host.
      - name: metrics
        image: registry.access.redhat.com/ubi9/python-312:latest
        command: ["python3", "/metrics-scripts/serve.py"]
        ports:
        - name: metrics
          containerPort: 9754
        readinessProbe:
          httpGet:
            path: /healthz
            port: metrics
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /healthz
            port: metrics
          periodSeconds: 30
        securityContext:
          privileged: false
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
          seccompProfile:
            type: RuntimeDefault
        resources:
          requests:
            cpu: 5m
            memory: 32Mi
          limits:
            memory: 64Mi
        volumeMounts:
        - name: metrics
          mountPath: /metrics
          readOnly: true
        - name: metrics-scripts
          mountPath: /metrics-scripts
          readOnly: true
      volumes:
      - name: host
        hostPath:
          path: /
          type: Directory
      - name: node-cert
        secret:
          secretName: ipsec-cert-unassigned   # replaced per node by Kyverno policy ipsec-cert-sync-mount
          optional: false
      - name: trust-ca
        configMap:
          name: ipsec-trust-ca
      - name: script
        configMap:
          name: ipsec-cert-sync-script
          defaultMode: 0555
      - name: metrics
        emptyDir: {}
      - name: metrics-scripts
        configMap:
          name: ipsec-metrics-scripts
          defaultMode: 0555
EOF

oc apply -f 26-cert-sync-daemonset.yaml
```

Verify:

```bash
# 1. One Running pod per worker, 3/3 containers ready
oc get pods -n kcs-ipsec -o wide

# 2. Each pod mounts ITS OWN node's secret
oc get pods -n kcs-ipsec -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,SECRET:.spec.volumes[?(@.name=="node-cert")].secret.secretName'

# 3. Logs show "Import OK" and "Node labelled"
oc logs -n kcs-ipsec -l app=ipsec-cert-sync -c sync --prefix --tail=20

# 4. Every worker has the label
oc get nodes -l node-role.kubernetes.io/worker -L ipsec.kcs.io/cert-ready

# 5. The cert is in one node's NSS database
NODE=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')
oc debug node/${NODE} -- chroot /host certutil -L -d /var/lib/ipsec/nss

# 6. The pod serves metrics (the tunnel itself comes in the next step, so tunnel_up is still 0)
oc exec -n kcs-ipsec ds/ipsec-cert-sync -c metrics -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:9754/metrics').read().decode())" | grep -E '^ipsec_nas_(collect_success|tunnel_up)'
```

✅ **Expected:** in check 2, `SECRET` equals `ipsec-cert-<that NODE>` on every row. In check 5, you see `left_server u,u,u` and `KCS-IPSEC-CA CT,C,C`. In check 6, `ipsec_nas_collect_success{...} 1` and `ipsec_nas_tunnel_up{...} 0`.

### Step B.9 – Policy 3: NNCP per node, only when its cert is ready

> [!IMPORTANT]
> **Stop here until the NAS side is ready.** This step creates the NNCPs, so the storage team must have finished [3.1](#31-nas-configuration-storage-team-not-us) first.

```bash
cat <<EOF > 27-kyverno-nncp-per-node.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ipsec-nncp-per-node
spec:
  failurePolicy: Ignore
  rules:
  - name: nncp-when-cert-ready
    match:
      any:
      - resources:
          kinds:
          - Node
          selector:
            matchLabels:
              node-role.kubernetes.io/worker: ""
              ipsec.kcs.io/cert-ready: "true"     # set by ipsec-cert-sync after import
    generate:
      generateExisting: true
      synchronize: true
      apiVersion: nmstate.io/v1
      kind: NodeNetworkConfigurationPolicy
      name: "ipsec-nas-{{ request.object.metadata.name }}"
      data:
        spec:
          nodeSelector:
            kubernetes.io/hostname: '{{ request.object.metadata.labels."kubernetes.io/hostname" }}'
          desiredState:
            interfaces:
            - name: ipsec-nas
              type: ipsec
              libreswan:
                left: "{{ request.object.metadata.name }}.${NODE_DOMAIN}"   # matches the Certificate dnsNames
                leftid: '%fromcert'
                leftrsasigkey: '%cert'
                leftcert: left_server
                leftmodecfgclient: false
                right: ${NAS_FQDN}
                rightid: '%fromcert'
                rightrsasigkey: '%cert'
                rightsubnet: ${NAS_IP}/32
                ikev2: insist
                type: transport
                # Uncomment ONLY if the NAS requires specific proposals:
                # esp: aes_gcm256
                # ike: aes256-sha2;dh20
EOF

oc apply -f 27-kyverno-nncp-per-node.yaml
oc get clusterpolicy ipsec-nncp-per-node         # READY must be True
```

Then go to [3.2](#32-verify-end-to-end) to verify.

### Step B.10 – Scale-up test (prove it is automatic)

Do this once in a non-production cluster, then after go-live.

```bash
# Scale a worker MachineSet up by one
oc get machinesets -n openshift-machine-api
oc scale machineset <machineset-name> -n openshift-machine-api --replicas=<current+1>
```

Then watch the chain happen with **no manual steps**:

```bash
watch 'oc get nodes -l node-role.kubernetes.io/worker -L ipsec.kcs.io/cert-ready; echo; \
       oc get certificate -n kcs-ipsec; echo; \
       oc get pods -n kcs-ipsec -o wide; echo; \
       oc get nncp | grep ipsec-nas'
```

✅ **Expected order for the new node:** Node `Ready` → Certificate `Ready` → cert-sync pod `Running` → label `true` → NNCP created → NNCE `Available`.

### Step B.11 – Scale-down / node removal

When a node is deleted, Kyverno deletes its `Certificate` and NNCP automatically. Two things stay behind:

```bash
# 1. Delete the leftover Secret (cert-manager does not delete it by default)
oc delete secret ipsec-cert-<deleted-node-name> -n kcs-ipsec

# 2. List leftovers at any time
for s in $(oc get secrets -n kcs-ipsec -o name | grep 'ipsec-cert-' | cut -d/ -f2); do
  n=${s#ipsec-cert-}; oc get node "$n" >/dev/null 2>&1 || echo "orphaned: $s"
done
```

Then **revoke** that node's certificate at the CA, following our CA process. This is possible because each node has its own certificate.

### Step B.12 – Metrics in Observe, alerts and a dashboard

The `collector` and `metrics` containers from Step B.8 already produce the numbers. This step makes OpenShift collect them, adds alerts, and ships a Grafana dashboard.

What every node reports:

| Metric | Meaning |
|---|---|
| `ipsec_nas_tunnel_up` | `1` if the node has an established tunnel to the NAS, `0` if not |
| `ipsec_nas_tunnel_out_bytes_total`, `ipsec_nas_tunnel_in_bytes_total` | Traffic through the tunnel. NFS shows up here. |
| `ipsec_nas_tunnel_established_timestamp_seconds` | When the current tunnel came up |
| `ipsec_nas_tunnel_info` | The identity the NAS presented (label `peer_id`) |
| `ipsec_nas_certificate_not_after_timestamp_seconds` | When the certificate in the node's NSS database expires |
| `ipsec_nas_certificate_import_timestamp_seconds` | When cert-sync last imported a certificate |
| `ipsec_nas_collect_success`, `ipsec_nas_collect_timestamp_seconds` | Whether libreswan answered, and when the collector last ran |
| `ipsec_nas_libreswan_info` | The libreswan version (label `version`) |

Every metric carries a `node` label with the node's name.

**1. Check that user workload monitoring is on.** It is what scrapes metrics outside the `openshift-*` namespaces.

```bash
oc get pods -n openshift-user-workload-monitoring
```

✅ **Expected:** `prometheus-user-workload-0` is `Running`. If the namespace is empty, user workload monitoring is off: enable it first (Red Hat: *Enabling monitoring for user-defined projects*).

**2. Apply the Service and ServiceMonitor, the alert rules and the dashboard**, from the repository root:

```bash
oc apply -f manifests/option-b-per-node-certs/28-metrics-servicemonitor.yaml
oc apply -f manifests/option-b-per-node-certs/29-prometheus-rule.yaml
oc apply -f manifests/option-b-per-node-certs/30-grafana-dashboard.yaml

oc get servicemonitor,prometheusrule -n kcs-ipsec
```

**3. See it in the console.** Open **Observe → Metrics**, run the query `ipsec_nas_tunnel_up`, and you get one row per worker. The alerts are under **Observe → Alerting → Alerting rules** (filter by source *User*).

✅ **Expected:** value `1` for every worker, with labels `node` and `connection="ipsec-nas"`.

The alerts:

| Alert | Fires when | Severity |
|---|---|---|
| `IpsecNasTunnelDown` | A node has had no tunnel for 5 minutes | critical |
| `IpsecNasLibreswanNotAnswering` | libreswan on a node has not answered the collector for 5 minutes | warning |
| `IpsecNasCertificateExpiringSoon` | A node's certificate has less than 14 days left. cert-manager renews at 30 days, so this means a renewal did not reach the node. | warning |
| `IpsecNasCertificateExpired` | A node's certificate has expired | critical |
| `IpsecNasMetricsStale` | A node's metrics are more than 5 minutes old (the collector stopped) | warning |
| `IpsecNasExporterMissing` | A worker reports no metrics at all for 15 minutes | warning |

**4. Grafana (optional).** The dashboard is a ConfigMap, `ipsec-nas-grafana-dashboard`, with the label `grafana_dashboard: "1"`. This guide does not install Grafana. If the platform has a central Grafana run by the Grafana Operator (for example in `ocp-platform-grafana` or `ocp-grafana`), this object tells it to load the dashboard:

```bash
cat <<'EOF' > 31-grafana-dashboard-cr.yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: ipsec-nas
  namespace: kcs-ipsec
spec:
  allowCrossNamespaceImport: true      # the Grafana instance lives in another namespace
  resyncPeriod: 10m
  instanceSelector:
    matchLabels:
      dashboards: grafana              # CHANGE: the labels on the central Grafana instance
  configMapRef:
    name: ipsec-nas-grafana-dashboard
    key: ipsec-nas.json
  datasources:
  - inputName: DS_PROMETHEUS
    datasourceName: openshift-thanos   # CHANGE: that Grafana's Prometheus (Thanos) datasource
EOF

oc apply -f 31-grafana-dashboard-cr.yaml
```

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/grafana-ipsec-nas.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="images/grafana-ipsec-nas.light.png">
  <img alt="The IPsec to the NAS dashboard in Grafana: 2 tunnels up, 0 down, 2 workers reporting, 29.9 days until the soonest certificate expiry, both nodes UP, a traffic graph and per-node tunnel age, metrics age and libreswan version." src="images/grafana-ipsec-nas.light.png">
</picture>

*The dashboard in the Lima lab on 2026-10-02, fed by two stand-in workers: 2 tunnels up, 0 down, 29.9 days to the soonest certificate expiry (the lab's test certificates last 30 days, hence yellow), and the traffic of a 5 MiB test write on each node.*

> [!NOTE]
> **What was tested, and where.** The collector and the metrics container were run on the lab workers against live tunnels, including taking a tunnel down and stopping libreswan. The alert rules pass `promtool` unit tests (`tests/test-alert-rules.sh`) and loaded in a real Prometheus. The dashboard was loaded in a real Grafana 13.2.3 and all of its queries returned data. **Not tested yet:** the ServiceMonitor and PrometheusRule on an OpenShift cluster, and the `GrafanaDashboard` object against a central Grafana; no such Grafana exists on our cluster today.

### ✅ Part 2 checklist

- [ ] All `Certificate`s `Ready`
- [ ] One cert-sync pod per worker, each mounting its own Secret
- [ ] All workers labelled `ipsec.kcs.io/cert-ready=true`
- [ ] One NNCP per worker, all NNCEs `Available`
- [ ] Scale-up test passed
- [ ] `ipsec_nas_tunnel_up` is `1` for every worker in **Observe → Metrics**
- [ ] Red Hat support stance recorded in the change ticket

---

## Part 3 – NAS side, verification, troubleshooting, teardown

### 3.1 NAS configuration (storage team, not us)

> [!TIP]
> **No NAS to test against yet?** [`test-nas-rhel-guide.md`](test-nas-rhel-guide.md) builds a test NAS on RHEL 10, and [`lab-lima-guide.md`](lab-lima-guide.md) runs it in a lab on a Mac.

The NAS needs its **own** certificate (the `right` side), and the **storage team** creates it. The key and CSR are generated on the NAS and the enterprise CA signs it. We never generate, hold or transfer the NAS private key. The only thing we install from that side is the **enterprise root CA**, so the nodes can trust the NAS.

> [!IMPORTANT]
> **Timing:** raise the storage ticket at the start (it is on the [Part 0 checklist](#02-requirements-checklist)). Everything in [What they send back](#3-what-they-send-back) must be confirmed **before Step B.9** (Appendix A: Step A.10), because that step creates the NNCPs.

#### The two certificates

| | Node certificate (`left`) | NAS certificate (`right`) |
|---|---|---|
| Installed on | Every worker, NSS nickname `left_server` | The NAS |
| Key + CSR created by | **Us**: cert-manager (Step B.4). Appendix A: by hand (Step A.3) | **Storage team**, on the NAS |
| Signed by | Enterprise CA, through the existing `ClusterIssuer` (`${CLUSTER_ISSUER}`) | The **same** enterprise CA |
| Name in the SAN | Worker FQDN `<node-name>.${NODE_DOMAIN}` | `${NAS_FQDN}` |
| IP address in the certificate | Not needed | Not needed. `${NAS_IP}` is only used in the NNCP `rightsubnet` |
| Private key stays | On our side | On the NAS |
| What the other side installs | The enterprise root CA | The enterprise root CA: `ipsec-trust-ca` (Appendix A: `ca.pem`) |

#### Who does what

| Task | KCS OpenShift (us) | Storage / NAS team |
|---|---|---|
| Node (`left`) certificates | ✅ cert-manager, automatically (Appendix A: our own CSR) | – |
| NAS (`right`) certificate: key + CSR **generated on the NAS** | – | ✅ |
| Submit the NAS CSR to the **enterprise CA** (same CA as ours) | – | ✅ |
| Install the signed cert + chain on the NAS | – | ✅ |
| Configure IPsec policy on the NAS ([settings below](#2-nas-ipsec-settings-to-request)) | Provide requirements | ✅ |
| Provide the enterprise root CA to trust | ✅ (or they get it from the CA team) | Install it on the NAS |
| Renew/revoke the NAS cert before expiry | Get notified | ✅ |

The work goes in four steps.

#### 1. What we send them (copy into their ticket)

- Our **worker subnet(s)** (all node IPs that will connect)
- The enterprise **root CA** the node certificates chain to
- The NAS name and IP we put in the NNCP: `${NAS_FQDN}` / `${NAS_IP}`
- The IPsec settings in the next table

#### 2. NAS IPsec settings to request

| Setting | Value |
|---|---|
| Protocol | IKEv2, **transport** mode |
| Authentication | Certificate (PKI), NAS cert signed by our enterprise CA, SAN = `${NAS_FQDN}` |
| Trusted CA | Enterprise root CA (same as `ipsec-trust-ca`) |
| Peers | **Worker node subnet** (not individual hosts), so scale-up needs no NAS change |
| Proposals | Must match the NNCP. Default libreswan proposals, or the `esp`/`ike` lines you uncommented |
| Duplicate peer IDs | Not needed with per-node certificates. **Appendix A only:** must be allowed (`uniqueids=no` equivalent) |
| Cleartext NFS from workers | **Rejected**, so IPsec is required and never silently bypassed |

#### 3. What they send back

Do not apply any NNCP (Step B.9; Appendix A: Step A.10) until every box is ticked.

- [ ] Confirmation that the NAS cert's **SAN contains `${NAS_FQDN}`**. The NNCP uses `right: ${NAS_FQDN}`, and Red Hat's procedure says that name should match the certificate SAN.
- [ ] The NAS cert's **issuer chain**: it must chain to the root in `ipsec-trust-ca` (Appendix A: `ca.pem`)
- [ ] The NAS cert's **expiry date** (put it in our calendar too)
- [ ] The IKE/ESP proposals the NAS accepts, if not the defaults
- [ ] The NFS data IP(s) that will be protected (one `rightsubnet` / tunnel per IP)
- [ ] The NAS certificate itself (**public part only**, PEM), so we can check it in the next step

#### 4. Check the NAS certificate ourselves

```bash
openssl x509 -in nas.crt -noout -subject -issuer -dates -ext subjectAltName
openssl verify -CAfile enterprise-root.pem -untrusted intermediate.pem nas.crt   # must print: nas.crt: OK
```

✅ **Expected:** the SAN lists `${NAS_FQDN}`, `notAfter` is far enough in the future, and `openssl verify` prints `nas.crt: OK`.

> [!IMPORTANT]
> If the NAS cert is signed by a **different** CA than our node certs, the nodes won't trust it: `ipsec-trust-ca` (Appendix A: `ca.pem`) holds **one** root only. Agree on **one enterprise CA for both sides** before starting.

> [!NOTE]
> We *could* issue the NAS cert from the same `ClusterIssuer` (`${CLUSTER_ISSUER}`) with cert-manager, but the private key would then be created inside our cluster and handed to another team. Only do this if the storage team and security explicitly agree, and the key is transferred securely.

### 3.2 Verify end to end

```bash
# Policies
oc get clusterpolicy

# NNCPs and per-node results
oc get nncp | grep ipsec-nas
oc get nnce | grep ipsec-nas            # STATUS must be Available

# Tunnel state on one node
NODE=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')
oc debug node/${NODE} -- chroot /host ipsec trafficstatus
```

✅ **Expected:** `trafficstatus` lists the `ipsec-nas` connection with `inBytes`/`outBytes`.

Final proof: run a workload on that node that reads/writes the NAS (NFS PVC), run `ipsec trafficstatus` again, and confirm the byte counters **increased**. [`nas-consumer-app-guide.md`](nas-consumer-app-guide.md) has a ready-made demo application for this, with a web page that shows the data on the NAS.

### 3.3 Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| No Kyverno pods; `oc get events -n kyverno` shows `unable to validate against any security context constraint` | Chart sets a fixed user ID that `restricted-v2` rejects | Apply the SCC setting in Step 1.6.3, then `helm upgrade` with the same flags |
| `clusterpolicy` READY = False | Policy syntax or missing RBAC | `oc describe clusterpolicy <name>`; re-check Step 1.7 |
| Alert `IpsecNasTunnelDown` for a node | That node's tunnel is not established | `oc debug node/<node> -- chroot /host ipsec trafficstatus`; then `journalctl -u ipsec` on the node. Check the NNCE for that node. |
| `ipsec_nas_tunnel_up` returns nothing in Observe → Metrics | Metrics are not scraped | `oc get servicemonitor -n kcs-ipsec`; `oc get pods -n openshift-user-workload-monitoring`; the pods must be `3/3` (Step B.8) |
| Alert `IpsecNasMetricsStale` | The `collector` container stopped | `oc logs -n kcs-ipsec <pod> -c collector`; delete the pod to restart it |
| No NNCP / Certificate created | Kyverno generate error | `oc get updaterequests -n kyverno`; `oc logs -n kyverno deploy/kyverno-background-controller` |
| Certificate not `Ready` | Issuer rejected the request | `oc describe certificate ipsec-<node> -n kcs-ipsec`; `oc get certificaterequest -n kcs-ipsec`; check the issuer: `oc get clusterissuer "${CLUSTER_ISSUER}"` |
| cert-sync pod `ContainerCreating`, event says `secret "ipsec-cert-unassigned" not found` | Kyverno mutation did not run | Check policy `ipsec-cert-sync-mount` is Ready, then `oc delete pod <pod> -n kcs-ipsec` |
| cert-sync pod `ContainerCreating`, event says `secret "ipsec-cert-<node>" not found` | Certificate not issued yet | Fix the Certificate first (row above) |
| Logs: `ERROR: import failed` | `openssl`/NSS refused the bundle (e.g. FIPS-mode cluster rejecting an empty password) | Read the full log; on FIPS clusters, change the script to use a non-empty password for `-passout`/`-W` |
| Node never gets `cert-ready` label | RBAC/SCC | `oc logs` of that node's pod; re-run Step B.6 |
| NNCE `Failing` | Cert nickname missing, DNS for `left`/`right` not resolving | `oc get nnce <node>.ipsec-nas-<node> -o yaml` and read `status.conditions`; check `certutil -L` on the node |
| NNCE `Available` but no traffic in `trafficstatus` | NAS proposal/CA mismatch, firewall | `oc debug node/<node> -- chroot /host journalctl -u ipsec --since "30 min ago"`; check UDP 500/4500 + ESP |
| Appendix A: tunnels on other nodes drop when one connects | NAS treats identical IDs as one peer | Allow duplicate IDs on the NAS (3.1) |
| Appendix A: MCP `DEGRADED` | Bad Butane render or file missing | `oc describe mcp worker`; check `ipsec-import.service` on the node: `journalctl -u ipsec-import` |

### 3.4 Teardown (remove IPsec to the NAS)

> [!WARNING]
> Deleting an NNCP does **not** remove the tunnel from the node. You must apply an NNCP with `state: absent`. Also delete the Kyverno policy first, or Kyverno will put the old NNCP back.

```bash
# 1. Stop Kyverno from (re)creating NNCPs
oc delete clusterpolicy ipsec-nncp-per-node ipsec-nncp-shared-cert --ignore-not-found

# 2. Remove the tunnel from every worker
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

# 3. Wait until every NNCE is Available, then delete the "absent" NNCPs
oc get nnce | grep ipsec-nas
oc get nncp -o name | grep ipsec-nas | xargs oc delete
```

Then remove the per-node certificate pieces:

```bash
oc delete clusterpolicy ipsec-node-certificate ipsec-cert-sync-mount
oc delete ds ipsec-cert-sync -n kcs-ipsec
oc delete namespace kcs-ipsec           # removes Certificates and Secrets: revoke certs at the CA
```

Appendix A only (reboots every worker):

```bash
oc delete mc 99-worker-import-certs
watch oc get mcp worker
```

---

## Appendix A – Shared certificate (documented, not our standard)

> [!WARNING]
> **We do not deploy this.** It is kept because it is the procedure Red Hat documents and because it explains why we chose per-node certificates. Use Part 2 for every real cluster.
>
> Measured in the lab ([`lab-lima-guide.md`](lab-lima-guide.md#8-what-the-lab-showed)): with one shared certificate and a NAS on its defaults, the NAS never held two workers' tunnels at the same time. It only worked after the NAS was told to allow duplicate peer IDs.

### A.0 How it works

This is the **Red Hat documented** method. One certificate and private key are copied to **every worker** through a MachineConfig. You create the certificate by hand, so **every worker reboots** each time it changes.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/ipsec-nas/option-a-shared-cert.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="diagrams/ipsec-nas/option-a-shared-cert.light.png">
  <img alt="Option A: you create one certificate that names every worker, a MachineConfig copies it to all workers and reboots them one at a time, then Kyverno generates one NNCP per worker and the tunnel comes up. Adding a worker or renewing the certificate repeats the manual steps and reboots every worker again." src="diagrams/ipsec-nas/option-a-shared-cert.light.png">
</picture>

*Figure 3. Option A (not our standard): you create one certificate that names every worker, a MachineConfig copies it to all workers and reboots them one at a time, then Kyverno generates one NNCP per worker. Adding a worker or renewing the certificate repeats steps 1 to 5 by hand and reboots every worker again.*

```text
YOU (workstation + enterprise CA)        CLUSTER (operators)                  EVERY WORKER NODE

1. Build one certificate request
   SAN lists ALL current workers
   key + CSR            (A.2, A.3)
        |
2. Enterprise CA signs it
   left_server.crt + CA chain  (A.4)
        |
3. Bundle and render            -->  4. MCO rolls it out             -->  5. Every worker reboots, one at a time
   left_server.p12 + ca.pem            99-worker-import-certs               ipsec-import.service fills the NSS DB
   -> MachineConfig  (A.5 - A.9)       files + import script                cert nickname: left_server
        |                                                                        |
6. Apply the Kyverno policy     -->  7. One NNCP per worker          -->  8. Tunnel to the NAS is up
   ipsec-nncp-shared-cert (A.10)       ipsec-nas-<node>                     libreswan connection ipsec-nas
                                       Kyverno generates, NMState applies   IKEv2, transport mode

New worker, or certificate renewal (A.11): repeat 1 to 5 by hand. Every worker reboots again.
One certificate and one private key are shared by every worker; a single node cannot be revoked on its own.
```

What each piece does:

| Piece | Job |
|---|---|
| **You** (workstation) | Build the SAN list of every worker, create the key and CSR, bundle `left_server.p12`. Nothing here is automatic. |
| **Enterprise CA** | Signs the CSR. One certificate for all workers, no automatic renewal. |
| **MachineConfig** `99-worker-import-certs` | Copies `ca.pem`, `left_server.p12` and the import script to every worker. Applying it makes the MCO reboot every worker, one at a time. |
| **`ipsec-import.service`** | Runs on each worker at boot, before libreswan (`ipsec.service`). Imports the certificate into the node's NSS DB as `left_server`. |
| **Policy** `ipsec-nncp-shared-cert` | For every worker, create the NNCP `ipsec-nas-<node>`. Unlike the standard path's policy 3 (Step B.9), it does **not** wait for the certificate, so finish Step A.9 before applying it. |

> [!CAUTION]
> ### Risks of the shared certificate. Read before choosing Option A.
>
> 1. **Scaling up is a manual, disruptive procedure.** Each node's `left` name must be in the certificate's SAN list. A new worker is **not** in the SAN, so its tunnel cannot be set up correctly until you re-issue the certificate with the new name **and** roll a new MachineConfig, which **reboots every worker in the pool** (rolling, one at a time). With the MachineAutoscaler or MachineSet scaling, new nodes arrive **without working IPsec** until someone does this by hand. (Lab note: against the libreswan test NAS, a worker whose name was not in the SAN still got a tunnel, because libreswan with `%fromcert` does not check the SAN. A storage appliance may check more, so treat the re-issue as required.)
> 2. **Renewal is the same disruptive procedure**, and it has a hard deadline (certificate expiry). A missed renewal takes down IPsec for **all** nodes at once.
> 3. **One private key on every node.** If any single node is compromised, the attacker can impersonate **every** node to the NAS.
> 4. **You cannot revoke one node.** Revoking the cert breaks all nodes.
> 5. **The private key is readable in the cluster API.** It is embedded in the MachineConfig, so anyone who can read `machineconfigs` can extract it.
> 6. **Same identity from every node.** The NAS sees N peers with the same certificate identity. Many IPsec stacks (libreswan's default `uniqueids=yes`) treat this as "the same peer reconnected" and **drop the previous node's tunnel**. The NAS must be configured to allow duplicate IDs.
>
> **Correction to a common assumption:** re-issuing does **not** require taking the whole cluster down. The MCO reboots nodes **one at a time**. It is still a full-pool reboot every time you add a node or renew, which is why **per-node certificates (Part 2) are our standard**.
>
> **Partial mitigation:** a **wildcard SAN** (e.g. `DNS:*.ocp.example.com`) avoids re-issuing on scale-up, **if** our CA policy allows wildcards. It does not fix risks 2–6 and widens what the certificate is trusted for.

### Step A.1 – Install Butane

```bash
curl -sSL https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest/butane --output butane
chmod +x butane && sudo mv butane /usr/local/bin/
butane --version
```

### Step A.2 – Build the SAN list from the current workers

```bash
SAN_LIST=$(oc get nodes -l node-role.kubernetes.io/worker \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
  | sed "s/.*/DNS:&.${NODE_DOMAIN}/" | paste -sd, -)

echo "${SAN_LIST}"
```

✅ **Expected:** something like `DNS:worker-0.ocp.example.com,DNS:worker-1.ocp.example.com,...`, one entry per worker.

> [!NOTE]
> Save this list in the change ticket. You will rebuild it every time a worker is added (see Step A.11).

### Step A.3 – Create the private key and CSR

```bash
openssl req -new -newkey rsa:3072 -nodes \
  -keyout left_server.key -out left_server.csr \
  -subj "/CN=ocp-ipsec-workers/O=KCS" \
  -addext "subjectAltName=${SAN_LIST}"

# Check what you are about to send to the CA
openssl req -in left_server.csr -noout -text | grep -A1 "Subject Alternative Name"
```

Rules:
- The **CN must not start with `ovs_`**, because that clashes with OpenShift's own IPsec certificates.
- Keep the key **RSA**, because the NNCP uses `leftrsasigkey: '%cert'`.
- `left_server.key` is the **private key**. Keep it in a protected location and never commit it to Git.

### Step A.4 – Get the CSR signed by the enterprise CA

Submit `left_server.csr` to the enterprise CA. Ask for a template with:
- **Key usage:** Digital Signature, Key Encipherment
- **Extended key usage:** Server Authentication **and** Client Authentication

You get back:
- `left_server.crt`, the signed certificate
- The CA chain: the **root** certificate and any **intermediate** certificates

If the CA gives you `.cer` / DER files, convert them to PEM:

```bash
openssl x509 -inform der -in left_server.cer       -out left_server.crt
openssl x509 -inform der -in enterprise-root.cer   -out enterprise-root.pem
openssl x509 -inform der -in intermediate.cer      -out intermediate.pem   # only if you have one
```

### Step A.5 – Create `ca.pem` (root CA only)

```bash
cp enterprise-root.pem ca.pem
openssl x509 -in ca.pem -noout -subject -issuer
```

✅ **Expected:** subject and issuer are **the same** (that is what a root CA looks like).

> **Why root only?** The node's import script runs `certutil -A` on `ca.pem`, which imports **one** certificate as the trust anchor. Intermediates go inside the `.p12` in the next step.

### Step A.6 – Bundle `left_server.p12`

```bash
openssl pkcs12 -export \
  -in left_server.crt -inkey left_server.key \
  -certfile intermediate.pem \
  -name left_server \
  -out left_server.p12 -passout pass:
```

What each part does:

| Flag | Why |
|---|---|
| `-name left_server` | Sets the **friendly name**. It becomes the certificate's nickname in the node's NSS database, and the NNCP refers to it as `leftcert: left_server`. **Must be exactly `left_server`.** |
| `-passout pass:` | **Empty password.** The import runs unattended at boot with `pk12util -W ""`, so a password would make it fail. |
| `-certfile intermediate.pem` | Adds the intermediate CA. **Remove this line** if our CA has no intermediate. |

### Step A.7 – Verify the bundle

```bash
openssl pkcs12 -in left_server.p12 -nokeys -passin pass: | grep friendlyName
openssl x509 -in left_server.crt -noout -ext subjectAltName
openssl x509 -in left_server.crt -noout -dates
```

✅ **Expected:** `friendlyName: left_server`; **every** worker FQDN in the SAN list; `notAfter` far enough in the future. Put the expiry date in the team calendar.

### Step A.8 – Write the Butane config

This creates a systemd service on every worker that imports the certificates into NSS at boot, before libreswan starts.

```bash
cat <<EOF > 99-ipsec-worker-endpoint-config.bu
variant: openshift
version: ${OCP_VERSION}
metadata:
  name: 99-worker-import-certs
  labels:
    machineconfiguration.openshift.io/role: worker
systemd:
  units:
  - name: ipsec-import.service
    enabled: true
    contents: |
      [Unit]
      Description=Import external certs into ipsec NSS
      Before=ipsec.service

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/ipsec-addcert.sh
      RemainAfterExit=false
      StandardOutput=journal

      [Install]
      WantedBy=multi-user.target
storage:
  files:
  - path: /etc/pki/certs/ca.pem
    mode: 0400
    overwrite: true
    contents:
      local: ca.pem
  - path: /etc/pki/certs/left_server.p12
    mode: 0400
    overwrite: true
    contents:
      local: left_server.p12
  - path: /usr/local/bin/ipsec-addcert.sh
    mode: 0740
    overwrite: true
    contents:
      inline: |
        #!/bin/bash -e
        echo "importing cert to NSS"
        certutil -A -n "CA" -t "CT,C,C" -d /var/lib/ipsec/nss/ -i /etc/pki/certs/ca.pem
        pk12util -W "" -i /etc/pki/certs/left_server.p12 -d /var/lib/ipsec/nss/
        certutil -M -n "left_server" -t "u,u,u" -d /var/lib/ipsec/nss/
EOF
```

> [!NOTE]
> `ca.pem` and `left_server.p12` **must be in the current folder**. `local:` reads them from there.

### Step A.9 – Render and apply the MachineConfig

```bash
butane -d . 99-ipsec-worker-endpoint-config.bu -o 99-ipsec-worker-endpoint-config.yaml
oc apply -f 99-ipsec-worker-endpoint-config.yaml
```

> [!WARNING]
> The MCO now reboots **every worker, one at a time**. External IPsec only works once **all** of them are done.

```bash
watch oc get mcp worker          # wait for UPDATED=True, UPDATING=False, DEGRADED=False
```

Check one node:

```bash
NODE=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')
oc debug node/${NODE} -- chroot /host certutil -L -d /var/lib/ipsec/nss
```

✅ **Expected:** `left_server` with trust `u,u,u` and `CA` with `CT,C,C`.

### Step A.10 – Kyverno policy: one NNCP per worker

> [!IMPORTANT]
> **Stop here until the NAS side is ready.** This step creates the NNCPs, so the storage team must have finished [3.1](#31-nas-configuration-storage-team-not-us) first.

```bash
cat <<EOF > 10-kyverno-nncp-shared-cert.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ipsec-nncp-shared-cert
spec:
  # If Kyverno is down, never block Node updates
  failurePolicy: Ignore
  rules:
  - name: nncp-per-worker
    match:
      any:
      - resources:
          kinds:
          - Node
          selector:
            matchLabels:
              node-role.kubernetes.io/worker: ""
    generate:
      generateExisting: true     # also create NNCPs for workers that already exist
      synchronize: true          # Kyverno owns these NNCPs: edit the policy, not the NNCPs
      apiVersion: nmstate.io/v1
      kind: NodeNetworkConfigurationPolicy
      name: "ipsec-nas-{{ request.object.metadata.name }}"
      data:
        spec:
          nodeSelector:
            kubernetes.io/hostname: '{{ request.object.metadata.labels."kubernetes.io/hostname" }}'
          desiredState:
            interfaces:
            - name: ipsec-nas
              type: ipsec
              libreswan:
                left: "{{ request.object.metadata.name }}.${NODE_DOMAIN}"   # must be in the cert SAN
                leftid: '%fromcert'
                leftrsasigkey: '%cert'
                leftcert: left_server
                leftmodecfgclient: false
                right: ${NAS_FQDN}
                rightid: '%fromcert'
                rightrsasigkey: '%cert'
                rightsubnet: ${NAS_IP}/32
                ikev2: insist
                type: transport
                # Uncomment ONLY if the NAS requires specific proposals:
                # esp: aes_gcm256
                # ike: aes256-sha2;dh20
EOF

oc apply -f 10-kyverno-nncp-shared-cert.yaml
oc get clusterpolicy ipsec-nncp-shared-cert      # READY must be True
```

Then go to [3.2](#32-verify-end-to-end) to verify.

### Step A.11 – Scale-up procedure (every time a worker is added)

> [!CAUTION]
> Until all of these steps are done, the **new worker has no working IPsec tunnel** to the NAS.

1. Add the new worker (MachineSet scale-up, or however we normally add nodes) and wait until it is `Ready`.
2. Repeat **Step A.2** (new SAN list including the new node).
3. Repeat **Steps A.3 → A.7** (new key, new CSR, CA signs, new `.p12`).
4. Repeat **Step A.8 → A.9** (re-render and re-apply the MachineConfig). **Every worker reboots, one at a time.**
5. When `mcp/worker` is `UPDATED=True`, check the new node's NNCE (section 3.2).
6. Update the change ticket with the new SAN list and expiry date.
7. Revoke the **old** certificate at the CA.

Renewal before expiry is the same procedure, steps 2–7.

---

## Reference

- Red Hat: *OpenShift Container Platform 4.19, Network security, Chapter 6: Configuring IPsec encryption* (sections "Enabling IPsec encryption" and "Configuring IPsec encryption for external traffic")
- Red Hat: *Changing the MTU for the cluster network*
- Kyverno: *Installation, Platform Notes (OpenShift)* and *Generate Rules*
- cert-manager: *Certificate resource*

---

## Diagram sources

The three figures in this guide are rendered from one hand-authored page, `docs/diagrams/ipsec-nas/source.html` (inline SVG, light and dark palettes). `docs/diagrams/render.py` screenshots each figure in both themes at twice the pixel density and checks the page at phone width. It needs Playwright's Chromium (`python3 -m pip install playwright && python3 -m playwright install chromium`). From the repository root:

```bash
python3 docs/diagrams/render.py docs/diagrams/ipsec-nas/source.html docs/diagrams/ipsec-nas \
  overview,option-a-shared-cert,option-b-per-node-certs
```

| Figure | Where it is shown | Rendered files (`docs/diagrams/ipsec-nas/`) | Mermaid text source (`docs/diagrams/mermaid/`) |
|---|---|---|---|
| 1. How IPsec to the NAS works | Overview, and `README.md` | `overview.light.png`, `overview.dark.png` | `overview.mmd` |
| 2. Our standard (Option B): one certificate per node | Section 2.0 | `option-b-per-node-certs.light.png`, `.dark.png` | `option-b-per-node-certs.mmd` |
| 3. Option A: one shared certificate | Appendix A (A.0) | `option-a-shared-cert.light.png`, `.dark.png` | `option-a-shared-cert.mmd` |

The Mermaid files are plain-text versions of the same flows, kept for editing and diffs. They are not what the documents display.

Each figure has a text twin directly under it. If a step in the guide changes, change the figure in `source.html`, re-render, and update the text twin and the Mermaid file together. The figures are drawn from this guide and its manifests; they have not been measured on a running cluster.
