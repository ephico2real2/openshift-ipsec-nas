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

**Before installing, check the node's memory headroom.** On OpenShift Local at 91% memory the install was followed by
memory reclaim, a slow API server and operators losing their leader leases (evidence 64, section 4). Also check, after
install, the console's `spec.plugins`: in 1.12.3 the operator adds `netobserv-plugin-static` even with
`consolePlugin.enable: false`.

To remove it all: delete the FlowCollector, then the Subscription and the CSV, then the namespaces `netobserv`,
`netobserv-privileged` and `openshift-netobserv-operator`, the three `*.flows.netobserv.io` CRDs, the ConsolePlugin
`netobserv-plugin-static`, and its entry in `consoles.operator.openshift.io/cluster` `spec.plugins`.
