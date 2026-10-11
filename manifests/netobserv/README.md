# Network Observability with the IPSec feature (spike, issue #35)

Lab manifests for evaluating Red Hat's Network Observability Operator as an addition to our collector: its eBPF agent
marks each flow's IPsec result (`IPSecStatus`), from probes on the kernel's `xfrm_output` and `xfrm_input`.
Results so far: [evidence 64](../../docs/evidence/crc/64-netobserv-ipsec.txt).

| File | What it creates |
|---|---|
| `00-operator.yaml` | The operator: namespace, OperatorGroup, Subscription (`stable`, `redhat-operators`) |
| `10-flowcollector.yaml` | The FlowCollector (`IPSec` feature, sampling 1, metrics only, one processor pod) and two FlowMetrics for the traffic to and from the lab NAS (`192.168.64.8`) |

Apply `00`, wait for the CSV `network-observability-operator` to report `Succeeded`, then `10`. The FlowMetrics need
the `netobserv` namespace, which the operator creates for the FlowCollector, and the operator's webhook.

**On a cluster with Dynatrace full stack, leave NetObserv's namespaces out of its injection first.** The injection adds
a seccomp annotation that the eBPF agent's SCC refuses, so the agent's DaemonSet creates no pod (`FailedCreate`, "seccomp
may not be set"). Dynatrace's documented way is a `namespaceSelector` in the DynaKube, as in
[`../dynatrace/dynakube-cloudnativefullstack.yaml`](../dynatrace/dynakube-cloudnativefullstack.yaml); then the agent
starts on the DaemonSet's next retry (evidence 64, section 7).

**Before installing, check the node's memory headroom, and record its load.** On OpenShift Local at 91% memory the
first run coincided with memory reclaim, a slow API server and operators losing their leader leases; another install
ran on the node at the same time, so the cause is not established (evidence 64, sections 4 and 6). The rerun, at 75%
with nothing else installing, left the node as it was: a 1-minute load of 3.2 to 3.7 on 14 CPUs with the agent
running, about 5.6 GiB available (section 7). Also check, after
install, the console's `spec.plugins`: in 1.12.3 the operator adds `netobserv-plugin-static` even with
`consolePlugin.enable: false`, as soon as the operator is installed.

**What the two FlowMetrics show, in 1.12.3** (section 7): egress to the NAS is UDP 4500 only, and a TCP flow to port
2049 there would be NFS that left the node unencrypted. On ingress, TCP from port 2049 is normal: the agent also sees
the NFS replies after the node decrypts them. `IPSecStatus` stays empty on both, because the agent stores it under
other flow keys; that label is kept for a later release.

To remove it all: delete the FlowCollector, then the Subscription and the CSV, then the namespaces `netobserv`,
`netobserv-privileged` and `openshift-netobserv-operator`, the three `*.flows.netobserv.io` CRDs, the ConsolePlugin
`netobserv-plugin-static`, and its entry in `consoles.operator.openshift.io/cluster` `spec.plugins`.
