#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OBSERVABILITY_ROOT="$(cd "${ROOT_DIR}/../../../.." && pwd)"

OPENSEARCH_CHART="${OPENSEARCH_CHART:-${OBSERVABILITY_ROOT}/qubership-opensearch/operator/charts/helm/opensearch-service}"
LOGGING_CHART="${LOGGING_CHART:-${OBSERVABILITY_ROOT}/qubership-logging-operator/charts/qubership-logging-operator}"

if [[ ! -d "${OPENSEARCH_CHART}" ]]; then
  echo "OpenSearch chart not found at ${OPENSEARCH_CHART}" >&2
  echo "Clone qubership-opensearch next to qubership-monitoring-operator or set OPENSEARCH_CHART." >&2
  exit 1
fi

if [[ ! -d "${LOGGING_CHART}" ]]; then
  echo "Logging operator chart not found at ${LOGGING_CHART}" >&2
  echo "Clone qubership-logging-operator next to qubership-monitoring-operator or set LOGGING_CHART." >&2
  exit 1
fi

echo "Installing OpenSearch..."
helm upgrade --install opensearch \
  --namespace opensearch \
  --create-namespace \
  --wait \
  --timeout 20m \
  "${OPENSEARCH_CHART}" \
  -f "${ROOT_DIR}/values-opensearch-kind.yaml"

echo "Waiting for OpenSearch status provisioner..."
attempt=1
max_attempts=60
while [[ ${attempt} -le ${max_attempts} ]]; do
  phase="$(kubectl get pod -l name=opensearch-status-provisioner -n opensearch -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo NotFound)"
  if [[ "${phase}" == "Succeeded" ]]; then
    break
  fi
  if [[ "${phase}" == "Failed" || "${phase}" == "Error" ]]; then
    echo "OpenSearch status provisioner failed: ${phase}" >&2
    kubectl get pods -n opensearch
    exit 1
  fi
  sleep 10
  attempt=$((attempt + 1))
done

if [[ "${phase:-}" != "Succeeded" ]]; then
  echo "Timed out waiting for OpenSearch status provisioner." >&2
  exit 1
fi

echo "Preparing logging namespace..."
kubectl create namespace logging --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace logging pod-security.kubernetes.io/enforce=privileged --overwrite

echo "Installing logging operator..."
helm upgrade --install qubership-logging-operator \
  --namespace logging \
  "${LOGGING_CHART}" \
  -f "${ROOT_DIR}/values-logging-kind.yaml"

echo "Waiting for Graylog pod..."
kubectl wait --for=condition=ready pod -l app=graylog -n logging --timeout=900s

echo "Logging stack deployed."
echo "Graylog UI: kubectl port-forward -n logging svc/graylog-service 9000:9000"
