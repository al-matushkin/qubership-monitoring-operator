# Keep shop-checkout PoC

Reproducible local PoC for [issue #330](https://github.com/Netcracker/qubership-monitoring-operator/issues/330): multi-service failures, manual Keep topology, alert correlation, Graylog log enrichment, and SMTP incident notifications.

## Architecture

```text
storefront -> checkout-demo -> payments-api
     |            |                |
     +------------+----------------+--> stdout JSON logs -> FluentBit -> Graylog
     +------------+----------------+--> /metrics -> vmagent -> VMSingle -> vmalert -> VMAlertmanager -> Keep
```

Keep integration:

| Signal | Path |
|--------|------|
| Alerts | VMAlertmanager `keep-shadow` webhook |
| Topology | Manual YAML import (`keep/topology.yaml`) + topology processor |
| Ops metadata | CSV mapping on `labels.service` (`keep/shop-checkout-mapping.csv`) |
| Log context | Graylog provider + alert workflow (`log_snippet`) + incident workflow (`log_summary`) |
| Rule incidents | App-level correlation rule (`keep/correlation-rules.json`) → `shopchk-*` |
| Topology incidents | Topology processor groups alerts by application → `Application incident: shop-checkout` |
| Notifications | Mailpit SMTP (optional) — rule + topology workflows |

Grafana and Jaeger are intentionally excluded.

### VMAlertmanager → Keep (alert webhook)

Alerts reach Keep through a standard **Alertmanager webhook** — not a custom vmalert push and not the Keep VictoriaMetrics *provider* (that provider is for querying metrics inside workflows).

```text
vmalert  →  VMAlertmanager  →  receiver keep-shadow (webhook_configs)  →  Keep backend
```

| Piece | Value (PoC) |
|-------|-------------|
| Keep ingest URL | `http://keep-backend.keep.svc:8080/alerts/event/victoriametrics` |
| Alternate URL | `/alerts/event/prometheus` — same Alertmanager JSON payload; also used on some Kind setups |
| Auth | HTTP Basic: username `api_key`, password = Keep API key (`any-local-key` in the local PoC) |
| Receiver name | `keep-shadow` (convention only; any name works) |
| Resolved alerts | Set `send_resolved: true` so Keep auto-resolves when VMAlertmanager clears an alert |

Keep documents this pattern in the [VictoriaMetrics provider — webhook section](https://docs.keephq.dev/providers/documentation/victoriametrics-provider#connecting-via-webhook-omnidirectional). `vmalert` talks to VMAlertmanager (`/api/v2/alerts`); VMAlertmanager forwards to Keep in **outbound webhook** form. Do not point vmalert directly at Keep.

**Kind / PoC (replace default route):** after monitoring-operator and Keep backend are up:

```bash
kubectl apply -f k8s/vmalertmanager-keep-shadow.yaml
```

That patches secret `vmalertmanager-config-secret` in namespace `monitoring` (see [`k8s/vmalertmanager-keep-shadow.yaml`](k8s/vmalertmanager-keep-shadow.yaml)). Change `password` if your Keep API key is not `any-local-key`.

**Production (additive route):** keep existing ops receivers and merge a shadow route with `continue: true` — example in [`k8s/vmalertmanager-keep-shadow-additive.yaml`](k8s/vmalertmanager-keep-shadow-additive.yaml). Prefer **light inhibition** on the Keep path so correlation still sees symptom alerts ([checklist item 3](../../keep/follow-up-checklist.md)).

**Verify wiring:**

```bash
# VMAlertmanager has the receiver
kubectl -n monitoring get secret vmalertmanager-config-secret -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | grep -A5 keep-shadow

# After an outage, alerts appear in Keep (needs shop rules + port-forward on ingress :30080)
curl -su 'api_key:any-local-key' 'http://keep.local:30080/v2/alerts?status=firing&limit=5' | jq 'length'
```

If Keep shows no alerts but VMAlertmanager does, check webhook delivery in VMAlertmanager logs (`kubectl -n monitoring logs statefulset/vmalertmanager-k8s`) and that the URL is reachable from the `monitoring` namespace.

### Incidents: rule vs topology

This PoC enables **both** correlation mechanisms:

| Type | Source | Name pattern | When it fires |
|------|--------|--------------|---------------|
| `rule` | `correlation-rules.json` | `shopchk-*` | On incident **created** when alerts match `application == shop-checkout` |
| `topology` | `KEEP_TOPOLOGY_PROCESSOR` + `topology.yaml` | `Application incident: shop-checkout` | When multiple services in the same application alert together |

Both can be active during an outage. To test only one path, disable the other in Keep UI or remove it from `apply-keep-config.sh`.

**Rule incident requirements** (`correlation-rules.json` ships a single app-level rule):

1. **Group by application, not service** — `groupingCriteria` is `["application", "namespace"]`. Adding `"service"` splits incidents per service.
2. **Alert labels** — every `PrometheusRule` sets `application: shop-checkout`, `namespace: shop`, and the correct `service` label.
3. **Upstream health checks** — storefront treats checkout `backend_up=0` as unreachable so cascade scenarios also raise storefront alerts.

Re-apply after edits:

```bash
KEEP_API_URL=http://keep.local:30080/v2 ./keep/apply-keep-config.sh
```

### Alert mapping (runbook / owner / tier)

`keep/shop-checkout-mapping.csv` joins on `labels.service` (VictoriaMetrics webhook ingest keeps `service` in labels) and adds `runbook_url`, `owner`, and `escalation_tier` to each shop alert in Keep.

**Where the fields land:** mapping adds **top-level** alert properties, not entries under **Labels** in the UI. Check the **alert sidebar** (after `ALERT_SIDEBAR_FIELDS` in `values-keep-kind.yaml`) or the API:

```bash
curl -u 'api_key:any-local-key' \
  'http://keep.local:30080/v2/alerts?status=firing&limit=5' | jq '.[] | {name, runbook_url, owner, escalation_tier, enriched_fields}'
```

`enriched_fields` lists applied enrichments (mapping: `runbook_url`, `owner`, `escalation_tier`; Graylog workflow: `log_snippet`, `graylog_query`).

**Workflows:** mapping fields are available in workflow expressions, e.g. `{{ alert.runbook_url }}`.

**UI sidebar:** `values-keep-kind-postgres.yaml` sets `ALERT_SIDEBAR_FIELDS` to include `runbook_url`, `owner`, `escalation_tier`, and `graylog_query` ([Keep docs](https://docs.keephq.dev/deployment/configuration)). Re-apply with `helm upgrade` after changing that overlay.

**Timing:** mapping runs on **new alert ingest** only. Deduplicated repeat webhooks may keep stale enrichments until a fresh firing cycle (recover → re-trigger outage).

### Extraction and alert visibility

**Extraction rules are not required** for this PoC. VMAlert/Alertmanager delivers structured labels and `description`; mapping and Graylog workflows add ops/log fields. Extend **`ALERT_SIDEBAR_FIELDS`** in `values-keep-kind-postgres.yaml` (e.g. `log_snippet`, `symptom`, `pod`) rather than adding regex extraction. See checklist item 5 in [`follow-up-checklist.md`](../../keep/follow-up-checklist.md).

**Incident log rollup:** `graylog-incident-enrichment-workflow.yaml` runs on incident `created`/`updated`, queries Graylog for all `shop-checkout` logs in `shop`, formats hits with the built-in **Python provider** (`default-python`), and sets incident enrichments `log_summary` + `graylog_query`. `log_summary` is a **single string** with `- ` prefixed lines (Keep 0.52.x treats array enrichments as clickable alert-filter badges, so do not store logs as an array). Per-alert `log_snippet` uses bullet separators (` • `) in `graylog-enrichment-workflow.yaml`.

### Keep persistence + ingress (Kind)

This PoC deploys Keep with **bundled PostgreSQL** (`values-keep-kind-postgres.yaml`) — chart-managed PVC, K8s-backed provider secrets, topology processor, and ingress on `keep.local`.

```bash
chmod +x deploy-keep-ingress-kind.sh port-forward-keep-ingress.sh
./deploy-keep-ingress-kind.sh
```

Add to `/etc/hosts`:

```
127.0.0.1 keep.local
```

Start ingress port-forward (required on Kind — NodePort is not bound to 127.0.0.1):

```bash
./port-forward-keep-ingress.sh
```

Default local port is **30080**. Open **http://keep.local:30080/** (API: **http://keep.local:30080/v2**).

Without port-forward, use the Kind node IP in hosts — e.g. `172.18.0.2 keep.local` → **http://keep.local:30080/**.

The Postgres overlay sets:

- Bundled Postgres (`keep-database:5432/keep`) with chart-managed PVC
- `DATABASE_CONNECTION_STRING=postgresql+psycopg2://postgres:…@keep-database:5432/keep`
- `SECRET_MANAGER_TYPE=k8s` — provider secrets in Kubernetes `Secret` objects
- `KEEP_TOPOLOGY_PROCESSOR=true`
- `global.ingress` on `keep.local`
- `ALERT_SIDEBAR_FIELDS` for mapping and Graylog columns

A **fresh Helm install or overlay switch** starts an empty database (Alembic schema on startup). Re-run `apply-keep-config.sh` after deploy; prior alerts/incidents are not migrated automatically.

**Restore Keep config** (after DB reset or provider breakage) — Graylog token creation needs port-forward on `19000` from the host:

```bash
kubectl -n logging port-forward svc/graylog-service 19000:9000 &
KEEP_API_URL=http://keep.local:30080/v2 ./keep/apply-keep-config.sh
```

**Port-forward fallback** (if ingress is not installed — backend API is at pod root, not `/v2`):

```bash
kubectl port-forward -n keep svc/keep-frontend 3000:3000 &
kubectl port-forward -n keep svc/keep-backend 18080:8080 &
KEEP_API_URL=http://127.0.0.1:18080 ./keep/apply-keep-config.sh
```

## Prerequisites

- Kind cluster with **monitoring-operator** (VMAlert, VMAlertmanager, vmagent) and **Keep** Helm release installed
- `kubectl` context pointed at the cluster (for example `kind-observability-local`)
- Local clones of `qubership-opensearch` and `qubership-logging-operator` next to this repo
- VMAlertmanager wired to Keep via `keep-shadow` webhook ([see above](#vmalertmanager--keep-alert-webhook)); PoC manifest: `k8s/vmalertmanager-keep-shadow.yaml`
- Keep API key matching the webhook password (`api_key:any-local-key` in the local PoC)

## Deploy order

### 1. Shop app + monitoring hooks

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/payments-api.yaml
kubectl apply -f k8s/checkout-demo.yaml
kubectl apply -f k8s/storefront.yaml
kubectl apply -f k8s/service-monitors.yaml
kubectl apply -f k8s/prometheus-rules.yaml
kubectl wait --for=condition=ready pod -l application=shop-checkout -n shop --timeout=180s
```

### 2. Keep persistence + ingress

```bash
./deploy-keep-ingress-kind.sh          # bundled PostgreSQL
./port-forward-keep-ingress.sh           # separate terminal, or background
```

### 2b. VMAlertmanager → Keep webhook

```bash
kubectl apply -f k8s/vmalertmanager-keep-shadow.yaml
```

Skip if already configured. See [VMAlertmanager → Keep](#vmalertmanager--keep-alert-webhook).

### 3. Keep topology, rules, mapping, workflows

```bash
chmod +x keep/apply-keep-config.sh
KEEP_API_URL=http://keep.local:30080/v2 ./keep/apply-keep-config.sh
```

### 4. Logging stack (OpenSearch + Graylog + FluentBit)

```bash
chmod +x deploy-logging.sh
./deploy-logging.sh
```

Re-run Keep config after Graylog is up (port-forward Graylog API on `19000` if running from the host):

```bash
kubectl -n logging port-forward svc/graylog-service 19000:9000 &
KEEP_API_URL=http://keep.local:30080/v2 ./keep/apply-keep-config.sh
```

### 5. Validate

Port-forwards for monitoring/logging (defaults match `validate.sh`):

```bash
kubectl port-forward -n monitoring svc/vmsingle-k8s 18428:8428 &
kubectl port-forward -n monitoring svc/vmalertmanager-k8s 19093:9093 &
kubectl port-forward -n logging svc/graylog-service 19000:9000 &
chmod +x validate.sh
KEEP_API_URL=http://keep.local:30080/v2 ./validate.sh
```

## Failure playbook

Control demo services with [`shop-control.sh`](shop-control.sh) (`wget` inside each pod):

| Action | Command | Expected result |
|--------|---------|-----------------|
| Storefront outage | `./shop-control.sh trigger-outage storefront` | Storefront alerts; rule and/or topology incident |
| Checkout outage | `./shop-control.sh trigger-outage checkout-demo` | Checkout + storefront alerts; correlated incident(s) |
| Payments outage | `./shop-control.sh trigger-outage payments-api` | Payments + checkout (+ storefront) alerts |
| Storefront slow mode | `./shop-control.sh slow-mode storefront` | Latency alert on storefront |
| Recover one service | `./shop-control.sh recover <service>` | That service’s alerts resolve in VMAlertmanager |
| Recover all | `./shop-control.sh recover storefront payments-api checkout-demo` | Full recovery (~60–90s for VMAlertmanager; Keep may lag) |

Direct equivalent:

```bash
kubectl -n shop exec deploy/checkout-demo -- wget -qO- http://127.0.0.1:8080/trigger-outage
kubectl -n shop exec deploy/checkout-demo -- wget -qO- http://127.0.0.1:8080/recover
```

## Artifacts

| Path | Purpose |
|------|---------|
| `k8s/` | Shop app, ServiceMonitors, PrometheusRules, Keep PVC, VMAlertmanager keep-shadow secret |
| `k8s/vmalertmanager-keep-shadow.yaml` | VMAlertmanager secret: `keep-shadow` webhook → Keep |
| `k8s/vmalertmanager-keep-shadow-additive.yaml` | Optional `VMAlertmanagerConfig` merge (shadow route with `continue: true`) |
| `values-keep-kind-postgres.yaml` | Keep Helm overlay (bundled Postgres, K8s secrets, topology, ingress) — **default** |
| `values-opensearch-kind.yaml` | Minimal OpenSearch for Kind |
| `values-logging-kind.yaml` | Graylog + FluentBit for Kind |
| `keep/topology.yaml` | Manual Keep topology (includes synthetic `external-psp` for processor quirk) |
| `keep/correlation-rules.json` | Single app-level correlation rule |
| `keep/shop-checkout-mapping.csv` | Service → runbook/owner/tier mapping |
| `keep/graylog-enrichment-workflow.yaml` | Per-alert log enrichment (`enrich_alert`; Python formats `log_snippet`) |
| `keep/graylog-incident-enrichment-workflow.yaml` | Per-incident log rollup (`enrich_incident`; Python formats `log_summary`) |
| `k8s/mailpit.yaml` | Local SMTP catcher (port 1025) + web UI (8025) |
| `keep/smtp-notification-workflow.yaml` | SMTP on `shopchk-*` rule incident `created` |
| `keep/smtp-topology-notification-workflow.yaml` | SMTP on topology incident `updated` (one email per episode) |
| `keep/test-smtp-notification.sh` | Verify rule-incident SMTP delivery via Mailpit |
| `keep/resolve-stale-incidents.sh` | Bulk-resolve firing incidents (cleanup helper) |
| `keep/apply-keep-config.sh` | Apply topology, rules, mapping, providers, workflows |
| `shop-control.sh` | Trigger outage / recover / slow-mode |
| `validate.sh` | End-to-end validation |

### SMTP notification (item 7)

Optional: deploy Mailpit first (`kubectl apply -f k8s/mailpit.yaml`), then re-run `apply-keep-config.sh`.

Two workflows (one email per incident episode, not per alert):

- **Rule** (`smtp-notification-workflow.yaml`) — trigger `incident:created` for `incident_type == rule` (`shopchk-*`).
- **Topology** (`smtp-topology-notification-workflow.yaml`) — trigger `incident:updated` for `incident_type == topology`. Guards duplicate sends with `topology_smtp_sent`, read via HTTP `GET http://keep-backend:8080/incidents/{id}` (`steps.fetch-incident-enrichment.results.body.topology_smtp_sent`). Do **not** use `incident.enrichments.*` in `if` conditions (UUID hyphen mismatch in Keep 0.52.x). Flag is set/cleared via `POST .../enrich`.

Verify: `./keep/test-smtp-notification.sh` (Mailpit UI: port-forward `8025` → `http://127.0.0.1:18025/`).

### Optional: SQLite overlay

The first PoC revision used SQLite on a PVC (`values-keep-kind.yaml`). **Postgres is the supported path now** — use the files below only if you cannot run the chart's bundled Postgres.

```bash
kubectl apply -f k8s/keep-backend-pvc.yaml
KEEP_VALUES_FILE=values-keep-kind.yaml ./deploy-keep-ingress-kind.sh
```

| File | Role |
|------|------|
| `values-keep-kind.yaml` | SQLite on PVC + file-based provider secrets (`SECRET_MANAGER_DIRECTORY=/data/secrets`) |
| `k8s/keep-backend-pvc.yaml` | PVC for `/data/keep.db` and `/data/secrets` |

Switching between SQLite and Postgres starts a **fresh** database; re-run `apply-keep-config.sh` and do not expect data migration.

## Kind troubleshooting

| Issue | Fix |
|-------|-----|
| Graylog `download-plugins` init fails | Set `graylog.initContainerDockerImage: alpine:3.17.2` in `values-logging-kind.yaml`, delete `statefulset/graylog`, wait for operator to recreate |
| FluentBit crashes on `/var/log/audit/audit.db` | Set audit logging flags to `false` in `values-logging-kind.yaml`; restart logging operator and FluentBit |
| OpenSearch Helm pre-install hook timeout | Re-run `helm upgrade --install opensearch ... --wait --timeout 20m` |
| Keep topology/rules lost after DB reset | Re-run `./keep/apply-keep-config.sh` |
| No alerts in Keep UI | Apply `k8s/vmalertmanager-keep-shadow.yaml`; confirm API key matches webhook `basic_auth.password` |
| Graylog/SMTP workflows fail (“provider not configured”) | Ensure `SECRET_MANAGER_DIRECTORY=/data/secrets`, `helm upgrade`, re-run `apply-keep-config.sh` |
| Graylog log enrichment empty or workflow step fails on `format-log-*` | Ensure `default-python` is installed (`apply-keep-config.sh` installs it before Graylog workflows) |
| Keep topology import fails | Service ids must be integers; application id must be UUID |
| Graylog provider install fails from host | Port-forward Graylog on `19000`; token via `POST /api/users/{id}/tokens/keep-shop-poc` (Graylog 5) |
| `log_summary` rows link to broken alert pages | Re-run `apply-keep-config.sh`; incident workflow must store `log_summary` as a string, not an array |
| Stale `log_snippet` on firing alerts | Keep deduplicates repeat webhooks; recover and re-trigger outage for fresh enrichment |

## Teardown

```bash
helm uninstall qubership-logging-operator -n logging || true
helm uninstall opensearch -n opensearch || true
kubectl delete -f k8s/prometheus-rules.yaml
kubectl delete -f k8s/service-monitors.yaml
kubectl delete -f k8s/storefront.yaml
kubectl delete -f k8s/checkout-demo.yaml
kubectl delete -f k8s/payments-api.yaml
kubectl delete namespace shop
```
