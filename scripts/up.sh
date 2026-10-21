#!/usr/bin/env bash
# Creates (or updates) the whole local setup: minikube cluster, local-path storage and the
# fun-with-minikube umbrella chart (charts/). Safe to run repeatedly.
#
# Usage: scripts/up.sh [extra helm args...]
#   e.g. scripts/up.sh --set otel.enabled=false

set -euo pipefail

PROFILE="${PROFILE:-fun-with-minikube}"
NODES="${NODES:-2}"
CPUS="${CPUS:-2}"
MEMORY="${MEMORY:-2560}"
RELEASE="${RELEASE:-fun-with-minikube}"
NAMESPACE="${NAMESPACE:-monitoring}"

CHART_DIR="$(cd "$(dirname "$0")/../charts" && pwd)"

if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  echo "minikube profile $PROFILE is running"
else
  # Without flags for an existing (stopped) profile, minikube uses the stored ones.
  if minikube profile list -o json 2>/dev/null | grep -Eq "\"Name\": *\"$PROFILE\""; then
    minikube start -p "$PROFILE"
  else
    minikube start -p "$PROFILE" --nodes "$NODES" --driver=docker --cpus "$CPUS" --memory "$MEMORY"
  fi
fi

# local-path StorageClass; the default minikube-hostpath class does not support multi-node clusters.
minikube addons enable storage-provisioner-rancher -p "$PROFILE"

helm repo add podinfo https://stefanprodan.github.io/podinfo --force-update >/dev/null
helm repo add vm https://victoriametrics.github.io/helm-charts/ --force-update >/dev/null
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null
helm dependency build "$CHART_DIR"

helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --kube-context "$PROFILE" \
  --namespace "$NAMESPACE" --create-namespace \
  --timeout 10m \
  "$@"
