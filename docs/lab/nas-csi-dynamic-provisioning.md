# Storage on Demand from the NAS — csi-driver-nfs over IPsec

**Team:** KCS OpenShift  **Audience:** junior/new platform engineers  **Purpose:** let applications ask for NAS storage with a PersistentVolumeClaim, with nobody writing a PersistentVolume by hand, and every byte travelling through the IPsec tunnel

[nas-consumer-app.md](nas-consumer-app.md) gives an application **one** share that an administrator hands out (a static PersistentVolume). This guide sets up **dynamic provisioning**: install the NFS CSI driver once, create one StorageClass for the NAS, and from then on every claim of that class gets its own directory on the NAS by itself.

| | |
|---|---|
| Driver | [`csi-driver-nfs`](https://github.com/kubernetes-csi/csi-driver-nfs) 4.13.4 (Kubernetes CSI project, upstream Helm chart), in the namespace `csi-driver-nfs` |
| StorageClass | `ipsec-nas-csi`: the NAS IP, the export, one directory per claim (`csi/<namespace>/<claim>`), `Retain` |
| Demo | The demo app of nas-consumer-app.md on a dynamic claim, in the namespace `ipsec-nas-csi-demo`, with a Route |
| Files | [`manifests/csi-driver-nfs/values.yaml`](../../manifests/csi-driver-nfs/values.yaml), [`manifests/demo-app-csi/`](../../manifests/demo-app-csi/) |
| Measured | Every step on OpenShift Local (CRC 4.22.7) against the lab NAS (NFS accepted only through IPsec), 2026-10-05: [evidence 56](../evidence/crc/56-csi-driver-nfs-dynamic-provisioning.txt) |

**Contents:** [How it works](#how-it-works) · [Before you start](#before-you-start) · [Part 1 – Install the driver](#part-1--install-the-driver) · [Part 2 – The StorageClass](#part-2--the-storageclass) · [Part 3 – Use it: the demo app](#part-3--use-it-the-demo-app) · [Part 4 – Use it for your application](#part-4--use-it-for-your-application) · [When a claim is deleted](#when-a-claim-is-deleted) · [Remove everything](#remove-everything) · [Troubleshooting](#troubleshooting) · [References](#references)

---

## How it works

```text
 application pod                       csi-nfs-node (DaemonSet, every node, host network)
   PVC app-data  ──────────────────▶    mounts NAS_IP:/export/csi/<ns>/<claim> on the node,
   (class ipsec-nas-csi)                 hands the directory to the pod
        │
        │ new claim                      csi-nfs-controller (Deployment, a worker, host network)
        └──────────────────────────▶    mounts NAS_IP:/export, creates csi/<ns>/<claim>,
                                          the PersistentVolume is created and bound

 both mounts leave the node from the node's own address to NAS_IP  ══ IPsec tunnel ══▶  NAS (NFS only over IPsec)
```

- **No NFS client in the application.** The node mounts the share; the pod runs under the default `restricted-v2` SCC with no privileges.
- **Both driver pods use the host network**, so their NFS traffic is the node's traffic: exactly what the tunnel covers. The **controller** mounts the share too (to create each claim's directory), so the node it runs on needs a tunnel. That is why [Step 1.3](#step-13--install-the-chart) keeps it on worker nodes.
- **The StorageClass uses the NAS IP**, not its name: the tunnel protects traffic to that one address (`rightsubnet: ${NAS_IP}/32` in the NNCP).

### Words you will see

| Term | Meaning |
|---|---|
| **CSI driver** | A plug-in that teaches Kubernetes a storage system. `csi-driver-nfs` is the one for NFS. Its name in the cluster is `nfs.csi.k8s.io`. |
| **StorageClass** | A named kind of storage. A claim of that class makes the driver create a PersistentVolume. |
| **PersistentVolumeClaim (PVC)** | A request for storage, in a namespace. |
| **PersistentVolume (PV)** | The cluster-wide object for one piece of storage. Here the driver creates it; its name is `pvc-<id>`. |
| **root_squash** | An NFS export option: requests from the user (and group) root on the client are handled as the NAS's anonymous user, usually `nobody` (65534). |

---

## Before you start

- [ ] The IPsec setup is finished: every worker's NNCE is `Available` and `ipsec trafficstatus` on a worker shows the `ipsec-nas` tunnel ([verify end to end](../00-prepare-the-cluster.md#32-verify-end-to-end)).
- [ ] You are logged in with `oc` as `cluster-admin`, and `helm` is installed (measured with Helm 4.3.0).
- [ ] From the storage team: the NAS IP, the export path, and these two facts about the export:

| Ask the storage team | Why | The lab NAS |
|---|---|---|
| The export is shared to every worker's address, NFS 4.1, read-write | The node plugin mounts from each worker; the controller from the worker it runs on | `/export 192.168.127.2(rw,sync,no_subtree_check)` (CRC's one node) |
| The export's top directory is writable by the anonymous user, or a directory `csi` in it is owned by the anonymous user | With `root_squash` (the default), the driver creates directories as the anonymous user | `/export` mode `0777`, `root_squash` |

`no_root_squash` is **not** needed: everything below was measured with `root_squash`.

### Set the variables

```bash
# ---- CHANGE THESE ----
export NAS_IP="10.10.10.50"       # the NAS NFS data IP, the same value as in the setup docs
export NAS_EXPORT="/export"       # the path the NAS exports
# ----------------------
```

---

## Part 1 – Install the driver

### Step 1.1 – Add the chart repository

```bash
helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
helm repo update csi-driver-nfs
helm search repo csi-driver-nfs/csi-driver-nfs --versions | head -3
```

✅ **Expected:** `csi-driver-nfs/csi-driver-nfs  4.13.4  4.13.4  CSI NFS Driver for Kubernetes` at the top.

### Step 1.2 – A namespace, and the privileged SCC for the driver's two service accounts

The driver's pods mount file systems on the node, so they need the `privileged` SCC. Grant it to the two service accounts the chart creates, by name, before installing it:

```bash
oc create namespace csi-driver-nfs
oc adm policy add-scc-to-user privileged -z csi-nfs-controller-sa -n csi-driver-nfs
oc adm policy add-scc-to-user privileged -z csi-nfs-node-sa -n csi-driver-nfs
```

✅ **Expected:** `clusterrole.rbac.authorization.k8s.io/system:openshift:scc:privileged added: "csi-nfs-controller-sa"`, and the same for `csi-nfs-node-sa`.

> [!NOTE]
> The upstream instructions install into `kube-system`. A namespace of its own keeps the driver, its grants and its removal in one place.

### Step 1.3 – Install the chart

```bash
helm install csi-driver-nfs csi-driver-nfs/csi-driver-nfs --namespace csi-driver-nfs --version 4.13.4 \
  -f manifests/csi-driver-nfs/values.yaml --wait
```

[`values.yaml`](../../manifests/csi-driver-nfs/values.yaml) changes one thing from the chart's defaults: the controller runs on **worker** nodes only (`nodeSelector: node-role.kubernetes.io/worker: ""`). The chart's default controller tolerates the control-plane taints, and `controller.runOnControlPlane: false` does not keep it off them; the setup builds tunnels on workers, so a controller on a control-plane node could not reach the NAS.

### Step 1.4 – Verify

```bash
oc get pods -n csi-driver-nfs -o wide
oc get pods -n csi-driver-nfs -o jsonpath='{range .items[*]}{.metadata.name} scc={.metadata.annotations.openshift\.io/scc}{"\n"}{end}'
oc get csidriver nfs.csi.k8s.io
```

✅ **Expected** (measured): `csi-nfs-controller-…` `5/5 Running` on a worker, one `csi-nfs-node-…` `3/3 Running` per node, both `scc=privileged`, and the CSIDriver `nfs.csi.k8s.io`.

---

## Part 2 – The StorageClass

### Step 2.1 – Render and read it

From the repository root. `render.sh` fills `${NAS_IP}` and `${NAS_EXPORT}` into the templates and writes everything to `rendered/`; it leaves `${pvc.metadata.…}`, which the driver fills in per claim.

```bash
export NODE_DOMAIN="${NODE_DOMAIN:-ocp.example.com}" NAS_FQDN="${NAS_FQDN:-nas01.example.com}" CLUSTER_ISSUER="${CLUSTER_ISSUER:-company-issuer-rnd}"
./render.sh
cat rendered/demo-app-csi/51-storageclass.yaml
```

| Line | Why |
|---|---|
| `provisioner: nfs.csi.k8s.io` | The driver from Part 1 |
| `server: ${NAS_IP}` | The address the tunnel protects. Never the NAS's name |
| `share: ${NAS_EXPORT}` | The export |
| `subDir: csi/${pvc.metadata.namespace}/${pvc.metadata.name}` | One directory per claim, named after it, under a parent of its own (see below) |
| `reclaimPolicy: Retain` | Deleting a claim never deletes data on the NAS ([details](#when-a-claim-is-deleted)) |
| `volumeBindingMode: Immediate` | The volume is made when the claim is created, not when a pod first uses it |
| `mountOptions: nfsvers=4.1, hard, noatime` | The same as the static volume of nas-consumer-app.md |

**Why the `csi/` parent.** With `root_squash`, the driver creates directories as the NAS's anonymous user, and that user cannot create a directory inside one that another user owns. Measured: with `subDir: ${pvc.metadata.namespace}/${pvc.metadata.name}`, a claim in `ipsec-nas-demo` failed with `mkdir …/ipsec-nas-demo/app-data: permission denied`, because `/export/ipsec-nas-demo` belongs to the static demo's pod. Under `csi/`, every directory is the driver's own.

### Step 2.2 – Create it

```bash
oc apply -f rendered/demo-app-csi/51-storageclass.yaml
oc get storageclass ipsec-nas-csi
```

✅ **Expected:** `ipsec-nas-csi   nfs.csi.k8s.io   Retain   Immediate`. It is not the default class; claims ask for it by name.

---

## Part 3 – Use it: the demo app

The same demo app as [nas-consumer-app.md](nas-consumer-app.md#step-5--deploy-the-demo-app) (a `writer` that appends a line every 10 seconds, a `web` that serves the page), on a dynamic claim.

### Step 3.1 – The namespace and the claim

```bash
oc apply -f rendered/demo-app-csi/50-namespace.yaml -f rendered/demo-app-csi/52-pvc.yaml
oc get pvc app-data -n ipsec-nas-csi-demo
oc get pv "$(oc get pvc app-data -n ipsec-nas-csi-demo -o jsonpath='{.spec.volumeName}')" \
  -o custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase,SUBDIR:.spec.csi.volumeAttributes.subDir
```

✅ **Expected** (measured, about 2 seconds after the apply): `app-data   Bound   pvc-<id>   1Gi   RWX   ipsec-nas-csi`, and the volume `Retain   Bound   csi/ipsec-nas-csi-demo/app-data`.

On the NAS (ask the storage team, or on the test NAS run it yourself), the directory is there:

```text
$ find /export/csi -printf "%p %m %U:%G\n"
/export/csi 755 65534:65534
/export/csi/ipsec-nas-csi-demo 755 65534:65534
/export/csi/ipsec-nas-csi-demo/app-data 755 65534:65534
```

### Step 3.2 – The app and its URL

```bash
oc apply -f rendered/demo-app-csi/53-app.yaml -f rendered/demo-app-csi/54-route.yaml
oc rollout status deploy/nas-demo -n ipsec-nas-csi-demo
URL="https://$(oc get route nas-demo -n ipsec-nas-csi-demo -o jsonpath='{.spec.host}')"
curl -sk "${URL}/"
```

✅ **Expected** (measured, 40 seconds after the pod started):

```text
<title>NAS demo</title><h1>Data on the NAS</h1>
<p>Written by pod nas-demo-5f69b4d9d9-2v6b4 on node crc to the NFS volume. Page built 2026-10-05T01:46:23Z.</p>
<p>5 lines in <a href=data.log>data.log</a>. The newest 20:</p><pre>
2026-10-05T01:45:43Z pod=nas-demo-5f69b4d9d9-2v6b4 node=crc line=1
…
2026-10-05T01:46:23Z pod=nas-demo-5f69b4d9d9-2v6b4 node=crc line=5
</pre>
```

### Step 3.3 – See the data on the NAS, and prove it used the tunnel

On the NAS:

```text
$ ls -lan /export/csi/ipsec-nas-csi-demo/app-data
drwxrwsr-x. 2      65534 65534  ... .
-rw-r--r--. 1 1001250000 65534  ... data.log
-rw-r--r--. 1 1001250000 65534  ... index.html
```

The files belong to the pod's user ID. The directory became `2775` (group-writable, set-group-ID) when the pod mounted it: the kubelet applies the pod's `fsGroup` to the volume (the driver declares `fsGroupPolicy: File`). Its group stays the anonymous one, and that is why the pod can write: a `restricted-v2` pod's primary group is root (0), which `root_squash` maps to the same anonymous group.

On the cluster, the node's mount and its tunnel counters, read twice a minute apart:

```bash
NODE="$(oc get pod -n ipsec-nas-csi-demo -l app=nas-demo -o jsonpath='{.items[0].spec.nodeName}')"
oc debug node/${NODE} -- chroot /host bash -c 'findmnt -t nfs4 -o SOURCE,OPTIONS | grep csi; ipsec trafficstatus'
```

✅ **Expected** (measured): the source `${NAS_IP}:${NAS_EXPORT}/csi/ipsec-nas-csi-demo/app-data` with `vers=4.1,…,hard`, and the `ipsec-nas` line with `outBytes` higher on the second read. On the lab NAS, which accepts NFS only when it arrived through IPsec, the counter of that rule rose (13,187,359 → 13,187,923 packets) and the counter of cleartext NFS it drops stayed at 660.

---

## Part 4 – Use it for your application

Once Parts 1 and 2 are done, an application team needs only a claim of class `ipsec-nas-csi` in its own namespace:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <claim name>
  namespace: <your namespace>
spec:
  accessModes:
  - ReadWriteMany            # NFS: many pods on many nodes may mount it
  storageClassName: ipsec-nas-csi
  resources:
    requests:
      storage: 10Gi          # recorded on the volume; the NAS decides the real limit
```

and a volume in the pod that names it:

```yaml
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: <claim name>
```

What the team gets: a directory `csi/<namespace>/<claim name>` on the NAS, writable by its pods under `restricted-v2`, reached only through the tunnel. Things to know:

- **The size is not a quota.** NFS has no per-directory limit here; ask the storage team for quotas if they matter.
- **The name is the directory.** Deleting a claim (and its volume) and creating one with the same name in the same namespace gives a new volume on the **same** directory, with the old data still in it (`Retain`; measured).
- **Pods write with the pod's user ID**, through the directory's group: the anonymous group, which `root_squash` also gives the pod's group 0 ([Step 3.3](#step-33--see-the-data-on-the-nas-and-prove-it-used-the-tunnel)). If the NAS maps users differently and writes fail, see [Troubleshooting](#troubleshooting).

---

## When a claim is deleted

`reclaimPolicy: Retain` (measured with a throwaway claim):

| You do | What happens |
|---|---|
| `oc delete pvc <claim> -n <namespace>` | The PersistentVolume becomes `Released`. The directory and its data stay on the NAS. |
| `oc delete pv <pv name>` | The PersistentVolume is gone. The directory and its data **still** stay on the NAS; the driver is not asked to delete anything. |
| Delete the data | On the NAS, by the storage team: `rm -r ${NAS_EXPORT}/csi/<namespace>/<claim>` |

With `reclaimPolicy: Delete` instead (measured with a separate class), deleting the claim makes the driver remove the claim's directory **and its data**, then every parent directory left empty. Use it only where losing the data with the claim is intended.

---

## Remove everything

```bash
# the demo
oc delete -f rendered/demo-app-csi/54-route.yaml -f rendered/demo-app-csi/53-app.yaml -f rendered/demo-app-csi/52-pvc.yaml
oc get pv -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName,STATUS:.status.phase | grep ipsec-nas-csi
oc delete pv <each Released volume of class ipsec-nas-csi>
oc delete -f rendered/demo-app-csi/50-namespace.yaml

# the StorageClass, then the driver (only when no volume of class ipsec-nas-csi is left)
oc delete -f rendered/demo-app-csi/51-storageclass.yaml
helm uninstall csi-driver-nfs --namespace csi-driver-nfs --wait
oc adm policy remove-scc-from-user privileged -z csi-nfs-controller-sa -n csi-driver-nfs
oc adm policy remove-scc-from-user privileged -z csi-nfs-node-sa -n csi-driver-nfs
oc delete namespace csi-driver-nfs
```

The data stays on the NAS under `${NAS_EXPORT}/csi/`; the storage team deletes it if it is no longer wanted.

---

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Claim `Pending`, event `failed to make subdirectory: mkdir …: permission denied` | The anonymous user cannot create the directory: the parent belongs to someone else, or the export's top directory is not writable for it | `oc describe pvc <claim> -n <namespace>`; keep the `csi/` parent in `subDir`; ask the storage team to make the top directory (or `csi`) writable for the anonymous user |
| Claim `Pending`, the controller log shows a mount that timed out | The controller's node has no working tunnel, so the NAS drops its NFS | `oc logs -n csi-driver-nfs deploy/csi-nfs-controller -c nfs --tail=30`; `oc get pod -n csi-driver-nfs -l app=csi-nfs-controller -o wide`; on that node `ipsec trafficstatus` |
| Pod stuck in `ContainerCreating`, `oc describe pod` shows a mount that timed out | The pod's node has no working tunnel | On that node: `oc debug node/<node> -- chroot /host ipsec trafficstatus`. No `ipsec-nas` line means the tunnel is down; go to the setup docs' troubleshooting |
| No driver pods, or fewer than expected | The SCC grants of Step 1.2 are missing (not measured: Step 1.2 was always run first) | `oc get events -n csi-driver-nfs`; run Step 1.2, then `oc rollout restart` the controller Deployment and the node DaemonSet in `csi-driver-nfs` |
| Pod `Running` but writes fail with `Permission denied` | The NAS maps users or groups differently from the lab's `root_squash` (anonymous 65534) | Add `mountPermissions: "0777"` to the class's `parameters` (a new class: parameters cannot be changed). Measured: the claim's directory becomes `2777` and a `restricted-v2` pod writes |

---

## References

- kubernetes-csi: [csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs), its [chart](https://github.com/kubernetes-csi/csi-driver-nfs/tree/master/charts) and its [StorageClass parameters](https://github.com/kubernetes-csi/csi-driver-nfs/blob/master/docs/driver-parameters.md) (`subDir`, `mountPermissions`, `onDelete`)
- [Connecting OpenShift to NFS storage with csi-driver-nfs](https://hackmd.io/@johnsimcall/BJeW2Y5mT) (a community guide): the `privileged` SCC for `csi-nfs-controller-sa` and `csi-nfs-node-sa` in a namespace of its own
- `exports(5)`: `root_squash` maps requests from uid/gid 0 to the anonymous uid/gid
