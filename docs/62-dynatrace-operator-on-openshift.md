# Dynatrace on OpenShift — How the Dynatrace Operator Was Installed

**Audience:** platform engineers. **Part of:** the Dynatrace epic ([#44](https://github.com/ephico2real2/openshift-ipsec-nas/issues/44)); this is its first step, the Dynatrace Operator on the cluster. Getting the IPsec metrics into Dynatrace comes next ([#45](https://github.com/ephico2real2/openshift-ipsec-nas/issues/45)).

This is how the Dynatrace Operator was installed on OpenShift Local (CRC 4.22.7) against a Dynatrace trial tenant, on 2026-10-04: the way that worked, the two that did not, and why. Every step was measured ([evidence 54](evidence/crc/54-dynatrace-operator.txt)).

**Contents:** [What was installed](#what-was-installed) · [Step D.1 – The tenant and the token](#step-d1--the-tenant-and-the-token) · [D.2 – The operator](#step-d2--the-operator-dynatraces-openshift-manifest) · [D.3 – The token Secret](#step-d3--the-token-secret) · [D.4 – The DynaKube](#step-d4--the-dynakube) · [D.5 – Verify](#step-d5--verify) · [What did not work](#what-did-not-work-and-why) · [Scope and security](#scope-and-security) · [Removal](#removal)

## What was installed

The method Dynatrace documents for OpenShift ([full-stack observability](https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/deployment/full-stack-observability); [OpenShift configuration](https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/guides/networking-security-compliance/security-configurations/openshift-configuration)): the operator from its release manifest, and a DynaKube for full-stack monitoring.

| Component | Image or version (measured) | SCC (measured; the docs list the same) |
|---|---|---|
| Dynatrace Operator 1.11.0 (operator, 2 webhooks, CSI driver) | `registry.connect.redhat.com/dynatrace/dynatrace-operator@sha256:5b772c…` | operator and webhook `nonroot-v2`; CSI driver `privileged` |
| OneAgent, full stack (`cloudNativeFullStack`), on every node | `public.ecr.aws/dynatrace/dynatrace-oneagent:1.347.49.20260928-064841` | `privileged` |
| ActiveGate (`routing`, `kubernetes-monitoring`, `dynatrace-api`) | `public.ecr.aws/dynatrace/dynatrace-activegate:1.337.36.20260526-135434` | `nonroot-v2` |

Everything lives in the namespace `dynatrace`. Nothing in `openshift-monitoring` is touched.

## Step D.1 – The tenant and the token

Two values from the Dynatrace tenant:

- **The environment.** The tenant's URL is `https://<ENVIRONMENT_ID>.apps.dynatrace.com` (the platform UI). The DynaKube's `apiUrl` is the Classic API on the same environment: `https://<ENVIRONMENT_ID>.live.dynatrace.com/api`.
- **A platform token** (`dt0s16.…`), made in the tenant (Dynatrace recommends its QuickStart app, which grants the scopes `dtwiz` lists in its [README](https://github.com/dynatrace-oss/dtwiz#platform-token-scopes)). The trial's token was enough to install and run everything below. It was **not** enough to read entities back through the API: `403 "OAuth token is missing required scope. Use one of: [environment-api:entities:read]"`. Add that scope to check results through the API.

Keep the token out of files, Git and chat. Below it is read from an environment variable only.

## Step D.2 – The operator: Dynatrace's OpenShift manifest

```bash
oc create namespace dynatrace
oc apply -f https://github.com/Dynatrace/dynatrace-operator/releases/download/v1.11.0/openshift-csi.yaml
oc -n dynatrace wait pod --for=condition=ready --selector=app.kubernetes.io/name=dynatrace-operator,app.kubernetes.io/component=webhook --timeout=300s
oc -n dynatrace rollout status ds/dynatrace-oneagent-csi-driver
oc -n dynatrace rollout status deploy/dynatrace-operator
```

✅ **Expected** (measured): 59 objects created (CRDs, RBAC, the operator, the webhook, the CSI driver; the manifest has no Namespace, hence the first command); the webhook and CSI driver ready, then the operator. The pods take the SCCs in the table above with no SCC configured by hand.

## Step D.3 – The token Secret

The DynaKube reads two keys, `apiToken` and `dataIngestToken`. With a platform token, both hold the platform token: that is what Dynatrace's own `dtwiz` does (its `pkg/installer/kubernetes/install.go`: "platform token used for both apiToken and dataIngestToken").

```bash
read -rs DT_PLATFORM_TOKEN          # paste the token; it is not echoed
oc -n dynatrace create secret generic dynakube \
  --from-literal=apiToken="${DT_PLATFORM_TOKEN}" --from-literal=dataIngestToken="${DT_PLATFORM_TOKEN}"
unset DT_PLATFORM_TOKEN
```

## Step D.4 – The DynaKube

[`manifests/dynatrace/dynakube-cloudnativefullstack.yaml`](../manifests/dynatrace/dynakube-cloudnativefullstack.yaml) is Dynatrace's sample for operator 1.11.0 (`assets/samples/dynakube/v1beta5/cloudNativeFullStack.yaml`) with one addition, the ActiveGate's image. Set `apiUrl` to your environment, then:

```bash
oc apply -f manifests/dynatrace/dynakube-cloudnativefullstack.yaml
oc -n dynatrace get dynakube dynakube -w          # until PHASE is Running
```

**Why the ActiveGate image is named.** Without it the DynaKube stayed in `Error`: the operator asks the tenant which ActiveGate image to run, and the trial tenant answered with none (`image discovery failed for "activegate": no matching image in DT API response`). The OneAgent then waits too, on the Secret `dynakube-activegate-tls-secret`, which the operator creates only with the ActiveGate. With the image named (the same one `dtwiz` names), the DynaKube was `Running` 122 seconds later.

The API server warns that `dynatrace.com/v1beta5` is deprecated. It is the version of Dynatrace's documentation and of the release's samples, and it works with operator 1.11.0.

## Step D.5 – Verify

```bash
oc -n dynatrace get dynakube dynakube -o jsonpath='{.status.phase} {.status.kubernetesClusterMEID}{"\n"}'
oc -n dynatrace get dynakube dynakube -o jsonpath='{range .status.conditions[?(@.status=="False")]}{.type}: {.message}{"\n"}{end}'
oc -n dynatrace get pods
```

✅ **Expected** (measured): `Running KUBERNETES_CLUSTER-64F82EA2AFC7919E`; no condition `False`; `dynakube-activegate-0` and `dynakube-oneagent-<id>` Running beside the operator, the two webhooks and the CSI driver. In the tenant, the cluster appears under **Kubernetes** with the name of the DynaKube's `kubernetesClusterName` (`crc` here).

## What did not work, and why

| Tried | What happened | Why it was not kept |
|---|---|---|
| `dtwiz install kubernetes` (Dynatrace's [dtwiz](https://github.com/dynatrace-oss/dtwiz) v1.10.0) | It installed the operator's Helm chart 1.11.0, then its DynaKube was refused: `unknown field "spec.extensions.prometheus"` (its manifest is newer than the chart it installed). It also detected the distribution as plain Kubernetes, not OpenShift | Removed: the DynaKube first (the operator then removes what it made), the Helm release, the namespace, and `dtwiz`'s ClusterRole and binding `dynatrace-kubernetes-monitoring-sensitive` |
| The OLM catalog (OperatorHub) | `dynatrace-operator` in Certified and Community Operators, channel `alpha`, is **v1.10.2**, AllNamespaces only; it installed (CSV `Succeeded` after 7 minutes) | Older than the 1.11.0 Dynatrace documents for OpenShift; removed (Subscription, CSV, OperatorGroup, CRDs, namespace) |

## Scope and security

- **Full stack touches every namespace.** `cloudNativeFullStack` puts a privileged OneAgent on every node, and its webhook injects Dynatrace's code module into pods as they start, in every namespace it matches: on CRC 53, other projects included, from their next restart. To limit it, add a `namespaceSelector` to `oneAgent.cloudNativeFullStack` (Dynatrace's DynaKube reference), or choose a lighter mode from the release's samples (`kubernetesObservability`, `applicationMonitoring`, `hostMonitoring`).
- **The token** is in one place on the cluster, the Secret `dynatrace/dynakube`, readable by whoever can read Secrets in `dynatrace`. Revoke a token that has been shared anywhere else, and replace it in the Secret.
- **Images** come from Red Hat's certified registry (the operator) and Dynatrace's public registry (OneAgent, ActiveGate).

## Removal

In the order the failed attempts were removed (measured with the Helm and OLM installs, not yet with this one): the DynaKube first, so the operator removes the OneAgent, the ActiveGate and its injections, then the operator.

```bash
oc -n dynatrace delete dynakube dynakube --wait=true
oc delete -f https://github.com/Dynatrace/dynatrace-operator/releases/download/v1.11.0/openshift-csi.yaml
oc delete namespace dynatrace
```
