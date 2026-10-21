{{- define "fun-with-minikube.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
{{- end -}}

{{- define "fun-with-minikube.podinfo.namespace" -}}
{{- .Values.podinfo.namespaceOverride | default .Release.Namespace -}}
{{- end -}}

{{- define "fun-with-minikube.podinfo.fullname" -}}
{{- required "podinfo.fullnameOverride is required" .Values.podinfo.fullnameOverride -}}
{{- end -}}
