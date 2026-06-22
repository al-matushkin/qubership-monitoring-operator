#!/usr/bin/env bash
# Verify enriched SMTP email per rule incident (not per alert).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP_API_URL="${KEEP_API_URL:-http://keep.local:30080/v2}"
KEEP_API_KEY="${KEEP_API_KEY:-any-local-key}"
MAILPIT_API_URL="${MAILPIT_API_URL:-http://127.0.0.1:18025/api/v1}"
WAIT_SECS="${WAIT_SECS:-150}"

before_count() {
  curl -fsS "${MAILPIT_API_URL}/messages" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('total',0))" || echo 0
}

find_firing_shopchk_incident() {
  curl -fsS -u "api_key:${KEEP_API_KEY}" "${KEEP_API_URL}/incidents?limit=30" | python3 -c "
import json, sys
items = json.load(sys.stdin)
if isinstance(items, dict):
    items = items.get('items', [])
for i in items:
    name = str(i.get('user_generated_name', ''))
    if i.get('incident_type') == 'rule' and i.get('status') == 'firing' and name.startswith('shopchk-'):
        print(i['id'])
        break
"
}

echo "==> Deploy Mailpit (SMTP capture) in namespace keep..."
kubectl apply -f "${ROOT_DIR}/k8s/mailpit.yaml"
kubectl -n keep rollout status deploy/mailpit --timeout=120s

echo "==> Port-forward Mailpit UI/API (background on 18025)..."
if ! curl -fsS -m 2 "${MAILPIT_API_URL}/messages" >/dev/null 2>&1; then
  kubectl -n keep port-forward svc/mailpit 18025:8025 >/tmp/mailpit-pf.log 2>&1 &
  sleep 2
fi

msgs_before="$(before_count)"

echo "==> Install SMTP provider + workflow..."
KEEP_API_URL="${KEEP_API_URL}" KEEP_API_KEY="${KEEP_API_KEY}" "${ROOT_DIR}/keep/apply-keep-config.sh"

incident_id="$(find_firing_shopchk_incident || true)"
if [[ -z "${incident_id:-}" ]]; then
  echo "No firing shopchk rule incident — triggering cascade..."
  "${ROOT_DIR}/shop-control.sh" trigger-cascade
  echo "Waiting up to ${WAIT_SECS}s for shopchk-* rule incident..."
  for _ in $(seq 1 $((WAIT_SECS / 5))); do
    incident_id="$(find_firing_shopchk_incident || true)"
    if [[ -n "${incident_id:-}" ]]; then
      echo "Firing rule incident: ${incident_id}"
      break
    fi
    sleep 5
  done
fi

if [[ -z "${incident_id:-}" ]]; then
  echo "No firing shopchk rule incident found. Check correlation rules and VMAlertmanager → Keep webhook."
  exit 1
fi

echo "==> Waiting up to ${WAIT_SECS}s for enriched SMTP (workflow polls Graylog/Aurora, then sends)..."
for i in $(seq 1 $((WAIT_SECS / 5))); do
  msgs_after="$(before_count)"
  new_msgs=$((msgs_after - msgs_before))
  if [[ "${new_msgs}" -ge 1 ]]; then
    echo "New Mailpit messages: ${new_msgs} (after $((i * 5))s)"
    curl -fsS "${MAILPIT_API_URL}/messages" | python3 -c "
import json, sys, urllib.request
data = json.load(sys.stdin)
msgs = sorted(data.get('messages', []), key=lambda m: m.get('Created', ''), reverse=True)
mid = msgs[0]['ID']
detail = json.load(urllib.request.urlopen('http://127.0.0.1:18025/api/v1/message/' + mid))
html = detail.get('HTML', '') or detail.get('Text', '')
print('Subject:', detail.get('Subject'))
for label in ['Log summary', 'Ops context', 'Correlated alerts', 'payments-oncall', 'runbook', 'Root cause']:
    print(f'  contains {label!r}:', label.lower() in html.lower())
print('HTML length:', len(html))
"
    echo "Open Mailpit UI: kubectl -n keep port-forward svc/mailpit 18025:8025  →  http://127.0.0.1:18025/"
    echo "SMTP incident notification PoC: OK (one enriched email per incident)"
    exit 0
  fi
  sleep 5
done

echo "No new email captured within ${WAIT_SECS}s. Check keep-backend logs:"
kubectl -n keep logs deploy/keep-backend --tail=60 | grep -iE 'smtp|shop-checkout-smtp|send-enriched|wait-enrich' || true
exit 1
