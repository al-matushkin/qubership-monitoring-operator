#!/usr/bin/env bash
set -euo pipefail

KEEP_API_URL="${KEEP_API_URL:-http://keep.local:30080/v2}"
KEEP_API_KEY="${KEEP_API_KEY:-any-local-key}"
COMMENT="${COMMENT:-Resolved during shop-checkout PoC cleanup.}"

python3 - <<'PY' "${KEEP_API_URL}" "${KEEP_API_KEY}" "${COMMENT}"
import json
import sys
import urllib.request

api_url, api_key, comment = sys.argv[1:4]
auth = "Basic " + __import__("base64").b64encode(f"api_key:{api_key}".encode()).decode()
headers = {"Authorization": auth, "Content-Type": "application/json"}
base = api_url.rstrip("/")

incidents = json.loads(
    urllib.request.urlopen(urllib.request.Request(f"{base}/incidents?limit=100", headers=headers), timeout=30).read().decode()
)
resolved = 0
for incident in incidents.get("items", []):
    if incident.get("status") != "firing":
        continue
    body = json.dumps({"status": "resolved", "comment": comment}).encode()
    req = urllib.request.Request(
        f"{base}/incidents/{incident['id']}/status",
        data=body,
        method="POST",
        headers=headers,
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        out = json.loads(resp.read().decode())
        print(f"resolved: {incident.get('user_generated_name', incident['id'])} -> {out.get('status')}")
        resolved += 1

if resolved == 0:
    print("no firing incidents to resolve")
else:
    print(f"done: resolved {resolved} incident(s)")
PY
