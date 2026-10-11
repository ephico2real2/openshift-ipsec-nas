# Network Observability with the IPSec feature (spike, issue #35)

**Not adopted.** Kept as the record of the evaluation; nothing here is installed on the lab
([evidence 64](../../docs/evidence/crc/64-netobserv-ipsec.txt), section 8).

- In 1.12.3 its `IPSecStatus` does not land on the NAS's flows for this tunnel (External libreswan, NAT-T).
- What it does show repeats the collector's metrics (tunnel bytes, the kernel's IPsec errors), at 227 MiB against
  12 MiB.
- **It is not compatible with Dynatrace full stack as installed:** the eBPF agent never starts until NetObserv's
  namespaces are left out of Dynatrace's injection, a change to the DynaKube
  ([doc 62](../../docs/62-dynatrace-operator-on-openshift.md#network-observability-does-not-run-beside-it)).

Lab manifests for evaluating Red Hat's Network Observability Operator as an addition to our collector: its eBPF agent
marks each flow's IPsec result (`IPSecStatus`), from probes on the kernel's `xfrm_output` and `xfrm_input`.

| File | What it creates |
|---|---|
| `00-operator.yaml` | The operator: namespace, OperatorGroup, Subscription (`stable`, `redhat-operators`) |
| `10-flowcollector.yaml` | The FlowCollector (`IPSec` feature, sampling 1, metrics only, one processor pod) and two FlowMetrics for the traffic to and from the lab NAS (`192.168.64.8`) |

Apply `00`, wait for the CSV `network-observability-operator` to report `Succeeded`, then `10`. The FlowMetrics need
the `netobserv` namespace, which the operator creates for the FlowCollector, and the operator's webhook.

**On a cluster with Dynatrace full stack, leave NetObserv's namespaces out of its injection first.** The injection adds
a seccomp profile that the eBPF agent's SCC refuses, so the agent's DaemonSet creates no pod (`FailedCreate`, "seccomp
may not be set"). The `oc patch` in
[doc 62](../../docs/62-dynatrace-operator-on-openshift.md#network-observability-does-not-run-beside-it) adds
Dynatrace's documented `namespaceSelector`; the agent then starts on the DaemonSet's next retry (evidence 64,
section 7a). Take it out again when NetObserv is removed.

**Before installing, check the node's memory headroom, and record its load.** On OpenShift Local at 91% memory the
first run coincided with memory reclaim, a slow API server and operators losing their leader leases; another install
ran on the node at the same time, so the cause is not established (evidence 64, sections 4 and 6). The rerun, at 75%
with nothing else installing, left the node as it was: a 1-minute load of 3.2 to 3.7 on 14 CPUs with the agent
running, about 5.6 GiB available (section 7). Also check, after install, the console's `spec.plugins`: in 1.12.3 the
operator adds `netobserv-plugin-static` even with `consolePlugin.enable: false`, as soon as the operator is installed.

**What the two FlowMetrics show, in 1.12.3** (section 7): egress to the NAS is UDP 4500 only, and a TCP flow to port
2049 there would be NFS that left the node unencrypted. On ingress, TCP from port 2049 is normal: the agent also sees
the NFS replies after the node decrypts them. `IPSecStatus` stays empty on both, because the agent stores it under
other flow keys.

## Removal (measured, section 8)

```bash
oc delete flowmetric -n netobserv --all
oc delete flowcollector cluster --wait=true                  # the operator removes the agent and the processor
oc delete subscription netobserv-operator -n openshift-netobserv-operator
oc delete csv network-observability-operator.v1.12.3 -n openshift-netobserv-operator   # only this CSV: the namespace also lists copies of every cluster-wide operator's
oc delete ns netobserv netobserv-privileged openshift-netobserv-operator
oc delete crd flowcollectors.flows.netobserv.io flowcollectorslices.flows.netobserv.io flowmetrics.flows.netobserv.io
# OLM leaves the operator's cluster roles and bindings behind: delete them by their owner label
oc delete clusterrole,clusterrolebinding -l olm.owner=network-observability-operator.v1.12.3
# the console plugin, and its entry: check that index 5 is the plugin before removing it
oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
oc patch consoles.operator.openshift.io cluster --type json \
  -p '[{"op":"test","path":"/spec/plugins/5","value":"netobserv-plugin-static"},{"op":"remove","path":"/spec/plugins/5"}]'
oc delete consoleplugin netobserv-plugin-static
```

Then nothing named `netobserv` is left (`oc get clusterrole,clusterrolebinding,crd,consoleplugin,scc -o name | grep
netobserv` prints nothing). If the DynaKube was changed for NetObserv, take its two `namespaceSelector`s out again.
