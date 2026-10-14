# fun-with-minikube

Demo repository for experimenting with a local multi-node Minikube cluster.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Minikube](https://minikube.sigs.k8s.io/docs/start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)

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

## Stop / restart / delete the cluster

```bash
# Stop (keeps cluster state)
minikube stop -p fun-with-minikube

# Start again after a stop (flags are stored in the profile)
minikube start -p fun-with-minikube

# Delete (removes the cluster completely)
minikube delete -p fun-with-minikube
```