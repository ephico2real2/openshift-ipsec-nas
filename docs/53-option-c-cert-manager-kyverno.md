# Option C with cert-manager and Kyverno — the Shared Wildcard Certificate, Automated

**Audience:** platform engineers. **Before this:** [50-option-c-wildcard-certificate.md](50-option-c-wildcard-certificate.md), which explains Option C and its manual steps, and [00-prepare-the-cluster.md](00-prepare-the-cluster.md), Parts 0 and 1.

This is Option C done with the tools Option B already uses. **cert-manager** issues the shared wildcard certificate, **Kyverno** makes each node's tunnel definition (C2), and one Helm chart, [`charts/ipsec-nas-option-c-metrics`](../charts/ipsec-nas-option-c-metrics/README.md), carries both, beside Option C's metrics. The chart uses Option B's value names and checks. One step stays deliberate: the MachineConfig, built from the certificate by a script.

**Contents:** [What works](#what-works-the-shared-wildcard-san-with-uniqueidsno) · [What does what](#what-does-what) · [Step K.1 – Prerequisites](#step-k1--what-must-already-be-on-the-cluster) · [K.2 – The certificate](#step-k2--the-certificate-from-cert-manager) · [K.3 – The MachineConfig](#step-k3--each-pools-machineconfig-from-the-certificate) · [K.4 – The tunnel](#step-k4--the-tunnel-from-kyverno) · [K.5 – Renewal](#step-k5--renewal) · [K.6 – Removal](#step-k6--removal) · [Measured](#measured-on-openshift-local-crc) · [Gotchas](#gotchas)

## What works: the shared wildcard SAN with `uniqueids=no`

One certificate for `*.<NODE_DOMAIN>` on every node works only if the NAS lets several peers present the same identity at once. Measured in the Lima lab with two stand-in workers sharing one wildcard certificate ([doc 51](51-option-c-summary.md), [evidence 34](evidence/crc/34-option-c-lab-identities.txt)):

| NAS `uniqueids` | NAS `rightid` | C1 (the certificate's DN) | C2 (each node's own name, by Kyverno) |
|---|---|---|---|
| `yes` (the default) | `%fromcert` | one tunnel at a time: the nodes step on each other's tunnel | the same |
| **`no`** | **`%fromcert`** | **2 tunnels, both NFS writes pass** | **2 tunnels, both NFS writes pass** |

This document builds **C2**, the Kyverno design. With `rightid=%fromcert` the NAS still identifies every node by the certificate's DN, so C2's per-node names do not give the NAS one identity per node. What Kyverno adds is one NNCP per node, made automatically for every node of the pool, new nodes included, each with its own `left` address. C1 (`tunnel.variant: c1`) needs no Kyverno and works with the same NAS settings.

## What does what

| Part | Made by | Notes |
|---|---|---|
| The wildcard certificate | **cert-manager**, from the chart (`certificate.enabled`) | A `Certificate` for `*.<nodeDomain>`, `CN=ocp-ipsec-workers, O=KCS`, RSA 3072, server and client auth, 2 years, from the enterprise CA's existing `ClusterIssuer`. Key and certificate in a Secret |
| Each pool's MachineConfig | **You**, with `scripts/option-c-certificate.sh from-secret` | Built from the Secret with every check of the manual path; `99-worker-…` and `99-master-…`. Applying it reboots the pool once |
| The tunnel | **Kyverno**, from the chart (`tunnel.enabled`, `variant: c2`) | A `GeneratingPolicy` per pool, `ipsec-nncp-wildcard-<pool>`, making NNCP `ipsec-nas-<node>` for each node. The worker pool's leaves out control-plane and master nodes |
| Metrics, alerts, dashboard | The same chart, on by default | [doc 50, *Monitoring, optional*](50-option-c-wildcard-certificate.md#monitoring-optional) |

**Why the chart does not make the MachineConfig.** A MachineConfig holds its files as fixed content, so it must contain the certificate and the private key when it is created, while cert-manager issues them only after the chart is installed. Helm could read the Secret on a later upgrade, but Argo CD renders without a cluster connection, where `lookup` returns nothing. And cert-manager renews by itself: a MachineConfig that followed each renewal would reboot every pool, unplanned. So the MachineConfig, with its key and its reboot, stays a step someone takes.

## Step K.1 – What must already be on the cluster

| Prerequisite | Why | Checked by the chart |
|---|---|---|
| **The NAS:** `uniqueids=no` and `rightid=%fromcert`, the enterprise CA trusted, the node subnets as peers, cleartext NFS refused | The shared wildcard identity ([above](#what-works-the-shared-wildcard-san-with-uniqueidsno)); the NAS team's handout is [doc 52](52-option-c-nas-team.md) | No |
| **cert-manager**, with the enterprise CA's `ClusterIssuer` | Issues the certificate | `cert-manager.io/v1` served; the `ClusterIssuer` exists |
| **Kyverno 1.19 or later**, not filtering out Nodes | Makes the NNCPs (C2) | `policies.kyverno.io/v1` served; `[Node,*,*]` not in its `resourceFilters` |
| **NMState Operator** with an `NMState` instance, and `routingViaHost` and IPsec `External` mode | Builds the tunnel on each node | `nmstate.io/v1` served |
| The namespace with the privileged pod-security labels | The metrics collector | No |
| For the metrics: user workload monitoring and its settings | [doc 60, *The cluster settings*](60-monitoring-per-node.md#the-cluster-settings-user-workload-monitoring-config) | No |

`prerequisites.skipCheck=true` skips the chart's checks, for rendering without a cluster, as in Option B's chart.

## Step K.2 – The certificate, from cert-manager

```bash
cat <<'EOF' > my-values.yaml
nodeDomain: ocp.example.com           # the certificate is for *.ocp.example.com
nas:
  fqdn: nas01.example.com
  ip: 10.0.0.50
clusterIssuer: company-issuer-rnd     # the EXISTING enterprise CA issuer: oc get clusterissuer
certificate:
  enabled: true
EOF
helm install ipsec-nas-metrics charts/ipsec-nas-option-c-metrics -n kcs-ipsec -f my-values.yaml
oc wait --for=condition=Ready certificate/ipsec-nas-wildcard -n kcs-ipsec --timeout=5m
oc get secret ipsec-nas-wildcard -n kcs-ipsec -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -ext subjectAltName -enddate
```

✅ **Expected** (measured on CRC): `Ready`; `subject=O=KCS, CN=ocp-ipsec-workers`, `DNS:*.<nodeDomain>`, `notAfter` two years ahead.

## Step K.3 – Each pool's MachineConfig, from the certificate

For each pool that reaches the NAS, `worker` and `master`, in a new directory outside Git. The enterprise root CA is the one the NAS trusts; with a CA `ClusterIssuer` it is also the Secret's `ca.crt`.

```bash
for pool in worker master; do
  MCP_ROLE=${pool} NODE_DOMAIN=ocp.example.com \
    scripts/option-c-certificate.sh from-secret ~/ipsec-option-c/2026-${pool} kcs-ipsec/ipsec-nas-wildcard enterprise-root.pem
done
oc apply -f ~/ipsec-option-c/2026-worker/99-worker-ipsec-wildcard-cert.yaml && watch oc get mcp worker
oc apply -f ~/ipsec-option-c/2026-master/99-master-ipsec-wildcard-cert.yaml && watch oc get mcp master
```

`from-secret` copies the Secret's key and certificate into the directory, then runs every check of the manual path ([doc 50, Step C.3](50-option-c-wildcard-certificate.md#step-c3--check-the-certificate-and-build-the-machineconfig)): the SAN, the key, client auth, the chain, 30 days of validity. Every node of each pool reboots once and imports the certificate at boot. The MachineConfig holds the private key: keep it out of Git, and delete the directories once both are applied.

✅ **Expected** (measured on CRC): each check `ok`; after the reboot, the node's `left_server` has the Secret's serial, one entry, and the journal shows `Finished Import the IPsec certificate`.

## Step K.4 – The tunnel, from Kyverno

After the MachineConfigs: the tunnel uses `leftcert: left_server`, the certificate the MachineConfig put on the node.

```bash
helm upgrade ipsec-nas-metrics charts/ipsec-nas-option-c-metrics -n kcs-ipsec -f my-values.yaml \
  --set tunnel.enabled=true --set tunnel.variant=c2 --set 'tunnel.pools={worker,master}'
oc get generatingpolicy | grep ipsec-nncp-wildcard      # one per pool
oc get nncp,nnce | grep ipsec-nas                       # one NNCP per node, Available
oc debug node/<node> -q -- chroot /host bash -c 'ipsec status | grep -o "our id=[^;]*"; ipsec trafficstatus'
```

✅ **Expected** (measured on CRC, master pool): `ipsec-nas-<node>   Available   SuccessfullyConfigured`; `our id=@<node>.<nodeDomain>`; one `type=ESP` line whose `id=` is the NAS's certificate.

On OpenShift Local, which reaches the NAS through NAT, add the lab's overrides `--set ipsec.type=tunnel --set ipsec.left=%defaultroute --set ipsec.right=<NAS IP>` ([doc 40](40-lab-crc-and-nas.md)) and use the master pool only.

## Step K.5 – Renewal

cert-manager renews the Secret 30 days before expiry (`certificate.renewBefore`). **The nodes keep the old certificate until the MachineConfig is rebuilt and applied**: repeat Step K.3 in new directories before the old certificate expires, one pool at a time. The metrics warn on each node 14 days before expiry (`IpsecNasCertificateExpiringSoon`), and after the reboot `ipsec_nas_certificate_not_after_timestamp_seconds` shows the new date and `ipsec_nas_certificate_import_timestamp_seconds` the boot ([doc 50, Step C.6](50-option-c-wildcard-certificate.md#step-c6--renew-every-two-years)).

## Step K.6 – Removal

Remove the tunnel from the nodes first, as [doc 50, Step C.7](50-option-c-wildcard-certificate.md#step-c7--remove-option-c) describes: deleting an NNCP or its policy does not take the tunnel off a node. Then `helm uninstall ipsec-nas-metrics -n kcs-ipsec` (it removes the policy, the Certificate and the metrics; the Secret cert-manager wrote stays until deleted), and delete each pool's MachineConfig.

## Measured on OpenShift Local (CRC)

CRC 4.22.7, one node in the master pool, cert-manager with the `enterprise-ca` `ClusterIssuer`, Kyverno 1.19.1, the lab NAS on `uniqueids=no` and `rightid=%fromcert` ([evidence 51](evidence/crc/51-option-c-cert-manager-kyverno.txt)):

| Step | Result |
|---|---|
| K.2 | The `Certificate` `Ready` within seconds: `O=KCS, CN=ocp-ipsec-workers`, `DNS:*.crc.testing`, server and client auth, until 2028-10-03 |
| K.3 | `from-secret` passed every check and wrote `99-master-ipsec-wildcard-cert.yaml`. After the reboot (and Gotcha 17's stop and start), the node's `left_server` had cert-manager's serial, one entry, imported at 21:48:41; the pool `UPDATED=True`, `DEGRADED=False` |
| K.4 | Kyverno's `ipsec-nas-crc` `Available`; `our id=@crc.crc.testing`; the tunnel back by itself after the reboot, with no NAS restart |
| Metrics | `tunnel_up` 1; expiry 2028-10-03T21:30:03Z and import 21:48:41Z on the node, as the certificate and the journal say; `mode="C"`; no alert; the demo application writing |

The chart's objects are the ones `render.sh` makes, compared object by object for C1 and C2 and each pool (`tests/test-option-c-chart.sh`). The Argo CD path of these parts was not measured; the chart carries Option B's sync waves (Kyverno's roles −2, the Certificate −1, the policies and NNCPs 1).

## Gotchas

### Gotcha 20 – On OpenShift Local, C2 needs `left=%defaultroute`

**What happened.** C2's default `left` is the node's FQDN. On CRC, Kyverno's NNCP went `Degraded` (NMState `VerificationError`), and the tunnel was down for about 10 minutes until the chart was upgraded with `ipsec.left=%defaultroute`. The same class of mistake with C1 (`ipsec.type` and `ipsec.right` left at their defaults) took the tunnel down for 7.5 minutes ([evidence 50](evidence/crc/50-option-c-per-pool.txt)).

**What to do.** On a cluster behind NAT, set all three of the lab's overrides: `ipsec.type=tunnel`, `ipsec.left=%defaultroute`, `ipsec.right=<NAS IP>`.

### Gotcha 21 – Taking over a tunnel object applied by hand

**What happened.** An NNCP of the same name, applied earlier with `oc apply`, made Helm 4 refuse to adopt it.

**What to do.** `helm install` or `helm upgrade` with `--take-ownership --force-conflicts`, once. The spec did not change, so the node did not change either (the NNCP's generation rose only for Helm's labels).

### While the tunnel is down, NFS hangs

The NAS refuses NFS outside IPsec, so a node without its tunnel cannot use the NAS: the demo application's writes stopped for the whole outage, and even reading a file on the volume hung. Check a tunnel from the node (`ipsec trafficstatus`), not through the NFS volume.
