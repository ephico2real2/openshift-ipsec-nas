# Option C — One Wildcard Certificate in a MachineConfig

**Audience:** platform engineers. **Status:** evaluated and measured; the standard remains [Option B](20-option-b-per-node-certificates.md). **Before this:** [00-prepare-the-cluster.md](00-prepare-the-cluster.md), Parts 0 and 1, and the NAS side (3.1).

Option C delivers **one** certificate to every node of a pool through a **MachineConfig**, like [Option A](10-option-a-shared-certificate.md), with one difference: the certificate names `*.<NODE_DOMAIN>` instead of a list of nodes, and is issued for two years. MachineConfig is how OpenShift itself puts files and services on RHCOS nodes, and a node that joins the pool later gets the same MachineConfig before it first starts. So a new node gets the certificate without a new certificate and without rebooting the others.

It comes in two variants, both measured:

| | **C1: Red Hat components only** | **C2: per-node identity** |
|---|---|---|
| Certificate | One wildcard certificate in a MachineConfig | The same |
| Tunnel definition | **One** NNCP for the whole pool | One NNCP per node, made by a Kyverno `GeneratingPolicy` |
| IKE identity of a node | The certificate's subject (`leftid: '%fromcert'`), the same for every node | The node's own name (`leftid: '@<node>.<NODE_DOMAIN>'`); a libreswan NAS did not enforce it (measured) |
| `left` | `%defaultroute`: the NAS is reached through the default-route interface | Per node: `<node>.<NODE_DOMAIN>` |
| Components | MachineConfig, NMState | MachineConfig, NMState, Kyverno 1.19 or later |
| The NAS must allow duplicate peer IDs | **Yes** (measured) | **Yes** with a libreswan NAS (measured); the per-node identity did not change that |

**Contents:** [C.0 How it works](#c0-how-it-works) · [What the NAS must allow](#what-the-nas-must-allow-measured) · [For the NAS team](#for-the-nas-team-what-option-c-needs) · [Compared with A and B](#compared-with-options-a-and-b) · Steps [C.1](#step-c1--a-key-and-a-certificate-request) to [C.7](#step-c7--remove-option-c) · [Measured on OpenShift Local (CRC)](#measured-on-openshift-local-crc)

> [!CAUTION]
> Never run two options on the same cluster: all of them import a certificate into each node's NSS database under the nickname `left_server`.

## C.0 How it works

<!-- markdownlint-disable MD033 -->
<img alt="Option C with the settings that worked: you make one key and CSR for the wildcard name, the enterprise CA signs it for two years, a script checks it and renders a MachineConfig, and every node of the pool reboots once and imports the certificate as left_server before libreswan starts. C1 uses one NNCP for the pool with the certificate's identity; C2 uses a Kyverno policy that makes one NNCP per node with the node's own name. The NAS takes the identity from the certificate (rightid=%fromcert) and allows several peers with one identity (uniqueids=no). Measured: two nodes, two tunnels, both NFS writes through IPsec, for C1 and for C2." src="diagrams/option-c/option-c-wildcard-cert.light.png">
<!-- markdownlint-enable MD033 -->

*Figure 4. Option C with the settings that worked: one wildcard certificate in a MachineConfig, C1 or C2 for the tunnel, and a NAS that takes the identity from the certificate (`rightid=%fromcert`) and allows several peers with one identity (`uniqueids=no`). The combinations that failed are in the [table for the NAS team](#for-the-nas-team-what-option-c-needs), not in the figure.*

<details>
<summary>The figure as text</summary>

```text
YOU (workstation + CA)          CLUSTER                         EVERY NODE OF THE POOL            NAS (storage team)

1. One key, one CSR        -->  MachineConfig             -->  4. Each node reboots once           NAS settings that worked,
   SAN DNS:*.<NODE_DOMAIN>         99-<pool>-ipsec-wildcard-cert    imports the certificate at boot,     for C1 and for C2:
2. the enterprise CA signs it,     ca.pem + left_server.p12         before libreswan: left_server        rightid=%fromcert   identity from the certificate
   valid 2 years                   + ipsec-nas-import.service       one copy, replaced on renewal        uniqueids=no        several peers, one identity
   (option-c-certificate.sh)       (script checks SAN, key, chain)          |                            rightca=%same       the enterprise root CA
                                                                            v                            right=%any          any peer address (not rightid=%any)
Every 2 years: renew            C1: one NNCP for the pool  -->  Connection ipsec-nas  <-- IKEv2/ESP -->  firewall: UDP 500/4500 + ESP from the worker subnet
   steps 1-3 with a new key        leftid %fromcert              IKEv2, certificate left_server          NFS accepted only through IPsec
   oc apply the MachineConfig      left %defaultroute            identity sent: C1 the subject,
   each node reboots once          no Kyverno, no DaemonSet      C2 the node's own name
   NNCP and NAS unchanged       C2: one NNCP per node      -->   every node presents the same certificate:
                                   Kyverno GeneratingPolicy      CN=ocp-ipsec-workers, O=KCS
                                   leftid @<node>.<NODE_DOMAIN>
                                   restart after a change

Measured with these settings: Lima lab, two nodes sharing one certificate *.internal: 2 tunnels, both NFS writes through IPsec,
for C1 (case 2) and C2 (case 7). OpenShift Local: C1's tunnel 10 s after its NNCP; a renewal took one reboot, tunnel back by itself.
The NAS does not enforce the name a node claims: the CA, the worker-subnet firewall and NFS only through IPsec are the controls.
Not measured: a new node joining the pool (by design it gets the MachineConfig and the NNCP), and a NAS product other than libreswan.
```

</details>

The import script runs at every boot. It removes an earlier `left_server` and CA first, so a renewed certificate replaces the old one instead of sitting next to it under the same nickname; Option A's documented script only adds.

## What the NAS must allow (measured)

Every node presents the same certificate. Whether the NAS can hold all their tunnels depends on how it identifies a peer. This was measured with a libreswan 5.4 NAS and two stand-in workers that share one certificate with SAN `*.internal` (`lab/lab.sh option-c`, [`evidence/crc/34-option-c-lab-identities.txt`](evidence/crc/34-option-c-lab-identities.txt)):

| Case | Identity the nodes send (`leftid`) | NAS `rightid` | NAS `uniqueids` | NAS tunnels (15 s) | NFS write through IPsec |
|---|---|---|---|---|---|
| 1 | the certificate's subject (`%fromcert`) | `%fromcert` | `yes` (default) | **1**: the nodes keep replacing each other | – |
| 2 | the certificate's subject | `%fromcert` | `no` | **2** | both pass |
| 3 | each its own FQDN | `%fromcert` | `yes` | **1**: the NAS takes the certificate's subject, the same for both | – |
| 4 | each its own FQDN | `%any` | `yes` | **0**: `AUTHENTICATION_FAILED` | – |
| 5 | each its own FQDN | `@*.internal` | `yes` | **1**: both recorded as `@*.internal` | – |
| 6 | each its own FQDN | `@*.internal` | `no` | **2** | both pass |
| 7 | each its own FQDN | `%fromcert` | `no` | **2** | both pass |
| – | a name outside the wildcard (`@…example.org`) | `@*.internal` | `no` | **accepted** | – |

<img alt="Terminal capture of lab/lab.sh option-c: two stand-in workers with one wildcard certificate *.internal. Case 1, certificate identity with uniqueids yes: one NAS tunnel at a time, connection instance 444. Case 2, uniqueids no: two tunnels and both 5 MiB NFS writes pass. Case 3, FQDN identities with rightid fromcert and uniqueids yes: one tunnel, recorded under the certificate subject. Case 4, rightid any: no tunnel. Case 5, rightid wildcard with uniqueids yes: one tunnel recorded as the wildcard. Case 7, FQDN identities with rightid fromcert and uniqueids no: two tunnels, both writes pass. Case 6, rightid wildcard with uniqueids no: two tunnels, both writes pass. Negative: a worker claiming an identity outside the wildcard still has a tunnel. Then the lab restored, and the NAS debug lines for case 4." src="images/crc/34-option-c-lab-identities.light.png">

*Capture 34. The wildcard-certificate cases in the Lima lab. Text: [`evidence/crc/34-option-c-lab-identities.txt`](evidence/crc/34-option-c-lab-identities.txt).*

What follows from it, for a libreswan NAS:

- **`uniqueids=no` is required** for C1 and for C2. With the default `uniqueids=yes`, the NAS keeps one tunnel per identity, and with one certificate it sees one identity in every combination above, even when each node sends its own name.
- **`rightid=%fromcert`** (identity taken from the certificate) works for both variants, with `uniqueids=no`: C1 in case 2, C2 in case 7. With FQDN identities it records the certificate's subject, not the name (case 3). `rightid=%any` refuses FQDN identities (case 4): with debugging on, the NAS logged `skipping because initiator_id does not match`. A wildcard `rightid=@*.internal` authenticates (cases 5, 6) but brings nothing over `%fromcert`.
- **The name a node claims is not a control**: a node presenting a name outside the wildcard was accepted (last row). What limits who connects is the CA the NAS trusts, the worker-subnet firewall and NFS only through IPsec, as for every option.

The next section is the request to the NAS team.

## For the NAS team: what Option C needs

### Measured: which NAS settings make Option C work

Every combination below was run with one wildcard certificate (`*.internal`) on two stand-in workers against a libreswan 5.4 NAS (`lab/lab.sh option-c`, [`evidence/crc/34-option-c-lab-identities.txt`](evidence/crc/34-option-c-lab-identities.txt)):

| # | Worker identity | NAS `rightid` | NAS `uniqueids` | Result |
|---|---|---|---|---|
| 1 | certificate DN | `%fromcert` | yes | One tunnel at a time; the nodes keep replacing each other |
| 2 | certificate DN | `%fromcert` | no | **2 tunnels, both NFS writes pass (C1)** |
| 3 | own FQDN | `%fromcert` | yes | One tunnel; the NAS uses the certificate DN instead |
| 4 | own FQDN | `%any` | yes | Refused: `AUTHENTICATION_FAILED` |
| 5 | own FQDN | `@*.internal` | yes | One tunnel; both recorded as `@*.internal` |
| 6 | own FQDN | `@*.internal` | no | 2 tunnels, both NFS writes pass |
| 7 | own FQDN | `%fromcert` | no | **2 tunnels, both NFS writes pass (C2)** |
| negative | a name outside the wildcard | `@*.internal` | no | Accepted: the claimed name is not enforced |

- **Required:** allow several peers with the same certificate identity (libreswan `uniqueids=no`), and take the peer's identity from its certificate (`rightid=%fromcert`). Rows 2 and 7 are the two working setups, for C1 and C2.
- **Security:** because a node's claimed name is not checked (negative row), the security rests on the CA the NAS trusts, the worker-subnet firewall and rejecting cleartext NFS.

Option C needs the NAS set up as for Option B ([00-prepare-the-cluster.md, 3.1](00-prepare-the-cluster.md#31-nas-configuration-storage-team-not-us)): its own certificate from the enterprise CA, IKEv2 with certificates, the worker subnet as peers, and cleartext NFS rejected. **One setting is added: the NAS must accept several peers that present the same certificate identity at the same time.** Without it, the NAS keeps one tunnel and the nodes keep replacing each other (case 1 above: connection instance 444 by the end of the case).

### What we send the NAS team

- The worker subnet(s): every node address that will connect.
- The enterprise root CA that the node certificate chains to.
- The node certificate's identity, public part only: subject `CN=ocp-ipsec-workers, O=KCS`, SAN `DNS:*.<NODE_DOMAIN>`. Every node presents this same certificate.
- The NAS name and NFS IP that the nodes connect to (`NAS_FQDN`, `NAS_IP`), and the settings below.

### What the NAS team configures

| # | Setting | Value | Why | Measured |
|---|---|---|---|---|
| 1 | NAS certificate | Its own, from the **same** enterprise CA, SAN `NAS_FQDN`; key made on the NAS | The nodes check it against the root CA they trust | As for Option B |
| 2 | Protocol | IKEv2, transport mode (tunnel mode only where there is NAT, as in the lab) | The node's NNCP insists on IKEv2 | As for Option B |
| 3 | Authentication | Certificate (PKI); trust the enterprise root CA | The node proves itself with the wildcard certificate | Cases 2 and 6 |
| 4 | Peers | Any peer in the worker subnet with a certificate from that CA, not a list of hosts | A new node connects with no NAS change | Lima lab, Option B |
| 5 | Peer identity | **Taken from the peer's certificate** (libreswan: `rightid=%fromcert`) | Works whatever identity the node sends | Cases 2 and 7; `rightid=%any` refused every FQDN identity (case 4) |
| 6 | **Several peers with the same identity** | **Allowed** (libreswan: `uniqueids=no` in `config setup`) | All nodes present one certificate | Case 1 (default: never more than one tunnel) against case 2 (2 tunnels, both NFS writes pass) |
| 7 | NFS without IPsec | **Rejected**: NFS (TCP 2049) accepted only when it arrived through IPsec | A tunnel restart must never fall back to cleartext | Option B and lab finding 2 |
| 8 | Firewall | UDP 500 and 4500, and ESP (IP protocol 50), from the worker subnet only | With one shared identity, the identity a node claims is not a control: the subnet, the CA and rule 7 are | Negative case: a name outside the wildcard was accepted |

### The reference configuration, as measured (libreswan 5.4)

The lab's test NAS ([`lab/rhel/setup-nas.sh`](../lab/rhel/setup-nas.sh), run with `ALLOW_DUPLICATE_IDS=yes`) is this configuration. A storage appliance has its own way to express each row of the table; this is what the rows mean in libreswan:

```text
# /etc/ipsec.conf
config setup
    uniqueids=no                       # row 6: several peers with the same identity

# /etc/ipsec.d/nas-workers.conf
conn workers
    left=%defaultroute                 # the NAS address the nodes connect to
    leftid=%fromcert
    leftcert=nas                       # row 1: the NAS's own certificate
    leftrsasigkey=%cert
    right=%any                         # row 4: any peer ...
    rightid=%fromcert                  # row 5: ... identified by its certificate
    rightrsasigkey=%cert
    rightca=%same                      # row 3: issued by the same CA as the NAS certificate
    ikev2=insist                       # row 2
    type=transport
    auto=add
```

```text
# nftables: rows 7 and 8
ip saddr <worker subnet> udp dport { 500, 4500 } accept
ip saddr <worker subnet> meta l4proto esp accept
ip saddr <worker subnet> tcp dport 2049 meta ipsec exists accept
tcp dport 2049 drop
```

### How the NAS team checks it

Once the nodes are up, on a libreswan NAS:

```bash
ipsec trafficstatus          # one entry per node, every one with id='CN=ocp-ipsec-workers, O=KCS'
ipsec status | grep -o '"workers"\[[0-9]*\]' | sort -u | tail -1      # the instance number stays put
nft list table inet nas_ipsec_only | grep -E 'nfs-(over-ipsec|cleartext)'
```

✅ **Expected:** as many tunnels as connected nodes, all with the same identity, and they stay; the NFS-over-IPsec rule counts the traffic. ❌ **If duplicate identities are not allowed:** one tunnel at a time, and the instance number climbs every few seconds (case 1).

### What the NAS team sends back

- [ ] Confirmation that several peers with the same certificate identity are allowed (row 6), and the setting that does it on their product
- [ ] The NAS certificate, public part only, with its SAN (`NAS_FQDN`), its issuer chain and its expiry date
- [ ] The IKE and ESP proposals the NAS accepts, if not the defaults
- [ ] The NFS IP(s) protected
- [ ] The NAS product and version, and whether it checks a peer's identity against the certificate's SAN. If it does, and requires one identity per node, tell us: that is what C2 sends (`leftid: '@<node>.<NODE_DOMAIN>'`), measured here only against libreswan

### Every two years, when we renew

Nothing changes on the NAS: the renewed certificate comes from the same CA and has the same subject. Measured on CRC ([`evidence/crc/36-option-c-crc-renewal-and-c2.txt`](evidence/crc/36-option-c-crc-renewal-and-c2.txt)): the NAS's configuration files were not touched, and it authenticated the renewed certificate (new serial) under the same identity. A NAS that pins a peer's certificate or fingerprint, instead of trusting the CA, would need the new certificate; that was not measured.

### When the nodes' identity changes

Moving a cluster from Option B to Option C, or between C1 and C2, changes the identity each node presents. A libreswan NAS that still holds a connection instance for a node's address under its **old** identity refused the node's new identity (`AUTHENTICATION_FAILED`, measured on CRC when switching to C2). After a restart of libreswan on the NAS, which cleared the old instance, the same node was accepted at once. So, at the switch: clear the NAS's old instances for the worker subnet (libreswan: `systemctl restart ipsec`, or delete those states), or wait until they time out.

A NAS product other than libreswan may treat identities differently; the cases above were measured with libreswan only.

## Compared with Options A and B

| | **A: shared certificate, node list** | **C: wildcard certificate** | **B: one certificate per node** |
|---|---|---|---|
| Delivered by | MachineConfig | MachineConfig | cert-manager + a DaemonSet |
| A new node | New certificate with a longer SAN list, new MachineConfig, every node reboots | **Nothing to do**: it gets the MachineConfig and the NNCP when it joins (by design: MachineConfig and NNCP apply to the pool; not measured, CRC has one node) | Nothing to do (measured with a stand-in node) |
| Renewal | By hand, every node reboots | By hand **every 2 years**, every node reboots once | Automatic, no reboot |
| Revoke one node | No | No | Yes |
| Private key | One, on every node and in the MachineConfig | One, on every node and in the MachineConfig | One per node, in a Secret |
| NAS must allow duplicate peer IDs | Yes | Yes | No |
| Components beyond OpenShift | Kyverno (or one NNCP per node by hand) | **C1: none.** C2: Kyverno | Kyverno, cert-manager |
| Monitoring | None | None | Per-node metrics and alerts |

**What the measurements show about viability:**

- It works on a real OpenShift node through Red Hat's own mechanisms: the MachineConfig imported the certificate at boot, and with C1 the tunnel was up 10 seconds after the NNCP, with no Kyverno and no DaemonSet (cert-manager only signed the certificate, because that is how this CRC reaches its CA) ([CRC run](#measured-on-openshift-local-crc)).
- A renewal is a new MachineConfig and one reboot per node; the node came back with the new certificate (one copy, new serial), its tunnel came back by itself, and the NAS needed no change.
- It holds only if the NAS allows several peers with the same identity: on a libreswan NAS that is required in every variant tested, C2 included. C2's per-node identity added Kyverno, a NAS-side cleanup at the switch and a connection restart, and did not remove that requirement.
- What it does not change from Option A: one private key on every node and readable in the MachineConfig, no revocation of a single node, no per-node identity on the NAS, a reboot of the pool at every renewal, and no monitoring.

Option B remains the standard. Option C is the alternative where no component beyond OpenShift may be added and the NAS team accepts shared identities.

## Step C.1 – A key and a certificate request

Set the variables of [00-prepare-the-cluster.md, Part 0.3](00-prepare-the-cluster.md#03-open-a-shell-and-set-variables), and `MCP_ROLE` to the pool that reaches the NAS (`worker` on most clusters). Work in a directory outside Git:

```bash
export MCP_ROLE=worker
scripts/option-c-certificate.sh csr ~/ipsec-option-c/2026        # a new directory for every new key
```

It writes `wildcard.key` and `wildcard.csr` with subject `CN=ocp-ipsec-workers, O=KCS` and SAN `DNS:*.${NODE_DOMAIN}`.

## Step C.2 – The enterprise CA signs it

Send `wildcard.csr` to the enterprise CA and ask for: validity 2 years (or the longest the CA allows), key usages digital signature and key encipherment, extended key usages server auth **and** client auth. The CA's policy must allow a wildcard certificate. Download the signed certificate and the root CA (and the intermediate, if the CA has one) in PEM.

If the cluster's existing enterprise CA `ClusterIssuer` may sign it, a cert-manager `CertificateRequest` does the same without the key leaving your directory: Step C.2 of the [CRC run](#measured-on-openshift-local-crc) shows it.

## Step C.3 – Check the certificate and build the MachineConfig

```bash
scripts/option-c-certificate.sh machineconfig ~/ipsec-option-c/2026 signed.pem enterprise-root.pem [intermediate.pem]
```

It refuses a certificate whose SAN is not `DNS:*.${NODE_DOMAIN}`, that does not belong to the key, has no client auth usage, does not chain to the root, or expires within 30 days. Then it writes `left_server.p12` (friendly name `left_server`, empty password: the node imports it unattended) and `99-${MCP_ROLE}-ipsec-wildcard-cert.yaml`, rendered with `butane` from [`manifests/option-c-wildcard-cert/99-ipsec-wildcard-cert.bu.tmpl`](../manifests/option-c-wildcard-cert/99-ipsec-wildcard-cert.bu.tmpl).

## Step C.4 – Apply the MachineConfig

> [!WARNING]
> Every node of the pool reboots, one at a time.

```bash
oc apply -f ~/ipsec-option-c/2026/99-${MCP_ROLE}-ipsec-wildcard-cert.yaml
watch oc get mcp ${MCP_ROLE}                    # UPDATED=True, UPDATING=False, DEGRADED=False
NODE=$(oc get nodes -l node-role.kubernetes.io/${MCP_ROLE} -o jsonpath='{.items[0].metadata.name}')
oc debug node/${NODE} -q -- chroot /host bash -c 'journalctl -b -u ipsec-nas-import --no-pager | tail -4; certutil -L -d /var/lib/ipsec/nss'
```

✅ **Expected:** `left_server u,u,u` and `KCS-IPSEC-CA CT,C,C`, and the import's log shows the subject and the new `Not After`.

The key is now in the MachineConfig, and anyone who can read `machineconfigs` can extract it. Delete the working directory once the MachineConfig is applied.

## Step C.5 – The tunnel: C1 or C2

> [!IMPORTANT]
> **Stop here until the NAS side is ready**, including duplicate peer IDs ([above](#what-the-nas-must-allow-measured)).

From the repository root, after `./render.sh` with `MCP_ROLE` set:

```bash
# C1: one NNCP for the pool, no Kyverno
oc apply -f rendered/option-c-wildcard-cert/10-nncp-all-workers.yaml

# or C2: one NNCP per node, made by Kyverno (needs manifests/common/03-kyverno-rbac.yaml)
oc apply -f manifests/common/03-kyverno-rbac.yaml
oc apply -f rendered/option-c-wildcard-cert/11-kyverno-nncp-per-node-fqdn.yaml
```

> [!IMPORTANT]
> **After an NNCP change on a running node, restart the node's connection.** Switching a node from C1 to C2 changed its connection in place; NetworkManager then reported it `activated` while libreswan had no SA, and nothing restarted it (measured on CRC). Option B's cert-sync pod does this restart by itself; Option C has no such pod. On each node: `nmcli connection down ipsec-nas; nmcli connection up ipsec-nas`. On a new node or after a reboot the connection starts fresh, so this applies only to changes of a running tunnel.

C1's NNCP selects the nodes by the pool's role label, so a new node of the pool gets it with no other step. Its `left: '%defaultroute'` uses the address of the node's default-route interface: if the NAS is reached through another interface, use C2. Then verify as in [00-prepare-the-cluster.md, 3.2](00-prepare-the-cluster.md#32-verify-end-to-end).

## Step C.6 – Renew, every two years

Steps C.1 to C.4 again, in a **new** directory, well before the old certificate expires. The new MachineConfig content reboots every node of the pool once; each node imports the new certificate at boot and comes back with it. The NNCP does not change.

```bash
scripts/option-c-certificate.sh csr ~/ipsec-option-c/2028
# ... the CA signs it ...
scripts/option-c-certificate.sh machineconfig ~/ipsec-option-c/2028 signed.pem enterprise-root.pem
oc apply -f ~/ipsec-option-c/2028/99-${MCP_ROLE}-ipsec-wildcard-cert.yaml
```

Then ask the CA team to revoke the old certificate. Put the new expiry date in the team calendar: nothing renews it, and nothing warns before it expires.

## Step C.7 – Remove Option C

The order matters: the tunnel definition first, then the tunnel, then the MachineConfig, then what the MachineConfig leaves behind.

```bash
# 1. C1: oc delete nncp ipsec-nas-wildcard      C2: oc delete generatingpolicy ipsec-nncp-wildcard-per-node
# 2. Remove the tunnel from every node with an NNCP that says absent (as in Option A, Step A.12)
# 3. Delete the MachineConfig: every node of the pool reboots
oc delete mc 99-${MCP_ROLE}-ipsec-wildcard-cert
# 4. The import does not run any more, but what it imported stays: remove it from every node.
#    Only while no other option is installed: Options A and B use the same nicknames, so this would
#    delete their certificate and key too.
for n in $(oc get nodes -l node-role.kubernetes.io/${MCP_ROLE} -o jsonpath='{.items[*].metadata.name}'); do
  oc debug "node/${n}" -q -- chroot /host bash -c '
    certutil -F -n left_server -d /var/lib/ipsec/nss; certutil -D -n KCS-IPSEC-CA -d /var/lib/ipsec/nss
    rmdir /etc/pki/ipsec-nas; certutil -L -d /var/lib/ipsec/nss'
done
```

✅ **Expected** (measured on CRC): an empty certificate list. Without step 4 the certificate and its private key stay in the NSS database after the MachineConfig is gone.

Then ask the CA team to revoke the certificate.

---

## Measured on OpenShift Local (CRC)

Everything below was run on OpenShift Local (CRC) 2.63.0 with OpenShift 4.22.7, one node in the `master` pool, against the CRC NAS of [40-lab-crc-and-nas.md](40-lab-crc-and-nas.md) (libreswan 5.4, `rightid=%fromcert`, `uniqueids=yes`: one node needs no duplicate IDs), on 2026-10-03. Option B was running before and was put back afterwards. The values differ from production as for every CRC run: the `master` pool, tunnel mode because of NAT, `left: '%defaultroute'`, the NAS IP as `right`.

| Step | What was measured | Evidence |
|---|---|---|
| Option B removed | The three-step Argo CD procedure: the cleanup in 8 seconds; no tunnel, empty NSS database | [35](evidence/crc/35-option-c-crc-install.txt) |
| C.1 to C.3 | A wildcard key and CSR (`DNS:*.crc.testing`); signed by the cluster's `enterprise-ca` through a cert-manager `CertificateRequest`, `duration: 17520h`: valid from 2026-10-03 to **2028-10-02**; every check of `option-c-certificate.sh machineconfig` passed | 35 |
| C.4 | MachineConfig applied 01:59:17; the node rebooted (new boot ID at 02:10:01); after CRC's stop and start the pool was `Updated`. `ipsec-nas-import` had imported the certificate: one `left_server` with the signed serial, and `KCS-IPSEC-CA` | 35 |
| C.5, C1 | One NNCP for the pool: `Available` in 8 seconds, the tunnel in 10; the node's identity `CN=ocp-ipsec-workers, O=KCS`; the NAS authenticated it; the demo application wrote again | 35 |
| C.6, renewal | A new key and certificate (serial `22C9…D9D2`), the MachineConfig replaced 02:33:31, one reboot; after it: one `left_server`, the new serial; the tunnel back by itself, the NNCP unchanged (generation 1); the NAS's files untouched and the renewed certificate authenticated | [36](evidence/crc/36-option-c-crc-renewal-and-c2.txt) |
| C1 to C2 | Kyverno's NNCP `Available` in 7 seconds with `leftid: @crc.crc.testing`, but no tunnel: NetworkManager `activated`, libreswan without SA; a restart was refused by the NAS (`AUTHENTICATION_FAILED`) while it held an instance from Option B for the same address; after a libreswan restart on the NAS, the node's identity `@crc.crc.testing` was accepted | 36 |
| C.7, removal | The policy deleted (Kyverno removed its NNCP), the tunnel removed with an `absent` NNCP, the MachineConfig deleted 02:55:16 and one reboot. Afterwards the unit and the files were gone, the empty directory `/etc/pki/ipsec-nas` stayed, and **the certificate and its key were still in the node's NSS database** until step 4 removed them | [37](evidence/crc/37-option-c-crc-removal-and-b-restored.txt) |
| Option B back | The same Argo CD Application from Git: `Synced` and `Healthy` after 14 seconds, the first pod with its node's secret, the tunnel after 23 seconds; the NAS authenticated `CN=crc.crc.testing` with no restart (it held no old instance, since the tunnel had been removed first); the demo application wrote again | 37 |

<img alt="Terminal capture of Option C on CRC: Option B running, then removed with the Argo CD procedure; a wildcard key and CSR for *.crc.testing signed by enterprise-ca for two years and checked by option-c-certificate.sh; the MachineConfig applied, the node rebooting, crc stop timing out and the forced restart; after the boot one left_server certificate with the signed serial in the node's NSS database; then the C1 NNCP Available in 8 seconds, the tunnel with identity CN=ocp-ipsec-workers, the NAS authenticating it, and the demo application writing again." src="images/crc/35-option-c-crc-install.light.png">

*Capture 35. Option C installed on CRC with C1. Captures of the renewal and C2 switch, and of the removal: [`evidence/crc/36-option-c-crc-renewal-and-c2.txt`](evidence/crc/36-option-c-crc-renewal-and-c2.txt), [`evidence/crc/37-option-c-crc-removal-and-b-restored.txt`](evidence/crc/37-option-c-crc-removal-and-b-restored.txt). Text: [`evidence/crc/35-option-c-crc-install.txt`](evidence/crc/35-option-c-crc-install.txt).*

The demo application's writes stopped for 34.5 minutes from the removal of Option B to the first Option C tunnel. Of that, 10.7 minutes were the MachineConfig rollout up to the reboot, and 21.9 minutes from the reboot to the cluster being back, because the CRC VM did not stop (Gotcha 17); after the third reboot, when it stopped normally, that took 3.5 minutes. The writes stopped for 9.3 minutes over the renewal's reboot and CRC restart, and 8.75 minutes over the C2 switch while its two problems were found.

## Gotchas

### Gotcha 17 – After a MachineConfig reboot, `crc stop` timed out and `crc start` started nothing

**What happened.** After two of the three MachineConfig reboots, `crc stop` ended with `VM Failed to gracefully shutdown, try the kill command` after 2 minutes; after the third it stopped normally. The guest had reached `System Power Off` (the VM's log), but its VM process had not exited. The first time, the following `crc start` printed `Started the OpenShift cluster.` without starting anything: the API reset every connection and `crc status` said `crc does not seem to be setup correctly`.

**What to do.** On CRC only: when `crc stop` reports that error, run `crc stop --force` (the guest is already powered off), then `crc start`. Both times the cluster was back about 6 minutes later. A real cluster has no `crc stop`; the MachineConfig Operator reboots each node and waits for it.

### Gotcha 18 – NMState changed a running connection and libreswan dropped it

**What happened.** When C2's NNCP replaced C1's on the running node, libreswan logged `terminating SAs using this connection` in the middle of the new negotiation and did not start again, while NetworkManager kept the connection `activated`.

**What to do.** After an NNCP change on a running node, restart the connection (`nmcli connection down ipsec-nas; nmcli connection up ipsec-nas`), see Step C.5. Option B's cert-sync pod already does this (`heal_tunnel`).

### Gotcha 19 – The NAS refused a node's new identity while it held the old one

**What happened.** After the switch to C2, the NAS answered the node's `@crc.crc.testing` with `AUTHENTICATION_FAILED`. Its debug log started the match on an instance still bound to Option B's `CN=crc.crc.testing` for the same address, and found no connection it could use. In the Lima lab, where the NAS was restarted before each case, the same identity type was accepted (case 3).

**What to do.** At a change of the nodes' identity, clear the NAS's old instances: see [When the nodes' identity changes](#when-the-nodes-identity-changes).
