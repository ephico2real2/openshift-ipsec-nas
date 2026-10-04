{{/* The roles among excludeNodeLabels, joined for a PromQL regex (as in the ipsec-nas chart). */}}
{{- define "optc.excludedRoles" -}}
{{- $roles := list -}}
{{- range .Values.excludeNodeLabels -}}
{{- if hasPrefix "node-role.kubernetes.io/" . -}}{{- $roles = append $roles (trimPrefix "node-role.kubernetes.io/" .) -}}{{- end -}}
{{- end -}}
{{- join "|" $roles -}}
{{- end -}}

{{/* The node role the "exporter missing" alert watches: the role in nodeSelector (worker if there is none). */}}
{{- define "optc.watchedRole" -}}
{{- $role := "worker" -}}
{{- range $k, $v := .Values.nodeSelector -}}
{{- if hasPrefix "node-role.kubernetes.io/" $k -}}{{- $role = trimPrefix "node-role.kubernetes.io/" $k -}}{{- end -}}
{{- end -}}
{{- $role -}}
{{- end -}}
