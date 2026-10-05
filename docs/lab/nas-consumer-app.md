# Use the NAS from an Application — Guide

**Team:** KCS OpenShift  **Audience:** junior/new platform engineers  **Purpose:** give an application storage on the NAS, and prove the data travels through IPsec

The setup docs ([`docs/README.md`](../README.md)) build the IPsec tunnel from every worker to the NAS. This guide is the next step: an application that **stores data on the NAS** through a PersistentVolumeClaim, with a small demo app whose web page shows what is on the NAS.

| | |
|---|---|
| Namespace | `ipsec-nas-demo` (never `default`) |
| Method 1 | A static PersistentVolume and PersistentVolumeClaim, plus the demo app and a Route. Manifests: [`manifests/demo-app/`](../../manifests/demo-app/) |
| Method 2 | Dynamic provisioning with the NFS CSI driver (`csi-driver-nfs`): its own guide, [nas-csi-dynamic-provisioning.md](nas-csi-dynamic-provisioning.md) |
| Measured | First the demo app's two containers with podman on a lab worker against the lab NAS (2026-10-02, the output in Step 6); then Method 1 on OpenShift Local (CRC 4.22.7) connected to that NAS through the tunnel ([Step H.6 of doc 20](../20-option-b-per-node-certificates.md#step-h6--an-application-that-stores-its-data-on-the-nas), [evidence 18](../evidence/crc/18-option-b-demo-app.txt)) |

---

## Before you start

- [ ] The setup is finished on this cluster: every worker's NNCE is `Available` and `ipsec trafficstatus` on a worker shows the tunnel: a `type=ESP` line whose `id=` is the NAS's certificate ([verify end to end](../00-prepare-the-cluster.md#32-verify-end-to-end)).
- [ ] You know the NAS IP and the path it exports.
- [ ] You are logged in with `oc` as `cluster-admin`. A PersistentVolume is a cluster-wide object.

### Words you will see

| Term | Meaning |
|---|---|
| **PersistentVolume (PV)** | A cluster-wide object that describes one piece of storage: here, "the NFS share at this IP and path". An administrator creates it. |
| **PersistentVolumeClaim (PVC)** | A request for storage, made inside a namespace. A pod uses the PVC; the PVC is bound to a PV. |
| **StorageClass** | A named kind of storage. With a CSI driver, creating a PVC of that class makes the PV automatically. |
| **CSI driver** | A plug-in that teaches Kubernetes a storage system. `csi-driver-nfs` is the one for NFS. |
| **ReadWriteMany (RWX)** | Many pods, on many nodes, can mount the volume at the same time. NFS supports this. |
| **Route** | The OpenShift object that gives an application a URL. |

### Why a PVC, and not an NFS client inside the container

It is tempting to build an image with `nfs-utils` and run `mount` in the container. Do not: mounting needs a privileged container, and every application would need the NAS address baked in.

With a PVC, the **node** mounts the NFS share and hands the directory to the pod. The container image needs no NFS client and no privileges, and it runs under the default `restricted-v2` SCC. That mount is made from the node's own address, which is exactly the traffic the IPsec tunnel covers.

### Set the variables

```bash
# ---- CHANGE THESE ----
export NAS_IP="10.10.10.50"       # the NAS NFS data IP, the same value as in the setup docs
export NAS_EXPORT="/export"       # the path the NAS exports
# ----------------------
```

> [!IMPORTANT]
> The PersistentVolume uses the NAS **IP**, not its name. The tunnel protects traffic to that one address (`rightsubnet: ${NAS_IP}/32` in the NNCP). A name that resolved to another address of the NAS would send NFS outside the tunnel.

---

## Method 1 – Static PersistentVolume and PersistentVolumeClaim

Use this when an administrator hands out one known share. It needs nothing installed.

### Step 1 – Render the manifests

From the repository root. `render.sh` fills `${NAS_IP}` and `${NAS_EXPORT}` into the template and writes everything to `rendered/`.

```bash
export NODE_DOMAIN="${NODE_DOMAIN:-ocp.example.com}" NAS_FQDN="${NAS_FQDN:-nas01.example.com}" CLUSTER_ISSUER="${CLUSTER_ISSUER:-company-issuer-rnd}"
./render.sh
grep -E 'server:|path:' rendered/demo-app/41-nfs-pv.yaml
```

✅ **Expected:** `server:` shows your NAS IP and `path:` your export path.

### Step 2 – Create the namespace

```bash
oc apply -f rendered/demo-app/40-namespace.yaml
```

### Step 3 – Create the PersistentVolume

```bash
oc apply -f rendered/demo-app/41-nfs-pv.yaml
oc get pv ipsec-nas-demo
```

What the important lines mean:

| Line | Why |
|---|---|
| `capacity: storage: 1Gi` | Advisory only for NFS. The NAS decides the real limit. It is used to match the claim. |
| `accessModes: ReadWriteMany` | Several pods on several nodes may mount it at once. |
| `persistentVolumeReclaimPolicy: Retain` | Deleting the claim never deletes data on the NAS. |
| `claimRef` | Only the claim `nas-data` in `ipsec-nas-demo` may bind this volume. |
| `mountOptions: nfsvers=4.1, hard, noatime` | NFS 4.1; `hard` retries forever instead of giving the application I/O errors; `noatime` saves writes. |
| `nfs.server` / `nfs.path` | The NAS IP and export path. |

✅ **Expected:** `STATUS` is `Available`, with `CLAIM` already showing `ipsec-nas-demo/nas-data`.

### Step 4 – Create the claim

```bash
oc apply -f rendered/demo-app/42-nfs-pvc.yaml
oc get pvc nas-data -n ipsec-nas-demo
```

✅ **Expected:** `STATUS` is `Bound` to volume `ipsec-nas-demo`. If it stays `Pending`, see [Troubleshooting](#troubleshooting).

### Step 5 – Deploy the demo app

One pod with two containers that share the volume:

| Container | What it does |
|---|---|
| `writer` | Every 10 seconds appends a line (time, pod name, node name, counter) to `data.log` on the NAS and rebuilds a small page from the newest 20 lines. |
| `web` | Serves that directory over HTTP on port 8080, read-only. |

```bash
oc apply -f rendered/demo-app/43-app.yaml
oc get pods -n ipsec-nas-demo -w        # wait for 2/2 Running, then Ctrl+C
```

✅ **Expected:** one `nas-demo-...` pod, `2/2 Running`. A pod stuck in `ContainerCreating` means the node could not mount the share; see [Troubleshooting](#troubleshooting).

### Step 6 – Give it a URL

```bash
oc apply -f rendered/demo-app/44-route.yaml
URL="https://$(oc get route nas-demo -n ipsec-nas-demo -o jsonpath='{.spec.host}')"
echo "${URL}"
curl -sk "${URL}/"
```

✅ **Expected:** the page, with a new line every 10 seconds. This is what the two containers produced in the lab test:

```text
<title>NAS demo</title><h1>Data on the NAS</h1>
<p>Written by pod nas-demo-lab-test on node lima-lab-worker1 to the NFS volume. Page built 2026-10-02T19:23:26Z.</p>
<p>3 lines in <a href=data.log>data.log</a>. The newest 20:</p><pre>
2026-10-02T19:23:06Z pod=nas-demo-lab-test node=lima-lab-worker1 line=1
2026-10-02T19:23:16Z pod=nas-demo-lab-test node=lima-lab-worker1 line=2
2026-10-02T19:23:26Z pod=nas-demo-lab-test node=lima-lab-worker1 line=3
</pre>
```

Open `${URL}` in a browser to watch it refresh. `${URL}/data.log` is the raw file.

### Step 7 – See the same data on the NAS, and prove it used the tunnel

On the NAS (ask the storage team, or on the test NAS run it yourself):

```text
ls -lan /export/ipsec-nas-demo
tail -3 /export/ipsec-nas-demo/data.log
```

In the lab test the files were owned by the pod's user ID, and the lines matched the page:

```text
-rw-r--r--. 1 1000680000 65534 216 Oct  2 19:23 data.log
-rw-r--r--. 1 1000680000 65534 529 Oct  2 19:23 index.html
2026-10-02T19:23:26Z pod=nas-demo-lab-test node=lima-lab-worker1 line=3
```

On the cluster, find the node the pod runs on and read its tunnel counters twice, a minute apart:

```bash
NODE="$(oc get pod -n ipsec-nas-demo -l app=nas-demo -o jsonpath='{.items[0].spec.nodeName}')"
oc debug node/${NODE} -- chroot /host ipsec trafficstatus
```

✅ **Expected:** the tunnel's `type=ESP` line (named by a UUID, not `ipsec-nas`), with `outBytes` higher on the second run. The application's writes are what moved it.

### Remove the demo

```bash
oc delete -f rendered/demo-app/44-route.yaml -f rendered/demo-app/43-app.yaml -f rendered/demo-app/42-nfs-pvc.yaml
oc delete -f rendered/demo-app/41-nfs-pv.yaml -f rendered/demo-app/40-namespace.yaml
```

Because of `Retain`, the files stay on the NAS in `${NAS_EXPORT}/ipsec-nas-demo/`. Delete them there if you no longer want them.

✅ **Measured** on CRC, 2026-10-05: the route, deployment, service, claim, volume and namespace deleted; the node no longer mounts the share; `/export/ipsec-nas-demo/data.log` still on the NAS with its last line (`line=1817`).

---

## Method 2 – Dynamic provisioning with the NFS CSI driver

Use this when many applications need their own space on the NAS: install `csi-driver-nfs` once, create the StorageClass `ipsec-nas-csi`, and every claim of that class gets its own directory on the NAS. It has its own step-by-step guide, measured on CRC against the lab NAS: **[nas-csi-dynamic-provisioning.md](nas-csi-dynamic-provisioning.md)**.

---

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| PVC stays `Pending` (Method 1) | The claim and the volume do not match | `oc describe pvc nas-data -n ipsec-nas-demo`; the class name, access mode and `volumeName` must match the PV, and the PV's `claimRef` must name this claim |
| PVC stays `Pending` (Method 2) | See [its guide's troubleshooting](nas-csi-dynamic-provisioning.md#troubleshooting) | |
| Pod stuck in `ContainerCreating`; `oc describe pod` shows a mount that timed out | The node has no working tunnel, so the NAS drops its NFS | On that node: `oc debug node/<node> -- chroot /host ipsec trafficstatus`. No `type=ESP` line with the NAS's `id=` means the tunnel is down; go to the setup docs' troubleshooting |
| Pod is `Running` but `writer` logs `Permission denied` | The export directory is not writable for the pod's user ID | The pod runs with a random user ID. The share (or the sub-directory) must allow it to write, for example mode `0777` on a test share |
| The page shows old data | The `writer` container stopped | `oc logs -n ipsec-nas-demo deploy/nas-demo -c writer --tail=20` |

---

## References

- OneUptime: [How to use NAS storage with Kubernetes](https://oneuptime.com/blog/post/2025-12-15-how-to-use-nas-storage-with-kubernetes/view), methods 1 (static NFS volumes) and 2 (dynamic provisioning with the NFS CSI driver)
- kubernetes-csi: [csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs), set up in [nas-csi-dynamic-provisioning.md](nas-csi-dynamic-provisioning.md)
