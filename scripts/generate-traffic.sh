#!/usr/bin/env bash
# Generates traffic against podinfo for the PromQL examples in README.md.
#
# Usage: scripts/generate-traffic.sh <scenario> [duration_seconds] [workers]
#   scenarios: steady | errors | latency | echo | burst | all
#
# Uses PODINFO_URL (default http://localhost:9898). If it is not reachable, a
# kubectl port-forward to svc/my-podinfo is started for the duration of the run.

set -euo pipefail

SCENARIO="${1:-}"
DURATION="${2:-300}"
WORKERS="${3:-4}"
PODINFO_URL="${PODINFO_URL:-http://localhost:9898}"
KUBE_CONTEXT="${KUBE_CONTEXT:-fun-with-minikube}"
NAMESPACE="${NAMESPACE:-demo}"

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

ensure_reachable() {
  if curl -fs -o /dev/null --max-time 2 "$PODINFO_URL/healthz"; then
    return
  fi
  local port="${PODINFO_URL##*:}"
  echo "podinfo not reachable at $PODINFO_URL, starting port-forward on $port ..."
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" port-forward svc/my-podinfo "$port:9898" >/dev/null 2>&1 &
  PIDS+=($!)
  for _ in $(seq 1 20); do
    curl -fs -o /dev/null --max-time 1 "$PODINFO_URL/healthz" && return
    sleep 0.5
  done
  echo "podinfo still not reachable at $PODINFO_URL" >&2
  exit 1
}

req() {
  curl -s -o /dev/null --max-time 10 "$@" || true
}

# 1) Constant load on GET / and GET /api/info (~5 req/s per worker).
steady_worker() {
  while :; do
    req "$PODINFO_URL/"
    req "$PODINFO_URL/api/info"
    sleep 0.4
  done
}

# 2) ~30% 500 and ~10% 404 responses mixed into normal traffic.
errors_worker() {
  while :; do
    case $((RANDOM % 10)) in
      0 | 1 | 2) req "$PODINFO_URL/status/500" ;;
      3) req "$PODINFO_URL/status/404" ;;
      *) req "$PODINFO_URL/api/info" ;;
    esac
    sleep 0.2
  done
}

# 3) Slow requests: /delay/{0..3} seconds plus fast /api/info requests.
latency_worker() {
  while :; do
    req "$PODINFO_URL/delay/$((RANDOM % 4))"
    req "$PODINFO_URL/api/info"
  done
}

# 4) POST requests with a JSON payload to /api/echo (status 202).
echo_worker() {
  while :; do
    req -X POST -H 'Content-Type: application/json' \
      -d "{\"worker\":\"$1\",\"ts\":$(date +%s)}" "$PODINFO_URL/api/echo"
    sleep 0.3
  done
}

# 5) As fast as possible, no sleep: drives CPU and goroutines up.
burst_worker() {
  while :; do
    req "$PODINFO_URL/api/info"
    req "$PODINFO_URL/headers"
  done
}

run() {
  local scenario="$1"
  echo "scenario=$scenario duration=${DURATION}s workers=$WORKERS url=$PODINFO_URL"
  for i in $(seq 1 "$WORKERS"); do
    "${scenario}_worker" "$i" &
    PIDS+=($!)
  done
}

case "$SCENARIO" in
  steady | errors | latency | echo | burst | all) ;;
  *) usage ;;
esac

ensure_reachable

if [ "$SCENARIO" = all ]; then
  for s in steady errors latency echo burst; do run "$s"; done
else
  run "$SCENARIO"
fi

sleep "$DURATION"
echo "done"
