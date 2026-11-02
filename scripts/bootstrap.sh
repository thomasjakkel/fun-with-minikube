#!/usr/bin/env bash
# Creates the minikube cluster with Terraform and bootstraps Flux against the GitHub repo.
# Safe to run repeatedly: both `terraform apply` and `flux bootstrap` are idempotent.
#
# Usage:
#   export GITHUB_TOKEN=<github.com PAT>
#   GITHUB_OWNER=<repo owner> scripts/bootstrap.sh
#
# Optional: GITHUB_REPO, BRANCH, PROFILE, TOKEN_AUTH=true (write access only, no deploy key),
#           PERSONAL=false (owner is an organization)

set -euo pipefail

PROFILE="${PROFILE:-fun-with-minikube}"
: "${GITHUB_OWNER:?export GITHUB_OWNER (owner of the GitHub repo) first}"
GITHUB_REPO="${GITHUB_REPO:-fun-with-minikube}"
BRANCH="${BRANCH:-flux}"
PERSONAL="${PERSONAL:-true}"
TOKEN_AUTH="${TOKEN_AUTH:-false}"
: "${GITHUB_TOKEN:?export GITHUB_TOKEN first}"

TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

terraform -chdir="$TF_DIR" init -input=false
terraform -chdir="$TF_DIR" apply -input=false -auto-approve

# The kubeconfig context is named like the minikube profile / cluster_name in terraform/main.tf.
kubectl config get-contexts "$PROFILE" >/dev/null

# minikube ships a podman CNI config with the same subnet as kindnet. Pods that start before
# kindnet is ready (CoreDNS, local-path provisioner) attach to it and cannot talk across nodes.
kubectl --context "$PROFILE" -n kube-system rollout status ds/kindnet --timeout=5m
kubectl --context "$PROFILE" -n kube-system rollout restart deploy/coredns
kubectl --context "$PROFILE" -n local-path-storage rollout restart deploy/local-path-provisioner
kubectl --context "$PROFILE" -n kube-system rollout status deploy/coredns --timeout=5m
kubectl --context "$PROFILE" -n local-path-storage rollout status deploy/local-path-provisioner --timeout=5m

flux check --pre --context "$PROFILE"

args=(
  --context="$PROFILE"
  --owner="$GITHUB_OWNER"
  --repository="$GITHUB_REPO"
  --branch="$BRANCH"
  --path=clusters/minikube
)
[[ "$PERSONAL" == "true" ]] && args+=(--personal)
if [[ "$TOKEN_AUTH" == "true" ]]; then
  args+=(--token-auth)
fi

flux bootstrap github "${args[@]}"

flux get kustomizations --context "$PROFILE" --watch
