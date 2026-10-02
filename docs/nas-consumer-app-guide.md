# Use the NAS from an Application — Guide

**Team:** KCS OpenShift  **Audience:** junior/new platform engineers  **Purpose:** give an application storage on the NAS, and prove the data travels through IPsec

The main guide ([`ipsec-nas-guide.md`](ipsec-nas-guide.md)) builds the IPsec tunnel from every worker to the NAS. This guide is the next step: an application that **stores data on the NAS** through a PersistentVolumeClaim, with a small demo app whose web page shows what is on the NAS.

| | |
|---|---|
| Namespace | `ipsec-nas-demo` (never `default`) |
| Method 1 | A static PersistentVolume and PersistentVolumeClaim, plus the demo app and a Route. Manifests: [`manifests/demo-app/`](../manifests/demo-app/) |
| Method 2 | Dynamic provisioning with the NFS CSI driver (`csi-driver-nfs`), installed with Helm |
| Tested so far | The demo app's two containers, run with podman on a lab worker against the lab NAS on 2026-10-02, with the same commands and the same NFS mount options as the manifests. The OpenShift objects were validated against an OpenShift 4.22.7 API with dry runs. |
| **Not tested yet** | Running it on an OpenShift cluster connected to the NAS. No such cluster exists for this project yet, so every `oc` output below is what the objects should show, not a measurement. |

---

## Before you start

- [ ] The main guide is finished on this cluster: every worker's NNCE is `Available` and `ipsec trafficstatus` on a worker shows the `ipsec-nas` tunnel (main guide, section 3.2).
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
export NAS_IP="10.10.10.50"       # the NAS NFS data IP, the same value as in the main guide
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

✅ **Expected:** the `ipsec-nas` line, with `outBytes` higher on the second run. The application's writes are what moved it.

### Remove the demo

```bash
oc delete -f rendered/demo-app/44-route.yaml -f rendered/demo-app/43-app.yaml -f rendered/demo-app/42-nfs-pvc.yaml
oc delete -f rendered/demo-app/41-nfs-pv.yaml -f rendered/demo-app/40-namespace.yaml
```

Because of `Retain`, the files stay on the NAS in `${NAS_EXPORT}/ipsec-nas-demo/`. Delete them there if you no longer want them.

---

## Method 2 – Dynamic provisioning with the NFS CSI driver

Use this when many applications need their own space on the NAS. Each new PVC gets its own sub-directory on the share, and nobody writes a PersistentVolume by hand.

> [!NOTE]
> This method is **documented, not yet run against this NAS**. The commands follow the upstream chart and the article in [References](#references). The facts marked "on our CRC cluster" were read from a cluster where the driver is already installed for another NFS server.

### Step 1 – Install the driver with Helm

```bash
helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
helm repo update
helm search repo csi-driver-nfs/csi-driver-nfs --versions | head -5

helm install csi-driver-nfs csi-driver-nfs/csi-driver-nfs --namespace kube-system \
  --version 4.13.4 \
  --set controller.replicas=2
```

Verify:

```bash
oc get pods -n kube-system | grep csi-nfs
oc get csidriver nfs.csi.k8s.io
```

✅ **Expected:** `csi-nfs-controller-...` pods and one `csi-nfs-node-...` pod per node, all `Running`.

On our CRC cluster (chart 4.13.4, default values, namespace `kube-system`): the controller and node pods run with `hostNetwork: true`, and no SCC grant was needed.

### Step 2 – Create a StorageClass for the NAS

```bash
cat <<EOF > ipsec-nas-csi-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ipsec-nas-csi
provisioner: nfs.csi.k8s.io
parameters:
  server: ${NAS_IP}                 # the IP the IPsec tunnel protects
  share: ${NAS_EXPORT}
  # one directory per claim: <namespace>/<claim name>
  subDir: \${pvc.metadata.namespace}/\${pvc.metadata.name}
reclaimPolicy: Retain               # deleting a claim keeps its data on the NAS
volumeBindingMode: Immediate
mountOptions:
- nfsvers=4.1
- hard
- noatime
EOF

oc apply -f ipsec-nas-csi-storageclass.yaml
oc get storageclass ipsec-nas-csi
```

> [!NOTE]
> Use a name of your own, such as `ipsec-nas-csi`. A class called `nfs-csi` may already exist for another NFS server; it does on our CRC cluster.

### Step 3 – Ask for storage with a claim

```bash
cat <<'EOF' > dynamic-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-data
  namespace: ipsec-nas-demo
spec:
  accessModes:
  - ReadWriteMany
  storageClassName: ipsec-nas-csi
  resources:
    requests:
      storage: 1Gi
EOF

oc apply -f dynamic-pvc.yaml
oc get pvc app-data -n ipsec-nas-demo
oc get pv | grep app-data
```

✅ **Expected:** the claim becomes `Bound` within seconds and a PersistentVolume named `pvc-<id>` appears. On the NAS there is a new directory `${NAS_EXPORT}/ipsec-nas-demo/app-data`.

To use it in the demo app, change `claimName: nas-data` to `claimName: app-data` in `43-app.yaml`.

### What IPsec changes for the CSI driver

- The **node** pods mount the share for application pods, from the node's own address. That is the traffic the tunnel covers.
- The **controller** pod also mounts the share, to create and delete the per-claim directories. It uses the host network of whichever node it runs on, so **that node needs a tunnel too**. The main guide builds tunnels on worker nodes only; the chart's default keeps the controller off the control plane (`controller.runOnControlPlane: false`), which is what we want. Do not change it.
- If the controller cannot reach the NAS, new claims stay `Pending` while existing volumes keep working.

---

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| PVC stays `Pending` (Method 1) | The claim and the volume do not match | `oc describe pvc nas-data -n ipsec-nas-demo`; the class name, access mode and `volumeName` must match the PV, and the PV's `claimRef` must name this claim |
| PVC stays `Pending` (Method 2) | The CSI controller cannot mount the share | `oc logs -n kube-system deploy/csi-nfs-controller -c nfs --tail=30`; check the tunnel on the node the controller runs on |
| Pod stuck in `ContainerCreating`; `oc describe pod` shows a mount that timed out | The node has no working tunnel, so the NAS drops its NFS | On that node: `oc debug node/<node> -- chroot /host ipsec trafficstatus`. No `ipsec-nas` line means the tunnel is down; go to the main guide's troubleshooting |
| Pod is `Running` but `writer` logs `Permission denied` | The export directory is not writable for the pod's user ID | The pod runs with a random user ID. The share (or the sub-directory) must allow it to write, for example mode `0777` on a test share |
| The page shows old data | The `writer` container stopped | `oc logs -n ipsec-nas-demo deploy/nas-demo -c writer --tail=20` |

---

## References

- OneUptime: [How to use NAS storage with Kubernetes](https://oneuptime.com/blog/post/2025-12-15-how-to-use-nas-storage-with-kubernetes/view), methods 1 (static NFS volumes) and 2 (dynamic provisioning with the NFS CSI driver)
- kubernetes-csi: [csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs)
