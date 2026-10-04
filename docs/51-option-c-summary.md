# Option C — Summary: What Works

Option C gives every node of a pool one wildcard certificate (`*.<NODE_DOMAIN>`) through a MachineConfig. The full design and steps are in [50-option-c-wildcard-certificate.md](50-option-c-wildcard-certificate.md); the NAS team's handout is [52-option-c-nas-team.md](52-option-c-nas-team.md).

## What the lab showed

In every combination that held both peers' tunnels, the NAS had `uniqueids=no` (cases 2, 6, 7). With the default `uniqueids=yes`, it failed in every variant. Measured with a libreswan 5.4 NAS and two stand-in workers (Lima VMs whose libreswan the lab script configures directly, not OpenShift nodes) sharing one wildcard certificate; on OpenShift, one CRC node confirmed that NMState sends the same identities for C1 and C2 (evidence 35, 49). **The results apply to an OpenShift cluster with the same settings:** the NAS decides from each peer's identity and certificate only, OpenShift nodes send the same ones (one wildcard certificate; the certificate's DN under C1, `@<node>.<domain>` under C2, measured on CRC), and the lab's two peers reached the NAS from two addresses, as nodes do ([`evidence/crc/34-option-c-lab-identities.txt`](evidence/crc/34-option-c-lab-identities.txt)).

**With the default `uniqueids=yes`, the nodes step on each other's tunnel.** Every node presents the same identity, so the NAS keeps one tunnel for it and each node's connection replaces the previous one, over and over. In case 1 the NAS never held more than one tunnel in 15 one-second samples, and its connection instance counter was at 444 by the end; in the earlier Option A run with one shared certificate it reached 744 in about 15 seconds ([`docs/lab/lima-lab.md`](lab/lima-lab.md), result 4). Per-node names (C2) do not prevent it: with `rightid=%fromcert` the NAS still identifies every node by the certificate's DN (case 3). What NFS does meanwhile was not measured: the lab checks NFS only when both tunnels hold. `uniqueids=no` on the NAS is the fix (cases 2, 6, 7):


| Variant | Identity sent / NAS `rightid` | With `uniqueids=yes` | With `uniqueids=no` |
|---|---|---|---|
| C1 | certificate DN / `%fromcert` | case 1: one tunnel at a time | **case 2: works** |
| C2 | own FQDN / `%fromcert` | case 3: one tunnel at a time | **case 7: works** |
| C2 | own FQDN / `@*.internal` | case 5: one tunnel at a time | **case 6: works** |
| C2 | own FQDN / `%any` | case 4: refused | – |

## What the NAS team must do for the three setups that work

| Setup | Nodes send | NAS `rightid` | NAS `uniqueids` | Result |
|---|---|---|---|---|
| Case 2 (C1) | the certificate's DN (`leftid=%fromcert`) | `%fromcert` | `no` | 2 tunnels, both NFS writes through IPsec |
| Case 7 (C2) | each its own FQDN (`leftid=@<node>.<NODE_DOMAIN>`) | `%fromcert` | `no` | 2 tunnels, both NFS writes through IPsec |
| Case 6 (C2) | each its own FQDN | `@*.<NODE_DOMAIN>` | `no` | 2 tunnels, both NFS writes through IPsec |

Cases 2 and 7 use the same NAS settings, `rightid=%fromcert` and `uniqueids=no`: one NAS configuration serves C1 and C2.

For all three, the NAS also needs:

| Setting | Value (libreswan) |
|---|---|
| Several peers with the same identity | `uniqueids=no` in `config setup` |
| Trust the enterprise root CA | `rightca=%same` |
| Accept any peer address | `right=%any` |
| Its own certificate from the same CA, key made on the NAS | `leftcert=<NAS certificate>`, SAN `NAS_FQDN` |
| IKEv2 | `ikev2=insist`, `type=transport` (tunnel only where there is NAT) |
| Firewall | UDP 500, 4500 and ESP (protocol 50) from the worker subnet only |
| NFS | TCP 2049 accepted only when it arrived through IPsec; cleartext dropped |
