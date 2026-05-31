{{/*
Common labels for every resource in this chart.
*/}}
{{- define "app.labels" -}}
app.kubernetes.io/name: {{ .Values.service.name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default "latest" | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
environment: {{ .Values.environment }}
{{- end -}}

{{/*
Label selector used by Deployment + Service.
*/}}
{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.service.name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Group secret/param entries by their target ClusterSecretStore.
Returns a list of dicts: { store, entries: [...] }
*/}}
{{- define "app.entriesByStore" -}}
{{- $all := list -}}
{{- range .Values.envSecrets -}}{{- $all = append $all . -}}{{- end -}}
{{- range .Values.envParams  -}}{{- $all = append $all . -}}{{- end -}}
{{- $grouped := dict -}}
{{- range $all -}}
  {{- $store := .store -}}
  {{- $bucket := index $grouped $store | default (list) -}}
  {{- $grouped = set $grouped $store (append $bucket .) -}}
{{- end -}}
{{- $out := list -}}
{{- range $store, $entries := $grouped -}}
  {{- $out = append $out (dict "store" $store "entries" $entries) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}
