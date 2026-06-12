#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEEP_API_URL="${KEEP_API_URL:-http://keep.local:30080/v2}"
KEEP_API_KEY="${KEEP_API_KEY:-any-local-key}"
GRAYLOG_URL="${GRAYLOG_URL:-http://127.0.0.1:19000}"
VMSINGLE_URL="${VMSINGLE_URL:-http://127.0.0.1:18428}"
VMALERTMANAGER_URL="${VMALERTMANAGER_URL:-http://127.0.0.1:19093}"
GRAYLOG_USER="${GRAYLOG_USER:-admin}"
GRAYLOG_PASSWORD="${GRAYLOG_PASSWORD:-admin}"

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; exit 1; }

echo "1) Checking shop pods..."
kubectl wait --for=condition=ready pod -l application=shop-checkout -n shop --timeout=180s
pass "shop-checkout pods are ready"

echo "2) Checking metrics in VMSingle..."
python3 - <<'PY'
import json
import urllib.parse
import urllib.request

query = 'up{namespace="shop"}'
import os
url = os.environ.get("VMSINGLE_URL", "http://127.0.0.1:18428").rstrip("/") + "/api/v1/query?query=" + urllib.parse.quote(query)
body = json.loads(urllib.request.urlopen(url, timeout=20).read().decode())
results = body.get("data", {}).get("result", [])
services = {item["metric"].get("service") for item in results if item.get("value", ["", "0"])[1] == "1"}
expected = {"storefront", "checkout-demo", "payments-api"}
missing = expected - services
if missing:
    raise SystemExit(f"missing healthy targets: {sorted(missing)}")
print("[PASS] VMSingle reports healthy shop targets")
PY

if kubectl get svc graylog-service -n logging >/dev/null 2>&1; then
  echo "3) Checking Graylog logs for shop-checkout..."
  python3 - <<'PY' "${GRAYLOG_URL}" "${GRAYLOG_USER}" "${GRAYLOG_PASSWORD}"
import json
import sys
import urllib.request

base, user, password = sys.argv[1:4]
payload = {
    "queries": [{
        "id": "shop-checkout",
        "query": {"type": "elasticsearch", "query_string": "application:shop-checkout"},
        "timerange": {"type": "relative", "range": 900},
        "search_types": [{"id": "messages", "type": "messages", "limit": 5, "offset": 0}],
    }]
}
req = urllib.request.Request(
    f"{base.rstrip('/')}/api/views/search/sync",
    data=json.dumps(payload).encode(),
    method="POST",
    headers={"Content-Type": "application/json", "X-Requested-By": "keep-shop-poc"},
)
password_mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
password_mgr.add_password(None, base, user, password)
opener = urllib.request.build_opener(urllib.request.HTTPBasicAuthHandler(password_mgr))
with opener.open(req, timeout=30) as resp:
    data = json.loads(resp.read().decode())
messages = []
for result in data.get("results", {}).values():
    for search_type in result.get("search_types", {}).values():
        messages.extend(search_type.get("messages", []))
if not messages:
    raise SystemExit("no shop-checkout logs found in Graylog")
print(f"[PASS] Graylog returned {len(messages)} shop-checkout log messages")
PY
else
  echo "[SKIP] Graylog not deployed"
fi

echo "4) Checking Keep topology..."
python3 - <<'PY' "${KEEP_API_URL}" "${KEEP_API_KEY}"
import json
import sys
import urllib.request

api_url, api_key = sys.argv[1:3]
req = urllib.request.Request(
    f"{api_url.rstrip('/')}/topology",
    headers={"Authorization": "Basic " + __import__("base64").b64encode(f"api_key:{api_key}".encode()).decode()},
)
data = json.loads(urllib.request.urlopen(req, timeout=20).read().decode())
services = {item.get("service"): item for item in data}
expected = {"storefront", "checkout-demo", "payments-api", "external-psp"}
missing = sorted(expected - set(services))
if missing:
    raise SystemExit(f"topology missing services: {missing}")
# Keep 0.52.x topology processor only matches alerts for services with dependencies[].
if not services.get("payments-api", {}).get("dependencies"):
    raise SystemExit("payments-api has no dependencies; topology processor will ignore it")
print("[PASS] Keep topology contains shop-checkout services (processor-ready)")
PY

echo "5) Triggering checkout-demo outage..."
"${ROOT_DIR}/shop-control.sh" trigger-outage checkout-demo

echo "Waiting for alerts to propagate..."
sleep 90

echo "6) Checking VMAlertmanager firing alerts..."
python3 - <<'PY'
import json
import os
import urllib.request

am_url = os.environ.get("VMALERTMANAGER_URL", "http://127.0.0.1:19093").rstrip("/") + "/api/v2/alerts"
body = json.loads(urllib.request.urlopen(am_url, timeout=20).read().decode())
shop_alerts = [
    a for a in body
    if a.get("labels", {}).get("namespace") == "shop"
    and a.get("status", {}).get("state") == "active"
]
if len(shop_alerts) < 2:
    raise SystemExit(f"expected >=2 firing shop alerts, got {len(shop_alerts)}")
services = sorted({a["labels"].get("service") for a in shop_alerts})
print(f"[PASS] VMAlertmanager has {len(shop_alerts)} firing shop alerts across {services}")
PY

echo "7) Checking Keep incidents..."
python3 - <<'PY' "${KEEP_API_URL}" "${KEEP_API_KEY}"
import json
import sys
import urllib.request

api_url, api_key = sys.argv[1:3]
req = urllib.request.Request(
    f"{api_url.rstrip('/')}/incidents?limit=20&offset=0",
    headers={"Authorization": "Basic " + __import__("base64").b64encode(f"api_key:{api_key}".encode()).decode()},
)
data = json.loads(urllib.request.urlopen(req, timeout=20).read().decode())
items = data.get("items", [])
matches = [
    item for item in items
    if "shop-checkout" in (item.get("user_generated_name") or "")
    or "checkout-demo" in (item.get("user_generated_name") or "")
]
if not matches:
    raise SystemExit("no correlated shop-checkout incident found")
print(f"[PASS] Keep incident found: {matches[0].get('user_generated_name')}")
PY

if curl -fsS -u "api_key:${KEEP_API_KEY}" "${KEEP_API_URL}/workflows" | grep -q "Shop checkout Graylog enrichment"; then
  echo "8) Graylog enrichment workflow is installed"
  pass "Keep workflow present"
else
  echo "[SKIP] Graylog enrichment workflow not installed"
fi

echo "Recovering checkout-demo..."
"${ROOT_DIR}/shop-control.sh" recover checkout-demo

echo "Validation complete."
