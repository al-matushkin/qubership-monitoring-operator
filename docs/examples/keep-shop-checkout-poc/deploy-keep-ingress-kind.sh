#!/usr/bin/env bash
# Install ingress-nginx on Kind (NodePort :30080) and upgrade Keep with values-keep-kind.yaml.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INGRESS_NS="${INGRESS_NS:-ingress-nginx}"
KEEP_NS="${KEEP_NS:-keep}"
KEEP_HOST="${KEEP_HOST:-keep.local}"
INGRESS_NODE_PORT="${INGRESS_NODE_PORT:-30080}"

echo "==> Ensuring ingress-nginx is installed (NodePort ${INGRESS_NODE_PORT})..."
if ! kubectl get namespace "${INGRESS_NS}" >/dev/null 2>&1; then
  kubectl create namespace "${INGRESS_NS}"
fi

if ! helm status ingress-nginx -n "${INGRESS_NS}" >/dev/null 2>&1; then
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update ingress-nginx >/dev/null 2>&1 || helm repo update >/dev/null 2>&1 || true
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace "${INGRESS_NS}" \
    --set controller.ingressClassResource.name=nginx \
    --set controller.ingressClass=nginx \
    --set controller.watchIngressWithoutClass=true \
    --set controller.allowSnippetAnnotations=true \
    --set controller.config.annotations-risk-level=Critical \
    --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http="${INGRESS_NODE_PORT}"
else
  echo "ingress-nginx already installed; ensuring snippet annotations are allowed..."
  helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
    --namespace "${INGRESS_NS}" \
    --reuse-values \
    --set controller.allowSnippetAnnotations=true \
    --set controller.config.annotations-risk-level=Critical
fi

kubectl -n "${INGRESS_NS}" rollout status deploy/ingress-nginx-controller --timeout=180s

echo "==> Upgrading Keep with ingress enabled..."
helm upgrade keep keephq/keep \
  --namespace "${KEEP_NS}" \
  --reuse-values=false \
  -f "${ROOT_DIR}/values-keep-kind.yaml"

kubectl -n "${KEEP_NS}" rollout status deploy/keep-frontend --timeout=180s
kubectl -n "${KEEP_NS}" rollout status deploy/keep-backend --timeout=180s

# Helm sets NEXTAUTH_URL=http://keep.local (no port). With port-forward on :30080 the UI
# redirects to port 80 and breaks. Patch after every upgrade (chart has no override hook).
LOCAL_INGRESS_PORT="${LOCAL_INGRESS_PORT:-30080}"
kubectl -n "${KEEP_NS}" set env deploy/keep-frontend \
  "NEXTAUTH_URL=http://${KEEP_HOST}:${LOCAL_INGRESS_PORT}"
kubectl -n "${KEEP_NS}" rollout status deploy/keep-frontend --timeout=180s

echo "==> Waiting for Keep ingress..."
for _ in $(seq 1 30); do
  if kubectl -n "${KEEP_NS}" get ingress keep-ingress >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

kubectl -n "${KEEP_NS}" get ingress keep-ingress 2>/dev/null || kubectl -n "${KEEP_NS}" get ingress

NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"

echo
echo "Access (requires port-forward on Kind — NodePort is not on 127.0.0.1):"
echo "  1. Add to /etc/hosts: 127.0.0.1 ${KEEP_HOST}"
echo "  2. Run: ./port-forward-keep-ingress.sh"
echo "  3. Open: http://${KEEP_HOST}:${LOCAL_INGRESS_PORT}/  (must include :${LOCAL_INGRESS_PORT})"
echo
echo "  NodePort direct (no port-forward): add '${NODE_IP} ${KEEP_HOST}' to /etc/hosts,"
echo "  open http://${KEEP_HOST}:${INGRESS_NODE_PORT}/"
echo
echo "Keep API: http://${KEEP_HOST}:${LOCAL_INGRESS_PORT}/v2"
echo "Example: KEEP_API_URL=http://${KEEP_HOST}:${LOCAL_INGRESS_PORT}/v2 ./keep/apply-keep-config.sh"
