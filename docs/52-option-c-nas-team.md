# Option C — What the NAS Team Must Do

**Audience:** the storage (NAS) team. **For:** clusters that use Option C, one wildcard certificate shared by every node ([50-option-c-wildcard-certificate.md](50-option-c-wildcard-certificate.md)). Option B, one certificate per node, needs none of the settings marked **Option C only** below.

Every node presents the **same** certificate, so the NAS sees many peers with one identity. The NAS must accept that. Everything else is the setup it already has for IPsec with certificates ([00-prepare-the-cluster.md, 3.1](00-prepare-the-cluster.md#31-nas-configuration-storage-team-not-us)).

Every row below was measured with a libreswan 5.4 NAS: in the Lima lab with two stand-in workers (Lima VMs, not OpenShift nodes) sharing one certificate ([`evidence/crc/34-option-c-lab-identities.txt`](evidence/crc/34-option-c-lab-identities.txt)), and on OpenShift Local ([`evidence/crc/35`](evidence/crc/35-option-c-crc-install.txt) to [`37`](evidence/crc/37-option-c-crc-removal-and-b-restored.txt)). A NAS product other than libreswan has its own name for each setting; the meaning is what must match.

## What we send the NAS team

| What | Value |
|---|---|
| Worker subnet(s) | Every node address that will connect |
| Enterprise root CA | The CA that signed the node certificate (PEM) |
| Node certificate identity | Subject `CN=ocp-ipsec-workers, O=KCS`, SAN `DNS:*.<NODE_DOMAIN>`, public part only. Every node presents this one |
| NAS name and NFS IP | `NAS_FQDN`, `NAS_IP`, as the nodes use them |

## What the NAS team must do

| # | Do this | Value (libreswan) | Why | How to check | Measured |
|---|---|---|---|---|---|
| 1 | **Allow several peers with the same identity** — Option C only | `uniqueids=no` in `config setup` | Every node presents one certificate. With the default, the NAS keeps one tunnel and the nodes keep replacing each other | `ipsec trafficstatus`: one tunnel per node, all with the same `id`, and they stay | Lab cases 2, 6, 7 work; cases 1, 3, 5 with `uniqueids=yes` never held more than one tunnel |
| 2 | **Take the peer's identity from its certificate** | `rightid=%fromcert` | Works whatever identity the node sends (C1: the certificate's subject; C2: the node's FQDN) | Peers are listed with `id='CN=ocp-ipsec-workers, O=KCS'` | Lab cases 2 (C1) and 7 (C2). `rightid=%any` refused every FQDN identity (case 4) |
| 3 | Trust the enterprise root CA | `rightca=%same` (the CA of the NAS certificate) | The node certificate chains to it | `ipsec status` lists the CA for the connection | Every working case |
| 4 | Accept any peer from the worker subnet, not a host list | `right=%any` | A new node connects with no NAS change | A node not seen before connects | Lima lab, Option B and C |
| 5 | Use the NAS's own certificate from the same CA, key made on the NAS | `leftcert=<NAS certificate>`, SAN `NAS_FQDN` | The nodes check the NAS against the root they trust | `openssl verify -CAfile root.pem nas.crt` prints `OK` | As for Option B |
| 6 | IKEv2, transport mode | `ikev2=insist`, `type=transport` (tunnel only where there is NAT) | The nodes' tunnel definition insists on IKEv2 | The tunnel comes up | As for Option B |
| 7 | Firewall IKE and ESP to the worker subnet only | UDP 500, 4500 and ESP (protocol 50) from the worker subnet | **The identity a node claims is not a control**: a node presenting a name outside the wildcard was accepted. The subnet and the CA are | Packets from outside the subnet are dropped | Negative case in the lab |
| 8 | Reject NFS that does not arrive through IPsec | Accept TCP 2049 only with `meta ipsec exists` (nftables), drop the rest | A tunnel restart must never fall back to cleartext | The cleartext drop counter rises when no tunnel is up; the NFS-over-IPsec counter carries the traffic | Lima lab finding 2; [40-lab-crc-and-nas.md, Step C.5](40-lab-crc-and-nas.md#step-c5--confirm-the-nas-refuses-nfs-without-ipsec) |
| 9 | At a renewal (every 2 years): **nothing to change** | – | Same CA, same subject | The NAS authenticates the renewed certificate | Measured on CRC: NAS files untouched, renewed certificate authenticated |
| 10 | When the nodes' identity changes (moving from Option B to C, or between C1 and C2): **clear the old connection instances** | `systemctl restart ipsec`, or delete the old states | The NAS refused a node's new identity while it still held an instance for that address under the old one | The node connects with its new identity | Measured on CRC (Gotcha 19) |

## The reference configuration (libreswan, as measured)

```text
# /etc/ipsec.conf
config setup
    uniqueids=no                       # row 1

# /etc/ipsec.d/nas-workers.conf
conn workers
    left=%defaultroute                 # the NAS address the nodes connect to
    leftid=%fromcert
    leftcert=nas                       # row 5
    leftrsasigkey=%cert
    right=%any                         # row 4
    rightid=%fromcert                  # row 2
    rightrsasigkey=%cert
    rightca=%same                      # row 3
    ikev2=insist                       # row 6
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

The lab's test NAS is this configuration: [`lab/rhel/setup-nas.sh`](../lab/rhel/setup-nas.sh) with `ALLOW_DUPLICATE_IDS=yes`.

## What the NAS team sends back

- [ ] Confirmation of row 1, and the setting that does it on their product
- [ ] The NAS certificate, public part only, with its SAN, its issuer chain and its expiry date
- [ ] The IKE and ESP proposals the NAS accepts, if not the defaults
- [ ] The NFS IP(s) protected
- [ ] The NAS product and version, and whether it checks a peer's identity against the certificate's SAN. If it does, and requires one identity per node, we use C2 (`leftid: '@<node>.<NODE_DOMAIN>'`); measured only against libreswan

## Not measured

- A NAS product other than libreswan (issue #34).
- More than two nodes. A single node does not need row 1; any real pool does.
