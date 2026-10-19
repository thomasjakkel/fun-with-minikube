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
  --namespace demo --create-namespace
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

### Troubleshooting

```bash
kubectl --context fun-with-minikube -n monitoring get pods -o wide
kubectl --context fun-with-minikube -n monitoring describe pod <pod>
kubectl --context fun-with-minikube -n monitoring get events --sort-by=.lastTimestamp
kubectl --context fun-with-minikube -n monitoring get pvc
```

- `Pending` with `Insufficient memory`: the nodes are too small. Remove components in `values.yaml` (for example Grafana) or recreate the cluster with more `--memory`.
- PVC `Pending`: the `local-path` StorageClass is missing, see step 1. It stays `Pending` until a pod using it is scheduled.

## Stop / restart / delete the cluster

```bash
# Stop (keeps cluster state)
minikube stop -p fun-with-minikube

# Start again after a stop (flags are stored in the profile)
minikube start -p fun-with-minikube

# Delete (removes the cluster completely)
minikube delete -p fun-with-minikube
```