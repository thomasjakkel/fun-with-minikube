# fun-with-minikube

Demo repository for experimenting with a local multi-node Minikube cluster.

## Prerequisites

- [Rancher Desktop](https://rancherdesktop.io/) with the `dockerd (moby)` container engine (provides the Docker socket that minikube's `docker` driver uses)
- [Minikube](https://minikube.sigs.k8s.io/docs/start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Terraform](https://developer.hashicorp.com/terraform/install) (creates the cluster)
- [Flux CLI](https://fluxcd.io/flux/installation/#install-the-flux-cli) (bootstraps GitOps)
- A GitHub personal access token for the repository (see [Bootstrap](#bootstrap-the-cluster-with-flux))

Install on macOS with [Homebrew](https://brew.sh):

```bash
brew install --cask rancher           # then start Rancher Desktop once
brew install minikube kubectl terraform fluxcd/tap/flux

docker --version && minikube version && kubectl version --client && terraform version && flux --version
```

Configure Rancher Desktop (Preferences):

- **Container Engine:** `dockerd (moby)`. With `containerd` there is no Docker socket and the minikube `docker` driver does not work.
- **Kubernetes:** disable it. minikube provides the cluster, so Rancher's built-in k3s only wastes memory.
- **Virtual Machine:** at least 6 GB memory and 4 CPUs so the two 2.5 GB nodes fit.

Make sure the Docker CLI talks to Rancher Desktop (`docker context use rancher-desktop`, or `DOCKER_HOST` pointing at `~/.rd/docker.sock`) and that `docker info` works. Docker Desktop works as well if you prefer it.

## Bootstrap the cluster with Flux

The cluster and everything on it are created by one re-runnable script, [scripts/bootstrap.sh](scripts/bootstrap.sh):

1. `terraform apply` creates the 2-node minikube cluster `fun-with-minikube` ([terraform/main.tf](terraform/main.tf): 2 CPUs and 2560 MB per node, `storage-provisioner-rancher` addon for the `local-path` StorageClass).
2. `flux bootstrap github` installs Flux, adds [clusters/minikube/flux-system/](clusters/minikube/flux-system) to the repository and makes Flux sync this repository from then on.

Before you run it:

- Start Rancher Desktop (`dockerd (moby)` engine, Kubernetes disabled). `docker info` must work.
- Push the manifests ([clusters/](clusters), [infrastructure/](infrastructure), [apps/](apps)) to the `flux` branch on GitHub. Flux only sees what is in the repository, not your working copy, and it syncs the `flux` branch (override with `BRANCH=<branch>`).

```bash
git push origin flux

export GITHUB_TOKEN=<github.com personal access token>
export GITHUB_OWNER=<owner of the GitHub repo>
scripts/bootstrap.sh              # syncs the flux branch (BRANCH=<branch> to change)

git pull                          # bootstrap commits clusters/minikube/flux-system/ to the branch
```

The script ends with `flux get kustomizations --watch`. Wait until `flux-system`, `infrastructure` and `apps` are `Ready True` (the first run takes several minutes), then stop it with `Ctrl+C`.

| Variable | Default | Description |
| --- | --- | --- |
| `GITHUB_OWNER` | (required) | User or organization that owns the repository |
| `GITHUB_TOKEN` | (required) | PAT. Fine-grained: *Administration* and *Contents* read/write on this repository |
| `GITHUB_REPO` | `fun-with-minikube` | Repository name |
| `BRANCH` | `flux` | Branch Flux syncs |
| `PERSONAL` | `true` | `false` if the owner is an organization |
| `TOKEN_AUTH` | `false` | `true` if you only have write access (no deploy key; Flux uses the PAT over HTTPS) |
| `PROFILE` | `fun-with-minikube` | minikube profile / kubectl context |

Running the script again is safe: `terraform apply` and `flux bootstrap` are idempotent. Flux only needs the token while bootstrapping; the cluster then reads the repository with a deploy key stored in the `flux-system` secret.

Flux does not wait for you: push changes to the watched branch and it applies them (the Git poll interval is 1 minute).

## Verify

```bash
minikube status -p fun-with-minikube
kubectl get nodes
flux get kustomizations   # flux-system, infrastructure, apps: READY True
flux get helmreleases -A  # vmks, vls, otel, my-podinfo: READY True
```

## What Flux deploys

Everything is declared in Git and applied by Flux in this order:

| Path | Flux Kustomization | Contents |
| --- | --- | --- |
| [clusters/minikube/](clusters/minikube) | `flux-system` (created by bootstrap) | Flux itself plus the two Kustomizations below |
| [infrastructure/](infrastructure) | `infrastructure` | Helm repositories, the `monitoring` namespace and the monitoring HelmReleases |
| [apps/](apps) | `apps` (after `infrastructure`) | `demo` namespace, podinfo and its `VMServiceScrape` |

| HelmRelease | Chart | Namespace | What it is |
| --- | --- | --- | --- |
| `my-podinfo` | `podinfo/podinfo` (`6.x`) | `demo` | Demo app, `logLevel: debug` |
| `vmks` | `victoria-metrics-k8s-stack` (`>=0.96.0 <1.0.0`) | `monitoring` | Operator, VMSingle, VMAgent, Grafana, kube-state-metrics, node-exporter |
| `vls` | `victoria-logs-single` (`>=0.13.10 <1.0.0`) | `monitoring` | VictoriaLogs (waits for `vmks`, which provides the CRDs) |
| `otel` | `opentelemetry-collector` (`>=0.176.1 <1.0.0`) | `monitoring` | DaemonSet that ships container logs to VictoriaLogs |

The resource names (`my-podinfo`, `vmks-*`, `vls-victoria-logs-single-server`, `otel-opentelemetry-collector-*`) are fixed via `fullnameOverride` in each HelmRelease.

### Auto release

The chart `version` of every HelmRelease is a semver range, so Flux installs the newest matching chart on its own (checked every `interval`; the Helm repositories are refreshed hourly). The first run installs the newest version in the range, not the minimum. A failed upgrade is retried 3 times and then rolled back (`remediateLastFailure`). To stop automatic updates, pin an exact version in the HelmRelease or run `flux suspend helmrelease <name> -n <namespace>`.

### Configuration

- Change values in the `values:` block of the HelmRelease, commit and push. Flux applies the change.
- To trigger it immediately: `flux reconcile kustomization infrastructure --with-source` (or `apps`).
- Disable a component by removing it from the `kustomization.yaml` next to it (Flux prunes it). When removing `vmks`, also set `server.vmServiceScrape.enabled: false` in `vls.yaml` and drop [apps/podinfo/vmservicescrape.yaml](apps/podinfo/vmservicescrape.yaml), since the CRD comes from `vmks`.
- Render and check the manifests locally: `kubectl kustomize infrastructure` and `kubectl kustomize apps`.

### Useful commands

```bash
flux get all -A
flux logs --level=error
flux tree kustomization flux-system
kubectl --context fun-with-minikube -n monitoring get pods,pvc
kubectl --context fun-with-minikube -n demo get pods,svc
```

The default `standard` StorageClass (`minikube-hostpath`) does not support multi-node clusters, so the volumes use `local-path`. It creates the volume on the node where the pod is scheduled. Data survives `minikube stop`/`start` but not `minikube delete`.

Minikube names the kubectl context after the profile. Optionally make it active and set `demo` as its default namespace:

```bash
kubectl config use-context fun-with-minikube
kubectl config set-context fun-with-minikube --namespace demo
```

### Access podinfo

```bash
kubectl --context fun-with-minikube -n demo port-forward svc/my-podinfo 9898:9898
# then browse http://localhost:9898
```

### Uninstall

```bash
# Remove the workloads but keep the cluster: delete the manifests from Git (Flux prunes them), or
flux uninstall --keep-namespace   # removes Flux; the deployed Helm releases keep running
# Delete everything, including the volumes
minikube delete -p fun-with-minikube
```

Run `scripts/bootstrap.sh` again to recreate the same state from Git.

### Migrating from the Helm umbrella chart

Earlier versions installed everything with `helm upgrade --install` (`scripts/up.sh`, umbrella chart in `charts/`). Remove that release before bootstrapping, since Flux creates the same resources and manages them as its own Helm releases. Metrics and logs stored on the old volumes are lost.

```bash
helm uninstall fun-with-minikube -n monitoring --kube-context fun-with-minikube
kubectl --context fun-with-minikube delete namespace demo
kubectl --context fun-with-minikube -n monitoring delete pvc --all
```

## VictoriaMetrics stack with persistent storage

The `vmks` HelmRelease runs the `victoria-metrics-k8s-stack` (operator, VMSingle, VMAgent, Grafana, kube-state-metrics, node-exporter) in the `monitoring` namespace and scrapes the podinfo app. Its settings are in [infrastructure/monitoring/vmks.yaml](infrastructure/monitoring/vmks.yaml).

### Pods in the `monitoring` namespace

| Pod | Type | Role |
| --- | --- | --- |
| `vmks-victoria-metrics-operator-*` | Deployment | Operator. Watches the VictoriaMetrics CRDs (`VMSingle`, `VMAgent`, `VMServiceScrape`, ...) and creates the matching pods, services and config. |
| `vmsingle-vmks-victoria-metrics-k8s-stack-*` | Deployment | VictoriaMetrics database (VMSingle). Receives the metrics, stores them on the 5Gi `local-path` volume and answers queries on port 8428. |
| `vmagent-vmks-victoria-metrics-k8s-stack-*` | Deployment | Scraper. Pulls metrics from all targets (pull model, Prometheus-compatible) and writes them to VMSingle. Runs 2 containers: `vmagent` and a config reloader that applies scrape-target changes without a restart. |
| `vmks-prometheus-node-exporter-*` | DaemonSet | Node exporter, one pod per node. Exposes CPU, memory, disk and network metrics of the node itself on port 9100. |
| `vmks-kube-state-metrics-*` | Deployment | Reads the Kubernetes API and exposes the state of objects as metrics (pod phase, restarts, replicas, PVC status, requests/limits). |
| `vmks-victoria-metrics-k8s-stack-sync-job-*` | Job | One-time post-install job. Downloads the default Grafana dashboards and stores them as ConfigMaps. Shows `Completed`, which is expected. |

The `vmks-grafana-*` pod runs Grafana with persistent storage. Alertmanager and vmalert are disabled in `vmks.yaml`.

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

- `Pending` with `Insufficient memory`: the nodes are too small. Remove components in the HelmReleases (for example `grafana.enabled: false` in `vmks.yaml`) or recreate the cluster with more `memory` in `terraform/main.tf`.
- PVC `Pending`: the `local-path` StorageClass is missing (`kubectl --context fun-with-minikube get sc`); check that the `storage-provisioner-rancher` addon is enabled in `terraform/main.tf`. It stays `Pending` until a pod using it is scheduled.
- A HelmRelease is not ready: `flux get helmreleases -A` and `kubectl -n <namespace> describe helmrelease <name>`.

## Logs with VictoriaLogs and the OpenTelemetry Collector

```
Pods -> /var/log/pods (each node) -> OTel Collector (DaemonSet) -> VictoriaLogs (:9428) -> Grafana
```

Both parts are deployed by Flux (see [What Flux deploys](#what-flux-deploys)); their settings are in [infrastructure/monitoring/vls.yaml](infrastructure/monitoring/vls.yaml), [infrastructure/monitoring/otel.yaml](infrastructure/monitoring/otel.yaml) and [infrastructure/monitoring/vmks.yaml](infrastructure/monitoring/vmks.yaml):

- `vls` runs VictoriaLogs with the `victoria-logs-single` chart (5Gi `local-path` volume, 7d retention). It also creates:
  - a `VMServiceScrape`, so the `vmks` VMAgent scrapes VictoriaLogs' own metrics (`vl_*`) into VictoriaMetrics.
  - the **VictoriaLogs - single-node** Grafana dashboard (ingestion rate, storage, resource usage). The chart also always adds an empty **Vector K8S Monitoring** dashboard, which you can ignore.
- `vmks.yaml` adds the **VictoriaLogs** Grafana datasource (`defaultDatasources.extra`) and installs the `victoriametrics-logs-datasource` plugin it needs (`grafana.plugins`).
- `otel` runs the collector as a DaemonSet. It tails container logs (`logsCollection` preset), adds Kubernetes metadata (`kubernetesAttributes` preset) and sends them via OTLP/HTTP to `/insert/opentelemetry/v1/logs`. Its collector config is set in `alternateConfig` (logs pipeline only), which replaces the chart's default traces/metrics pipelines.

The collector and the datasource use `http://vls-victoria-logs-single-server.monitoring.svc:9428`. Update it in `vmks.yaml` and `otel.yaml` if you change the `vls` `fullnameOverride` or the namespace.

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