# fun-with-minikube

Demo repository for experimenting with a local multi-node Minikube cluster.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Minikube](https://minikube.sigs.k8s.io/docs/start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

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

## Verify

```bash
minikube status -p fun-with-minikube
kubectl get nodes
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