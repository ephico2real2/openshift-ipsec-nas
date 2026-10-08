# Runbook — Revoking a Removed Node's Certificate

**Audience:** platform engineering, with the PKI team. **Applies to:** Option B, node certificates issued by the enterprise CA (Venafi TPP) through cert-manager ([doc 72](72-option-b-implementation-plan.md)). **Status:** 2026-10-07. The procedure is written from the products' documentation; it has not been run against Venafi TPP. Revocation needs planning before it is used: [Plan first](#plan-first).

**Contents:** [What happens when a node leaves](#what-happens-when-a-node-leaves) · [Deleting the Certificate does not revoke it](#deleting-the-certificate-does-not-revoke-it) · [Plan first](#plan-first) · [Find the orphaned certificates](#find-the-orphaned-certificates) · [Revoke one](#revoke-one) · [Automating it later](#automating-it-later) · [Questions for the PKI and NAS teams](#questions-for-the-pki-and-nas-teams)

## What happens when a node leaves

| Step | What happens | By |
|---|---|---|
| 1 | The Node is deleted | People or the Machine API |
| 2 | Kyverno deletes the node's `Certificate` and its NNCP (policy `ipsec-node-certificate`, `synchronize`) | Kyverno |
| 3 | cert-manager leaves the Secret `ipsec-cert-<node>` behind, the private key inside; policy `ipsec-orphaned-node-secrets` deletes it within 5 minutes | Kyverno |
| 4 | **The certificate is still valid at the CA**, until it expires (one year after issue, or what the Venafi zone set) | — |

Steps 1 to 3 are measured or documented in [doc 20](20-option-b-per-node-certificates.md#step-b11--scale-down--node-removal) (B.11, B.13). Step 4 is what this runbook is for: the certificate of a node that no longer exists is an **orphaned certificate**.

## Deleting the Certificate does not revoke it

cert-manager has no revocation. When a `Certificate` is deleted, cert-manager sends nothing to the issuer; the certificate stays valid at the CA until it expires. The project's own tracker says so:

- [cert-manager #8209](https://github.com/cert-manager/cert-manager/issues/8209), *Add revocation at certificate deletion* (open, 2025): when the resource "is deleted from the cluster, it is not automatically revoked until it expires".
- [cert-manager #2178](https://github.com/cert-manager/cert-manager/issues/2178), *Handling 'unregistering' certificates from Venafi TPP* (open since 2019): a Venafi TPP user "has no way to delete instances of certificates automatically when the user deletes the Certificate resource".

So **deleting a node's Certificate from the cluster does not trigger revocation at the enterprise CA** with cert-manager alone. Revoke-on-delete exists only where something else is built for it, for example Cloudera's own `certrevoke` operator for Venafi TPP ([Automating it later](#automating-it-later)). If our Venafi setup already has such an integration, the PKI team will know; it is the first question below.

## Plan first

Revocation only protects anything when the parties that trust the certificate check it, and it can lock out the next node of the same name. Decide each point with the PKI and NAS teams before revoking anything:

| # | Point | Why it matters | Fact |
|---|---|---|---|
| 1 | **Does the NAS check revocation?** | A revoked certificate still authenticates against a NAS that checks neither a CRL nor OCSP | libreswan's defaults: `crlcheckinterval=0` (CRL updating disabled), `ocsp-enable=no`, `crl-strict=no` ([`ipsec.conf(5)`](https://libreswan.org/man/ipsec.conf.5.html)). The enterprise NAS's product and settings: to ask |
| 2 | **Revoke by thumbprint, never by name** | A node re-created with the same name gets a new certificate with the same subject; revoking by name could hit the new one | Venafi's revoke call takes a certificate `Thumbprint` or the object's `CertificateDN` ([POST Certificates/Revoke](https://docs.venafi.com/Docs/25.3/TopNav/Content/SDK/WebSDK/r-SDK-POST-Certificates-revoke.php)) |
| 3 | **`Disable` must stay `false`** | `Disable=true` stops the certificate object from being enrolled again: a node re-created with the same name could not get its certificate | The same API: `Disable` true prevents re-enrollment, false allows a replacement |
| 4 | **Superseded certificates** | Every renewal leaves the previous certificate valid until it expires (a new key each time) | Decide with PKI whether superseded certificates are revoked too (reason "superseded") or left to expire |
| 5 | **Who may revoke** | Revocation is irreversible for a certificate | The token needs the scope `Certificate:Revoke` and write access to the certificate object; listing needs the scope `Certificate` |
| 6 | **The reason code** | Audits read it | Venafi's codes: 0 none, 1 key compromised, 3 changed affiliation, 4 superseded, 5 original use no longer valid. A removed node is 5; a stolen key is 1 |
| 7 | **When** | After the node is gone for good, not during a replacement that reuses the name | Confirm with the change record that the node will not come back |

## Find the orphaned certificates

An orphaned certificate is one issued for `<node>.<NODE_DOMAIN>` whose node is no longer in the cluster.

**From the CA's inventory** (no change to the cluster). List the certificates in the Venafi zone (folder) used for this cluster's nodes, and compare their common names with the cluster's nodes:

```bash
# The cluster's nodes, as the certificates name them
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}.<NODE_DOMAIN>{"\n"}{end}' | sort > nodes.txt

# The zone's certificates (Venafi WebSDK, scope "Certificate"; page with Limit and Offset)
curl -s -H "Authorization: Bearer ${TPP_TOKEN}" \
  "https://<tpp>/vedsdk/certificates/?parentdnrecursive=<zone DN>&Limit=100&Offset=0" > zone.json
# from each entry: Name, DN, X509.CN, X509.Thumbprint, X509.Serial, X509.ValidTo
```

Every certificate whose common name is not in `nodes.txt`, and that has not expired, is a candidate. Check each against the change record (point 7 above) before revoking.

**In the cluster, while it still exists** (the first 5 minutes after the node is deleted). The leftover Secret still holds the certificate; record its thumbprint before the cleanup policy deletes it:

```bash
oc get secret ipsec-cert-<node> -n kcs-ipsec -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -serial -enddate -fingerprint -sha1
```

A record that outlives the node, kept by the cluster itself, is a possible addition ([Automating it later](#automating-it-later)); it is not built.

## Revoke one

For each orphaned certificate, after the plan above is agreed:

1. **Confirm the node is gone for good**: `oc get node <node>` reports not found, and the change record says it is not coming back.
2. **Confirm the certificate**: its thumbprint, subject `CN=<node>.<NODE_DOMAIN>`, and expiry, from the CA's inventory.
3. **Revoke it**, by thumbprint, reason 5, `Disable` false:

   ```bash
   curl -s -X POST -H "Authorization: Bearer ${TPP_TOKEN}" -H "Content-Type: application/json" \
     "https://<tpp>/vedsdk/Certificates/Revoke" \
     -d '{"Thumbprint":"<sha1 thumbprint>","Reason":5,"Comments":"OpenShift node <node> removed, change <id>","Disable":false}'
   ```

   ✅ Expected (from Venafi's documentation): HTTP 200 with `Requested` and `Success` true (or `Revoked` true if it already was); HTTP 202 means the CA had not finished within the timeout, check again.
4. **Verify**: the certificate shows as revoked in the CA's inventory; once the CA has published, it is on the CRL or reported revoked by OCSP.
5. **Record** the node, thumbprint, serial, reason and change in the change record.

## Automating it later

A revoke-on-delete component would call the revoke API when a node's `Certificate` is deleted. It is not part of Option B, and it is not built. What it would have to get right, from one that exists (Cloudera's `certrevoke` operator for Venafi TPP, described in its documentation, *Manually revoking certificates from Venafi TPP*):

- **Certificates deleted while it is down stay valid.** Cloudera's operator misses deletions made while it is offline, and documents a manual hunt for them. A record of every issued certificate's thumbprint that survives the node (proposed: a ConfigMap per node certificate, public part only, not removed with the node) would let a sweep find them.
- **Name collisions.** Cloudera's documentation lists a known issue in which the operator revoked the wrong certificate when the same certificate name existed in different namespaces. Revoking by thumbprint avoids it.
- **The same planning points** as above: revocation checked by the NAS, `Disable` false, who holds the revoke credential.

Until then, this runbook is the process, run after each node removal or on a schedule.

## Questions for the PKI and NAS teams

- [ ] PKI: does our Venafi setup already revoke a certificate when cert-manager's `Certificate` is deleted (an integration of its own)? cert-manager does not.
- [ ] PKI: the zone (folder) for this cluster's node certificates, and who holds a token with `Certificate:Revoke`.
- [ ] PKI: superseded certificates at renewal: revoke or leave to expire?
- [ ] PKI: the CRL distribution point and OCSP responder in the node certificates, and how often the CRL is published.
- [ ] NAS: does the NAS check revocation of peer certificates (CRL or OCSP), and how often? Without it, revocation does not stop a removed node's certificate.
