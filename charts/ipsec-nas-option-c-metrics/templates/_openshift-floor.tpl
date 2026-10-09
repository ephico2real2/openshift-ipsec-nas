{{/*
Fails when the refined tunnel's keys are set on an OpenShift release whose NMState or node plugin does not know
them (docs/70-review-enterprise-linux-ipsec-config.md, "Which OpenShift versions carry rightca and the port
selectors"): the port selectors need 4.19.22, 4.20.11 or 4.21; rightca alone needs 4.19.19, 4.20.3 or 4.21.
Called with (dict "ipsec" .Values.ipsec "version" "<x.y.z>"); an empty version (not OpenShift) checks nothing.
The same template is in both charts; tests/test-openshift-floor.sh keeps them identical.
*/}}
{{- define "ipsec-nas.openshiftFloor" -}}
{{- $ipsec := .ipsec | default dict -}}
{{- $need := "" -}}
{{- $floor := "" -}}
{{- $keys := "" -}}
{{- if or $ipsec.leftprotoport $ipsec.rightprotoport -}}
{{- $need = ">=4.19.22-0 <4.20.0-0 || >=4.20.11-0 <4.21.0-0 || >=4.21.0-0" -}}
{{- $floor = "4.19.22, 4.20.11, or any 4.21 or later" -}}
{{- $keys = "ipsec.leftprotoport and ipsec.rightprotoport" -}}
{{- else if $ipsec.rightca -}}
{{- $need = ">=4.19.19-0 <4.20.0-0 || >=4.20.3-0 <4.21.0-0 || >=4.21.0-0" -}}
{{- $floor = "4.19.19, 4.20.3, or any 4.21 or later" -}}
{{- $keys = "ipsec.rightca" -}}
{{- end -}}
{{- if and $need .version (not (semverCompare $need .version)) -}}
{{- fail (printf "setting %s requires OpenShift %s: the cluster's last completed update is %s, whose NMState or node plugin (NetworkManager-libreswan) does not carry these keys. Update the cluster, or leave the keys empty. See docs/70-review-enterprise-linux-ipsec-config.md, \"Which OpenShift versions carry rightca and the port selectors\"." $keys $floor .version) -}}
{{- end -}}
{{- end -}}

{{/*
The OpenShift version every node has reached: the newest Completed entry of the ClusterVersion's history (during
an update, status.desired is the target while nodes still run the old release). The desired version while the
first install has not completed; empty when the cluster is not OpenShift.
*/}}
{{- define "ipsec-nas.openshiftVersion" -}}
{{- $cv := lookup "config.openshift.io/v1" "ClusterVersion" "" "version" -}}
{{- if $cv -}}
{{- $current := "" -}}
{{- range ($cv.status.history | default list) -}}
{{- if and (not $current) (eq .state "Completed") }}{{ $current = .version }}{{ end -}}
{{- end -}}
{{- $current | default $cv.status.desired.version -}}
{{- end -}}
{{- end -}}
