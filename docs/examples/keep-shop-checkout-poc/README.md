# Keep shop-checkout PoC

Reproducible local PoC for [issue #330](https://github.com/Netcracker/qubership-monitoring-operator/issues/330): multi-service failures, manual Keep topology, alert correlation, and Graylog log enrichment.

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
| Topology | Manual YAML import (`keep/topology.yaml`) |
| Ops metadata | CSV mapping on `labels.service` (`keep/shop-checkout-mapping.csv`) |
| Log context | Graylog provider + alert workflow (`log_snippet`) + incident workflow (`log_summary`) |
| Incidents | Single app-level correlation rule (`keep/correlation-rules.json`) |

Grafana and Jaeger are intentionally excluded.

### One application incident for all services

Keep should surface **one** `shopchk-*` incident per outage, with alerts from every affected service attached.

Requirements:

1. **Only the app-level rule** — do not keep per-service correlation rules; they create parallel incidents for the same outage.
2. **Group by application, not service** — `groupingCriteria` must be `["application", "namespace"]`. Including `"service"` splits incidents per service.
3. **Alert labels** — every `PrometheusRule` must set `application: shop-checkout`, `namespace: shop`, and the correct `service` label so alerts match the rule and appear under distinct services in the incident.
4. **Upstream health checks** — storefront treats checkout `backend_up=0` as unreachable so cascade scenarios also raise storefront alerts.

Re-apply after edits: `KEEP_API_URL=http://127.0.0.1:18080 ./keep/apply-keep-config.sh` (updates the rule and deletes obsolete service-level rules).

### Alert mapping (runbook / owner / tier)

`keep/shop-checkout-mapping.csv` joins on `labels.service` (VictoriaMetrics webhook ingest keeps `service` in labels) and adds `runbook_url`, `owner`, and `escalation_tier` to each shop alert in Keep. This is operational metadata separate from topology (dependencies) and PrometheusRule labels.

**Where the fields land:** mapping adds **top-level** alert properties, not entries under **Labels** in the UI. Prometheus labels stay unchanged; the alert detail Labels panel will look the same even when mapping succeeded. Check the **alert sidebar** (after `ALERT_SIDEBAR_FIELDS` is set in `values-keep-kind.yaml`) or the API:

```bash
curl -H 'Authorization: Bearer api_key:any-local-key' \
  'http://<keep-api>/alerts/<fingerprint>' | jq '{name, runbook_url, owner, escalation_tier, enriched_fields}'
```

`enriched_fields` lists applied enrichments (mapping: `runbook_url`, `owner`, `escalation_tier`; Graylog workflow: `log_snippet`, `graylog_query`).

**Workflows:** mapping fields are available in workflow expressions, e.g. `{{ alert.runbook_url }}`, same as `enrich_alert` output.

**UI sidebar:** `values-keep-kind.yaml` sets frontend `ALERT_SIDEBAR_FIELDS` to include `runbook_url`, `owner`, `escalation_tier`, and `graylog_query` alongside the default sidebar fields ([Keep docs](https://docs.keephq.dev/deployment/configuration)). Re-apply with `helm upgrade` after changing that overlay.

**Timing:** mapping runs on **new alert ingest** only. Alerts that fired before mapping was installed, or deduplicated repeat webhooks, may lack mapping fields until the next fresh firing cycle.

Mapping does not change correlation or log workflows.

### Extraction and alert visibility

For this PoC, **extraction rules are not required**. VMAlert/Alertmanager already delivers structured labels and `description`; mapping and the Graylog workflow add top-level ops/log fields. To show more context in the UI, extend **`ALERT_SIDEBAR_FIELDS`** in `values-keep-kind.yaml` (e.g. `log_snippet`, `generatorURL`, `symptom`, `pod`, `startsAt`) rather than adding regex extraction. The one nested field to watch is **`annotations.summary`** (short title) — it is not promoted to top-level; use a nested sidebar key or a single extraction rule if needed. See checklist item 5 in [`follow-up-checklist.md`](../../keep/follow-up-checklist.md).

**Incident log rollup:** `graylog-incident-enrichment-workflow.yaml` runs on incident `created`/`updated`, queries Graylog for all `shop-checkout` logs in `shop`, and sets incident enrichments `log_summary` + `graylog_query`. Per-alert `log_snippet` remains on linked alerts. Check incident enrichments in the Keep UI and workflow execution history.

### Keep persistence + ingress (Kind)

The default Keep Helm install uses `sqlite:////tmp/keep.db` (lost on pod restart). Use the PoC overlay for persistent SQLite, topology processor, ingress, and sidebar fields for mapping enrichments:

```bash
kubectl apply -f k8s/keep-backend-pvc.yaml
chmod +x deploy-keep-ingress-kind.sh
./deploy-keep-ingress-kind.sh
```

Add to `/etc/hosts`:

```
127.0.0.1 keep.local
```

Start a **single** ingress port-forward (required on Kind — NodePort is not bound to 127.0.0.1):

```bash
chmod +x port-forward-keep-ingress.sh
./port-forward-keep-ingress.sh
```

Then open **http://keep.local/** (API: **http://keep.local/v2**). Do **not** omit the port-forward; `http://keep.local` alone hits localhost:80 which has nothing listening until the forward is running.

Fallback if port 80 cannot bind: `LOCAL_PORT=30080 ./port-forward-keep-ingress.sh` → use **http://keep.local:30080/**.

Without port-forward, use the Kind node IP (`kubectl get nodes -o wide`) in hosts — e.g. `172.18.0.2 keep.local` → **http://keep.local:30080/**.

`values-keep-kind.yaml` sets `DATABASE_CONNECTION_STRING=sqlite:////data/keep.db`, mounts PVC `keep-backend-data` at `/data`, enables `KEEP_TOPOLOGY_PROCESSOR=true`, `global.ingress` on `keep.local`, and `ALERT_SIDEBAR_FIELDS` for mapping columns (`runbook_url`, `owner`, `escalation_tier`).

**Provider credentials vs SQLite:** Keep stores provider *metadata* in SQLite (`provider` table on the PVC) but stores provider *secrets* (Graylog token, SMTP password, etc.) via the default **file** secret manager. Without `SECRET_MANAGER_DIRECTORY`, those files land in the ephemeral container working directory (`/app`) and are **lost on pod restart**, while the SQLite row remains — workflows then fail with “provider not configured”. The PoC overlay sets `SECRET_MANAGER_DIRECTORY=/data/secrets` so secrets live on the same PVC as `keep.db`. After upgrading Keep with that value, run `apply-keep-config.sh` once if providers need reinstalling.

| Approach | PoC / production | Notes |
|----------|------------------|-------|
| `SECRET_MANAGER_DIRECTORY=/data/secrets` | PoC (this repo) | File secrets on PVC; minimal change |
| `SECRET_MANAGER_TYPE=DB` | PoC / single-node SQLite | Secrets in `secret` table inside `keep.db` |
| `SECRET_MANAGER_TYPE=k8s` | Production Helm default | Native Kubernetes `Secret` objects; needs SA RBAC |

When the topology processor is enabled, expect **`incident_type: topology`** incidents named like `Application incident: shop-checkout` in addition to (or instead of) `shopchk-*` rule incidents. For a clean comparison, disable or remove the app-level correlation rule before testing topology-only grouping.

**Restore Keep config** (after DB reset, restart, or fresh PVC) — Graylog still needs port-forward on `19000` unless you add a similar ingress for logging:

```bash
KEEP_API_URL=http://keep.local/v2 ./keep/apply-keep-config.sh
```

**Port-forward fallback** (if ingress is not installed):

```bash
kubectl port-forward -n keep svc/keep-frontend 3000:3000 &
kubectl port-forward -n keep svc/keep-backend 18080:8080 &
KEEP_API_URL=http://127.0.0.1:18080 ./keep/apply-keep-config.sh
```

## Prerequisites

- Kind cluster with monitoring-operator and Keep already installed
- `kubectl` context pointed at the cluster (for example `kind-observability-local`)
- Local clones of `qubership-opensearch` and `qubership-logging-operator` next to this repo
- Keep API key configured for the `keep-shadow` receiver (`api_key:any-local-key` in the local PoC)

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

### 2. Keep topology + correlation rules

With ingress (recommended after `./deploy-keep-ingress-kind.sh`):

```bash
chmod +x keep/apply-keep-config.sh
KEEP_API_URL=http://keep.local/v2 ./keep/apply-keep-config.sh
```

### 3. Logging stack (OpenSearch + Graylog + FluentBit)

```bash
chmod +x deploy-logging.sh
./deploy-logging.sh
```

Re-run Keep config after Graylog is up:

```bash
KEEP_API_URL=http://keep.local/v2 ./keep/apply-keep-config.sh
```

### 4. Validate

With Keep ingress, only monitoring/logging port-forwards are required:

```bash
kubectl port-forward -n monitoring svc/vmsingle-k8s 8428:8428 &
kubectl port-forward -n monitoring svc/vmalertmanager-k8s 9093:9093 &
kubectl port-forward -n logging svc/graylog-service 9000:9000 &
chmod +x validate.sh
KEEP_API_URL=http://keep.local/v2 ./validate.sh
```

## Failure playbook

Control demo services with [`shop-control.sh`](shop-control.sh) (HTTP `GET` via `wget` inside each pod):

| Action | Command | Expected result |
|--------|---------|-----------------|
| Storefront outage | `./shop-control.sh trigger-outage storefront` | Storefront availability + latency alerts; Keep incident |
| Checkout outage | `./shop-control.sh trigger-outage checkout-demo` | Checkout + storefront alerts; one `shopchk-*` app incident |
| Payments outage | `./shop-control.sh trigger-outage payments-api` | Payments + checkout (+ storefront) alerts; same `shopchk-*` app incident |
| Storefront slow mode | `./shop-control.sh slow-mode storefront` | Latency alert on storefront |
| Recover one service | `./shop-control.sh recover <service>` | That service’s alerts resolve in VMAlertmanager |
| Recover all | `./shop-control.sh recover storefront payments-api checkout-demo` | Full shop-checkout recovery (~60–90s for Keep) |

Direct equivalent (no helper script):

```bash
kubectl -n shop exec deploy/checkout-demo -- wget -qO- http://127.0.0.1:8080/trigger-outage
kubectl -n shop exec deploy/checkout-demo -- wget -qO- http://127.0.0.1:8080/recover
```

## Artifacts

| Path | Purpose |
|------|---------|
| `k8s/` | Shop app, ServiceMonitors, PrometheusRules, Keep PVC |
| `values-keep-kind.yaml` | Keep Helm overlay (persistent SQLite + topology processor) |
| `k8s/keep-backend-pvc.yaml` | PVC for Keep SQLite at `/data/keep.db` |
| `values-opensearch-kind.yaml` | Minimal OpenSearch for Kind |
| `values-logging-kind.yaml` | Graylog + FluentBit for Kind |
| `keep/topology.yaml` | Manual Keep topology |
| `keep/correlation-rules.json` | Keep incident rules |
| `keep/shop-checkout-mapping.csv` | Service → runbook/owner/tier mapping |
| `keep/graylog-enrichment-workflow.yaml` | Per-alert log enrichment (`enrich_alert`) |
| `keep/graylog-incident-enrichment-workflow.yaml` | Per-incident log rollup (`enrich_incident`) |
| `k8s/mailpit.yaml` | Local SMTP catcher (port 1025) + web UI (8025) |
| `keep/smtp-notification-workflow.yaml` | SMTP on `shopchk-*` rule incident `created` |
| `keep/smtp-topology-notification-workflow.yaml` | SMTP on topology incident `updated` when `alerts_count == 3` |
| `keep/test-smtp-notification.sh` | Verify incident notification after a firing `shopchk-*` incident |
| `keep/apply-keep-config.sh` | Apply Keep topology/rules/mapping/provider/workflow |
| `shop-control.sh` | Trigger outage / recover / slow-mode on demo services |
| `validate.sh` | End-to-end validation script |

### SMTP notification (item 7)

`apply-keep-config.sh` installs the Mailpit SMTP provider when `svc/mailpit` exists in `keep`. Two workflows (not per alert): **rule** (`smtp-notification-workflow.yaml`) on incident **`created`** for `shopchk-*`; **topology** (`smtp-topology-notification-workflow.yaml`) on incident **`updated`** — one email per firing episode using **`topology_smtp_sent`** fetched via HTTP `GET /incidents/{id}` (API SQL join works; `incident.enrichments.*` in `if` does not). Uses in-cluster `http://keep-backend:8080` and PoC API key in `consts.keep_api_auth`. Each email includes **Open incident in Keep** (`consts.keep_ui_base`).

## Kind troubleshooting

| Issue | Fix |
|-------|-----|
| Graylog `download-plugins` init fails (`cp: can't create directory '/usr/share/graylog/plugin'`) | Set `graylog.initContainerDockerImage: alpine:3.17.2` in `values-logging-kind.yaml`, delete `statefulset/graylog`, wait for operator to recreate |
| FluentBit crashes on `/var/log/audit/audit.db` | Set `fluentbit.systemAuditLogging/kubeAuditLogging/kubeApiserverAuditLogging: false`; restart `logging-service-operator` and FluentBit pod |
| OpenSearch Helm pre-install hook timeout | Re-run `helm upgrade --install opensearch ... --wait --timeout 20m` after tls-init job completes |
| Keep topology/rules lost after restart | Apply `k8s/keep-backend-pvc.yaml` + `helm upgrade ... -f values-keep-kind.yaml` so SQLite lives at `/data/keep.db` on a PVC |
| Graylog/SMTP workflows fail after backend restart (“provider not configured”) | Ensure `SECRET_MANAGER_DIRECTORY=/data/secrets` in `values-keep-kind.yaml` and `helm upgrade`; re-run `apply-keep-config.sh` if migrating from an older install |
| Keep topology import fails | Use `curl -F file=@keep/topology.yaml`; service ids must be integers, application id must be UUID |
| Graylog provider install fails | Create API token via `POST /api/users/{id}/tokens/keep-shop-poc` (Graylog 5), not password auth |

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
