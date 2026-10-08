# Review — Our Enterprise Linux IPsec Configuration, and Which Option Matches It

**Audience:** platform engineers and the storage team. **Question:** our regular Linux hosts already reach the NAS over IPsec with an enterprise standard configuration. Which OpenShift setup option (A, B or C) lets the nodes connect to the same NAS the same way, and what would change?

**Contents:** [The reference configuration](#the-reference-configuration) · [What it tells us, and what it does not](#what-it-tells-us-and-what-it-does-not) · [What does not carry over: odd and even](#what-does-not-carry-over-odd-and-even) · [Setting by setting, against our NNCP](#setting-by-setting-against-our-nncp) · [Each option against the reference](#each-option-against-the-reference) · [`uniqueids` and Option B](#uniqueids-and-option-b) · [Sample NNCP for Option B](#sample-nncp-for-option-b-nas-on-uniqueidsyes) · [Findings](#findings) · [Questions for the storage team](#questions-for-the-storage-team) · [What to test next](#what-to-test-next)

## The reference configuration

The enterprise configuration for a regular Linux host, one libreswan connection (shared as a photo of the standard; host names, NAS names and addresses replaced here):

```text
# DNS nas server name <NAS FQDN>
conn mytunnel2
        left=<host IP>
        right=<NAS IP>
        leftcert="<host FQDN>"
        leftid=%fromcert
        leftauth=rsasig
        leftrsasigkey=%cert
        leftprotoport=tcp
        rightid=%fromcert
        rightrsasigkey=%cert
        rightauth=rsasig
        rightca=%same
        rightprotoport=tcp/nfs
        auto=start
```

The photo shows this connection under the heading `mytunnel2.conf`, and the start of another, `mytunnel4.conf`, whose content was not in the photo; what distinguishes the files is not visible.

What each line means ([libreswan `ipsec.conf(5)`](https://libreswan.org/man/ipsec.conf.5.html)):

| Line | Meaning |
|---|---|
| `left=<host IP>`, `right=<NAS IP>` | The host's address and the NAS's. The NAS is named by its IP; its name is only a comment |
| `leftcert="<host FQDN>"` | The host's **own** certificate, its NSS nickname being the host's FQDN: one certificate per host |
| `leftid=%fromcert`, `rightid=%fromcert` | Each side identifies itself by its certificate's subject |
| `leftrsasigkey=%cert`, `rightrsasigkey=%cert`, `leftauth=rsasig`, `rightauth=rsasig` | Both sides authenticate with RSA signatures from their certificates |
| `rightca=%same` | The NAS's certificate must be signed by the same CA as the host's |
| `leftprotoport=tcp`, `rightprotoport=tcp/nfs` | **Port selectors:** the connection covers only TCP to the NAS's `nfs` port (2049 in `/etc/services`). Other traffic to the NAS is not in it. They filter outbound traffic; inbound filtering stays with the firewall |
| no `type=` | libreswan's default, `tunnel` |
| `auto=start` | Brought up when IPsec starts |

## What it tells us, and what it does not

- **It is the host side only.** How the NAS is configured for these hosts is not in it: whether the NAS has one connection per host (pinned by address and identity) or one for any peer from a subnet (`right=%any`), and whether it allows several peers with one identity (`uniqueids`). That decides Options A and C, and it has to come from the storage team ([questions](#questions-for-the-storage-team)).
- **The enterprise model is one certificate per host.** The certificate's nickname is the host's FQDN, and each host identifies itself by its own certificate. No host shares an identity with another.
- **It narrows the tunnel to NFS.** Our NNCP protects all traffic to the NAS's IP (`rightsubnet: ${NAS_IP}/32`); the reference protects only TCP to port 2049.

## What does not carry over: odd and even

The standard groups host connections under "EVEN" headings (`mytunnel2.conf`, `mytunnel4.conf`): on our Linux hosts, which tunnel and NAS a host uses follows whether its **host name or the last octet of its IP address is odd or even**. **That does not work on OpenShift, and we will not use it.**

| On a Linux host | On OpenShift |
|---|---|
| A person names the host and gives it its address, once | Nodes come from **MachineSets**: the Machine API creates them with generated names and addresses from the network's address management, not chosen by a person |
| The host keeps its name and address for years | Nodes are added when a MachineSet scales up, removed when it scales down, and replaced when a machine health check deletes an unhealthy machine: each new node has a new name and a new address |
| Odd or even is fixed, so a host's tunnel and NAS are too | Odd or even is an accident of the generated name or the address, and changes when the node is replaced. Tracking it per node is a manual list again, which does not scale |

On OpenShift, a group of nodes is chosen by a **node label**, which the cluster sets and keeps: the node's zone (`topology.kubernetes.io/zone`), its MachineSet, or a label of our own on the MachineSet's template. Were the nodes of one cluster ever split between two NAS servers, the split would be by label (Kyverno giving each group the tunnel to its NAS), one rule for all nodes, applied automatically to each new one. We split between clusters instead, below.

**Our approach: one NAS IP per cluster, alternated between clusters.** Every node of a cluster uses that cluster's one NAS IP; the next cluster uses the other NAS IP, and so on. The split that odd and even makes between hosts is made between clusters instead, as one value per cluster in Git (`nas.ip` in its chart values): it never changes when nodes do, and **the charts need no change**, since they build one tunnel to one NAS IP per node today. (Several NAS IPs in one cluster would need one tunnel per NAS per node, by label or to all: new chart work, not planned.)

## Setting by setting, against our NNCP

Our NNCP's libreswan settings are in [`manifests/option-b-per-node-certs/27-kyverno-nncp-per-node.yaml.tmpl`](../manifests/option-b-per-node-certs/27-kyverno-nncp-per-node.yaml.tmpl) (Options A and C use the same keys). The OpenShift columns were read on CRC (OpenShift 4.22.7) on 2026-10-05: NMState **2.2.60** (`nmstatectl --version` in the handler pod), whose `LibreswanConfig` ([source at v2.2.60](https://github.com/nmstate/nmstate/blob/v2.2.60/rust/src/lib/ifaces/ipsec.rs)) lists every NMState field below, and the node's NetworkManager-libreswan plugin (`/usr/libexec/nm-libreswan-service`, which names the libreswan keys it writes), with libreswan 5.3.

| Reference | Our NNCP today | Same? | NMState field on OpenShift 4.22 | Node plugin knows the key |
|---|---|---|---|---|
| `left=<host IP>` | `left: <node FQDN>` (B), `%defaultroute` where there is NAT | Equivalent: the node's own address | `left` | yes |
| `right=<NAS IP>` | `right: ${NAS_FQDN}` (its IP where there is NAT), `rightsubnet: ${NAS_IP}/32` | Equivalent: both reach the NAS's IP; the reference sets no subnet | `right`, `rightsubnet` | yes |
| `leftcert="<host FQDN>"` | `leftcert: left_server` | The nickname is local to the node's NSS database and is not sent; what the NAS sees is `leftid` | `leftcert` | yes |
| `leftid=%fromcert` | `leftid: '%fromcert'` (B, A, C1); `'@<node FQDN>'` (C2) | **Yes** for B, A, C1 | `leftid` | yes |
| `leftrsasigkey`, `rightrsasigkey=%cert` | the same | **Yes** | `leftrsasigkey`, `rightrsasigkey` | yes |
| `leftauth`, `rightauth=rsasig` | not set | Not settable: no NMState field, and the plugin does not write the keys. Every option's node key is RSA 3072, which the libreswan NAS accepted in every run; the reference NAS's acceptance is to confirm | — (only `authby`) | no |
| `rightid=%fromcert` | `rightid: '%fromcert'` | **Yes** | `rightid` | yes |
| `rightca=%same` | not set by default; chart value `ipsec.rightca: '%same'` | **Yes** with the chart value: the node refuses a NAS certificate from any other CA (measured, [evidence 63](evidence/crc/63-rightca-enforcement.txt)) | `rightca` | yes |
| `leftprotoport=tcp`, `rightprotoport=tcp/nfs` | not set by default (all traffic to the NAS's IP); chart values `ipsec.leftprotoport`, `ipsec.rightprotoport` | **Yes** with the chart values (`tcp/2049` avoids the name lookup; measured, [evidence 62](evidence/crc/62-nfs-only-selectors.txt)) | `leftprotoport`, `rightprotoport` | yes |
| no `type` (tunnel) | `type: transport` (`tunnel` where there is NAT) | **No** unless the NAS accepts transport mode from these peers | `type` | in use: the tunnel comes up with it (measured) |
| no `ikev2` (libreswan's default) | `ikev2: insist` | Compatible when the NAS speaks IKEv2 (to confirm) | `ikev2` | yes |
| `auto=start` | NetworkManager activates the connection the NNCP defines | Equivalent | — | — |

All three settings the reference adds to ours were applied to a node on CRC through the charts ([Sample 2](#sample-2--matching-the-enterprise-standard-measured-in-the-lab), [evidence 62](evidence/crc/62-nfs-only-selectors.txt), [evidence 63](evidence/crc/63-rightca-enforcement.txt)).

### Which OpenShift versions carry `rightca` and the port selectors

Two components must know a key before it reaches libreswan: **NMState** (the handler pod turns the NNCP into a NetworkManager connection) and the node's **NetworkManager-libreswan** plugin (it turns that connection into libreswan's configuration). Red Hat's article on IPsec with ONTAP ([7130948](https://access.redhat.com/articles/7130948), updated 2026-09-07, written for OpenShift 4.19) still says `rightca` "is not a supported parameter to use with nmstate" and cites the request [RHEL-114237](https://issues.redhat.com/browse/RHEL-114237). That request is **closed** (Done-Errata, 2026-05-19, fix version `rhel-10.2`); the nmstate change that resolves it is upstream commit [`891e18f4`](https://github.com/nmstate/nmstate/commit/891e18f41d2dbada961931631a15ea09678cce2a) (2025-11-18), first released in **nmstate 2.2.56**.

**Minimum supported OpenShift version for the refined tunnel (Sample 2): 4.19.22, 4.20.11, or any 4.21 or 4.22.** Per release, from the package versions in the two tables further down:

| OpenShift | `rightca` | NFS port selectors (`leftprotoport`, `rightprotoport`) | Sample 2 |
|---|---|---|---|
| 4.19.0 to 4.19.18 | No | No | Not supported |
| 4.19.19 to 4.19.21 | Yes | No | Not supported |
| **4.19.22 and later** | Yes | Yes | **Supported** (not measured) |
| 4.20.0 to 4.20.2 | No | No | Not supported |
| 4.20.3 to 4.20.10 | Yes | No | Not supported |
| **4.20.11 and later** | Yes | Yes | **Supported** (not measured) |
| **4.21** | Yes | Yes | **Supported** (not measured) |
| **4.22** | Yes | Yes | **Supported**, measured on CRC 4.22.7 ([evidence 62](evidence/crc/62-nfs-only-selectors.txt), [63](evidence/crc/63-rightca-enforcement.txt)) |

On a release that has `rightca` but not the selectors (4.19.19 to 4.19.21, 4.20.3 to 4.20.10), `ipsec.rightca` alone may be set, if the NAS does not limit its connection to NFS. Sample 1 uses none of these keys, so this floor does not apply to it. The NMState Operator must also be current: nmstate 2.2.57 or later in its handler (the command below).

| Component | First version with `rightca` | First version with `leftprotoport`/`rightprotoport` | Source |
|---|---|---|---|
| nmstate | 2.2.56 (commit `891e18f4`) | 2.2.57 (commit [`c8c94b75`](https://github.com/nmstate/nmstate/commit/c8c94b75), RHEL-107158) | nmstate git history |
| NetworkManager-libreswan (RHEL 9) | 1.2.27-1 (RHEL-118819) | 1.2.29-1 (RHEL-130907) | [CentOS Stream 9 package changelog](https://gitlab.com/redhat/centos-stream/rpms/NetworkManager-libreswan/-/blob/c9s/NetworkManager-libreswan.spec) |

The NMState handler's package in each release, read on 2026-10-08 from the rpm manifest of the newest `openshift4/ose-kubernetes-nmstate-handler-rhel9` image in the Red Hat container catalog:

| OpenShift | nmstate in the handler | `rightca` and port selectors in NMState |
|---|---|---|
| 4.14, 4.15 | 2.2.39 | No |
| 4.16 to 4.19 | 2.2.59 (el9_4) | Yes |
| 4.20, 4.21 | 2.2.60 (el9_6.1) | Yes |
| 4.22 | 2.2.60 (el9_8) | Yes; measured on CRC 4.22.7 |

The NMState Operator is updated through OLM, apart from the cluster: the table shows the newest handler of each release, and a cluster that has not taken the update runs an older one (the command below shows which).

The node's plugin comes with the OpenShift release (the RHCOS extensions). Its package in each z-stream, read on 2026-10-08 from the release pages of the 4-stable stream ([example: 4.19.49](https://amd64.ocp.releases.ci.openshift.org/releasestream/4-stable/release/4.19.49), *Extensions*); upstream NetworkManager-libreswan has `"rightca"` from tag 1.2.27 and `"leftprotoport"` from 1.2.29:

| OpenShift | NetworkManager-libreswan | `rightca` | Port selectors |
|---|---|---|---|
| 4.19.0 to 4.19.18 | 1.2.24-1.el9 | No | No |
| 4.19.19 to 4.19.21 | 1.2.27-2.el9_6 | Yes | No |
| **4.19.22 and later** | 1.2.29-1.el9_6 | Yes | Yes |
| 4.20.0 to 4.20.2 | 1.2.24-1.el9 | No | No |
| 4.20.3 to 4.20.10 | 1.2.27-2.el9_6 | Yes | No |
| **4.20.11 and later**, 4.21 | 1.2.29-1.el9_6 | Yes | Yes |
| 4.22 | 1.2.30-1.el9 | Yes | Yes; **measured** on CRC 4.22.7 ([evidence 62](evidence/crc/62-nfs-only-selectors.txt), [63](evidence/crc/63-rightca-enforcement.txt)) |

Hence the minimum above; only 4.22 was measured. Red Hat's article was written for 4.19, whose early z-streams indeed lacked `rightca`. On a cluster, read both versions on one of its nodes before using Sample 2:

```sh
oc -n openshift-nmstate exec ds/nmstate-handler -- nmstatectl --version      # 2.2.57 or later
oc debug node/<node> -- chroot /host sh -c 'strings /usr/libexec/nm-libreswan-service | grep -x -e rightca -e leftprotoport -e rightprotoport'
```

Both commands were run on CRC 4.22.7: `nmstatectl 2.2.60`, and the plugin printed all three keys.

## Each option against the reference

What each option makes a node present, from our manifests and charts:

| | Certificate | Identity the NAS sees (`rightid=%fromcert`) | Key |
|---|---|---|---|
| **B** | One per node, from the enterprise CA (cert-manager) | `CN=<node>.<NODE_DOMAIN>`: **its own** | RSA 3072 |
| **C** | One wildcard certificate per pool, `SAN *.<NODE_DOMAIN>` | `CN=ocp-ipsec-workers, O=KCS` on **every** node (C1 and C2 alike: the NAS takes the certificate's DN; [doc 51](51-option-c-summary.md)) | RSA 3072 |
| **A** | One certificate for every node, its SAN listing each node | `CN=ocp-ipsec-workers, O=KCS` on **every** node | RSA 3072 |

What the NAS does with them, measured against a libreswan NAS ([lab/lima-lab.md, *What the lab showed*](lab/lima-lab.md#8-what-the-lab-showed); [doc 51](51-option-c-summary.md)):

| Option | Matches the reference's model (one certificate per host) | With the NAS on its defaults (`uniqueids=yes`) | What the NAS must change | Verdict |
|---|---|---|---|---|
| **B** | **Yes**: a node is one more host with its own certificate from the same CA | **Works**: two peers with their own certificates held two tunnels at once (lab finding 3) | Nothing beyond accepting the nodes as peers: by subnet with `right=%any`, `rightid=%fromcert`, `rightca=%same` (no change per node), or one entry per node if the NAS pins its peers | **Fits the enterprise standard** |
| **C** | **No**: every node shares one identity | **Fails**: the nodes replace each other's tunnel (cases 1, 3, 5); the NAS never held more than one | `uniqueids=no`, a setting for the whole NAS, so every peer may share an identity, not only the nodes (cases 2, 6, 7 work) | **Works only if the storage team accepts shared identities** on that NAS |
| **A** | **No**: as C | **Fails**: the NAS never held two tunnels (lab finding 4) | `uniqueids=no` (finding 5) | As C, with by-hand renewal and a reboot of every node; not used ([doc 10](10-option-a-shared-certificate.md)) |

The certificate chain is the same for all three: every node certificate and the NAS's come from the one enterprise CA ([doc 00, 3.1](00-prepare-the-cluster.md#31-nas-configuration-storage-team-not-us)), which is what `rightca=%same` checks.

## `uniqueids` and Option B

`uniqueids` is not in the reference configuration because it is not a connection setting: it belongs to `config setup`, and the one that matters is the **NAS's**. libreswan's manual: "Acceptable values are `yes` (the default) and `no`. Participant IDs normally are unique, so a new connection instance using the same remote ID is almost invariably intended to replace an old existing connection" ([`ipsec.conf(5)`](https://libreswan.org/man/ipsec.conf.5.html)). It only ever compares peers that present the **same** identity.

| Peers present | NAS `uniqueids` | Result | Measured |
|---|---|---|---|
| Each its own certificate (**Option B**) | `yes` (default) | **Two tunnels at once, both NFS writes through IPsec** | Lima lab, finding 3: the base run sets the NAS up with `nas_setup no`, which writes `uniqueids=yes` (`lab/lab.sh`, `lab/rhel/setup-nas.sh`) |
| One shared identity (A, C) | `yes` | One tunnel at a time: the nodes replace each other | Lab finding 4; Option C cases 1, 3, 5 |
| One shared identity (A, C) | `no` | Works | Lab finding 5; Option C cases 2, 6, 7 |
| Each its own certificate (B) | `no` | Not measured with two peers | — |

So **Option B needs no `uniqueids` change on the NAS**: every node's identity (`CN=<node>.<NODE_DOMAIN>`) is its own, so no two nodes ever collide, and the default `yes` keeps working. The default also suits it: when a node reboots and connects again under its own identity, the new connection replaces that node's old one (from the manual's definition; not measured on a NAS with several nodes). `uniqueids=no` is needed only where nodes share an identity, Options A and C, and it applies to every peer of that NAS.

## Sample NNCP for Option B (NAS on `uniqueids=yes`)

Under Option B no one writes the NNCP by hand: Kyverno's policy `ipsec-nncp-per-node` ([`27-kyverno-nncp-per-node.yaml.tmpl`](../manifests/option-b-per-node-certs/27-kyverno-nncp-per-node.yaml.tmpl), or the chart) generates one per node once that node's certificate is imported ([doc 20](20-option-b-per-node-certificates.md)). The samples show what it generates for one node, with the docs' example values (node `worker-0`, `NODE_DOMAIN=ocp.example.com`, `NAS_FQDN=nas01.example.com`, `NAS_IP=10.10.10.50`).

The node's certificate, for reference: `CN=worker-0.ocp.example.com`, SAN `DNS:worker-0.ocp.example.com`, RSA 3072, from the enterprise CA through cert-manager, imported into the node's NSS database as `left_server`.

### Sample 1 – As Option B deploys it (measured)

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ipsec-nas-worker-0                       # one per node: ipsec-nas-<node>
spec:
  nodeSelector:
    kubernetes.io/hostname: worker-0             # this node only
  desiredState:
    interfaces:
    - name: ipsec-nas
      type: ipsec
      libreswan:
        left: worker-0.ocp.example.com           # the node's own name: its certificate's DNS name
        leftid: '%fromcert'                      # the NAS sees CN=worker-0.ocp.example.com: unique per node
        leftrsasigkey: '%cert'
        leftcert: left_server                    # NSS nickname on the node; not sent to the NAS
        leftmodecfgclient: false
        right: nas01.example.com                 # the NAS; its certificate's SAN
        rightid: '%fromcert'
        rightrsasigkey: '%cert'
        rightsubnet: 10.10.10.50/32              # the NFS IP: all traffic to it goes through the tunnel
        ikev2: insist
        type: transport                          # tunnel where there is NAT
```

Measured on CRC: the NNCP `Available` 13 seconds after the policy, the NAS log `authenticated peer certificate 'CN=crc.crc.testing' and 3072-bit RSASSA-PSS with SHA2_512 digital signature` ([evidence 17](evidence/crc/17-option-b-tunnel.txt)); against a NAS on `uniqueids=yes` with two peers, the Lima lab (finding 3).

### Sample 2 – Matching the enterprise standard (measured in the lab)

The same NNCP with the three settings of the reference that ours lacks. Every field exists in NMState and in the node's NetworkManager-libreswan plugin from OpenShift 4.19.22, 4.20.11 and 4.21 ([which versions](#which-openshift-versions-carry-rightca-and-the-port-selectors)). NMState accepts it: on CRC, `nmstatectl gc` (which generates the configuration without applying it) turned its `desiredState` into a NetworkManager connection with `leftprotoport=tcp`, `rightca=%same`, `rightprotoport=tcp/2049` and `type=tunnel` among its `[vpn]` keys. It was then applied on OpenShift Local through the charts' new values: see *Measured in the lab* below.

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ipsec-nas-worker-0
spec:
  nodeSelector:
    kubernetes.io/hostname: worker-0
  desiredState:
    interfaces:
    - name: ipsec-nas
      type: ipsec
      libreswan:
        left: worker-0.ocp.example.com
        leftid: '%fromcert'
        leftrsasigkey: '%cert'
        leftcert: left_server
        leftmodecfgclient: false
        leftprotoport: tcp                       # NEW, as the reference: TCP only...
        right: nas01.example.com
        rightid: '%fromcert'
        rightrsasigkey: '%cert'
        rightca: '%same'                         # NEW: the NAS's certificate from the node's own CA
        rightsubnet: 10.10.10.50/32
        rightprotoport: tcp/2049                 # NEW: ...to NFS on the NAS (the reference's tcp/nfs)
        ikev2: insist
        type: tunnel                             # CHANGED: the reference's mode (libreswan's default)
```

What changes with it: only TCP to port 2049 on the NAS goes through the tunnel; anything else to the NAS (`ping`, NFSv3's helpers) leaves the node in clear, and an IPsec-only NAS drops it. Whether to use it depends on the storage team's answers: if the NAS's connection for hosts is limited to TCP 2049, Sample 1 may be refused and Sample 2 needed ([finding 4](#findings)). In Option B it is set once, as the chart values `ipsec.rightca`, `ipsec.leftprotoport`, `ipsec.rightprotoport` and `ipsec.type`, which the chart's Kyverno policy writes into every node's NNCP; no one edits a node's NNCP.

`rightca: '%same'` also works on its own: it was measured without port selectors, in tunnel mode (transport mode with it not measured). With it the node accepts the NAS only with a certificate from the CA that issued the node's own; without it, from any CA in the node's NSS database ([evidence 63](evidence/crc/63-rightca-enforcement.txt)).

**Measured in the lab** ([evidence 62](evidence/crc/62-nfs-only-selectors.txt), [evidence 63](evidence/crc/63-rightca-enforcement.txt)), on OpenShift Local through the charts' new values `ipsec.rightca`, `ipsec.leftprotoport` and `ipsec.rightprotoport` (tunnel mode, as the lab needs for its NAT), against the libreswan NAS:

| The NAS's connection | The node's NNCP | Result |
|---|---|---|
| NFS only (`leftprotoport=tcp/2049`, `rightprotoport=tcp`) | Sample 1 (all traffic to the NAS) | **Refused**: `TS_UNACCEPTABLE`; the IKE SA authenticates, no Child SA, no tunnel |
| NFS only | **Sample 2** | **Tunnel up**, `[…/32/TCP===…/32/TCP/2049]`; NFS through it; a `ping` to the NAS goes outside the tunnel |
| All traffic (no selectors) | Sample 2 | **Refused**: `TS_UNACCEPTABLE` |
| Certificate from the node's CA | `rightca: '%same'` | **Tunnel up**; libreswan's connection lists the CA on both sides: `CAs: 'O=Enterprise POC, CN=Enterprise Root CA'...'O=Enterprise POC, CN=Enterprise Root CA'` (`'%any'` on the NAS's side without it) |
| Certificate from **another CA**, which the node also trusts | `rightca: '%same'` | **Refused by the node**: `authentication failed: no certificate matched … 'CN=crc-nas.lab.internal, O=rightca test'` |
| The same | no `rightca` | **Tunnel up**: `authenticated peer certificate … issued by 'CN=Other Lab Root CA'`, so `rightca` alone made the difference |

The NAS narrowed the request in neither direction: **the NNCP's selectors must match the NAS's exactly**, so the storage team's answer decides which sample to use. Not measured: an enterprise NAS product, which may narrow differently; transport mode with port selectors or `rightca`.

Three behaviours the runs showed, for anyone repeating them:

- **A changed NNCP leaves the node without a tunnel until the connection is restarted.** NetworkManager takes the new keys and removes libreswan's old connection without loading the new one; `nmcli connection down` then `up` loads it. Option B's cert-sync pod restarts the connection when it finds no tunnel; that path was not measured after an NNCP change.
- **libreswan writes a distinguished name with `O=` first** (`O=Enterprise POC, CN=Enterprise Root CA`), the other way round from `openssl` and `certutil`. A `rightca` written as an explicit name in the wrong order matches nothing; `%same` avoids the question.
- **pluto caches its root certificates**: a CA added to the NSS database while it runs is used only after `ipsec whack --rereadcerts`.

### The NAS side for both samples (`uniqueids=yes`)

The configuration Option B was measured against in the lab ([`lab/rhel/setup-nas.sh`](../lab/rhel/setup-nas.sh) with its default `ALLOW_DUPLICATE_IDS=no`): one connection for every node, no change per node, `uniqueids` left at its default.

```text
# /etc/ipsec.conf
config setup
    uniqueids=yes                      # the default; every node has its own identity

# /etc/ipsec.d/nas-workers.conf
conn workers
    left=<NAS IP>
    leftid=%fromcert
    leftcert=nas
    leftrsasigkey=%cert
    right=%any                         # any node; the firewall limits it to the worker subnet
    rightid=%fromcert                  # each node's own CN=<node>.<NODE_DOMAIN>
    rightrsasigkey=%cert
    rightca=%same
    ikev2=insist
    type=transport
    auto=add
```

On the NAS, `ipsec trafficstatus` then lists one tunnel per node, each with its own `id='CN=<node>.<NODE_DOMAIN>'`. For Sample 2 the NAS's connection carries the matching `type=tunnel` and port selectors (`leftprotoport=tcp/2049`, `rightprotoport=tcp`, the NAS being `left` there); measured in the lab ([evidence 62](evidence/crc/62-nfs-only-selectors.txt), section 2).

## Findings

1. **Option B is the option that matches the enterprise standard.** The standard gives every host its own certificate and identity; Option B gives every node its own certificate from the same CA, and it worked against a libreswan NAS on its default settings. It is already our standard ([docs/README.md](README.md)).
2. **Options A and C need the NAS to accept one identity from many peers** (`uniqueids=no`). The standard has no case of hosts sharing an identity, so the NAS may not allow it today. Measured against libreswan only; another NAS product has its own setting, or none (issue #34).
3. **The three settings of the standard our NNCP lacked, `rightca=%same`, the NFS port selectors and tunnel mode, work on OpenShift.** They are chart values in both charts, empty by default, and were measured on CRC 4.22.7: `rightca: '%same'` refuses a NAS certificate from another CA and accepts one from the node's own ([evidence 63](evidence/crc/63-rightca-enforcement.txt)); the selectors carry NFS only ([evidence 62](evidence/crc/62-nfs-only-selectors.txt)). Red Hat's article on ONTAP still calls `rightca` unsupported in NMState; its request RHEL-114237 is closed, and the NMState and node plugin support it from OpenShift 4.19.22, 4.20.11 and 4.21 ([which versions](#which-openshift-versions-carry-rightca-and-the-port-selectors)).
4. **The port selectors must match the NAS's exactly.** Measured against the lab's libreswan NAS ([evidence 62](evidence/crc/62-nfs-only-selectors.txt)): a NAS limited to TCP 2049 refused the node's all-traffic request (`TS_UNACCEPTABLE`), and a NAS without selectors refused the node's NFS-only request. Which one to use is the storage team's answer.
5. **`leftauth`/`rightauth=rsasig` cannot be set from OpenShift** (no NMState field, not written by the plugin). With RSA keys on every option, authentication is by RSA signature anyway: on CRC the node signed with `3072-bit RSASSA-PSS with SHA2_512` ([evidence 17](evidence/crc/17-option-b-tunnel.txt)). Confirm the enterprise NAS accepts RSA-PSS signatures.

## Questions for the storage team

- [ ] For the existing Linux hosts: does the NAS have one connection per host (address and identity pinned), or one for any peer from a subnet?
- [ ] Is that connection limited to TCP 2049 (port selectors on the NAS side too)?
- [ ] Tunnel or transport mode on the NAS's side?
- [ ] `uniqueids` (or the product's equivalent): may several peers present the same certificate identity? (Only matters for A and C.)
- [ ] IKEv2 only, and which IKE and ESP proposals?
- [ ] The NAS product and version.

## What to test next

Done on CRC and the lab NAS: the NAS set like the standard's counterpart against today's NNCP (refused, [evidence 62](evidence/crc/62-nfs-only-selectors.txt) section 1); Sample 2 applied through the chart (tunnel up, NFS through it, section 2); a `ping` to the NAS leaves the node in clear (section 2; the lab NAS answered it, as its firewall drops only cleartext NFS); `rightca: '%same'` enforced ([evidence 63](evidence/crc/63-rightca-enforcement.txt)).

Still to measure:

1. Against the enterprise NAS, in the PoC ([doc 72](72-option-b-implementation-plan.md#6-the-engineering-poc), criterion 3).
2. Transport mode with the port selectors and `rightca` (CRC needs tunnel mode for its NAT; a Lima worker does not).
3. Option B's cert-sync pod restarting the connection by itself after an NNCP change (both runs restarted it by hand).
4. A node on OpenShift 4.19.22 or 4.20.11 or later, to confirm the version table above on a real cluster.
