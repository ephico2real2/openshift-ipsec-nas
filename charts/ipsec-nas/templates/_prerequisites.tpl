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
{{- $apis := dict "kyverno.io/v1" "Kyverno (docs/ipsec-nas-guide.md, Step 1.6)" "cert-manager.io/v1" "cert-manager" "nmstate.io/v1" "the NMState Operator with an NMState instance (Step 1.5)" -}}
{{- range $api, $what := $apis -}}
{{- if not ($.Capabilities.APIVersions.Has $api) }}{{ fail (printf "prerequisite missing: %s. The cluster does not serve %s. Install it first; this chart does not install it. (Without a cluster, use --set prerequisites.skipCheck=true.)" $what $api) }}{{ end -}}
{{- end -}}
{{- if lookup "v1" "Namespace" "" "kube-system" -}}
{{- if not (lookup "cert-manager.io/v1" "ClusterIssuer" "" .Values.clusterIssuer) }}{{ fail (printf "prerequisite missing: ClusterIssuer %q does not exist. Set clusterIssuer to the existing enterprise CA issuer (oc get clusterissuer). This chart does not create one." .Values.clusterIssuer) }}{{ end -}}
{{- $kyverno := lookup "v1" "ConfigMap" .Values.prerequisites.kyvernoNamespace "kyverno" -}}
{{- if $kyverno -}}
{{- if contains "[Node,*,*]" (get $kyverno.data "resourceFilters" | default "") }}{{ fail "prerequisite missing: Kyverno ignores Node objects ([Node,*,*] is in its resourceFilters), so the policies of this chart would do nothing. Fix: docs/ipsec-nas-guide.md, Step 1.6.3 (config.resourceFiltersExclude)." }}{{ end -}}
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
