# Option C — Summary: What Works

Option C gives every node of a pool one wildcard certificate (`*.<NODE_DOMAIN>`) through a MachineConfig. The full design and steps are in [50-option-c-wildcard-certificate.md](50-option-c-wildcard-certificate.md); the NAS team's handout is [52-option-c-nas-team.md](52-option-c-nas-team.md).

## What the lab showed

In every combination that held two nodes' tunnels, the NAS had `uniqueids=no` (cases 2, 6, 7). With the default `uniqueids=yes`, it failed in every variant. Measured with a libreswan 5.4 NAS and two nodes sharing one wildcard certificate ([`evidence/crc/34-option-c-lab-identities.txt`](evidence/crc/34-option-c-lab-identities.txt)):

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
