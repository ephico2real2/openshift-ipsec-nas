# CRC Integration Guide — OpenShift Local to a NAS on the Same Mac

**Team:** KCS OpenShift  **Audience:** junior/new platform engineers  **Purpose:** connect a real OpenShift node (OpenShift Local, "CRC") to the test NAS, so the main guide can be exercised end to end on a laptop

The Lima lab ([`lab-lima-guide.md`](lab-lima-guide.md)) proves the NAS side with stand-in workers. This guide goes one step further and connects the **CRC cluster** on the same Mac to a NAS VM. CRC differs from a production cluster in ways that change a few settings, and this guide records each difference and why.

## Where this stands

| Part | What | Status on 2026-10-02 |
|---|---|---|
| A | Measure the network path from the CRC node to a Lima VM | **Done**, measured |
| B | A NAS VM that CRC can reach, and a tunnel that works through the NAT in between | **Done**, measured with a stand-in VM behind the same kind of NAT |
| C | The NAS side for CRC: a NAS certificate signed by the cluster's enterprise CA, and the NAS configured for the CRC node | **Done**, measured |
| D | Change the CRC cluster: `routingViaHost`, NMState, Kyverno RBAC, IPsec `External` mode | `routingViaHost`, NMState and the Kyverno RBAC are **done**, measured. IPsec `External` mode **fails on CRC**: the node cannot install libreswan. It was reverted and the cluster is healthy. |
| – | The node's own tunnel, Appendix A, Part 2 from Step B.5, the demo app, metrics in Observe | **Not run on CRC.** They all need libreswan on the node. |

Everything in this guide was run and the outputs shown are real, including the step that failed. Nothing is shown as working that was not measured.

---

## How CRC differs from the cluster the main guide targets

| | Main guide (production cluster) | CRC on this Mac (measured) |
|---|---|---|
| Nodes | Many workers in the `worker` pool | One node, `crc`, with roles `control-plane,master,worker`, in the **`master`** MachineConfigPool. The `worker` pool has 0 machines. |
| Path to the NAS | Routed, no NAT | **Through NAT.** The node's packets leave through the Mac and reach the NAS from `192.168.64.1`. |
| IPsec mode on the tunnel | `transport`, bare ESP | **`tunnel`**, ESP wrapped in UDP 4500. Transport mode is refused behind NAT (Part B). |
| The node's address toward the NAS | `<node>.<NODE_DOMAIN>` resolves to it | `192.168.127.2`. No `crc.<domain>` name resolves to it, so the NNCP would use `left: '%defaultroute'` (not applied on CRC, see Step D.4). The node's other address, `192.168.126.11`, cannot reach the NAS. |
| Enterprise CA issuer | The placeholder `company-issuer-rnd` stands for yours | `enterprise-ca`, a root CA valid to 2031 |
| Installing libreswan on the nodes | `ipsecConfig.mode: External` adds it as an OS extension and reboots each node | **Fails.** The CRC image carries three extra packages that the extension install cannot find again (Step D.4). |
| IPsec today | – | `ipsecConfig.mode: Disabled`, `routingViaHost: true`, libreswan not installed on the node, NMState installed |
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

## Part D – Change the CRC cluster

> [!WARNING]
> These steps change cluster-wide settings on CRC. Step D.4 is meant to reboot its only node. If an OS-level change fails on a single-node cluster, CRC may need to be rebuilt.

The baseline before any change was recorded on 2026-10-02: OpenShift 4.22.7, all cluster operators healthy, the `master` pool updated, 196 pods, none failing.

| Step | Result on 2026-10-02 |
|---|---|
| D.1 `routingViaHost` | **Done.** OVN restarted in under a minute, no reboot. |
| D.2 NMState Operator and instance | **Done.** |
| D.3 Kyverno RBAC | **Done.** |
| D.4 IPsec `External` mode | **Fails on CRC.** The node cannot install libreswan. Reverted; the cluster is healthy again. |

### Step D.1 – Enable `routingViaHost` (main guide, Step 1.3)

```bash
oc patch networks.operator.openshift.io cluster --type=merge -p \
'{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'

oc get networks.operator.openshift.io cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig}{"\n"}'
oc get pods -n openshift-ovn-kubernetes        # repeat until ovnkube-node shows 8/8
oc get co network                              # AVAILABLE=True, PROGRESSING=False, DEGRADED=False
```

✅ **Expected** (measured). The patch was applied at 20:48:28 UTC. The two OVN pods were replaced, and within 62 seconds of the patch `ovnkube-node` was back to `8/8`. The node did not reboot.

```text
network.operator.openshift.io/cluster patched
{"ipv4":{},"ipv6":{},"routingViaHost":true}

NAME                                     READY   STATUS    RESTARTS   AGE
ovnkube-control-plane-6dc8ffb6bf-v2g66   2/2     Running   0          44s
ovnkube-node-dgn5x                       8/8     Running   0          42s
NAME      VERSION   AVAILABLE   PROGRESSING   DEGRADED   SINCE   MESSAGE
network   4.22.7    True        False         False      65d
```

### Step D.2 – NMState Operator and instance (main guide, Step 1.5)

CRC's `redhat-operators` catalog offers the package in the `stable` channel.

```bash
oc apply -f manifests/common/01-nmstate-operator.yaml
oc get csv -n openshift-nmstate | grep -i -E 'NAME|nmstate'    # wait for PHASE=Succeeded
```

✅ **Expected** (measured, columns shortened):

```text
namespace/openshift-nmstate created
operatorgroup.operators.coreos.com/openshift-nmstate created
subscription.operators.coreos.com/kubernetes-nmstate-operator created

NAME                                              DISPLAY                       VERSION               PHASE
kubernetes-nmstate-operator.4.22.0-202609230131   Kubernetes NMState Operator   4.22.0-202609230131   Succeeded
```

Then the instance, which starts the handler on the node:

```bash
oc apply -f manifests/common/02-nmstate-instance.yaml
oc get pods -n openshift-nmstate
oc get nns
```

✅ **Expected** (measured, 25 seconds after the instance was created): every pod `1/1`, and a `NodeNetworkState` for the node.

```text
nmstate.nmstate.io/nmstate created

nmstate-console-plugin-c7d695d6c-wvq75   1/1   Running   0     24s
nmstate-handler-5jzth                    1/1   Running   0     25s
nmstate-metrics-9cbc858c-mv48q           1/1   Running   0     25s
nmstate-operator-5894554fdb-pn6lp        1/1   Running   0     12m
nmstate-webhook-6cd895856c-9hg5h         1/1   Running   0     25s

NAME   AGE
crc    3s
```

### Step D.3 – Kyverno RBAC (main guide, Step 1.7)

Kyverno itself is already installed on CRC. This gives it permission to create NNCPs and Certificates.

```bash
oc apply -f manifests/common/03-kyverno-rbac.yaml

for sa in kyverno-background-controller kyverno-admission-controller; do
  for r in nodenetworkconfigurationpolicies.nmstate.io certificates.cert-manager.io; do
    printf '%s create %s: ' "$sa" "$r"
    oc auth can-i create "$r" --as="system:serviceaccount:kyverno:${sa}" -n kcs-ipsec
  done
done
```

✅ **Expected** (measured): four times `yes`. The warning that NNCPs are not namespace scoped is harmless.

```text
clusterrole.rbac.authorization.k8s.io/kyverno:ipsec-nas-generate created

kyverno-background-controller create nodenetworkconfigurationpolicies.nmstate.io: yes
kyverno-background-controller create certificates.cert-manager.io: yes
kyverno-admission-controller create nodenetworkconfigurationpolicies.nmstate.io: yes
kyverno-admission-controller create certificates.cert-manager.io: yes
```

### Step D.4 – IPsec in `External` mode (main guide, Step 1.4): fails on CRC

> [!CAUTION]
> **Do not run this step on CRC.** It was run here to find out, it failed, and it was undone. It is recorded so that nobody has to repeat it.

What was run, at 20:50:14 UTC:

```bash
oc patch networks.operator.openshift.io cluster --type=merge -p \
'{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"ipsecConfig":{"mode":"External"}}}}}'
```

The Cluster Network Operator created the two MachineConfigs, as the main guide says:

```text
80-ipsec-master-extensions                                                                    3.2.0             8s
80-ipsec-worker-extensions                                                                    3.2.0             8s
```

`80-ipsec-master-extensions` asks for the `ipsec` extension and enables `ipsecenabler.service`. The node then tried to install the extension and could not. Within 55 seconds of the patch, the `master` pool was degraded:

```bash
oc get mcp master -o jsonpath='{range .status.conditions[*]}{.type}={.status} msg={.message}{"\n"}{end}'
```

```text
Updating=True msg=All nodes are updating to MachineConfig rendered-master-b3f2e397f8d74fba1e653fbe4392558d
NodeDegraded=True msg=Node crc is reporting: "Node crc upgrade failure. error running rpm-ostree update --install NetworkManager-libreswan --install libreswan: error: Packages not found: cloud-init, gvisor-tap-vsock-gvforwarder, qemu-user-static-x86\n: exit status 1"
```

The node **did not reboot** and stayed `Ready`. The `network` cluster operator went `DEGRADED=True` with `master machine config pool in degraded state`.

#### Why it fails

The three packages in the error are not libreswan's. They are packages the CRC image already has installed on top of the base operating system:

```bash
oc debug node/crc -q -- chroot /host bash -c 'rpm-ostree status; ls -A /etc/yum.repos.d/'
```

```text
* ostree-unverified-registry:quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:fdab859490948a296e4d04353360f3834150630ec02e30a176edea52c191701d
                  Version: 9.8.20260721-0 (2026-07-22T05:28:57Z)
          LayeredPackages: cloud-init gvisor-tap-vsock-gvforwarder qemu-user-static-x86
```

`/etc/yum.repos.d/` is empty. The machine-config-daemon's log shows the only repository in use during the install, and that the install is retried about once a minute:

```bash
oc logs -n openshift-machine-config-operator ds/machine-config-daemon -c machine-config-daemon --since=10m | grep -i -E 'extension|rpm-ostree|Packages not found'
```

```text
Running: rpm-ostree update --install NetworkManager-libreswan --install libreswan
Enabled rpm-md repositories: coreos-extensions
rpm-md repo 'coreos-extensions' (cached); generated: 2026-07-22T05:32:31Z solvables: 136
Rolling back applied changes to OS due to error: error running rpm-ostree update --install NetworkManager-libreswan --install libreswan: error: Packages not found: cloud-init, gvisor-tap-vsock-gvforwarder, qemu-user-static-x86
Error syncing node crc (retries 11): error running rpm-ostree update --install NetworkManager-libreswan --install libreswan: error: Packages not found: cloud-init, gvisor-tap-vsock-gvforwarder, qemu-user-static-x86
```

So: to add libreswan, `rpm-ostree` must also find the three packages that are already layered, and the only repository it is given (`coreos-extensions`, the OpenShift extensions) does not contain them. Removing the three packages from the node was **not tried**. They come with the CRC image: `cloud-init`, the gvisor-tap-vsock forwarder (not running on this Mac: `gv-user-network@tap0.service` is inactive) and x86 emulation, which is registered on the node (`qemu-x86_64` in `/proc/sys/fs/binfmt_misc/`). Removing them changes the node's operating system and needs a reboot.

This was measured on CRC 2.63.0 with the OpenShift 4.22.7 bundle on an Apple Silicon Mac. Other CRC versions were not tested. A production cluster's nodes have no such extra packages, so the main guide's Step 1.4 is not affected.

#### How it was undone

```bash
oc patch networks.operator.openshift.io cluster --type=merge -p \
'{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"ipsecConfig":{"mode":"Disabled"}}}}}'

oc get mc | grep ipsec      # no output: both MachineConfigs are gone
oc get mcp master
oc get co network machine-config
```

✅ **Expected** (measured). The patch was applied at 20:53:25 UTC. The two MachineConfigs were removed at once, and within 38 seconds the pool and both operators were healthy, with no reboot:

```text
NAME     CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master   rendered-master-a8e0982444c8d7812f7bef6a181da1b1   True      False      False      1              1                   1                     0                      65d
state=Done
NAME             VERSION   AVAILABLE   PROGRESSING   DEGRADED   SINCE   MESSAGE
network          4.22.7    True        False         False      65d
machine-config   4.22.7    True        False         False      65d
cluster operators not healthy: 0
```

### What this means for the rest

Without libreswan and `NetworkManager-libreswan` on the node, an NMState `ipsec` interface cannot be created, and there is no `certutil` or `/var/lib/ipsec/nss` for the certificate import. That stops, on CRC:

- **Appendix A (shared certificate)**: its MachineConfig imports into the NSS database that libreswan would have created.
- **Part 2 (per-node certificates)** from Step B.5 on: the cert-sync DaemonSet and the NNCP. Steps B.1 to B.4 (the certificate itself, issued by `enterprise-ca`) do not need libreswan.

Not run on CRC, and still open: the node's own tunnel, the demo application through that tunnel, and the metrics in Observe.

State of CRC now: `routingViaHost: true`, `ipsecConfig.mode: Disabled`, the NMState Operator with its instance, the Kyverno ClusterRole, and the `kcs-ipsec` namespace with the NAS `CertificateRequest`. To put `routingViaHost` back: the patch of Step D.1 with `false`.

---

## Diagram sources

Figure 1 is rendered from `docs/diagrams/crc-nat/source.html` by `docs/diagrams/render.py` (see the main guide's [Diagram sources](ipsec-nas-guide.md#diagram-sources)):

```bash
python3 docs/diagrams/render.py docs/diagrams/crc-nat/source.html docs/diagrams/crc-nat nat-tunnel-mode
```

The Mermaid text version is `docs/diagrams/mermaid/nat-tunnel-mode.mmd`; it is not what this document displays. The dashed box in the figure marks the part that is proposed and not built; redraw it solid once the CRC node's tunnel is measured.
