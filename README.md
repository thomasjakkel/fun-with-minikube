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

## Deploy everything with Helm

The whole setup is a single umbrella chart in [charts/](charts/), configured by one file, [charts/values.yaml](charts/values.yaml). It pulls in these charts as dependencies (versions pinned in [charts/Chart.yaml](charts/Chart.yaml) and [charts/Chart.lock](charts/Chart.lock)):

| Values key | Chart | Namespace | What it is |
| --- | --- | --- | --- |
| `podinfo` | `podinfo/podinfo` | `demo` | Demo app (`my-podinfo`), `logLevel: debug` |
| `vmks` | `vm/victoria-metrics-k8s-stack` | `monitoring` | Operator, VMSingle, VMAgent, Grafana, kube-state-metrics, node-exporter |
| `vls` | `vm/victoria-logs-single` | `monitoring` | VictoriaLogs |
| `otel` | `open-telemetry/opentelemetry-collector` | `monitoring` | DaemonSet that ships container logs to VictoriaLogs |

The chart itself adds the `demo` namespace and a `VMServiceScrape` so VMAgent scrapes podinfo's `/metrics`. The release is installed into `monitoring`; podinfo is moved to `demo` via `podinfo.namespaceOverride`. The resource names (`my-podinfo`, `vmks-*`, `vls-victoria-logs-single-server`, `otel-opentelemetry-collector-*`) are fixed via `fullnameOverride`, so they do not depend on the release name.

### Quick start

[scripts/up.sh](scripts/up.sh) starts the minikube cluster if needed, enables the `local-path` storage class, downloads the chart dependencies and installs or upgrades the release. Run it again after changing `charts/values.yaml`:

```bash
scripts/up.sh
scripts/up.sh --set otel.enabled=false   # extra args are passed to helm
```

`PROFILE`, `NODES`, `CPUS`, `MEMORY`, `RELEASE` and `NAMESPACE` can be overridden as environment variables.

### Manual steps

Minikube names the kubectl context after the profile. Optionally make it active and set `demo` as its default namespace:

```bash
kubectl config use-context fun-with-minikube
kubectl config set-context fun-with-minikube --namespace demo
```

The default `standard` StorageClass (`minikube-hostpath`) does not support multi-node clusters. The `local-path` provisioner creates the volume on the node where the pod is scheduled. Data survives `minikube stop`/`start` but not `minikube delete`.

```bash
minikube addons enable storage-provisioner-rancher -p fun-with-minikube
kubectl --context fun-with-minikube get sc
```

Add the chart repositories once (`helm dependency build` needs them), download the dependencies into `charts/charts/` (not committed) and install. The same command applies changes to an existing release:

```bash
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts

helm dependency build charts/

helm upgrade --install fun-with-minikube charts/ \
  --kube-context fun-with-minikube \
  --namespace monitoring --create-namespace \
  --timeout 10m

helm list -n monitoring --kube-context fun-with-minikube
kubectl --context fun-with-minikube -n monitoring get pods,pvc
kubectl --context fun-with-minikube -n demo get pods,svc
```

To update a dependency, change its `version` in `charts/Chart.yaml` and run `helm dependency update charts/`, which also rewrites `Chart.lock`.

### Configuration

- Every dependency is configured under its key (`podinfo`, `vmks`, `vls`, `otel`) and can be switched off with `<key>.enabled: false`. When disabling `vmks`, also set `vls.server.vmServiceScrape.enabled: false` (its CRD comes from `vmks`).
- `shared` holds values reused via YAML anchors: the node selector for the worker node, the StorageClass and the VictoriaLogs URL.
- `podinfoScrape.enabled` and `podinfoNamespace.create` control the objects added by the umbrella chart.
- Render the manifests without installing: `helm template fun-with-minikube charts/ -n monitoring`.

### Access podinfo

```bash
kubectl --context fun-with-minikube -n demo port-forward svc/my-podinfo 9898:9898
# then browse http://localhost:9898
```

### Uninstall

```bash
helm uninstall fun-with-minikube -n monitoring --kube-context fun-with-minikube
# Some volumes (e.g. the VictoriaLogs StatefulSet PVC) are kept; delete them to drop the data
kubectl --context fun-with-minikube -n monitoring delete pvc --all
```

### Migrating from the separate releases

Earlier versions of this repository installed four releases (`my-podinfo`, `vmks`, `vls`, `otel`). Remove them before installing the umbrella chart, since it uses the same resource names and creates the `demo` namespace itself. Metrics and logs stored on the old volumes are lost.

```bash
helm uninstall my-podinfo -n demo --kube-context fun-with-minikube
helm uninstall otel vls vmks -n monitoring --kube-context fun-with-minikube
kubectl --context fun-with-minikube delete namespace demo
kubectl --context fun-with-minikube -n monitoring delete pvc --all
```

## VictoriaMetrics stack with persistent storage

The `vmks` part of the chart runs the `victoria-metrics-k8s-stack` (operator, VMSingle, VMAgent, Grafana, kube-state-metrics, node-exporter) in the `monitoring` namespace and scrapes the podinfo app. Its settings are under `vmks` in [charts/values.yaml](charts/values.yaml).

### Pods in the `monitoring` namespace

| Pod | Type | Role |
| --- | --- | --- |
| `vmks-victoria-metrics-operator-*` | Deployment | Operator. Watches the VictoriaMetrics CRDs (`VMSingle`, `VMAgent`, `VMServiceScrape`, ...) and creates the matching pods, services and config. |
| `vmsingle-vmks-victoria-metrics-k8s-stack-*` | Deployment | VictoriaMetrics database (VMSingle). Receives the metrics, stores them on the 5Gi `local-path` volume and answers queries on port 8428. |
| `vmagent-vmks-victoria-metrics-k8s-stack-*` | Deployment | Scraper. Pulls metrics from all targets (pull model, Prometheus-compatible) and writes them to VMSingle. Runs 2 containers: `vmagent` and a config reloader that applies scrape-target changes without a restart. |
| `vmks-prometheus-node-exporter-*` | DaemonSet | Node exporter, one pod per node. Exposes CPU, memory, disk and network metrics of the node itself on port 9100. |
| `vmks-kube-state-metrics-*` | Deployment | Reads the Kubernetes API and exposes the state of objects as metrics (pod phase, restarts, replicas, PVC status, requests/limits). |
| `vmks-victoria-metrics-k8s-stack-sync-job-*` | Job | One-time post-install job. Downloads the default Grafana dashboards and stores them as ConfigMaps. Shows `Completed`, which is expected. |

The `vmks-grafana-*` pod runs Grafana with persistent storage. Alertmanager and vmalert are disabled in `charts/values.yaml`.

Besides the stack itself, kubelet/cAdvisor (per-container usage), the API server, CoreDNS and podinfo (`/metrics`) are scraped by VMAgent. They have no pod in this namespace.

### Access Grafana and VictoriaMetrics

```bash
# Grafana (user: admin)
kubectl --context fun-with-minikube -n monitoring get secret vmks-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl --context fun-with-minikube -n monitoring port-forward svc/vmks-grafana 3000:80

# VictoriaMetrics UI / query API
kubectl --context fun-with-minikube -n monitoring port-forward svc/vmsingle-vmks-victoria-metrics-k8s-stack 8428:8428
# then browse http://localhost:8428/vmui
```

### Generate traffic and observe it with PromQL

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

- `Pending` with `Insufficient memory`: the nodes are too small. Remove components in `charts/values.yaml` (for example `vmks.grafana.enabled: false`) or recreate the cluster with more `--memory`.
- PVC `Pending`: the `local-path` StorageClass is missing, see [Manual steps](#manual-steps). It stays `Pending` until a pod using it is scheduled.

## Logs with VictoriaLogs and the OpenTelemetry Collector

```
Pods -> /var/log/pods (each node) -> OTel Collector (DaemonSet) -> VictoriaLogs (:9428) -> Grafana
```

Both parts are installed with the umbrella chart (see [Deploy everything with Helm](#deploy-everything-with-helm)); their settings are in [charts/values.yaml](charts/values.yaml):

- `vls` runs VictoriaLogs with the `victoria-logs-single` chart (5Gi `local-path` volume, 7d retention). It also creates:
  - a `VMServiceScrape`, so the `vmks` VMAgent scrapes VictoriaLogs' own metrics (`vl_*`) into VictoriaMetrics.
  - the **VictoriaLogs - single-node** Grafana dashboard (ingestion rate, storage, resource usage). The chart also always adds an empty **Vector K8S Monitoring** dashboard, which you can ignore.
- `vmks.defaultDatasources.extra` adds the **VictoriaLogs** Grafana datasource, and `vmks.grafana.plugins` installs the `victoriametrics-logs-datasource` plugin it needs.
- `otel` runs the collector as a DaemonSet. It tails container logs (`logsCollection` preset), adds Kubernetes metadata (`kubernetesAttributes` preset) and sends them via OTLP/HTTP to `/insert/opentelemetry/v1/logs`. Its collector config is set in `otel.alternateConfig` (logs pipeline only), because Helm cannot remove the chart's default traces/metrics pipelines with `null` from a parent chart.

The collector and the datasource use `shared.victoriaLogsUrl` (`http://vls-victoria-logs-single-server.monitoring.svc:9428`). Update it if you change `vls.fullnameOverride` or the namespace.

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