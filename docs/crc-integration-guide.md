# CRC Integration Guide — OpenShift Local to a NAS on the Same Mac

**Team:** KCS OpenShift  **Audience:** junior/new platform engineers  **Purpose:** connect a real OpenShift node (OpenShift Local, "CRC") to the test NAS, so the main guide can be exercised end to end on a laptop

The Lima lab ([`lab-lima-guide.md`](lab-lima-guide.md)) proves the NAS side with stand-in workers. This guide goes one step further and connects the **CRC cluster** on the same Mac to a NAS VM. CRC differs from a production cluster in ways that change a few settings, and this guide records each difference and why.

## Where this stands

| Part | What | Status on 2026-10-02 |
|---|---|---|
| A | Measure the network path from the CRC node to a Lima VM | **Done**, measured |
| B | A NAS VM that CRC can reach, and a tunnel that works through the NAT in between | **Done**, measured with a stand-in VM behind the same kind of NAT |
| C | The NAS side for CRC: a NAS certificate signed by the cluster's enterprise CA, and the NAS configured for the CRC node | **Done**, measured |
| D | Change the CRC cluster (IPsec mode, NMState, node certificates, NNCP) and run the demo app | **Not run yet**, with one exception: the NMState Operator subscription is applied, and its result is not confirmed yet. The cluster's network settings are unchanged. |

Everything in Parts A to C was run and the outputs shown are real. Part D is a plan: it will be filled in with measured output as each step is run.

---

## How CRC differs from the cluster the main guide targets

| | Main guide (production cluster) | CRC on this Mac (measured) |
|---|---|---|
| Nodes | Many workers in the `worker` pool | One node, `crc`, with roles `control-plane,master,worker`, in the **`master`** MachineConfigPool. The `worker` pool has 0 machines. |
| Path to the NAS | Routed, no NAT | **Through NAT.** The node's packets leave through the Mac and reach the NAS from `192.168.64.1`. |
| IPsec mode on the tunnel | `transport`, bare ESP | **`tunnel`**, ESP wrapped in UDP 4500. Transport mode is refused behind NAT (Part B). |
| The node's address toward the NAS | `<node>.<NODE_DOMAIN>` resolves to it | `192.168.127.2`. No `crc.<domain>` name resolves to it, so the NNCP uses `left: '%defaultroute'`. The node's other address, `192.168.126.11`, cannot reach the NAS. |
| Enterprise CA issuer | The placeholder `company-issuer-rnd` stands for yours | `enterprise-ca`, a root CA valid to 2031 |
| IPsec today | – | `ipsecConfig.mode: Disabled`, `routingViaHost: false`, libreswan not installed on the node, no `NMState` instance |
| Kyverno, cert-manager | Installed by the guide | Already installed (Kyverno chart 3.9.1, cert-manager running) |

> [!IMPORTANT]
> Tunnel mode and `%defaultroute` are **CRC-only** settings, forced by the NAT. A production cluster on a routed network keeps the main guide's transport mode, which the Lima lab measured with bare ESP.

---

## Part A – Measure the path from the CRC node

### Step A.1 – Create the NAS VM for CRC

The lab's `lab-nas` sits on a network CRC cannot reach. This VM gets a second network, `vzNAT`, which puts it on the Mac's own bridge (`192.168.64.0/24`). The lab VMs are not touched.

```bash
limactl create --name=crc-nas --tty=false lab/lima/stream10-vznat.yaml
limactl start crc-nas --tty=false
limactl shell crc-nas ip -4 -br addr

NAS_IP="$(limactl shell crc-nas ip -4 -br addr | awk '$3 ~ /^192\.168\.64\./ {split($3,a,"/"); print a[1]}')"
echo "NAS_IP=${NAS_IP}"
```

✅ **Expected** (measured): two interfaces, and `NAS_IP` is the `192.168.64.x` one.

```text
eth0             UP             192.168.104.8/24
lima1            UP             192.168.64.8/24
NAS_IP=192.168.64.8
```

### Step A.2 – Check that the CRC node reaches it

`oc debug node` starts a temporary pod on the node and removes it when the command ends.

```bash
oc debug node/crc -q -- chroot /host bash -c "ip route get ${NAS_IP} | head -1; curl -s -m 4 --interface 192.168.127.2 telnet://${NAS_IP}:22 </dev/null | head -c 20; echo"
```

✅ **Expected** (measured): the route leaves through `br-ex` from `192.168.127.2`, and the NAS answers with its SSH banner.

```text
192.168.64.8 via 192.168.127.1 dev br-ex src 192.168.127.2 uid 0
SSH-2.0-OpenSSH_9.9
```

Also measured, with a packet capture on the NAS VM while the node sent one UDP packet to each IKE port: both arrived, **from `192.168.64.1`** with a changed source port. That is the NAT.

```text
IP 192.168.64.1.56670 > 192.168.64.6.ipsec-nat-t: UDP-encap:  [|esp]
IP 192.168.64.1.58166 > 192.168.64.6.isakmp:  [|isakmp]
```

---

## Part B – A tunnel that works through the NAT

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/crc-nat/nat-tunnel-mode.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="diagrams/crc-nat/nat-tunnel-mode.light.png">
  <img alt="Behind NAT, the NAS refuses an IKEv2 transport-mode tunnel with TS_UNACCEPTABLE because the client proposes its own private address while the NAS sees the NAT's address. In tunnel mode the same client gets a tunnel, with ESP wrapped in UDP port 4500, and NFS arrives at the NAS from the client's own address." src="diagrams/crc-nat/nat-tunnel-mode.light.png">
</picture>

*Figure 1. Behind NAT, the NAS refuses a transport-mode tunnel because the client proposes an address the NAS never sees. Tunnel mode works through the same NAT, with ESP wrapped in UDP 4500. Measured with a stand-in VM; the CRC node's own tunnel (dashed) is proposed, not built.*

```text
CLIENT (behind NAT)                    NAT (on the Mac)                        NAS VM (192.168.64.8)

Transport mode, as in the guide   -->  source rewritten to 192.168.64.1   -->  REFUSED: TS_UNACCEPTABLE
  IKEv2 proposes the client's own       IKE notices the NAT, moves to           the selector names an address
  address as the traffic selector       UDP 4500; the IKE login succeeds        the NAS does not see

Tunnel mode                       <->  ESP wrapped in UDP 4500            <->  ACCEPTED: the tunnel is up
  selector: client/32 to NAS/32         forwarded like any UDP flow             NFS arrives from the client's
  rest of the NNCP unchanged            (bare ESP would not pass)               own address; write check passed

Proposed, not built yet: the same tunnel-mode connection for the CRC node (192.168.127.2).
```

### What was measured

A stand-in VM on Lima's default network leaves through the Mac the same way the CRC node does: the NAS saw it as `192.168.64.1`.

**Transport mode, the main guide's setting.** The IKE login succeeded, then every attempt to build the tunnel was refused. From the NAS's log:

```text
"workers"[1] 192.168.64.1 #5: Child SA's Traffic Selector request {TSi=192.168.5.15/32;TSr=192.168.64.7/32} does not match any IKEv2 connection; responding with TS_UNACCEPTABLE
```

The client proposed its own address (`192.168.5.15`). The NAS only knows the peer as `192.168.64.1`, so nothing matches.

**Tunnel mode.** The same client, with `type=tunnel` and the NAS told the client's own address:

```text
"ipsec-nas" #2: initiator established Child SA using #1; IPsec tunnel [192.168.5.15/32===192.168.64.8/32] {ESPinUDP/ESN=>0x2f836478 <0xdf91b36d xfrm=AES_GCM_16_256 NATD=192.168.64.8:4500 ...
tunnel outBytes: before=4796 after=5467548 grew=5462752 (wrote 5242880)
  	proto esp spi 0x2f836478 reqid 16389 mode tunnel
  	encap type espinudp sport 4500 dport 4500 addr 0.0.0.0
PASS: 5 MiB written to /mnt/nas/verify-lima-nat-worker.bin went through the IPsec tunnel
```

On the wire at the NAS there was only UDP 4500 carrying ESP, and the NAS counted the NFS as arriving through IPsec from the client's own address:

```text
IP 192.168.64.1.60824 > 192.168.64.8.ipsec-nat-t: UDP-encap: ESP(spi=0x2f836478,seq=0xef6)
ip saddr 192.168.5.15 tcp dport 2049 meta ipsec exists counter packets 565 bytes 5281240 accept
tcp dport 2049 counter packets 0 bytes 0 drop comment "nfs-cleartext-dropped"
```

### Step B.1 – Rehearse it with a stand-in (optional, changes nothing on CRC)

This repeats the measurement above with the repository's scripts. `192.168.5.15` is the address every VM gets on Lima's default network.

```bash
limactl create --name=nat-worker --vm-type=vz --plain --cpus=2 --memory=2 --disk=10 --tty=false template:centos-stream-10
limactl start nat-worker --tty=false
for vm in crc-nas nat-worker; do limactl copy -r lab "${vm}:/tmp/lab"; done

# throwaway certificates, made on the NAS VM
limactl shell crc-nas sudo dnf -y -q install openssl
limactl shell crc-nas /tmp/lab/pki/make-test-pki.sh /tmp/pki crc-nas.lab.internal nat-worker.lab.internal
limactl shell crc-nas sudo install -D -m 0644 -t /root/ipsec-pki /tmp/pki/ca.pem /tmp/pki/nas.p12
limactl copy crc-nas:/tmp/pki/ca.pem nat-worker:/tmp/ca.pem
limactl copy crc-nas:/tmp/pki/nat-worker.lab.internal.p12 nat-worker:/tmp/left_server.p12
limactl shell nat-worker sudo install -D -m 0644 -t /root/ipsec-pki /tmp/ca.pem /tmp/left_server.p12

# the NAS: IKE arrives from the Mac's bridge network; ONE client behind NAT has the address 192.168.5.15
limactl shell crc-nas sudo WORKER_SUBNET=192.168.64.0/24 NAS_LEFT="${NAS_IP}" NAT_CLIENT=192.168.5.15 bash /tmp/lab/rhel/setup-nas.sh

# the stand-in: no shared DNS on this path, so the two names go in /etc/hosts
limactl shell nat-worker sudo bash -c "echo '${NAS_IP} crc-nas.lab.internal' >> /etc/hosts; echo '192.168.5.15 nat-worker.lab.internal' >> /etc/hosts"
limactl shell nat-worker sudo WORKER_FQDN=nat-worker.lab.internal NAS_FQDN=crc-nas.lab.internal NAS_IP="${NAS_IP}" IPSEC_TYPE=tunnel bash /tmp/lab/rhel/setup-worker.sh
limactl shell nat-worker sudo bash /tmp/lab/rhel/verify-worker.sh
```

✅ **Expected** (measured): `Worker ready: ...`, then `mode tunnel`, `encap type espinudp sport 4500 dport 4500` and a `PASS` line.

What the two script switches do:

| Switch | Script | Effect |
|---|---|---|
| `NAT_CLIENT=<address>` | `setup-nas.sh` | Builds the NAS connection in tunnel mode for that one client, and accepts and exports NFS to that address. `NAS_LEFT` must be the NAS IP. |
| `IPSEC_TYPE=tunnel` | `setup-worker.sh` | Uses `type=tunnel` in the stand-in's connection. Default `transport`. |

Delete the stand-in when done: `limactl stop nat-worker && limactl delete nat-worker`.

---

## Part C – The NAS side for CRC

In production the storage team owns the NAS certificate (main guide, [3.1](ipsec-nas-guide.md#31-nas-configuration-storage-team-not-us)). On a laptop we play both roles, and we keep the same rule: **the NAS private key is made on the NAS and never leaves it.** Only the CSR (a public file) goes to the cluster, where the existing enterprise CA issuer signs it through a cert-manager `CertificateRequest`. No issuer is created.

On the cluster this part creates one namespace and one `CertificateRequest`. It does not touch the cluster's network.

### Step C.1 – Create the key and the CSR on the NAS

```bash
limactl shell crc-nas sudo NAS_IP="${NAS_IP}" bash -c '
set -euo pipefail
umask 077
mkdir -p /root/ipsec-pki-crc && cd /root/ipsec-pki-crc
openssl req -new -newkey rsa:3072 -nodes -keyout nas.key -out nas.csr \
  -subj "/O=KCS OpenShift lab/CN=crc-nas.lab.internal" \
  -addext "subjectAltName=DNS:crc-nas.lab.internal,IP:${NAS_IP}" 2>/dev/null
openssl req -in nas.csr -noout -verify -subject
openssl req -in nas.csr -noout -text | grep -A1 "Subject Alternative Name"
install -m 0644 nas.csr /tmp/crc-nas.csr
'
limactl copy crc-nas:/tmp/crc-nas.csr crc-nas.csr
```

✅ **Expected** (measured):

```text
Certificate request self-signature verify OK
subject=O=KCS OpenShift lab, CN=crc-nas.lab.internal
                X509v3 Subject Alternative Name:
                    DNS:crc-nas.lab.internal, IP Address:192.168.64.8
```

The repository's `.gitignore` already excludes `*.csr`, `*.crt` and `*.pem`, so the files this part leaves in your working directory cannot be committed by accident.

### Step C.2 – Have the cluster's enterprise CA sign it

The namespace is the one the main guide creates in Step B.2. `duration: 2160h` asks for 90 days.

```bash
oc apply -f manifests/option-b-per-node-certs/20-namespace.yaml

cat <<EOF > nas-certificaterequest.yaml
apiVersion: cert-manager.io/v1
kind: CertificateRequest
metadata:
  name: crc-nas
  namespace: kcs-ipsec
spec:
  request: $(base64 < crc-nas.csr | tr -d '\n')
  duration: 2160h
  isCA: false
  usages:
  - digital signature
  - key encipherment
  - server auth
  - client auth
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: enterprise-ca
EOF

oc apply -f nas-certificaterequest.yaml
oc wait -n kcs-ipsec certificaterequest/crc-nas --for=condition=Ready --timeout=60s
oc get certificaterequest -n kcs-ipsec crc-nas -o wide
```

✅ **Expected** (measured):

```text
namespace/kcs-ipsec created
certificaterequest.cert-manager.io/crc-nas created
certificaterequest.cert-manager.io/crc-nas condition met
NAME      APPROVED   DENIED   READY   ISSUER          REQUESTER   STATUS                                         AGE
crc-nas   True                True    enterprise-ca   kubeadmin   Certificate fetched from issuer successfully   0s
```

### Step C.3 – Fetch the certificate and check it

The signed certificate and the CA's own certificate are both in the request's status. Neither is secret.

```bash
oc get certificaterequest -n kcs-ipsec crc-nas -o jsonpath='{.status.certificate}' | base64 -d > crc-nas.crt
oc get certificaterequest -n kcs-ipsec crc-nas -o jsonpath='{.status.ca}' | base64 -d > enterprise-root.pem

openssl x509 -in crc-nas.crt -noout -subject -issuer -dates -ext subjectAltName,keyUsage,extendedKeyUsage,basicConstraints
openssl verify -CAfile enterprise-root.pem crc-nas.crt
```

✅ **Expected** (measured):

```text
subject=O=KCS OpenShift lab, CN=crc-nas.lab.internal
issuer=O=Enterprise POC, CN=Enterprise Root CA
notBefore=Oct  2 20:35:41 2026 GMT
notAfter=Dec 31 20:35:41 2026 GMT
X509v3 Key Usage: critical
    Digital Signature, Key Encipherment
X509v3 Extended Key Usage:
    TLS Web Server Authentication, TLS Web Client Authentication
X509v3 Basic Constraints: critical
    CA:FALSE
X509v3 Subject Alternative Name:
    DNS:crc-nas.lab.internal, IP Address:192.168.64.8
crc-nas.crt: OK
```

> [!NOTE]
> A `CertificateRequest` is signed once and is not renewed. Before `notAfter`, repeat Steps C.1 to C.4 with a new request name.

### Step C.4 – Install it on the NAS and configure the NAS for the CRC node

First bundle the certificate with the key that stayed on the NAS:

```bash
limactl copy crc-nas.crt crc-nas:/tmp/crc-nas.crt
limactl copy enterprise-root.pem crc-nas:/tmp/enterprise-root.pem
limactl shell crc-nas sudo bash -c '
set -euo pipefail
cd /root/ipsec-pki-crc
install -m 0644 /tmp/enterprise-root.pem ca.pem
install -m 0644 /tmp/crc-nas.crt nas.crt
# the certificate must belong to the key that never left this host
[[ "$(openssl x509 -in nas.crt -noout -pubkey | sha256sum)" == "$(openssl pkey -in nas.key -pubout | sha256sum)" ]] && echo "certificate matches the private key"
openssl verify -CAfile ca.pem nas.crt
openssl pkcs12 -export -in nas.crt -inkey nas.key -name nas -out nas.p12 -passout pass:
chmod 0600 nas.p12
'
```

✅ **Expected** (measured): `certificate matches the private key`, then `nas.crt: OK`.

Then configure the NAS. The two `certutil` lines are only needed if you ran the rehearsal in Step B.1: they remove its throwaway certificates, which use the same nicknames. `NAT_CLIENT` is now the CRC node's own address.

```bash
limactl copy -r lab crc-nas:/tmp/lab
limactl shell crc-nas sudo bash -c '
set -euo pipefail
systemctl stop ipsec
certutil -F -n nas -d /var/lib/ipsec/nss     # rehearsal certificate and its key
certutil -D -n CA  -d /var/lib/ipsec/nss     # rehearsal CA
PKI_DIR=/root/ipsec-pki-crc WORKER_SUBNET=192.168.64.0/24 NAS_LEFT=192.168.64.8 NAT_CLIENT=192.168.127.2 bash /tmp/lab/rhel/setup-nas.sh
certutil -L -n nas -d /var/lib/ipsec/nss | grep -E "Subject:|Issuer:|Not After"
'
```

✅ **Expected** (measured, shortened): the connection is loaded with the NAS's new identity and the CRC node's address, NFS is exported to that one address, and the certificate in the NSS database is the one from the enterprise CA.

```text
"workers": 192.168.64.8[O=KCS OpenShift lab, CN=crc-nas.lab.internal]...%any[%fromcert]===192.168.127.2/32; unrouted; my_ip=unset; their_ip=unset;
		ip saddr 192.168.127.2 tcp dport 2049 meta ipsec exists counter packets 0 bytes 0 accept comment "nfs-over-ipsec"
		tcp dport 2049 counter packets 0 bytes 0 drop comment "nfs-cleartext-dropped"
/export       	192.168.127.2(sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,root_squash,no_all_squash)
NAS ready: lima-crc-nas exports /export to 192.168.127.2, IPsec only.
        Issuer: "CN=Enterprise Root CA,O=Enterprise POC"
            Not After : Thu Dec 31 20:35:41 2026
        Subject: "CN=crc-nas.lab.internal,O=KCS OpenShift lab"
```

### Step C.5 – Confirm the NAS refuses NFS without IPsec

The node has no tunnel yet, so this is NFS in cleartext. It must fail.

```bash
oc debug node/crc -q -- chroot /host bash -c 'ip route show default; curl -s -m 4 --interface 192.168.127.2 telnet://192.168.64.8:2049 </dev/null; echo "curl exit code: $?"'
limactl shell crc-nas sudo nft list table inet nas_ipsec_only | grep counter
```

✅ **Expected** (measured): `curl` gives up after 4 seconds (exit code 28 is a timeout), and the NAS counted the packets on its drop rule.

```text
default via 192.168.127.1 dev br-ex proto dhcp src 192.168.127.2 metric 48
curl exit code: 28
		ip saddr 192.168.64.0/24 udp dport { 500, 4500 } counter packets 0 bytes 0 accept comment "ike"
		ip saddr 192.168.64.0/24 meta l4proto esp counter packets 0 bytes 0 accept comment "esp-in"
		ip saddr 192.168.127.2 tcp dport 2049 meta ipsec exists counter packets 0 bytes 0 accept comment "nfs-over-ipsec"
		tcp dport 2049 counter packets 6 bytes 384 drop comment "nfs-cleartext-dropped"
```

The first line also shows that the node's default route leaves through `br-ex` from `192.168.127.2`. That is the address `left: '%defaultroute'` will pick in the NNCP, and the one the NAS now expects.

---

## Part D – Change the CRC cluster (prepared; only the first command of Step D.3 has been run)

> [!WARNING]
> These steps change cluster-wide network settings on CRC and **reboot its only node** at least once. While the node reboots, everything on CRC is down for several minutes. If an OS-level change fails on a single-node cluster, CRC may need to be rebuilt.

The baseline before any change was recorded on 2026-10-02: OpenShift 4.22.7, all cluster operators healthy, the `master` pool updated, 196 pods, none failing.

### Step D.1 – Enable `routingViaHost` (main guide, Step 1.3)

```bash
oc patch networks.operator.openshift.io cluster --type=merge -p \
'{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'

oc get pods -n openshift-ovn-kubernetes -w     # wait until the ovnkube-node pod is Running again, then Ctrl+C
oc get co network                              # AVAILABLE=True, PROGRESSING=False, DEGRADED=False
```

### Step D.2 – Enable IPsec in `External` mode (main guide, Step 1.4)

This installs libreswan on the node through a MachineConfig and reboots it.

```bash
oc patch networks.operator.openshift.io cluster --type=merge -p \
'{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"ipsecConfig":{"mode":"External"}}}}}'

oc get mc | grep ipsec           # 80-ipsec-master-extensions appears
watch oc get mcp master          # wait for UPDATED=True, UPDATING=False, DEGRADED=False
oc debug node/crc -q -- chroot /host rpm -q libreswan
```

### Step D.3 – NMState Operator and instance (main guide, Step 1.5)

The subscription was applied on 2026-10-02. CRC's `redhat-operators` catalog offers the package in the `stable` channel (`kubernetes-nmstate-operator.4.22.0-202609230131`).

```bash
oc apply -f manifests/common/01-nmstate-operator.yaml
```

```text
namespace/openshift-nmstate created
operatorgroup.operators.coreos.com/openshift-nmstate created
subscription.operators.coreos.com/kubernetes-nmstate-operator created
```

**Not confirmed yet:** that the operator reached `Succeeded`. Check it, and only then create the instance:

```bash
oc get csv -n openshift-nmstate | grep -i -E 'NAME|nmstate'    # PHASE must be Succeeded
oc apply -f manifests/common/02-nmstate-instance.yaml
oc get pods -n openshift-nmstate                               # an nmstate-handler pod, Running
```

### What follows, in order

Each of these will be written up with its measured output when it is run.

1. **Kyverno RBAC** (main guide, Step 1.7). Kyverno itself is already installed.
2. **Option A, documented and then removed**: the shared certificate through a MachineConfig. On CRC the MachineConfig role is `master`, not `worker`, and it reboots the node again. Record the installation, verify the tunnel, then clean it off the cluster.
3. **Option B, the standard**: per-node certificate from `enterprise-ca`, the cert-sync DaemonSet, and the NNCP with the CRC settings (`type: tunnel`, `left: '%defaultroute'`, `right: ${NAS_IP}`).
4. **The demo application** from [`nas-consumer-app-guide.md`](nas-consumer-app-guide.md), with its Route.

To undo Steps D.1 and D.2: set `ipsecConfig.mode` back to `Disabled` (the node reboots again) and `routingViaHost` back to `false`.

---

## Diagram sources

Figure 1 is rendered from `docs/diagrams/crc-nat/source.html` by `docs/diagrams/render.py` (see the main guide's [Diagram sources](ipsec-nas-guide.md#diagram-sources)):

```bash
python3 docs/diagrams/render.py docs/diagrams/crc-nat/source.html docs/diagrams/crc-nat nat-tunnel-mode
```

The Mermaid text version is `docs/diagrams/mermaid/nat-tunnel-mode.mmd`; it is not what this document displays. The dashed box in the figure marks the part that is proposed and not built; redraw it solid once the CRC node's tunnel is measured.
