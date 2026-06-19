#!/usr/bin/env bash
# Trigger outage, recover, or slow-mode on shop-checkout demo services.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: shop-control.sh <action> [service ...]

Actions:
  trigger-cascade  Root failure at payments-api → checkout → storefront (all 3 services)
  trigger-outage   Simulate failure on one service (default: checkout-demo)
  recover          Return service(s) to normal (default: all three — required after trigger-cascade)
  slow-mode        Add latency (storefront only)

Services (default for trigger-outage: checkout-demo):
  checkout-demo, storefront, payments-api

Examples:
  shop-control.sh trigger-cascade
  shop-control.sh trigger-cascade
  shop-control.sh recover
  shop-control.sh recover storefront payments-api checkout-demo
  shop-control.sh slow-mode storefront

Equivalent one-liner (full cascade — payments root):
  kubectl -n shop exec deploy/payments-api -- wget -qO- http://127.0.0.1:8080/trigger-outage
EOF
  exit 1
}

ACTION="${1:-}"
shift || usage

case "${ACTION}" in
  trigger-cascade|trigger-outage|recover|slow-mode) ;;
  *) usage ;;
esac

if [[ "${ACTION}" == "trigger-cascade" ]]; then
  if [[ "$#" -gt 0 ]]; then
    echo "trigger-cascade takes no service arguments (root is always payments-api)" >&2
    exit 1
  fi
  out="$(kubectl -n shop exec deploy/payments-api -- wget -qO- "http://127.0.0.1:8080/trigger-outage")"
  echo "payments-api (cascade root): ${out}"
  echo "Cascade: payments-api → checkout-demo → storefront (see README for timing)"
  exit 0
fi

if [[ "${ACTION}" == "slow-mode" ]]; then
  SERVICES=("${@:-storefront}")
elif [[ "${ACTION}" == "recover" && "$#" -eq 0 ]]; then
  # Cascade root is payments-api; recovering only checkout leaves charges failing.
  SERVICES=(payments-api checkout-demo storefront)
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
