# Option C — Summary

**What it is:** one certificate for `*.<NODE_DOMAIN>`, valid two years, delivered to every node of a pool by a MachineConfig. The full design, steps and measurements are in [50-option-c-wildcard-certificate.md](50-option-c-wildcard-certificate.md); what the NAS team must do is in [52-option-c-nas-team.md](52-option-c-nas-team.md).

| | C1 | C2 |
|---|---|---|
| Tunnel definition | One NNCP for the whole pool | One NNCP per node, made by Kyverno |
| Identity a node sends | The certificate's subject | The node's own FQDN |
| Components beyond OpenShift | None | Kyverno |
| NAS must allow duplicate peer IDs | Yes | Yes |

**What was measured:**

- **Lima lab** (libreswan 5.4 NAS, two nodes sharing one certificate `*.internal`): with `uniqueids=no`, 2 tunnels and both NFS writes through IPsec, for C1 and for C2 ([`evidence/crc/34-option-c-lab-identities.txt`](evidence/crc/34-option-c-lab-identities.txt)).
- **OpenShift Local** ([`evidence/crc/35`](evidence/crc/35-option-c-crc-install.txt) to [`37`](evidence/crc/37-option-c-crc-removal-and-b-restored.txt)):
  - A 2-year certificate from the cluster's enterprise CA, imported at boot by the MachineConfig.
  - C1's tunnel was up 10 seconds after its NNCP.
  - A renewal took one reboot; the tunnel came back by itself and the NAS needed no change.
  - Switching to C2 needed a connection restart on the node and clearing the NAS's old instance.
  - Removal left the certificate and key in the node's database until removed.
  - Option B was put back from Git.
- **Not measured:** a node joining a real pool, and a NAS product other than libreswan (issue #34).

## `uniqueids` must be `no` in every setup that worked

In every combination that held two nodes' tunnels, the NAS had `uniqueids=no` (cases 2, 6, 7). With the default `uniqueids=yes`, every variant failed:

| Variant | Identity sent / NAS `rightid` | With `uniqueids=yes` | With `uniqueids=no` |
|---|---|---|---|
| C1 | certificate DN / `%fromcert` | case 1: one tunnel at a time | case 2: works |
| C2 | own FQDN / `%fromcert` | case 3: one tunnel at a time | case 7: works |
| C2 | own FQDN / `@*.internal` | case 5: one tunnel at a time | case 6: works |
| C2 | own FQDN / `%any` | case 4: refused | – |

Even when each node sends its own name, the libreswan NAS records one identity for all of them: the certificate's DN, or `@*.internal`. So it must allow duplicates.

What this does and does not cover:

1. **More than one node.** A single node does not need it: the CRC run worked with `uniqueids=yes` because only one peer connected. Any real pool has several nodes, so in practice it is required.
2. **libreswan only.** Your NAS product will have its own equivalent setting. A product that tells peers apart by the name each node sends, rather than by the certificate, might not need it with C2. That is not measured: it is the question in the NAS team's checklist ([52-option-c-nas-team.md](52-option-c-nas-team.md)) and in issue #34.
3. **The variants tried.** The NAS identity settings tested were `%fromcert`, `%any` and a wildcard ID. Another libreswan configuration is not ruled out, but none of these avoided it.

For a libreswan NAS: **`uniqueids=no` is required for C1 and for C2.**
