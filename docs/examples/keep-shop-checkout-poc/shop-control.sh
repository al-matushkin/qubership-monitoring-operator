#!/usr/bin/env bash
# Trigger outage, recover, or slow-mode on shop-checkout demo services.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: shop-control.sh <action> [service ...]

Actions:
  trigger-outage   Simulate service failure
  recover          Return service to normal
  slow-mode        Add latency (storefront only)

Services (default: checkout-demo):
  checkout-demo, storefront, payments-api

Examples:
  shop-control.sh trigger-outage checkout-demo
  shop-control.sh recover storefront payments-api checkout-demo
  shop-control.sh slow-mode storefront

Equivalent one-liner (same HTTP call inside the pod):
  kubectl -n shop exec deploy/checkout-demo -- wget -qO- http://127.0.0.1:8080/trigger-outage
EOF
  exit 1
}

ACTION="${1:-}"
shift || usage

case "${ACTION}" in
  trigger-outage|recover|slow-mode) ;;
  *) usage ;;
esac

if [[ "${ACTION}" == "slow-mode" ]]; then
  SERVICES=("${@:-storefront}")
else
  SERVICES=("${@:-checkout-demo}")
fi

for svc in "${SERVICES[@]}"; do
  case "${svc}" in
    checkout-demo|storefront|payments-api) ;;
    *) echo "unknown service: ${svc}" >&2; exit 1 ;;
  esac
  if [[ "${ACTION}" == "slow-mode" && "${svc}" != "storefront" ]]; then
    echo "slow-mode applies only to storefront (skipping ${svc})" >&2
    continue
  fi
  out="$(kubectl -n shop exec "deploy/${svc}" -- wget -qO- "http://127.0.0.1:8080/${ACTION}")"
  echo "${svc}: ${out}"
done
