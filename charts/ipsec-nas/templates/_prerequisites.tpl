{{/*
Fails the install with a plain message when something this chart depends on is missing.
Kyverno, cert-manager and NMState are prerequisites: the chart uses them and never installs them.
The checks that read objects only run against a real cluster ("helm template" has none).
*/}}
{{- define "ipsec-nas.prerequisites" -}}
{{- if not .Values.nas.fqdn }}{{ fail "nas.fqdn is required: the DNS name of the NAS" }}{{ end -}}
{{- if not .Values.nas.ip }}{{ fail "nas.ip is required: the IP address of the NAS that carries NFS" }}{{ end -}}
{{- if not .Values.clusterIssuer }}{{ fail "clusterIssuer is required: the name of the EXISTING ClusterIssuer for the enterprise CA (oc get clusterissuer)" }}{{ end -}}
{{- if and (not .Values.nodeDomain) (not .Values.ipsec.left) }}{{ fail "nodeDomain is required: the DNS domain of the nodes" }}{{ end -}}
{{- if and (not .Values.trustCA.pem) (not .Values.trustCA.existingConfigMap) }}{{ fail "trustCA.pem is required: --set-file trustCA.pem=enterprise-root.pem (or set trustCA.existingConfigMap)" }}{{ end -}}
{{- if not (has .Values.ipsec.type (list "transport" "tunnel")) }}{{ fail "ipsec.type must be transport or tunnel" }}{{ end -}}
{{- if not .Values.prerequisites.skipCheck -}}
{{- $apis := dict "cert-manager.io/v1" "cert-manager" "nmstate.io/v1" "the NMState Operator with an NMState instance (Step 1.5)" -}}
{{- if .Values.kyverno.legacyPolicies -}}
{{- $_ := set $apis "kyverno.io/v1" "Kyverno (docs/00-prepare-the-cluster.md, Step 1.6)" -}}
{{- if .Values.nodeCleanup.deleteOrphanedSecrets }}{{ $_ := set $apis "kyverno.io/v2" "Kyverno's CleanupPolicy (kyverno.io/v2)" }}{{ end -}}
{{- else if not (.Capabilities.APIVersions.Has "policies.kyverno.io/v1") -}}
{{- if .Capabilities.APIVersions.Has "kyverno.io/v1" }}{{ fail "prerequisite missing: Kyverno's CEL policies. The cluster does not serve policies.kyverno.io/v1 (Kyverno 1.19 or later). Upgrade Kyverno, or set kyverno.legacyPolicies=true to use the legacy ClusterPolicy kinds." }}{{ end -}}
{{- $_ := set $apis "policies.kyverno.io/v1" "Kyverno 1.19 or later (docs/00-prepare-the-cluster.md, Step 1.6)" -}}
{{- end -}}
{{- range $api, $what := $apis -}}
{{- if not ($.Capabilities.APIVersions.Has $api) }}{{ fail (printf "prerequisite missing: %s. The cluster does not serve %s. Install it first; this chart does not install it. (Without a cluster, use --set prerequisites.skipCheck=true.)" $what $api) }}{{ end -}}
{{- end -}}
{{- if lookup "v1" "Namespace" "" "kube-system" -}}
{{- if not (lookup "cert-manager.io/v1" "ClusterIssuer" "" .Values.clusterIssuer) }}{{ fail (printf "prerequisite missing: ClusterIssuer %q does not exist. Set clusterIssuer to the existing enterprise CA issuer (oc get clusterissuer). This chart does not create one." .Values.clusterIssuer) }}{{ end -}}
{{- $kyverno := lookup "v1" "ConfigMap" .Values.prerequisites.kyvernoNamespace "kyverno" -}}
{{- if $kyverno -}}
{{- if contains "[Node,*,*]" (get $kyverno.data "resourceFilters" | default "") }}{{ fail "prerequisite missing: Kyverno ignores Node objects ([Node,*,*] is in its resourceFilters), so the policies of this chart would do nothing. Fix: docs/00-prepare-the-cluster.md, Step 1.6.3 (config.resourceFiltersExclude)." }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* The match labels of a Node, as YAML for a Kyverno selector. */}}
{{- define "ipsec-nas.nodeMatchLabels" -}}
{{- range $k, $v := .Values.nodeSelector }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end -}}

{{- define "ipsec-nas.trustConfigMap" -}}
{{- .Values.trustCA.existingConfigMap | default "ipsec-trust-ca" -}}
{{- end -}}

{{/* The annotations that make an object part of the uninstall hook, for Helm or for Argo CD. */}}
{{- define "ipsec-nas.uninstallHook" -}}
{{- if eq .root.Values.uninstallCleanup.hook "argocd" -}}
argocd.argoproj.io/hook: PreDelete
argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded
argocd.argoproj.io/sync-wave: {{ .weight | quote }}
{{- else -}}
helm.sh/hook: pre-delete
helm.sh/hook-weight: {{ .weight | quote }}
helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
argocd.argoproj.io/sync-wave: {{ .weight | quote }}
{{- end -}}
{{- end -}}

{{/* A Kyverno "exclude" block for the Nodes that carry any of the excluded label keys. */}}
{{- define "ipsec-nas.kyvernoExclude" -}}
{{- if .Values.excludeNodeLabels }}
exclude:
  any:
  {{- range .Values.excludeNodeLabels }}
  - resources:
      kinds:
      - Node
      selector:
        matchExpressions:
        - key: {{ . }}
          operator: Exists
  {{- end }}
{{- end }}
{{- end -}}

{{/* The excluded label keys that are node roles, as a regex for kube_node_role: "control-plane|master". */}}
{{- define "ipsec-nas.excludedRoles" -}}
{{- $roles := list -}}
{{- range .Values.excludeNodeLabels -}}
{{- if hasPrefix "node-role.kubernetes.io/" . -}}{{- $roles = append $roles (trimPrefix "node-role.kubernetes.io/" .) -}}{{- end -}}
{{- end -}}
{{- join "|" $roles -}}
{{- end -}}

{{/* The Node selection of a CEL policy, as matchConditions: the nodeSelector labels, plus "extra"
     labels, and none of the excluded label keys. Not an objectSelector: with one, the API server
     stops sending a Node to Kyverno once it no longer matches, so a Node that gains an excluded
     label would keep its Certificate. With matchConditions Kyverno sees the change and deletes it. */}}
{{- define "ipsec-nas.nodeMatchConditions" -}}
{{- $labels := list -}}
{{- range $k, $v := merge (dict) (.extra | default dict) .root.Values.nodeSelector -}}
{{- $labels = append $labels (printf "object.metadata.?labels[?%q] == optional.of(%q)" $k $v) -}}
{{- end -}}
- name: selected-nodes
  expression: >-
    {{ join " &&\n    " $labels }}
{{- with .root.Values.excludeNodeLabels }}
# Nodes with ANY of these labels are left out, even if they also match the labels above.
- name: not-excluded
  expression: >-
    !{{ toJson . | replace "," ", " }}.exists(k, k in object.metadata.?labels.orValue({}))
{{- end }}
{{- end -}}
