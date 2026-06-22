#!/usr/bin/env bash
# Verify Aurora RCA enrichments on latest shopchk-* rule incident (topology has no Aurora workflows).
set -euo pipefail

KEEP_API_URL="${KEEP_API_URL:-http://keep.local:30080/v2}"
KEEP_API_KEY="${KEEP_API_KEY:-any-local-key}"
WAIT_SECS="${WAIT_SECS:-180}"

echo "Waiting ${WAIT_SECS}s for integrated SMTP workflow (Graylog + optional Aurora; needs ≥1 linked alert)..."
sleep "${WAIT_SECS}"

incident="$(curl -fsSu "api_key:${KEEP_API_KEY}" \
  "${KEEP_API_URL}/incidents?limit=30" | python3 -c "
import json, sys
items = json.load(sys.stdin)
if isinstance(items, dict):
    items = items.get('items', [])
matches = [i for i in items if (i.get('user_generated_name') or '').startswith('shopchk-') and i.get('status') == 'firing']
if not matches:
    matches = [i for i in items if (i.get('user_generated_name') or '').startswith('shopchk-')]
if not matches:
    matches = [i for i in items if i.get('incident_type') == 'rule']
if not matches:
    raise SystemExit('no rule incident found')
print(json.dumps(matches[0]))
")"

id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"${incident}")"
name="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("user_generated_name",""))' <<<"${incident}")"
echo "Rule incident: ${name} (${id})"

detail="$(curl -fsSu "api_key:${KEEP_API_KEY}" "${KEEP_API_URL}/incidents/${id}")"
python3 -c '
import json, sys
d = json.load(sys.stdin)
fields = {
    "name": d.get("user_generated_name"),
    "incident_type": d.get("incident_type"),
    "aurora_incident_id": d.get("aurora_incident_id"),
    "aurora_rca_status": d.get("aurora_rca_status"),
    "aurora_url": d.get("aurora_url"),
    "rca_summary": (d.get("rca_summary") or "")[:120],
    "root_cause": d.get("root_cause"),
}
print(json.dumps(fields, indent=2))
missing = [k for k, v in fields.items() if k not in ("name", "rca_summary", "incident_type") and not v]
if fields.get("aurora_rca_status") != "complete":
    print("WARN: aurora_rca_status is not complete yet — wait and re-run", file=sys.stderr)
    if missing:
        raise SystemExit(f"missing fields: {missing}")
    raise SystemExit(2)
if not fields.get("rca_summary"):
    raise SystemExit("rca_summary empty after complete status")
print("OK: Aurora RCA enrichments present on Keep incident")
' <<<"${detail}"
