# Review — Our Enterprise Linux IPsec Configuration, and Which Option Matches It

**Audience:** platform engineers and the storage team. **Question:** our regular Linux hosts already reach the NAS over IPsec with an enterprise standard configuration. Which OpenShift setup option (A, B or C) lets the nodes connect to the same NAS the same way, and what would change?

**Contents:** [The reference configuration](#the-reference-configuration) · [What it tells us, and what it does not](#what-it-tells-us-and-what-it-does-not) · [Setting by setting, against our NNCP](#setting-by-setting-against-our-nncp) · [Each option against the reference](#each-option-against-the-reference) · [Findings](#findings) · [Questions for the storage team](#questions-for-the-storage-team) · [What to test next](#what-to-test-next)

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

## Findings

1. **Option B is the option that matches the enterprise standard.** The standard gives every host its own certificate and identity; Option B gives every node its own certificate from the same CA, and it worked against a libreswan NAS on its default settings. It is already our standard ([docs/README.md](README.md)).
2. **Options A and C need the NAS to accept one identity from many peers** (`uniqueids=no`). The standard has no case of hosts sharing an identity, so the NAS may not allow it today. Measured against libreswan only; another NAS product has its own setting, or none (issue #34).
3. **Three settings of the standard are not in our NNCP: `rightca=%same`, the NFS port selectors, and tunnel mode.** All three exist in NMState 2.2.60 and the node's plugin on OpenShift 4.22, so any option can carry them; they were not tested.
4. **The port selectors may be required, not optional.** If the NAS's connection for these hosts is limited to TCP 2049, a node proposing all traffic to the NAS's IP may be refused unless the NAS narrows the proposal. Whether it does depends on its configuration; this is the first thing to test.
5. **`leftauth`/`rightauth=rsasig` cannot be set from OpenShift** (no NMState field, not written by the plugin). With RSA keys on every option, authentication is by RSA signature anyway; confirm the NAS does not insist on a specific RSA signature scheme the node does not offer.

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
