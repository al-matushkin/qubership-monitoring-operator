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
| Notifications | Mailpit SMTP (optional) — **rule** incidents only (`shopchk-*` on `created`) |
| RCA (optional) | [Aurora](https://arvo-ai-aurora.mintlify.app/) stub — rule `created` workflow waits for `alerts_count >= 2`, then trigger + poll |

Grafana and Jaeger are intentionally excluded.

### VMAlertmanager → Keep (alert webhook)

Alerts reach Keep through a standard **Alertmanager webhook** — not a custom vmalert push and not the Keep VictoriaMetrics *provider* (that provider is for querying metrics inside workflows).

```text
vmalert  →  VMAlertmanager  →  receiver keep-shadow (webhook_configs)  →  Keep backend
```

| Piece | Value (PoC) |
|-------|-------------|
| Keep ingest URL | `http://keep-backend.keep.svc:8080/alerts/event/prometheus` |
| Alternate URL | `/alerts/event/victoriametrics` — same Alertmanager JSON payload, but Keep 0.52.x **does not** promote `labels.*` to top-level alert fields (`application`, `namespace`, `service`, …). Correlation CEL and mapping matchers break if you use this path. |
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

| Type | Source | Name pattern | When it fires | Auto-resolve |
|------|--------|--------------|---------------|--------------|
| `rule` | `correlation-rules.json` | `shopchk-*` | On incident **created** when alerts match `application == shop-checkout` | `all_resolved` |
| `topology` | `KEEP_TOPOLOGY_PROCESSOR` + `topology.yaml` | `Application incident: shop-checkout` | When multiple services in the same application alert together | `all_resolved` |

Both can be active during an outage. **Workflows target rule incidents only** (`shopchk-*` on `created`). The topology incident is **graph + linked alerts only** — no SMTP, Graylog rollup, or Aurora.

To test only one path, disable the other in Keep UI or remove it from `apply-keep-config.sh`.

**Rule incident requirements** (`correlation-rules.json` ships a single app-level rule):

1. **Group by application, not service** — `groupingCriteria` is `["application", "namespace"]`. Adding `"service"` splits incidents per service.
2. **Alert labels** — every `PrometheusRule` sets `application: shop-checkout`, `namespace: shop`, and the correct `service` label (used as the mapping join key).
3. **Upstream health checks** — storefront treats checkout `backend_up=0` as unreachable so cascade scenarios also raise storefront alerts.
4. **Auto-resolve** — `resolveOn: all_resolved` closes the rule incident when every linked alert is resolved (see below).

### Alert lifecycle, dedup, and when incidents resolve

Keep learns alert state from **VMAlertmanager webhooks** (`send_resolved: true` on the `keep-shadow` receiver). VMAlertmanager notifies on state changes and repeats firing alerts on `repeat_interval` (5m in this PoC); Keep **deduplicates** identical repeat payloads so correlation and enrichment are not re-run every 5 minutes.

**Preferred recovery cycle (do not skip steps):**

1. Fix the app: `./shop-control.sh recover checkout-demo` (and other services if needed).
2. Wait ~60–75s for VMAlertmanager to send **resolved** webhooks and for Keep to mark alerts resolved.
3. Rule and topology incidents with `resolve_on: all_resolved` should close automatically once all linked alerts are resolved.
4. If stale firing incidents remain (orphans, manual-resolve drift), run `./keep/resolve-stale-incidents.sh`.

**Alert timing:** availability/latency alerts (`*_up`, `*_latency_seconds`) clear soon after recover (~60–90s). `CheckoutDemoHighErrorRatio` uses a **5m rolling rate** over `checkout_requests_total` (not the lifetime `checkout_error_ratio` gauge in `/status`), so it clears within ~5–6 minutes after recover — even after a long outage.

**Why manual resolve is dangerous:** resolving an alert or incident in the UI while VMAlertmanager still considers the alert **firing** tells Keep to stop tracking it. AM repeat webhooks are then **full duplicates** (same fingerprint + payload hash) and do **not** flip status back to firing. You get silent drift: metrics bad, AM firing, Keep quiet. Prefer `./shop-control.sh recover` and let `send_resolved` drive state; use `resolve-stale-incidents.sh` only after verified recovery or for known duplicate rows.

Re-apply correlation rules after edits:

```bash
KEEP_API_URL=http://keep.local:30080/v2 ./keep/apply-keep-config.sh
```

### Alert mapping (runbook / owner / tier / environment / repository)

`keep/shop-checkout-mapping.csv` joins on `labels.service` (VictoriaMetrics webhook ingest keeps `service` in labels) and adds **one row per service**: `runbook_url`, `owner`, `escalation_tier`, `environment`, and `repository` (Git repo URL). Keep applies these at alert ingest; the incident overview **Environments** and **Repositories** fields aggregate the enriched alert properties — no duplication on each `PrometheusRule`.

**Why not on alert rules?** Ops metadata belongs in a service catalog (CSV, CMDB, or topology), not repeated on every alert definition. Prometheus rules should stay focused on signal (`severity`, `symptom`, `team`).

**Why `/prometheus` and not `/victoriametrics`?** Same Alertmanager webhook body, different Keep parser. The Prometheus ingest path promotes alert labels to **top-level** fields (`application`, `namespace`, `service`, …). The shop correlation rule CEL is `application == "shop-checkout" && namespace == "shop"` — that only works when those fields are top-level. VictoriaMetrics ingest leaves them under `labels` only, so rule incidents stop matching. Ops metadata (`repository`, `environment`, runbook) still comes from **mapping CSV**, not from the webhook path.

**From the workload (production path):** put `environment` / `repository` on Deployment pod labels and join via Keep mapping on `labels.service` — no need to duplicate URLs on PrometheusRule labels.

**Where the fields land:** mapping adds **top-level** alert properties, not entries under **Labels** in the UI. Check the **alert sidebar** (after `ALERT_SIDEBAR_FIELDS` in `values-keep-kind.yaml`) or the API:

```bash
curl -u 'api_key:any-local-key' \
  'http://keep.local:30080/v2/alerts?status=firing&limit=5' | jq '.[] | {name, runbook_url, owner, escalation_tier, enriched_fields}'
```

`enriched_fields` lists applied enrichments (mapping: `runbook_url`, `owner`, `escalation_tier`, `environment`, `repository`; Graylog workflow: `log_snippet`, `graylog_query`).

**Workflows:** mapping fields are available in workflow expressions, e.g. `{{ alert.runbook_url }}`.

**UI sidebar:** `values-keep-kind-postgres.yaml` sets `ALERT_SIDEBAR_FIELDS` to include `runbook_url`, `owner`, `escalation_tier`, and `graylog_query` ([Keep docs](https://docs.keephq.dev/deployment/configuration)). Re-apply with `helm upgrade` after changing that overlay.

**Timing:** mapping runs on **new alert ingest** only. Deduplicated repeat webhooks may keep stale enrichments until a fresh firing cycle (recover → re-trigger outage).

### Extraction and alert visibility

**Extraction rules are not required** for this PoC. VMAlert/Alertmanager delivers structured labels and `description`; mapping and Graylog workflows add ops/log fields. Extend **`ALERT_SIDEBAR_FIELDS`** in `values-keep-kind-postgres.yaml` (e.g. `log_snippet`, `symptom`, `pod`) rather than adding regex extraction. See checklist item 5 in [`follow-up-checklist.md`](../../keep/follow-up-checklist.md).

**Incident log rollup:** `graylog-incident-enrichment-workflow.yaml` runs on **rule** `incident:created`, waits until `alerts_count >= 2`, then sets `log_summary` + `graylog_query`. Per-alert `log_snippet` still comes from `graylog-enrichment-workflow.yaml` (`type: alert`).

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

### 4b. Aurora RCA stub (optional)

```bash
kubectl apply -f k8s/aurora-rca-stub.yaml
kubectl -n aurora rollout status deploy/aurora-rca --timeout=120s
KEEP_API_URL=http://keep.local:30080/v2 ./keep/apply-keep-config.sh   # installs Aurora workflows when stub is up
```

After a rule incident (`shopchk-*`), verify: `./keep/test-aurora-rca.sh`. See [Aurora RCA integration](#aurora-rca-integration-optional).

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
| **Full cascade (3 services)** | `./shop-control.sh trigger-cascade` | payments → checkout → storefront alerts; one `shopchk-*` incident |
| Storefront outage | `./shop-control.sh trigger-outage storefront` | Storefront alerts only |
| Checkout outage | `./shop-control.sh trigger-outage checkout-demo` | Checkout + storefront (payments stays healthy) |
| Payments outage | `./shop-control.sh trigger-outage payments-api` | Same as `trigger-cascade` |
| Storefront slow mode | `./shop-control.sh slow-mode storefront` | Latency alert on storefront |
| Recover one service | `./shop-control.sh recover <service>` | That service’s alerts resolve in VMAlertmanager |
| Recover all | `./shop-control.sh recover` (no args — all three, upstream first) or explicit service list |

Direct equivalent:

```bash
kubectl -n shop exec deploy/checkout-demo -- wget -qO- http://127.0.0.1:8080/trigger-outage
kubectl -n shop exec deploy/checkout-demo -- wget -qO- http://127.0.0.1:8080/recover
```

### Cascading outage timing

Symptoms are **staggered** (~10–20s app delays between hops) so alerts do not all land in the same second; Prometheus `for: 30s` still adds ~30–45s before each alert fires.

**Full chain (recommended):** `./shop-control.sh trigger-cascade` — root failure at **payments-api** (`storefront → checkout-demo → payments-api`):

| Phase | When | What happens |
|-------|------|----------------|
| Root failure | T+0 | `payments_up=0` (payments-api outage) |
| Payments alert | ~T+30–45s | `PaymentsApiUnavailable` (`for: 30s`) |
| Checkout grace | ~T+2s → T+14s | Checkout charges every **2s**, **12s** grace before `backend_up=0` |
| Checkout alert | ~T+44–60s | `CheckoutDemoTargetDown` |
| Storefront grace | after checkout down | Poll every **3s**, **12s** grace before `storefront_up=0` |
| Storefront alert | ~T+56–75s | `StorefrontCheckoutUnreachable` |
| Checkout latency | T+15s after payments fail | `CheckoutDemoLatencyHigh` ~T+45–60s |
| Error-ratio alerts | ~T+5–6m | 5m Prometheus rate windows |

**Checkout-only outage** (`trigger-outage checkout-demo`): checkout **15s / 20s** symptom ramp + storefront **12s** grace; **payments-api stays healthy**.

Tune delays in `k8s/payments-api.yaml`, `k8s/checkout-demo.yaml` (`PAYMENTS_FAILURE_*`, `OUTAGE_*`), and `k8s/storefront.yaml` (`POLL_INTERVAL_SECONDS`, `DOWNSTREAM_GRACE_SECONDS`). After edits:

```bash
kubectl apply -f k8s/payments-api.yaml -f k8s/checkout-demo.yaml -f k8s/storefront.yaml
kubectl -n shop rollout restart deploy/payments-api deploy/checkout-demo deploy/storefront
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
| `keep/graylog-incident-enrichment-workflow.yaml` | Rule `incident:created` — wait for ≥2 alerts, then `log_summary` rollup |
| `k8s/mailpit.yaml` | Local SMTP catcher (port 1025) + web UI (8025) |
| `keep/smtp-notification-workflow.yaml` | SMTP on `shopchk-*` rule incident `created` |
| `keep/test-smtp-notification.sh` | Verify rule-incident SMTP delivery via Mailpit |
| `k8s/aurora-rca-stub.yaml` | Minimal Aurora-compatible RCA API for Kind (optional) |
| `keep/aurora-rca-rule-trigger-workflow.yaml` | Rule `incident:created` — wait for cascade (≥2 alerts), POST Aurora, poll, enrich RCA |
| `keep/test-aurora-rca.sh` | Verify Aurora RCA enrichments on latest `shopchk-*` incident |
| `keep/resolve-stale-incidents.sh` | Bulk-resolve firing incidents (cleanup helper) |
| `keep/apply-keep-config.sh` | Apply topology, rules, mapping, providers, workflows |
| `shop-control.sh` | Trigger cascade / outage / recover / slow-mode |
| `validate.sh` | End-to-end validation |

### SMTP notification (item 7)

Optional: deploy Mailpit first (`kubectl apply -f k8s/mailpit.yaml`), then re-run `apply-keep-config.sh`.

One workflow — email on **`shopchk-*` rule incident `created`** (`smtp-notification-workflow.yaml`). Topology incidents do not send email.

Verify: `./keep/test-smtp-notification.sh` (Mailpit UI: port-forward `8025` → `http://127.0.0.1:18025/`).

### Aurora RCA integration (optional)

Keep OSS correlates symptoms and assembles context (topology, logs, alerts) but does **not** run automated root-cause analysis. A logical next step if Keep is adopted is to **trigger an external RCA tool** on incident create and **enrich results back** onto the Keep incident.

This PoC wires **[Arvo AI Aurora](https://arvo-ai-aurora.mintlify.app/)** using **one** Keep workflow and a **lightweight API stub** for Kind.

```text
Rule (shopchk-*): incident created
  → SMTP immediately
  → Graylog + Aurora wait (poll up to 90s) until alerts_count ≥ 2, then enrich
Topology: no workflows — UI graph only
```

| Piece | PoC value |
|-------|-----------|
| Stub manifest | `k8s/aurora-rca-stub.yaml` — service `aurora-rca.aurora.svc:5080` |
| Rule workflow | `keep/aurora-rca-rule-trigger-workflow.yaml` — **`incident:created`**, inline wait until `alerts_count >= 2`, then Aurora POST + poll |
| Install | `apply-keep-config.sh` when `aurora-rca` service exists |
| Verify | `./keep/test-aurora-rca.sh` |

**Deploy stub + workflows:**

```bash
kubectl apply -f k8s/aurora-rca-stub.yaml
kubectl -n aurora rollout status deploy/aurora-rca --timeout=120s
KEEP_API_URL=http://keep.local:30080/v2 ./keep/apply-keep-config.sh
```

**Incident enrichments set by the workflows:**

| Field | When |
|-------|------|
| `aurora_incident_id` | After trigger |
| `aurora_rca_status` | `investigating` → `complete` |
| `aurora_url` | In-cluster API URL (for workflows; not a browser link) |
| `rca_summary`, `root_cause` | After poll sees Aurora `auroraStatus=complete` |

**Keep UI — “External incident”:** Keep has a built-in sidebar block for linking to an external ticket/RCA system. It reads enrichments `incident_id`, `incident_url`, and `incident_provider` (see [Keep incident enrich example](https://github.com/keephq/keep/blob/main/examples/workflows/incident-enrich.yaml)). The PoC currently sets custom `aurora_*` fields only; a production wiring should also set `incident_id` + `incident_url` (Aurora **UI** URL) + `incident_provider: aurora` so the link is clickable. Do not point `incident_url` at the in-cluster API hostname.

**Enrichment merge (important):** Aurora workflows use the **`mock` provider + `enrich_incident`** (same pattern as Graylog incident enrichment). Do **not** use HTTP `POST /incidents/{id}/enrich` with `force: true` for partial updates — that **replaces** the whole enrichment dict and wipes `log_summary` / `graylog_query`. Poll reads `aurora_rca_status` via HTTP `GET http://keep-backend:8080/incidents/{id}` (`steps.fetch-keep-incident.results.body.*`) because `incident.enrichments.*` in workflow `if` conditions is unreliable in Keep 0.52.x.

**Stub vs real Aurora:**

| | PoC stub | Real [Aurora](https://arvo-ai-aurora.mintlify.app/) |
|--|----------|------------------------------------------------------|
| Deploy | `kubectl apply -f k8s/aurora-rca-stub.yaml` | Docker Compose or Helm (`github.com/arvo-ai/aurora`) |
| API | Minimal create + get JSON | Full RCA agent, chat UI, connectors |
| Docs | This README | [Mintlify docs](https://arvo-ai-aurora.mintlify.app/), [GitHub Pages](https://arvo-ai.github.io/aurora) |
| Workflow `aurora_api_base` | `http://aurora-rca.aurora.svc:5080` | Your Aurora API base URL |

**Anti-spam:** Aurora and Graylog incident rollup use **`incident:created` only** (not `updated`) so topology processor ticks (~10s) never dispatch them. Both poll the incident API until `alerts_count >= 2` before enriching. SMTP stays on rule `created` (immediate).

See checklist item 6 in [`follow-up-checklist.md`](../../keep/follow-up-checklist.md) for how Aurora fits the broader “Keep + RCA sidecar” evaluation.

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
| Recover after cascade | `./shop-control.sh recover` with no args now recovers **all three** (payments-api first). `./shop-control.sh recover checkout-demo` alone leaves payments in outage and checkout keeps failing charges |
| Duplicate rule/topology incidents (`shopchk-4` + `shopchk-5`, twin topology rows) | Keep image defaults to Gunicorn `--workers 4`; PoC values set `--workers 1`. Re-run `./deploy-keep-ingress-kind.sh` after edits. Also caused by **same-second** alert batches — use staggered cascade timing (see [Cascading outage timing](#cascading-outage-timing-checkout-demo-trigger)) |
| Orphan duplicate incident won't resolve (UI hangs) | Stale row lock from worker race; restart `keep-backend`, resolve once, or fix `alerts_count`/status in DB |
| Keep quiet but shop still in outage / AM still firing | Manual resolve drift or deduped repeats; `./shop-control.sh recover`, wait for AM resolved webhooks, then `resolve-stale-incidents.sh` if needed — do not manual-resolve during an active outage |
| Incidents stuck after recover (`CheckoutDemoHighErrorRatio`) | Alert uses `rate(checkout_requests_total[5m])`, not lifetime `/status` `error_ratio`; wait ~5–6m or `kubectl -n shop rollout restart deploy/checkout-demo` to speed up |
| Incidents/alerts need manual refresh; no WebSocket in DevTools | PoC `frontend.env` / `backend.env` must include chart defaults (`PUSHER_APP_KEY`, `PUSHER_HOST=keep-websocket`, …). Re-run `./deploy-keep-ingress-kind.sh`. DevTools: **Socket** filter (not text search `ws`). Menu badge may update via HTTP polling while the list stays stale without push |
| Aurora trigger workflow failed (`keep.join` in HTTP body) | `keep.join()` works in SMTP/HTML templates only, not HTTP JSON `body` fields. Re-run `apply-keep-config.sh` (revision ≥ 3 uses `service: shop-checkout`) |
| `log_summary` missing after Aurora RCA | HTTP enrich with `force: true` wipes other enrichments. PoC workflows use `mock` + `enrich_incident` (merge). Re-install workflows; Graylog refresh on next `incident:updated` restores logs |
| `aurora_url` does not open in browser | PoC URL is in-cluster API (`aurora-rca.aurora.svc`), not Aurora UI. Use port-forward + curl, or set `incident_url` to a public Aurora UI URL for the External incident block |

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
