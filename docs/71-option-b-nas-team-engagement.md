# Option B — Summary for the NAS Team, and What Is Left for Us to Specify

**Audience:** the platform engineers who meet the storage (NAS) team and the PKI team. **Status:** 2026-10-07, before the first meeting. **Read with:** [doc 70](70-review-enterprise-linux-ipsec-config.md) (our enterprise Linux IPsec standard against the options) and [doc 72](72-option-b-implementation-plan.md) (the implementation plan).

**Contents:** [Where we stand](#where-we-stand) · [The meeting with the NAS team](#the-meeting-with-the-nas-team) · [The certificate profile for Venafi](#the-certificate-profile-for-venafi) · [What is left for us to specify](#what-is-left-for-us-to-specify) · [Decision log](#decision-log)

## Where we stand

| | Fact | Source |
|---|---|---|
| Our enterprise standard | Every Linux host has **its own certificate** (`leftcert=<host FQDN>`, `leftid=%fromcert`), checks the NAS against the same CA (`rightca=%same`), and protects only NFS (`leftprotoport=tcp`, `rightprotoport=tcp/nfs`, tunnel mode). A valid, working setup | [doc 70](70-review-enterprise-linux-ipsec-config.md#the-reference-configuration) |
| The option that matches it | **Option B**: one certificate per node from the enterprise CA, imported on that node only | [doc 70, *Each option*](70-review-enterprise-linux-ipsec-config.md#each-option-against-the-reference) |
| Why not A or C | Every node presents one identity, so the NAS must allow `uniqueids=no` for **all** its peers; with the default the nodes replace each other's tunnel (measured) | [doc 51](51-option-c-summary.md), [lab findings 4, 5](lab/lima-lab.md#8-what-the-lab-showed) |
| Option B and `uniqueids` | Works with the NAS's default `uniqueids=yes`: two peers with their own certificates held two tunnels (measured) | [doc 70, *`uniqueids`*](70-review-enterprise-linux-ipsec-config.md#uniqueids-and-option-b) |
| The tunnel definition we propose | Option B's NNCP plus the standard's `rightca=%same`, `leftprotoport: tcp`, `rightprotoport: tcp/2049`, `type: tunnel` ("Sample 2"). NMState 2.2.60 accepts it offline; **not yet applied to a node** | [doc 70, Sample 2](70-review-enterprise-linux-ipsec-config.md#sample-2--matching-the-enterprise-standard-not-tested) |
| Measured where | Our lab (OpenShift Local and a libreswan NAS, where every tool is installed). **Not** on an enterprise cluster, **not** against the enterprise NAS | [docs/README.md](README.md) |
| Enterprise clusters today | No Kyverno, no cert-manager integration with the enterprise CA | Operator, 2026-10-07 |

## The meeting with the NAS team

### What we bring

| What | Value |
|---|---|
| Who connects | The worker subnet(s) of each cluster: every node address that will connect |
| The CA | The enterprise CA chain (Venafi TPP) that signs both the node certificates and the NAS's |
| The node certificate | One per node: `CN=<node>.<NODE_DOMAIN>`, SAN `DNS:<node>.<NODE_DOMAIN>`, RSA 3072, extended key usage server and client authentication, valid one year, renewed 30 days before expiry with a new key. A node signs with RSA-PSS (`3072-bit RSASSA-PSS with SHA2_512`, measured) |
| The tunnel we propose | Sample 2 of doc 70: IKEv2, certificates on both sides (`%fromcert`), `rightca=%same`, tunnel mode, only TCP to port 2049 on the NAS |
| The NAS address | The NFS IP the nodes will use (`server` in our StorageClasses, `rightsubnet` in the NNCP) and the NAS name in its certificate |

### What we ask

- [ ] **How the NAS defines its IPsec peers today** for the Linux hosts: one connection per host (address and identity pinned), or one for any peer of a subnet (`right=%any`, `rightid=%fromcert`)? For OpenShift, a subnet definition means no NAS change when a node is added.
- [ ] **The NAS side of the port selectors**: is its connection limited to TCP 2049? If yes, our NNCP must carry Sample 2's selectors.
- [ ] **Tunnel or transport mode** on the NAS's side.
- [ ] **`uniqueids`** (or the product's equivalent): we expect the default (`yes`); Option B needs no change. A and C would need `no` for every peer.
- [ ] **Signature schemes**: does the NAS accept RSA-PSS signatures from a peer? (`leftauth=rsasig` in the standard; OpenShift cannot set `leftauth`.)
- [ ] **IKE and ESP proposals** the NAS accepts, if not the defaults.
- [ ] **The NAS product and version.** Our measurements are against libreswan; an appliance may differ.
- [ ] **Firewall**: UDP 500 and 4500 and ESP from the worker subnet(s); NFS accepted only through IPsec.
- [ ] **Their change process and lead time** for a new peer subnet, and for the PoC cluster.

### What they send back

- [ ] The NAS certificate, public part only, with its chain and expiry date; its SAN holds the NAS name we target.
- [ ] Their peer definition for our subnet(s), and its mode and selectors.
- [ ] The proposals, if not the defaults.
- [ ] The NFS IP(s) protected.
- [ ] A contact for the PoC run, to read the NAS's IPsec status while we test.

## The certificate profile for Venafi

Node certificates come from the enterprise Venafi TPP through cert-manager's Venafi issuer. The zone used for them must allow what Option B requests:

| Field | Value |
|---|---|
| Subject and SAN | `CN=<node>.<NODE_DOMAIN>`, `DNS:<node>.<NODE_DOMAIN>` |
| Key | RSA 3072, generated by the requester (cert-manager), new key at each renewal |
| Extended key usage | Server and client authentication |
| Validity | Longer than 30 days (cert-manager renews 30 days before expiry); one year requested |

## What is left for us to specify

| # | Item | What to decide or write | Owner | Status |
|---|---|---|---|---|
| 1 | The refined NNCP | Sample 2's four settings into the Kyverno policy template and the chart's values, as options with today's behaviour as the default | Platform | Spec in doc 70; not built |
| 2 | Venafi issuer | The chart's `clusterIssuer` value pointing at the Venafi `ClusterIssuer`, and its zone allowing the profile above | Platform | Open |
| 3 | cert-manager | The cert-manager Operator for Red Hat OpenShift on enterprise clusters (channel, version, who operates it) | Platform | Open: not on enterprise clusters today |
| 4 | Kyverno | Kyverno on enterprise clusters: version (1.19 or later) and its two OpenShift settings. The most popular policy engine for Kubernetes; we run the open-source release as-is and support it ourselves ([doc 72](72-option-b-implementation-plan.md#4-the-case-for-each-component)) | Platform | Support model decided |
| 5 | NMState | The NMState Operator and its instance; `routingViaHost` and IPsec `External` mode | Platform | Documented ([doc 00](00-prepare-the-cluster.md)) |
| 6 | Monitoring | The user workload monitoring settings ([doc 60](60-monitoring-per-node.md#the-cluster-settings-user-workload-monitoring-config)); the Cluster Observability Operator for the console dashboard ([doc 61](61-perses-dashboard-review.md)) | Platform | Measured in the lab |
| 7 | Which nodes | The pools and labels that get a tunnel, and the exclusions (control plane, infra) | Platform | Chart values exist |
| 8 | Firewall | Rules between the worker subnets and the NAS (IKE, NAT-T, ESP) | Network | Open |
| 9 | NAS certificate rotation | Who renews the NAS's certificate, and how we are told | Storage | Open |
| 10 | PoC | An enterprise non-production cluster with at least three workers, and the acceptance criteria of [doc 72](72-option-b-implementation-plan.md#6-the-engineering-poc) | Platform | Open |

## Decision log

| Date | Decision or open item | State |
|---|---|---|
| 2026-10-07 | Option B is the option for enterprise clusters | Direction (operator); to confirm after the NAS meeting |
| 2026-10-07 | The tunnel definition follows the enterprise standard (Sample 2) | Proposed; depends on the NAS team's answers |
| 2026-10-07 | The enterprise CA is Venafi TPP, through cert-manager's Venafi issuer | Decided (operator) |
| 2026-10-07 | Kyverno: the open-source release as-is, supported by platform engineering | Decided (operator) |
| — | The PoC cluster | Open |
