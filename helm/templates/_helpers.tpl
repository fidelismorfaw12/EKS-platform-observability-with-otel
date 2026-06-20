{{/*
Inject IRSA role ARNs into the upstream sub-chart service accounts.

We don't use helm's built-in values for this because terraform passes the ARNs
as a single string at deploy time. This helper formats them consistently.
*/}}

{{- define "obs.irsaAnnotation" -}}
{{- if .roleArn -}}
eks.amazonaws.com/role-arn: {{ .roleArn | quote }}
{{- end -}}
{{- end -}}

{{- define "obs.namespace" -}}
{{- .Release.Namespace -}}
{{- end -}}

{{- define "obs.fullName" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name -}}
{{- end -}}
