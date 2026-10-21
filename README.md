# fun-with-minikube

Demo repository for experimenting with a local multi-node Minikube cluster.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Minikube](https://minikube.sigs.k8s.io/docs/start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)

Install on macOS with [Homebrew](https://brew.sh):

```bash
brew install --cask docker-desktop   # then start Docker Desktop once
brew install minikube kubectl helm

docker --version && minikube version && kubectl version --client && helm version
```

In Docker Desktop, give the VM at least 6 GB memory (Settings > Resources) so the two 2.5 GB nodes fit.

## Start the cluster

```bash
minikube start -p fun-with-minikube --nodes 2 --driver=docker --cpus 2 --memory 2560
```

| Flag                   | Description                                  |
| ---------------------- | -------------------------------------------- |
| `-p fun-with-minikube` | Profile (cluster) name                       |
| `--nodes 2`            | Number of nodes (1 control plane + 1 worker) |
| `--driver=docker`      | Run nodes as Docker containers               |
| `--cpus 2`             | CPUs per node                                |
| `--memory 2560`        | Memory per node in MB                        |

### Minimal single-node cluster

For the lowest resource usage, start a single node with the minimum values Minikube accepts (2 CPUs, 1800 MB):

```bash
minikube start -p fun-with-minikube --nodes 1 --driver=docker --cpus 2 --memory 1800
```

The node count of an existing profile cannot be reduced. Delete the cluster first (`minikube delete -p fun-with-minikube`) when switching from the 2-node setup.

## Verify

```bash
minikube status -p fun-with-minikube
kubectl get nodes
```

## Deploy podinfo with Helm

Minikube names the kubectl context after the profile. Make sure it is active and set `demo` as its default namespace:

```bash
kubectl config use-context fun-with-minikube
kubectl config set-context fun-with-minikube --namespace demo
kubectl config current-context
```

Add the chart repository and install into the `demo` namespace:

```bash
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm repo update

helm install my-podinfo podinfo/podinfo \
  --kube-context fun-with-minikube \
  --namespace demo --create-namespace \
  -f podinfo/values.yaml
```

[podinfo/values.yaml](podinfo/values.yaml) sets `logLevel: debug`. To apply it to an existing release:

```bash
helm upgrade my-podinfo podinfo/podinfo \
  --kube-context fun-with-minikube \
  --namespace demo \
  -f podinfo/values.yaml
```

Verify and access the app:

```bash
helm list -n demo --kube-context fun-with-minikube
kubectl --context fun-with-minikube -n demo get pods,svc
kubectl --context fun-with-minikube -n demo port-forward svc/my-podinfo 9898:9898
# then browse http://localhost:9898
```

Uninstall (the `demo` namespace is kept unless deleted separately):

```bash
helm uninstall my-podinfo -n demo --kube-context fun-with-minikube
kubectl --context fun-with-minikube delete namespace demo
```

## VictoriaMetrics stack with persistent storage

Installs the `victoria-metrics-k8s-stack` chart (operator, VMSingle, VMAgent, Grafana, kube-state-metrics, node-exporter) into the `monitoring` namespace and scrapes the podinfo app. The settings are in [victoria-metrics/values.yaml](victoria-metrics/values.yaml).

### 1. Enable a storage class that works on multiple nodes

The default `standard` class (`minikube-hostpath`) does not support multi-node clusters. The `local-path` provisioner creates the volume on the node where the pod is scheduled:

```bash
minikube addons enable storage-provisioner-rancher -p fun-with-minikube
kubectl --context fun-with-minikube get sc
```

Data survives `minikube stop`/`start` but not `minikube delete`.

### 2. Install

```bash
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo update

helm install vmks vm/victoria-metrics-k8s-stack \
  --kube-context fun-with-minikube \
  --namespace monitoring --create-namespace \
  -f victoria-metrics/values.yaml

kubectl --context fun-with-minikube apply -f victoria-metrics/podinfo-vmservicescrape.yaml
kubectl --context fun-with-minikube -n monitoring get pods,pvc
```

### Pods in the `monitoring` namespace

| Pod | Type | Role |
| --- | --- | --- |
| `vmks-victoria-metrics-operator-*` | Deployment | Operator. Watches the VictoriaMetrics CRDs (`VMSingle`, `VMAgent`, `VMServiceScrape`, ...) and creates the matching pods, services and config. |
| `vmsingle-vmks-victoria-metrics-k8s-stack-*` | Deployment | VictoriaMetrics database (VMSingle). Receives the metrics, stores them on the 5Gi `local-path` volume and answers queries on port 8428. |
| `vmagent-vmks-victoria-metrics-k8s-stack-*` | Deployment | Scraper. Pulls metrics from all targets (pull model, Prometheus-compatible) and writes them to VMSingle. Runs 2 containers: `vmagent` and a config reloader that applies scrape-target changes without a restart. |
| `vmks-prometheus-node-exporter-*` | DaemonSet | Node exporter, one pod per node. Exposes CPU, memory, disk and network metrics of the node itself on port 9100. |
| `vmks-kube-state-metrics-*` | Deployment | Reads the Kubernetes API and exposes the state of objects as metrics (pod phase, restarts, replicas, PVC status, requests/limits). |
| `vmks-victoria-metrics-k8s-stack-sync-job-*` | Job | One-time post-install job. Downloads the default Grafana dashboards and stores them as ConfigMaps. Shows `Completed`, which is expected. |

Not running because they are disabled in `values.yaml`: Grafana, Alertmanager and vmalert. Set `grafana.enabled: true` to get dashboards.

Besides the stack itself, kubelet/cAdvisor (per-container usage), the API server, CoreDNS and podinfo (`/metrics`) are scraped by VMAgent. They have no pod in this namespace.

### 3. Access

```bash
# Grafana (user: admin)
kubectl --context fun-with-minikube -n monitoring get secret vmks-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl --context fun-with-minikube -n monitoring port-forward svc/vmks-grafana 3000:80

# VictoriaMetrics UI / query API
kubectl --context fun-with-minikube -n monitoring port-forward svc/vmsingle-vmks-victoria-metrics-k8s-stack 8428:8428
# then browse http://localhost:8428/vmui
```

### 4. Generate traffic and observe it with PromQL

[scripts/generate-traffic.sh](scripts/generate-traffic.sh) sends requests to podinfo. It uses `http://localhost:9898` (override with `PODINFO_URL`) and starts a `kubectl port-forward` itself if podinfo is not reachable there.

```bash
# scripts/generate-traffic.sh <scenario> [duration_seconds=300] [workers=4]
scripts/generate-traffic.sh steady
scripts/generate-traffic.sh errors 600 2
scripts/generate-traffic.sh all 300   # all five scenarios at once
```

Run the queries in Grafana (**Explore**, VictoriaMetrics data source) or in vmui. VMAgent scrapes every 30s, so wait 1 to 2 minutes before data shows up. podinfo exposes `http_requests_total{status}` and the histogram `http_request_duration_seconds{method,path,status}`.

| # | Scenario | What it does | PromQL |
| --- | --- | --- | --- |
| 1 | `steady` | Constant GET `/` and `/api/info` | `sum by (path) (rate(http_request_duration_seconds_count{job="my-podinfo", path!="healthz", path!="readyz", path!="metrics"}[1m]))` |
| 2 | `errors` | ~30% `500`, ~10% `404` | `sum(rate(http_requests_total{job="my-podinfo", status=~"5.."}[5m])) / sum(rate(http_requests_total{job="my-podinfo"}[5m]))` |
| 3 | `latency` | `/delay/0..3` seconds | `histogram_quantile(0.95, sum by (le, path) (rate(http_request_duration_seconds_bucket{job="my-podinfo"}[5m])))` |
| 4 | `echo` | POST JSON to `/api/echo` (202) | `sum by (method, status) (rate(http_request_duration_seconds_count{job="my-podinfo", path="api_echo"}[5m]))` |
| 5 | `burst` | No sleep, max request rate | `sum(rate(container_cpu_usage_seconds_total{namespace="demo", pod=~"my-podinfo-.*", container="podinfo"}[2m]))` |

Notes:

1. Requests per second per endpoint. The kubelet probes (`healthz`, `readyz`) and the scrape itself (`metrics`) are excluded.
2. Share of 5xx responses (0.3 = 30%). Use `sum by (status) (rate(http_requests_total{job="my-podinfo"}[1m]))` to see all status codes as stacked series.
3. 95th percentile latency per path in seconds. The `delay` path rises to several seconds, all others stay in the millisecond range.
4. POST rate on the echo endpoint, split by method and status code.
5. CPU cores used by the podinfo container (from cAdvisor). Also try `go_goroutines{job="my-podinfo"}` or `container_memory_working_set_bytes{namespace="demo", container="podinfo"}`.

### Troubleshooting

```bash
kubectl --context fun-with-minikube -n monitoring get pods -o wide
kubectl --context fun-with-minikube -n monitoring describe pod <pod>
kubectl --context fun-with-minikube -n monitoring get events --sort-by=.lastTimestamp
kubectl --context fun-with-minikube -n monitoring get pvc
```

- `Pending` with `Insufficient memory`: the nodes are too small. Remove components in `values.yaml` (for example Grafana) or recreate the cluster with more `--memory`.
- PVC `Pending`: the `local-path` StorageClass is missing, see step 1. It stays `Pending` until a pod using it is scheduled.

## Logs with VictoriaLogs and the OpenTelemetry Collector

```
Pods -> /var/log/pods (each node) -> OTel Collector (DaemonSet) -> VictoriaLogs (:9428) -> Grafana
```

- [victoria-logs/values.yaml](victoria-logs/values.yaml) installs VictoriaLogs standalone with the `victoria-logs-single` chart (release `vls`, 5Gi `local-path` volume, 7d retention). It also creates:
  - a ConfigMap with the **VictoriaLogs** Grafana datasource, which the Grafana sidecar of `vmks` picks up.
  - a `VMServiceScrape`, so the `vmks` VMAgent scrapes VictoriaLogs' own metrics (`vl_*`) into VictoriaMetrics.
  - the **VictoriaLogs - single-node** Grafana dashboard (ingestion rate, storage, resource usage). The chart also always adds an empty **Vector K8S Monitoring** dashboard, which you can ignore.
- [victoria-metrics/values.yaml](victoria-metrics/values.yaml) installs the `victoriametrics-logs-datasource` Grafana plugin needed by that datasource.
- [otel-collector/values.yaml](otel-collector/values.yaml) runs the collector as a DaemonSet. It tails container logs (`logsCollection` preset), adds Kubernetes metadata (`kubernetesAttributes` preset) and sends them via OTLP/HTTP to `/insert/opentelemetry/v1/logs`.

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

helm install vls vm/victoria-logs-single \
  --kube-context fun-with-minikube \
  --namespace monitoring \
  -f victoria-logs/values.yaml

helm install otel open-telemetry/opentelemetry-collector \
  --kube-context fun-with-minikube \
  --namespace monitoring \
  -f otel-collector/values.yaml

# Installs the Grafana plugin
helm upgrade vmks vm/victoria-metrics-k8s-stack \
  --kube-context fun-with-minikube \
  --namespace monitoring \
  -f victoria-metrics/values.yaml

kubectl --context fun-with-minikube -n monitoring get pods,pvc
```

The collector sends to `vls-victoria-logs-single-server`. If you use another release name than `vls`, update the URLs in both values files.

Query the logs in Grafana (**Explore**, **VictoriaLogs**) or in the VictoriaLogs UI:

```bash
kubectl --context fun-with-minikube -n monitoring port-forward svc/vls-victoria-logs-single-server 9428:9428
# then browse http://localhost:9428/select/vmui
```

LogsQL examples (run `scripts/generate-traffic.sh errors` first):

```
k8s.namespace.name:demo
k8s.namespace.name:demo k8s.container.name:podinfo error
k8s.namespace.name:demo | stats by (k8s.pod.name) count() logs
```

## Stop / restart / delete the cluster

```bash
# Stop (keeps cluster state)
minikube stop -p fun-with-minikube

# Start again after a stop (flags are stored in the profile)
minikube start -p fun-with-minikube

# Delete (removes the cluster completely)
minikube delete -p fun-with-minikube
```