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

On OpenShift, a group of nodes is chosen by a **node label**, which the cluster sets and keeps: the node's zone (`topology.kubernetes.io/zone`), its MachineSet, or a label of our own on the MachineSet's template. If the nodes must be split between two NAS servers, the split is by label (Kyverno gives each group the tunnel to its NAS); otherwise every node gets one tunnel per NAS IP. Either way it is one rule for all nodes, applied automatically to each new one.

**Today the charts build one tunnel, to one NAS IP, per node.** More than one NAS IP per cluster needs one tunnel per NAS per node, chosen by label or applied to all: new work in the charts, the same Kyverno and NNCP pattern. How many NAS IPs the nodes will use is a question for the storage team ([doc 71](71-option-b-nas-team-engagement.md#what-we-ask)).

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
| `rightca=%same` | not set | **No**; could be added | `rightca` | yes |
| `leftprotoport=tcp`, `rightprotoport=tcp/nfs` | not set: all traffic to the NAS's IP | **No**; could be added (`tcp/2049` avoids the name lookup) | `leftprotoport`, `rightprotoport` | yes |
| no `type` (tunnel) | `type: transport` (`tunnel` where there is NAT) | **No** unless the NAS accepts transport mode from these peers | `type` | in use: the tunnel comes up with it (measured) |
| no `ikev2` (libreswan's default) | `ikev2: insist` | Compatible when the NAS speaks IKEv2 (to confirm) | `ikev2` | yes |
| `auto=start` | NetworkManager activates the connection the NNCP defines | Equivalent | — | — |

None of the three settings marked "could be added" has been tried on a node yet.

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

The same NNCP with the three settings of the reference that ours lacks. Every field exists in NMState 2.2.60 on OpenShift 4.22 and in the node's NetworkManager-libreswan plugin ([setting by setting](#setting-by-setting-against-our-nncp)). NMState accepts it: on CRC, `nmstatectl gc` (which generates the configuration without applying it) turned its `desiredState` into a NetworkManager connection with `leftprotoport=tcp`, `rightca=%same`, `rightprotoport=tcp/2049` and `type=tunnel` among its `[vpn]` keys. It was then applied on OpenShift Local through the charts' new values: see *Measured in the lab* below.

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

What changes with it: only TCP to port 2049 on the NAS goes through the tunnel; anything else to the NAS (`ping`, NFSv3's helpers) leaves the node in clear, and an IPsec-only NAS drops it. Whether to use it depends on the storage team's answers: if the NAS's connection for hosts is limited to TCP 2049, Sample 1 may be refused and Sample 2 needed ([finding 4](#findings)). In Option B it would go into the policy's template (`27-kyverno-nncp-per-node.yaml.tmpl`, or the chart's), not into each node's NNCP.

**Measured in the lab** ([evidence 62](evidence/crc/62-nfs-only-selectors.txt)), on OpenShift Local through the charts' new values `ipsec.rightca`, `ipsec.leftprotoport` and `ipsec.rightprotoport` (tunnel mode, as the lab needs for its NAT), against the libreswan NAS:

| The NAS's connection | The node's NNCP | Result |
|---|---|---|
| NFS only (`leftprotoport=tcp/2049`, `rightprotoport=tcp`) | Sample 1 (all traffic to the NAS) | **Refused**: `TS_UNACCEPTABLE`; the IKE SA authenticates, no Child SA, no tunnel |
| NFS only | **Sample 2** | **Tunnel up**, `[…/32/TCP===…/32/TCP/2049]`; NFS through it; a `ping` to the NAS goes outside the tunnel |
| All traffic (no selectors) | Sample 2 | **Refused**: `TS_UNACCEPTABLE` |

The NAS narrowed the request in neither direction: **the NNCP's selectors must match the NAS's exactly**, so the storage team's answer decides which sample to use. Not measured: an enterprise NAS product, which may narrow differently; transport mode with port selectors.

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

On the NAS, `ipsec trafficstatus` then lists one tunnel per node, each with its own `id='CN=<node>.<NODE_DOMAIN>'`. For Sample 2 the NAS's connection would carry the matching `type=tunnel` and port selectors (`leftprotoport=tcp/2049`, `rightprotoport=tcp`, the NAS being `left` there); not tested.

## Findings

1. **Option B is the option that matches the enterprise standard.** The standard gives every host its own certificate and identity; Option B gives every node its own certificate from the same CA, and it worked against a libreswan NAS on its default settings. It is already our standard ([docs/README.md](README.md)).
2. **Options A and C need the NAS to accept one identity from many peers** (`uniqueids=no`). The standard has no case of hosts sharing an identity, so the NAS may not allow it today. Measured against libreswan only; another NAS product has its own setting, or none (issue #34).
3. **Three settings of the standard are not in our NNCP: `rightca=%same`, the NFS port selectors, and tunnel mode.** All three exist in NMState 2.2.60 and the node's plugin on OpenShift 4.22, so any option can carry them; they were not tested.
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

On CRC and the lab NAS, with Option B's settings on a node (CRC runs Option C today; the test needs Option B there, or the C2 tunnel values):

1. The NAS's connection set like the standard's counterpart (port selectors `tcp/2049`, tunnel mode, `rightca=%same`), and the node's NNCP **unchanged**: does the tunnel come up? This answers finding 4.
2. The NNCP with `leftprotoport: tcp`, `rightprotoport: tcp/2049`, `rightca: '%same'`, `type: tunnel`: does NMState accept it, does the tunnel come up, and do NFS writes go through it?
3. Traffic to the NAS other than TCP 2049 (for example `ping`) with the port selectors: it leaves the node in clear, and an IPsec-only NAS should not answer it.
