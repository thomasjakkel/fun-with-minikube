provider "minikube" {
  kubernetes_version = "v1.36.4"
}

resource "minikube_cluster" "docker" {
  driver       = "docker"
  cluster_name = "fun-with-minikube"
  nodes        = 2
  cpus         = 2
  memory       = "2560m"
  addons = [
    "storage-provisioner-rancher"
  ]
}

terraform {
  required_providers {
    minikube = {
      source  = "scott-the-programmer/minikube"
      version = "0.8.0"
    }
  }
}