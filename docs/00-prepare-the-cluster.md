# Prepare the Cluster and the NAS — IPsec from OpenShift Nodes to the NAS

**Team:** KCS OpenShift  **Audience:** platform engineers, including new ones  **Design target:** OpenShift 4.19 and later, RHCOS nodes

This doc prepares what every setup option needs: the cluster settings, the operators, Kyverno, and the NAS side. Then pick the certificate option. The [README](README.md) has the overview of all docs.

| After this doc | What it sets up |
|---|---|
| [20-option-b-per-node-certificates.md](20-option-b-per-node-certificates.md) | **Our standard, the enterprise north star:** one certificate per node, issued and renewed by cert-manager, delivered with no reboot |
| [30-option-b-automated-helm-argocd.md](30-option-b-automated-helm-argocd.md) | The same Option B as one Helm release, installed with Helm or from Git with Argo CD |
| [10-option-a-shared-certificate.md](10-option-a-shared-certificate.md) | The procedure Red Hat documents, one shared certificate for every node. **Documented, not used** |

**Contents:** [Overview](#overview--how-ipsec-to-the-nas-works) · [Part 0 – Before you start](#part-0--before-you-start) · [Part 1 – Cluster preparation](#part-1--cluster-preparation) · [Part 3 – NAS side, verification, troubleshooting](#part-3--nas-side-verification-troubleshooting) · [Reference](#reference)

## Overview – how IPsec to the NAS works

<img alt="Cluster settings put libreswan, a certificate and one tunnel definition on each worker node. The node and the NAS authenticate each other with certificates over IKEv2, and NFS traffic to the NAS IP travels as ESP in transport mode. Pod-to-pod traffic is not encrypted." src="diagrams/ipsec-nas/overview.light.png">

*Figure 1. Cluster settings put libreswan, a certificate and one tunnel definition on each worker. The node and the NAS then authenticate each other with certificates over IKEv2, and NFS traffic to the NAS IP travels as ESP in transport mode. The figure is drawn from these docs and their manifests; it has not been measured on a running cluster.*

<details>
<summary>The figure as text</summary>

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

</details>

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
| **cert-manager** | Issues and renews certificates from a `ClusterIssuer`. We use the one the cluster **already has** for the enterprise CA. Nothing here creates an issuer; `company-issuer-rnd` is a placeholder for that issuer's name. |
| **MCO / MachineConfig** | Machine Config Operator. Changing a MachineConfig **reboots nodes one at a time**. |

### 0.2 Requirements checklist

- [ ] You are `cluster-admin` (`oc whoami` and `oc auth can-i '*' '*' --all-namespaces` returns `yes`).
- [ ] Platform is **bare metal, vSphere, RHOSP or Google Cloud**. External IPsec is not supported on other platforms, on **RHEL compute nodes**, or with **hosted control planes**.
- [ ] Every worker FQDN `<node-name>.<NODE_DOMAIN>` **resolves in DNS** to that node's IP. libreswan and the certificates use this name.
- [ ] Firewalls allow **UDP 500**, **UDP 4500** and **ESP (IP protocol 50)** between all workers and the NAS.
- [ ] The NAS supports **IKEv2, transport mode and certificate (PKI) authentication**, and trusts our enterprise root CA.
- [ ] The **storage team** has a ticket to create the **NAS (`right`) certificate** and IPsec policy (see [3.1](#31-nas-configuration-storage-team-not-us)). We do not create the NAS certificate.
- [ ] Tools on your workstation: `oc`, `openssl`, `helm` (Part 1), and a clone of this repository. Option A also needs `butane`.
- [ ] A **change window** has been approved: Part 1 reboots every node at least once.
- [ ] The cert-manager Operator is installed and the cluster's **existing enterprise CA `ClusterIssuer`** is `Ready`. You know its name (`oc get clusterissuer`). Nothing here creates one.

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
# "company-issuer-rnd" is only a placeholder. Nothing here creates an issuer.
export CLUSTER_ISSUER="company-issuer-rnd"
# ----------------------

# Butane version = your cluster's x.y with .0 on the end (e.g. 4.19.0). Only Option A uses it.
export OCP_VERSION="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1,2).0"

# The commands run from the root of this repository
cd openshift-ipsec-nas
./render.sh       # fills the variables into the manifests: rendered/
echo "Domain=${NODE_DOMAIN} NAS=${NAS_FQDN}/${NAS_IP} Issuer=${CLUSTER_ISSUER} Butane=${OCP_VERSION}"
```

The manifests are files in [`manifests/`](../manifests/); the steps apply them from there or from `rendered/`, and show the lines that matter. Read a file before applying it.

> [!TIP]
> **About `cat <<EOF` vs `cat <<'EOF'`:** with `<<EOF`, bash **replaces** `${VARIABLES}` inside the block. With `<<'EOF'` (quoted), the text is written **exactly as typed**. Each step uses the right one, so copy the blocks exactly.

---

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

> [!NOTE]
> libreswan is **not** in the node's base image. It is the `ipsec` OS extension (`libreswan` and `NetworkManager-libreswan`) that ships inside the OpenShift release, so the nodes download nothing from outside. The extension is defined the same way in 4.19, 4.20, 4.21 and 4.22 (checked in the Machine Config Operator source; details and links in [`40-lab-crc-and-nas.md`](40-lab-crc-and-nas.md#is-libreswan-built-into-a-full-openshift-cluster-419-and-later)).
>
> **OpenShift Local (CRC) cannot install this extension**, because its node image carries extra packages that the install cannot find again. [40-lab-crc-and-nas.md](40-lab-crc-and-nas.md#gotcha-1--ipsecconfigmode-external-cannot-install-libreswan-on-crc) shows the failure and a CRC-only way around it.

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
oc apply -f manifests/common/01-nmstate-operator.yaml     # Namespace, OperatorGroup, Subscription (channel stable, redhat-operators)
```

Wait for the operator:

```bash
watch oc get csv -n openshift-nmstate      # wait for PHASE=Succeeded, then Ctrl+C
```

Create the `NMState` instance, which starts the per-node handlers:

```bash
oc apply -f manifests/common/02-nmstate-instance.yaml     # the NMState object named nmstate
oc get pods -n openshift-nmstate           # nmstate-handler pod on every node, all Running
```

### Step 1.6 – Install Kyverno

Kyverno is installed with Helm. There are two ways to run the install (1.6.4 **or** 1.6.5), and both need the two settings in 1.6.3: the OpenShift SCC setting, and the setting that lets Kyverno see Nodes.

> [!IMPORTANT]
> Kyverno is a **community project, not Red Hat-supported**. Use the chart version approved by our change process (`--version`), and the internal mirror if the cluster is disconnected. Option B's policies need **Kyverno 1.19 or later** (its CEL policy kinds); with the legacy policy files, Kyverno 1.13 or later. Measured with Kyverno 1.19.1, chart 3.9.1.

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

**Option 2: keep the fixed ID and grant an SCC that allows it.** Give Kyverno's service accounts the `nonroot-v2` SCC **before** installing, then leave the `-f kyverno-openshift-values.yaml` line out of the install command (keep `-f kyverno-node-values.yaml`).

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

**Both options: let Kyverno see Nodes.** Out of the box Kyverno **ignores every Node object**: its `resourceFilters` list contains `[Node,*,*]`. Every policy of Options A and B is triggered by a Node, so with the default they are accepted, show `READY=True`, and never create anything. The chart has a setting that takes one entry out of that list:

```bash
cat <<'EOF' > kyverno-node-values.yaml
config:
  # Kyverno ignores Node objects by default; the IPsec policies are triggered by Nodes.
  resourceFiltersExclude:
  - '[Node,*,*]'
EOF

# Check what it changes before installing: the first command prints two Node filters, the second only one
helm template kyverno kyverno/kyverno --version "${KYVERNO_CHART_VERSION}" -n kyverno | grep -o '\[Node[^]]*\]' | sort | uniq -c
helm template kyverno kyverno/kyverno --version "${KYVERNO_CHART_VERSION}" -n kyverno -f kyverno-node-values.yaml | grep -o '\[Node[^]]*\]' | sort | uniq -c
```

✅ **Expected** (measured with chart 3.9.1): `[Node,*,*]` and `[Node/?*,*,*]` without the file, only `[Node/?*,*,*]` with it. That second entry covers Node sub-resources such as the status a node reports every few seconds; it stays filtered on purpose.

Kyverno is **already installed**? Add the setting to the running release and keep everything else as it is:

```bash
helm upgrade kyverno kyverno/kyverno -n kyverno --version "${KYVERNO_CHART_VERSION}" --reuse-values -f kyverno-node-values.yaml
oc get cm -n kyverno kyverno -o jsonpath='{.data.resourceFilters}' | grep -o '\[Node[^]]*\]'      # only [Node/?*,*,*]
```

Kyverno then also looks at Nodes for every other policy on the cluster. Check first that no existing policy matches Nodes by accident: `oc get clusterpolicy -o yaml | grep -n -A3 'kinds:'` and `oc get generatingpolicy,mutatingpolicy,validatingpolicy -o yaml | grep -n -B2 -A2 'nodes'`.

#### 1.6.4 Install method 1 – straight from the Helm repository

```bash
helm install kyverno kyverno/kyverno -n kyverno --create-namespace \
  --version "${KYVERNO_CHART_VERSION}" \
  -f kyverno-openshift-values.yaml \
  -f kyverno-node-values.yaml \
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

Copy `kyverno-${KYVERNO_CHART_VERSION}.tgz`, `kyverno-openshift-values.yaml` and `kyverno-node-values.yaml` to the machine that is logged in to the cluster, then install from the file:

```bash
helm install kyverno "./kyverno-${KYVERNO_CHART_VERSION}.tgz" -n kyverno --create-namespace \
  -f kyverno-openshift-values.yaml \
  -f kyverno-node-values.yaml \
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
oc get cm -n kyverno kyverno -o jsonpath='{.data.resourceFilters}' | grep -o '\[Node[^]]*\]'
```

✅ **Expected:** every pod `Running`; `SCC` is `restricted-v2` (Option 1) or `nonroot-v2` (Option 2); image tags are `v1.19` or later (`v1.13` or later with the legacy policies); the last command prints only `[Node/?*,*,*]`.

### Step 1.7 – Give Kyverno permission to create NNCPs and Certificates

By default Kyverno cannot create these resource types, and it cannot read Nodes, which every policy of Options A and B matches on. These two ClusterRoles are **aggregated** into Kyverno's own roles through their labels.

```bash
oc apply -f manifests/common/03-kyverno-rbac.yaml
```

| ClusterRole | Aggregated into | Grants |
|---|---|---|
| `kyverno:ipsec-nas-generate` | background and admission controllers | Create, update and delete NNCPs and cert-manager Certificates |
| `kyverno:ipsec-nas-read-nodes` | background and reports controllers | Read Nodes: the background controller lists them to create objects for nodes that already exist, the reports controller for policy reports |

Check it. Every line must say `yes`:

```bash
for r in nodenetworkconfigurationpolicies.nmstate.io certificates.cert-manager.io; do
  printf 'background-controller create %s: ' "$r"
  oc auth can-i create "$r" --as=system:serviceaccount:kyverno:kyverno-background-controller -n kcs-ipsec
done
printf 'background-controller list nodes: '
oc auth can-i list nodes --as=system:serviceaccount:kyverno:kyverno-background-controller
```

> [!IMPORTANT]
> Without the second ClusterRole the policies show `READY=True` and **create nothing**. Measured with Kyverno 1.19.1 (chart 3.9.1): the background controller logged `nodes is forbidden: ... cannot list resource "nodes"` and no NNCP appeared.

### ✅ Part 1 checklist

- [ ] MTU checked (and lowered if required)
- [ ] `routingViaHost: true`
- [ ] `ipsecConfig.mode: External`, all MCPs `UPDATED=True`
- [ ] NMState Operator `Succeeded`, `NMState` instance created
- [ ] Kyverno running (1.19 or later; 1.13 with the legacy policies), RBAC applied

**Next:** the NAS side (Part 3.1) has to be ready before any tunnel is created. Then set up the certificates: [20-option-b-per-node-certificates.md](20-option-b-per-node-certificates.md), our standard, by hand to learn each object, or [30-option-b-automated-helm-argocd.md](30-option-b-automated-helm-argocd.md), the same objects from Git. Everything in Part 1 is a prerequisite of both.

---

## Part 3 – NAS side, verification, troubleshooting

### 3.1 NAS configuration (storage team, not us)

> [!TIP]
> **No NAS to test against yet?** [`lab/test-nas-rhel.md`](lab/test-nas-rhel.md) builds a test NAS on RHEL 10, and [`lab/lima-lab.md`](lab/lima-lab.md) runs it in a lab on a Mac.

The NAS needs its **own** certificate (the `right` side), and the **storage team** creates it. The key and CSR are generated on the NAS and the enterprise CA signs it. We never generate, hold or transfer the NAS private key. The only thing we install from that side is the **enterprise root CA**, so the nodes can trust the NAS.

> [!IMPORTANT]
> **Timing:** raise the storage ticket at the start (it is on the [Part 0 checklist](#02-requirements-checklist)). Everything in [What they send back](#3-what-they-send-back) must be confirmed **before** the step that creates the NNCPs: Step B.9 of Option B (Option A: Step A.10).

#### The two certificates

| | Node certificate (`left`) | NAS certificate (`right`) |
|---|---|---|
| Installed on | Every worker, NSS nickname `left_server` | The NAS |
| Key + CSR created by | **Us**: cert-manager (Option B, Step B.4). Option A: by hand (Step A.3) | **Storage team**, on the NAS |
| Signed by | Enterprise CA, through the existing `ClusterIssuer` (`${CLUSTER_ISSUER}`) | The **same** enterprise CA |
| Name in the SAN | Worker FQDN `<node-name>.${NODE_DOMAIN}` | `${NAS_FQDN}` |
| IP address in the certificate | Not needed | Not needed. `${NAS_IP}` is only used in the NNCP `rightsubnet` |
| Private key stays | On our side | On the NAS |
| What the other side installs | The enterprise root CA | The enterprise root CA: `ipsec-trust-ca` (Option A: `ca.pem`) |

#### Who does what

| Task | KCS OpenShift (us) | Storage / NAS team |
|---|---|---|
| Node (`left`) certificates | ✅ cert-manager, automatically (Option A: our own CSR) | – |
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
| Duplicate peer IDs | Not needed with per-node certificates (Option B). **Options A and C:** must be allowed (`uniqueids=no` equivalent; [measured for C](50-option-c-wildcard-certificate.md#for-the-nas-team-what-option-c-needs)) |
| Cleartext NFS from workers | **Rejected**, so IPsec is required and never silently bypassed |

#### 3. What they send back

Do not apply any NNCP (Option B: Step B.9; Option A: Step A.10) until every box is ticked.

- [ ] Confirmation that the NAS cert's **SAN contains `${NAS_FQDN}`**. The NNCP uses `right: ${NAS_FQDN}`, and Red Hat's procedure says that name should match the certificate SAN.
- [ ] The NAS cert's **issuer chain**: it must chain to the root in `ipsec-trust-ca` (Option A: `ca.pem`)
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
> If the NAS cert is signed by a **different** CA than our node certs, the nodes won't trust it: `ipsec-trust-ca` (Option A: `ca.pem`) holds **one** root only. Agree on **one enterprise CA for both sides** before starting.

> [!NOTE]
> We *could* issue the NAS cert from the same `ClusterIssuer` (`${CLUSTER_ISSUER}`) with cert-manager, but the private key would then be created inside our cluster and handed to another team. Only do this if the storage team and security explicitly agree, and the key is transferred securely. A cert-manager `CertificateRequest` avoids the problem: it signs a CSR that was made on the NAS, so the key stays there. [`40-lab-crc-and-nas.md`](40-lab-crc-and-nas.md#part-c--the-nas-side-for-crc) shows it, measured on CRC.

### 3.2 Verify end to end

```bash
# Policies (the legacy kinds: oc get clusterpolicy)
oc get generatingpolicy,mutatingpolicy

# NNCPs and per-node results
oc get nncp | grep ipsec-nas
oc get nnce | grep ipsec-nas            # STATUS must be Available

# Tunnel state on one node
NODE=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')
oc debug node/${NODE} -- chroot /host ipsec trafficstatus
```

✅ **Expected:** `trafficstatus` lists the `ipsec-nas` connection with `inBytes`/`outBytes`.

Final proof: run a workload on that node that reads/writes the NAS (NFS PVC), run `ipsec trafficstatus` again, and confirm the byte counters **increased**. [`lab/nas-consumer-app.md`](lab/nas-consumer-app.md) has a ready-made demo application for this, with a web page that shows the data on the NAS.

### 3.3 Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| No Kyverno pods; `oc get events -n kyverno` shows `unable to validate against any security context constraint` | Chart sets a fixed user ID that `restricted-v2` rejects | Apply the SCC setting in Step 1.6.3, then `helm upgrade` with the same flags |
| A policy's READY is false | Policy syntax or missing RBAC | `oc describe generatingpolicy <name>` (or `mutatingpolicy`; legacy: `clusterpolicy`) and read its conditions; re-check Step 1.7 |
| Alert `IpsecNasTunnelDown` for a node | That node's tunnel is not established | `oc debug node/<node> -- chroot /host ipsec trafficstatus`; then `journalctl -u ipsec` on the node. Check the NNCE for that node. |
| `ipsec_nas_tunnel_up` returns nothing in Observe → Metrics | Metrics are not scraped | `oc get servicemonitor -n kcs-ipsec`; `oc get pods -n openshift-user-workload-monitoring`; the pods must be `3/3` (Step B.8) |
| Alert `IpsecNasMetricsStale` | The `collector` container stopped | `oc logs -n kcs-ipsec <pod> -c collector`; delete the pod to restart it |
| No NNCP / Certificate created, policy is `READY=True`, and Kyverno logs nothing after `policy created` | Kyverno is ignoring Nodes | `oc get cm -n kyverno kyverno -o jsonpath='{.data.resourceFilters}' \| grep -o '\[Node[^]]*\]'` must not print `[Node,*,*]`. Fix: Step 1.6.3, then delete and re-apply the policy |
| No NNCP / Certificate created, and Kyverno logs `nodes is forbidden` | Kyverno may not read Nodes | Apply both ClusterRoles of Step 1.7, then delete and re-apply the policy |
| No NNCP / Certificate created | Another Kyverno generate error | `oc get updaterequests -n kyverno`; `oc logs -n kyverno deploy/kyverno-background-controller` |
| Certificate not `Ready` | Issuer rejected the request | `oc describe certificate ipsec-<node> -n kcs-ipsec`; `oc get certificaterequest -n kcs-ipsec`; check the issuer: `oc get clusterissuer "${CLUSTER_ISSUER}"` |
| cert-sync pods are replaced every minute, and their log says `This pod mounts the placeholder secret` | The Kyverno mutation does not run | The pods retry by themselves. Fix the cause: policy `ipsec-cert-sync-mount` must be `READY=True`, and Kyverno's admission controller must be running |
| cert-sync log repeats `Waiting for certificate files in /certs` | Certificate not issued yet | Fix the Certificate first (row above) |
| Logs: `ERROR: import failed` | `openssl`/NSS refused the bundle (e.g. FIPS-mode cluster rejecting an empty password) | Read the full log; on FIPS clusters, change the script to use a non-empty password for `-passout`/`-W` |
| Node never gets `cert-ready` label | RBAC/SCC | `oc logs` of that node's pod; re-run Option B, Step B.6 |
| NNCE `Failing` | Cert nickname missing, DNS for `left`/`right` not resolving | `oc get nnce <node>.ipsec-nas-<node> -o yaml` and read `status.conditions`; check `certutil -L` on the node |
| NNCE `Available` but no traffic in `trafficstatus` | NAS proposal/CA mismatch, firewall | `oc debug node/<node> -- chroot /host journalctl -u ipsec --since "30 min ago"`; check UDP 500/4500 + ESP |
| Option A: tunnels on other nodes drop when one connects | NAS treats identical IDs as one peer | Allow duplicate IDs on the NAS (3.1) |
| Option A: MCP `DEGRADED` | Bad Butane render or file missing | `oc describe mcp worker`; check `ipsec-import.service` on the node: `journalctl -u ipsec-import` |

---

## Reference

- Red Hat: *OpenShift Container Platform 4.19, Network security, Chapter 6: Configuring IPsec encryption* (sections "Enabling IPsec encryption" and "Configuring IPsec encryption for external traffic")
- Red Hat: *Changing the MTU for the cluster network*
- Kyverno: *Installation, Platform Notes (OpenShift)* and *Generate Rules*
- cert-manager: *Certificate resource*

---

## Diagram sources

Figures 1 to 3 are rendered from one hand-authored page, `docs/diagrams/ipsec-nas/source.html`, and Figure 4 from `docs/diagrams/option-c/source.html` (inline SVG, light and dark palettes). The docs show the light version of every figure; the dark one is rendered next to it. [diagram-kit](https://github.com/ephico2real2/diagram-kit) (MPL-2.0) renders each figure in both themes at twice the pixel density, and writes a PNG only when the page passes its checks: a font that did not load, a label that runs past its box, text that cannot be read in one of the two themes, a page that scrolls sideways at phone width. Install it once, pinned (`python3 -m venv .venv && .venv/bin/pip install "diagram-kit @ git+https://github.com/ephico2real2/diagram-kit@v0.2.0" && .venv/bin/playwright install chromium`). From the repository root:

```bash
.venv/bin/diagram-render docs/diagrams/ipsec-nas/source.html docs/diagrams/ipsec-nas \
  overview,option-a-shared-cert,option-b-per-node-certs,perses-dashboard
.venv/bin/diagram-render docs/diagrams/option-c/source.html docs/diagrams/option-c option-c-wildcard-cert
```

| Figure | Where it is shown | Rendered files (`docs/diagrams/ipsec-nas/`) | Mermaid text source (`docs/diagrams/mermaid/`) |
|---|---|---|---|
| 1. How IPsec to the NAS works | Overview above, `docs/README.md` and `README.md` | `overview.light.png`, `overview.dark.png` | `overview.mmd` |
| 2. Our standard (Option B): one certificate per node | `20-option-b-per-node-certificates.md`, 2.0 | `option-b-per-node-certs.light.png`, `.dark.png` | `option-b-per-node-certs.mmd` |
| 3. Option A: one shared certificate | `10-option-a-shared-certificate.md`, A.0 | `option-a-shared-cert.light.png`, `.dark.png` | `option-a-shared-cert.mmd` |
| 4. Option C: one wildcard certificate, the settings that worked | `50-option-c-wildcard-certificate.md`, C.0 | `diagrams/option-c/option-c-wildcard-cert.light.png`, `.dark.png` (source: `diagrams/option-c/source.html`) | `option-c-wildcard-cert.mmd` |

The Mermaid files are plain-text versions of the same flows, kept for editing and diffs. They are not what the documents display.

Each figure has a text twin directly under it. If a step in the docs changes, change the figure in `source.html`, re-render, and update the text twin and the Mermaid file together. The figures are drawn from these docs and their manifests; they have not been measured on a running cluster.
