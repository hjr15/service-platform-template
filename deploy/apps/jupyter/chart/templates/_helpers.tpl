{{- define "jupyter.labels" -}}
app.kubernetes.io/name: jupyter
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: Helm
{{- end -}}
