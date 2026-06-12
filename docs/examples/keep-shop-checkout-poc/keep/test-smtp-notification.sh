#!/usr/bin/env bash
# Verify item 7: one SMTP email per incident (not per alert).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP_API_URL="${KEEP_API_URL:-http://keep.local:30080/v2}"
KEEP_API_KEY="${KEEP_API_KEY:-any-local-key}"
MAILPIT_API_URL="${MAILPIT_API_URL:-http://127.0.0.1:18025/api/v1}"

before_count() {
  curl -fsS "${MAILPIT_API_URL}/messages" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('total',0))" || echo 0
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

workflow_id="$(curl -fsS -u "api_key:${KEEP_API_KEY}" "${KEEP_API_URL}/workflows" | python3 -c "
import json,sys
for w in json.load(sys.stdin):
    if w.get('id') == 'shop-checkout-smtp-notification' or w.get('name') == 'Shop checkout SMTP notification':
        print(w['id'])
        break
")"

incident_id="$(curl -fsS -u "api_key:${KEEP_API_KEY}" "${KEEP_API_URL}/incidents?limit=20" | python3 -c "
import json,sys
items=json.load(sys.stdin)
if not isinstance(items,list): items=items.get('items',[])
for i in items:
    if not isinstance(i,dict): continue
    if i.get('incident_type')=='rule' and i.get('status')=='firing' and 'shopchk' in str(i.get('user_generated_name','')):
        print(i['id']); break
")"

echo "==> Run workflow against firing rule incident (${workflow_id}, incident=${incident_id:-none})..."
if [[ -n "${incident_id:-}" ]]; then
  curl -fsS -u "api_key:${KEEP_API_KEY}" -X POST \
    "${KEEP_API_URL}/workflows/${workflow_id}/run?incident_id=${incident_id}" \
    -H 'Content-Type: application/json' \
    -d '{}'
else
  echo "No firing shopchk rule incident found; trigger an outage first or pass incident_id."
  exit 1
fi

echo
echo "==> Waiting for workflow + SMTP delivery..."
sleep 8

msgs_after="$(before_count)"
new_msgs=$((msgs_after - msgs_before))
echo "New Mailpit messages: ${new_msgs} (total ${msgs_after})"

if [[ "${new_msgs}" -lt 1 ]]; then
  echo "No new email captured. Check keep-backend logs:"
  kubectl -n keep logs deploy/keep-backend --tail=40 | grep -iE 'smtp|workflow|shop-checkout-smtp' || true
  exit 1
fi

if [[ "${new_msgs}" -gt 1 ]]; then
  echo "WARN: expected 1 new message, got ${new_msgs}"
fi

curl -fsS "${MAILPIT_API_URL}/messages" | python3 -c "
import json,sys
data=json.load(sys.stdin)
msg=data['messages'][0]
print('Subject:', msg.get('Subject'))
print('To:', msg.get('To'))
print('Snippet:', msg.get('Snippet','')[:240])
"

echo "Open Mailpit UI: kubectl -n keep port-forward svc/mailpit 18025:8025  →  http://127.0.0.1:18025/"
echo "SMTP incident notification PoC: OK (one email per incident)"
