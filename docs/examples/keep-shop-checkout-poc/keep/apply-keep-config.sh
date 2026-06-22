#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP_API_URL="${KEEP_API_URL:-http://keep.local:30080/v2}"
KEEP_API_KEY="${KEEP_API_KEY:-any-local-key}"
# Graylog token API: reachable from where you run this script (Kind default: port-forward on 19000).
GRAYLOG_API_URL="${GRAYLOG_API_URL:-http://127.0.0.1:19000}"
# Keep backend queries Graylog in-cluster.
GRAYLOG_DEPLOYMENT_URL="${GRAYLOG_DEPLOYMENT_URL:-http://graylog-service.logging.svc:9000}"
GRAYLOG_USER="${GRAYLOG_USER:-admin}"
GRAYLOG_PASSWORD="${GRAYLOG_PASSWORD:-admin}"

create_graylog_token() {
  python3 - <<'PY' "${GRAYLOG_API_URL}" "${GRAYLOG_USER}" "${GRAYLOG_PASSWORD}"
import json
import sys
import urllib.request

base, user, password = sys.argv[1:4]
password_mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
password_mgr.add_password(None, base, user, password)
opener = urllib.request.build_opener(urllib.request.HTTPBasicAuthHandler(password_mgr))
try:
    with opener.open(f"{base.rstrip('/')}/api/users?query={user}", timeout=20) as resp:
        users = json.loads(resp.read().decode()).get("users", [])
    user_id = users[0]["id"] if users else f"local:{user}"
    req = urllib.request.Request(
        f"{base.rstrip('/')}/api/users/{user_id}/tokens/keep-shop-poc",
        method="POST",
        data=b"{}",
        headers={"Content-Type": "application/json", "X-Requested-By": "keep-shop-poc"},
    )
    with opener.open(req, timeout=20) as resp:
        payload = json.loads(resp.read().decode())
        print(payload.get("token") or password)
except Exception:
    print(password)
PY
}

import_topology() {
  local needs_import
  needs_import="$(curl -fsS -u "api_key:${KEEP_API_KEY}" "${KEEP_API_URL}/topology" | python3 -c '
import json, sys
data = json.load(sys.stdin)
services = {item.get("service"): item for item in data}
required = {"storefront", "checkout-demo", "payments-api", "external-psp"}
missing = sorted(required - set(services))
if missing:
    print("missing-services:" + ",".join(missing))
    raise SystemExit(0)
# Keep 0.52.x topology processor ignores services with no outgoing dependencies.
if not services.get("payments-api", {}).get("dependencies"):
    print("payments-api-missing-dependencies")
    raise SystemExit(0)
print("ok")
' 2>/dev/null || echo "import-error")"
  if [[ "${needs_import}" == "ok" ]]; then
    echo "topology already imported and processor-ready"
    return 0
  fi
  echo "importing topology (${needs_import})..."
  curl -fsS -u "api_key:${KEEP_API_KEY}" -X POST "${KEEP_API_URL}/topology/import" \
    -F "file=@${ROOT_DIR}/keep/topology.yaml;type=application/x-yaml"
}

install_rules() {
  python3 - <<'PY' "${ROOT_DIR}/keep/correlation-rules.json" "${KEEP_API_URL}" "${KEEP_API_KEY}"
import json
import sys
import urllib.error
import urllib.request

rules_path, api_url, api_key = sys.argv[1:4]
auth = "Basic " + __import__("base64").b64encode(f"api_key:{api_key}".encode()).decode()
headers = {"Authorization": auth, "Content-Type": "application/json"}
base = api_url.rstrip("/")

SYNC_FIELDS = (
    "celQuery",
    "timeframeInSeconds",
    "timeUnit",
    "threshold",
    "groupingCriteria",
    "incidentNameTemplate",
    "incidentPrefix",
    "groupDescription",
    "requireApprove",
    "resolveOn",
)


def request(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(f"{base}{path}", data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = resp.read().decode()
        return json.loads(body) if body else {}


def desired_view(rule):
    view = {field: rule.get(field) for field in SYNC_FIELDS}
    if view.get("groupingCriteria") is None:
        view["groupingCriteria"] = []
    return view


existing = request("GET", "/rules")
by_name = {}
for rule in existing:
    by_name.setdefault(rule.get("name"), []).append(rule)

for rule in json.load(open(rules_path)):
    name = rule["ruleName"]
    matches = by_name.get(name, [])
    if len(matches) > 1:
        matches.sort(key=lambda r: r.get("creation_time") or "")
        for duplicate in matches[1:]:
            request("DELETE", f"/rules/{duplicate['id']}")
            print(f"rule deleted duplicate: {name} ({duplicate['id']})")
        matches = matches[:1]

    payload = dict(rule)
    if matches:
        current = matches[0]
        if desired_view(rule) == desired_view(current):
            print(f"rule up to date: {name}")
            continue
        request("DELETE", f"/rules/{current['id']}")
        print(f"rule deleted for recreate: {name} ({current['id']})")

    try:
        request("POST", "/rules", payload)
        print(f"rule created: {name}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        if exc.code == 409 or "already exists" in body.lower():
            print(f"rule exists: {name}")
        else:
            raise RuntimeError(f"failed to create rule {name}: {body}") from exc
PY
}

install_python_provider() {
  python3 - <<'PY' "${KEEP_API_URL}" "${KEEP_API_KEY}"
import json
import sys
import urllib.error
import urllib.request

api_url, api_key = sys.argv[1:3]
payload = {
    "provider_id": "default-python",
    "provider_name": "default-python",
    "provider_type": "python",
}
req = urllib.request.Request(
    f"{api_url.rstrip('/')}/providers/install",
    data=json.dumps(payload).encode(),
    method="POST",
    headers={
        "Authorization": "Basic " + __import__("base64").b64encode(f"api_key:{api_key}".encode()).decode(),
        "Content-Type": "application/json",
    },
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        print(f"python provider installed ({resp.status})")
except urllib.error.HTTPError as exc:
    body = exc.read().decode()
    if "already" in body.lower():
        print("python provider already installed")
    else:
        raise RuntimeError(f"failed to install python provider: {body}") from exc
PY
}

install_graylog_provider() {
  local token
  token="$(create_graylog_token)"
  python3 - <<'PY' "${KEEP_API_URL}" "${KEEP_API_KEY}" "${GRAYLOG_DEPLOYMENT_URL}" "${GRAYLOG_USER}" "${token}"
import json
import sys
import urllib.request

api_url, api_key, graylog_url, graylog_user, graylog_token = sys.argv[1:6]
payload = {
    "provider_id": "graylog-shop",
    "provider_name": "graylog-shop",
    "provider_type": "graylog",
    "graylog_user_name": graylog_user,
    "graylog_access_token": graylog_token,
    "deployment_url": graylog_url,
    "verify": False,
}
req = urllib.request.Request(
    f"{api_url.rstrip('/')}/providers/install",
    data=json.dumps(payload).encode(),
    method="POST",
    headers={
        "Authorization": "Basic " + __import__("base64").b64encode(f"api_key:{api_key}".encode()).decode(),
        "Content-Type": "application/json",
    },
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        print(f"graylog provider installed ({resp.status})")
except urllib.error.HTTPError as exc:
    body = exc.read().decode()
    if "already" in body.lower():
        print("graylog provider already installed")
    else:
        raise RuntimeError(f"failed to install graylog provider: {body}") from exc
PY
}

install_workflow() {
  local workflow_file="$1"
  curl -fsS -u "api_key:${KEEP_API_KEY}" -X POST \
    "${KEEP_API_URL}/workflows?lookup_by_name=true" \
    -F "file=@${workflow_file};type=application/x-yaml"
}

install_mapping() {
  python3 - <<'PY' "${ROOT_DIR}/keep/shop-checkout-mapping.csv" "${KEEP_API_URL}" "${KEEP_API_KEY}"
import csv
import json
import sys
import urllib.error
import urllib.request

csv_path, api_url, api_key = sys.argv[1:4]
auth = "Basic " + __import__("base64").b64encode(f"api_key:{api_key}".encode()).decode()
headers = {"Authorization": auth, "Content-Type": "application/json"}
base = api_url.rstrip("/")

MAPPING_NAME = "shop-checkout-ops"
MAPPING_DESCRIPTION = "PoC ops metadata (runbook, owner, tier, environment, repository) for shop-checkout services"
MAPPING_MATCHERS = [["labels.service"]]
MAPPING_PRIORITY = 10


def request(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(f"{base}{path}", data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = resp.read().decode()
        return json.loads(body) if body else {}


def comparable(mapping):
    return {
        "description": mapping.get("description"),
        "file_name": mapping.get("file_name"),
        "matchers": sorted(tuple(m) for m in (mapping.get("matchers") or [])),
        "priority": mapping.get("priority"),
        "rows": sorted(
            mapping.get("rows") or [],
            key=lambda row: tuple(sorted(row.items())),
        ),
    }


with open(csv_path, newline="", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle))

desired = {
    "name": MAPPING_NAME,
    "description": MAPPING_DESCRIPTION,
    "file_name": "shop-checkout-mapping.csv",
    "matchers": MAPPING_MATCHERS,
    "rows": rows,
    "priority": MAPPING_PRIORITY,
}

existing = request("GET", "/mapping")
matches = [m for m in existing if m.get("name") == MAPPING_NAME]

if len(matches) > 1:
    matches.sort(key=lambda m: m.get("created_at") or "")
    for duplicate in matches[1:]:
        request("DELETE", f"/mapping/{duplicate['id']}")
        print(f"mapping deleted duplicate: {MAPPING_NAME} ({duplicate['id']})")
    matches = matches[:1]

if matches:
    current = request("GET", f"/mapping/{matches[0]['id']}")
    if comparable(current) == comparable(desired):
        print(f"mapping up to date: {MAPPING_NAME}")
    else:
        request("DELETE", f"/mapping/{current['id']}")
        print(f"mapping deleted for recreate: {MAPPING_NAME} ({current['id']})")
        request("POST", "/mapping", desired)
        print(f"mapping created: {MAPPING_NAME}")
else:
    try:
        request("POST", "/mapping", desired)
        print(f"mapping created: {MAPPING_NAME}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        if exc.code == 409 or "already exists" in body.lower():
            print(f"mapping exists: {MAPPING_NAME}")
        else:
            raise RuntimeError(f"failed to create mapping {MAPPING_NAME}: {body}") from exc
PY
}

install_smtp_provider() {
  python3 - <<'PY' "${KEEP_API_URL}" "${KEEP_API_KEY}"
import json
import sys
import urllib.error
import urllib.request

api_url, api_key = sys.argv[1:3]
payload = {
    "provider_id": "smtp-poc",
    "provider_name": "smtp-poc",
    "provider_type": "smtp",
    "smtp_server": "mailpit.keep.svc",
    "smtp_port": 1025,
    "encryption": "None",
    "smtp_username": "",
    "smtp_password": "",
}
req = urllib.request.Request(
    f"{api_url.rstrip('/')}/providers/install",
    data=json.dumps(payload).encode(),
    method="POST",
    headers={
        "Authorization": "Basic " + __import__("base64").b64encode(f"api_key:{api_key}".encode()).decode(),
        "Content-Type": "application/json",
    },
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        print(f"smtp provider installed ({resp.status})")
except urllib.error.HTTPError as exc:
    body = exc.read().decode()
    if "already" in body.lower():
        print("smtp provider already installed")
    else:
        raise RuntimeError(f"failed to install smtp provider: {body}") from exc
PY
}

echo "Importing Keep topology..."
import_topology

echo "Installing correlation rules..."
install_rules

echo "Installing alert mapping..."
install_mapping

echo "Installing Python provider (log formatting in Graylog workflows)..."
install_python_provider || echo "Python provider install skipped."

if kubectl get svc graylog-service -n logging >/dev/null 2>&1; then
  echo "Installing Graylog provider..."
  install_graylog_provider || echo "Graylog provider install skipped (already installed or auth failed)."
  echo "Installing Graylog alert enrichment workflow..."
  install_workflow "${ROOT_DIR}/keep/graylog-enrichment-workflow.yaml" || echo "Graylog alert workflow install skipped."
  python3 - <<'PY' "${KEEP_API_URL}" "${KEEP_API_KEY}"
import json, sys, urllib.request
api_url, api_key = sys.argv[1:3]
auth = "Basic " + __import__("base64").b64encode(f"api_key:{api_key}".encode()).decode()
headers = {"Authorization": auth}
req = urllib.request.Request(f"{api_url.rstrip('/')}/workflows", headers=headers)
retire_ids = {
    "shop-checkout-graylog-incident-enrichment",
}
retire_names = {
    "Shop checkout Graylog incident enrichment (rule)",
    "Shop checkout Graylog incident enrichment",
}
for w in json.load(urllib.request.urlopen(req, timeout=20)):
    if w.get("id") in retire_ids or w.get("name") in retire_names:
        del_req = urllib.request.Request(
            f"{api_url.rstrip('/')}/workflows/{w['id']}", headers=headers, method="DELETE"
        )
        try:
            urllib.request.urlopen(del_req, timeout=20)
            print(f"retired workflow: {w['id']} (incident logs now in integrated SMTP workflow)")
        except Exception as exc:
            print(f"workflow {w['id']} not removed: {exc}")
PY
else
  echo "Graylog service not found in logging namespace; skipping provider/workflow install."
  echo "Re-run this script after deploying the logging stack."
fi

if kubectl get svc mailpit -n keep >/dev/null 2>&1; then
  echo "Installing SMTP provider (Mailpit)..."
  install_smtp_provider || echo "SMTP provider install skipped."
  python3 - <<'PY' "${KEEP_API_URL}" "${KEEP_API_KEY}"
import json, sys, urllib.request
api_url, api_key = sys.argv[1:3]
auth = "Basic " + __import__("base64").b64encode(f"api_key:{api_key}".encode()).decode()
headers = {"Authorization": auth}
req = urllib.request.Request(f"{api_url.rstrip('/')}/workflows", headers=headers)
for w in json.load(urllib.request.urlopen(req, timeout=20)):
    if w.get("id") == "shop-checkout-smtp-topology-notification" or w.get("name") == "Shop checkout SMTP notification (topology)":
        del_req = urllib.request.Request(f"{api_url.rstrip('/')}/workflows/{w['id']}", headers=headers, method="DELETE")
        try:
            urllib.request.urlopen(del_req, timeout=20)
            print(f"retired workflow: {w['id']}")
        except Exception as exc:
            print(f"workflow {w['id']} not removed: {exc}")
        break
PY
  echo "Installing integrated SMTP workflow (Graylog + Aurora + email)..."
  install_workflow "${ROOT_DIR}/keep/smtp-notification-workflow.yaml" || echo "SMTP rule workflow install skipped."
else
  echo "Mailpit service not found in keep namespace; skipping SMTP notification PoC."
  echo "Deploy with: kubectl apply -f k8s/mailpit.yaml"
fi

if kubectl get svc aurora-rca -n aurora >/dev/null 2>&1; then
  echo "Aurora stub detected — RCA runs inside integrated SMTP workflow (no separate workflow)."
  # Retire topology / legacy Aurora and separate rule Aurora workflows.
  python3 - <<'PY' "${KEEP_API_URL}" "${KEEP_API_KEY}"
import json, sys, urllib.request
api_url, api_key = sys.argv[1:3]
auth = "Basic " + __import__("base64").b64encode(f"api_key:{api_key}".encode()).decode()
headers = {"Authorization": auth}
req = urllib.request.Request(f"{api_url.rstrip('/')}/workflows", headers=headers)
workflows = json.load(urllib.request.urlopen(req, timeout=20))
legacy_ids = {
    "shop-checkout-aurora-rca-trigger",
    "shop-checkout-aurora-rca-topology-trigger",
    "shop-checkout-aurora-rca-topology-sync",
        "shop-checkout-aurora-rca-poll",
        "shop-checkout-aurora-rca-rule-poll",
    "shop-checkout-aurora-rca-rule-trigger",
    "shop-checkout-smtp-topology-notification",
}
legacy_names = {
    "Shop checkout Aurora RCA trigger",
    "Shop checkout Aurora RCA trigger (topology)",
    "Shop checkout Aurora RCA topology sync",
    "Shop checkout Aurora RCA sync",
        "Shop checkout Aurora RCA poll",
        "Shop checkout Aurora RCA trigger (rule)",
    "Shop checkout Aurora RCA (rule)",
    "Shop checkout SMTP notification (topology)",
}
to_delete = {
    w["id"]
    for w in workflows
    if w.get("id") in legacy_ids or w.get("name") in legacy_names
}
for wid in to_delete:
    del_req = urllib.request.Request(
        f"{api_url.rstrip('/')}/workflows/{wid}",
        headers=headers,
        method="DELETE",
    )
    try:
        urllib.request.urlopen(del_req, timeout=20)
        print(f"retired workflow: {wid}")
    except Exception as exc:
        print(f"workflow {wid} not removed: {exc}")
if not to_delete:
    print("no legacy Aurora workflows to retire (ok)")
PY
else
  echo "Aurora RCA stub not found — integrated SMTP workflow skips Aurora (Graylog + email only)."
  echo "Deploy stub with: kubectl apply -f k8s/aurora-rca-stub.yaml"
  python3 - <<'PY' "${KEEP_API_URL}" "${KEEP_API_KEY}"
import json, sys, urllib.request
api_url, api_key = sys.argv[1:3]
auth = "Basic " + __import__("base64").b64encode(f"api_key:{api_key}".encode()).decode()
headers = {"Authorization": auth}
req = urllib.request.Request(f"{api_url.rstrip('/')}/workflows", headers=headers)
for w in json.load(urllib.request.urlopen(req, timeout=20)):
    if w.get("id") == "shop-checkout-aurora-rca-rule-trigger" or w.get("name") == "Shop checkout Aurora RCA (rule)":
        del_req = urllib.request.Request(f"{api_url.rstrip('/')}/workflows/{w['id']}", headers=headers, method="DELETE")
        try:
            urllib.request.urlopen(del_req, timeout=20)
            print(f"retired workflow: {w['id']}")
        except Exception as exc:
            print(f"workflow {w['id']} not removed: {exc}")
PY
fi

echo "Keep configuration applied."
