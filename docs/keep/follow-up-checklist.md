# Keep PoC Follow-Up Checklist

This document captures the open questions and validation points for evaluating Keep as an alert correlation and incident management layer for the monitoring stack.

## Topics To Validate

1. **Enrichment by logs**
   - Check whether Keep can enrich alerts/incidents with related logs.
   - Identify required integrations and label fields needed to query logs reliably.

   **Findings (initial):**

   - Keep does not automatically attach logs to incidents. Enrichment is explicit: a provider integration plus a workflow or enrichment rule runs when an alert/incident matches.
   - Typical flow: `VMAlertmanager alert → Keep receives alert → rule/workflow matches → query logs provider → enrich alert/incident` with log snippets, links, or derived fields.
   - Relevant Keep mechanisms:
     - **Providers** — connect to external log systems (documented examples include CloudWatch, GCP Logging; Loki/OpenSearch/Elasticsearch need to be checked for our stack).
     - **Workflows** — on alert trigger, query a provider using alert labels (`namespace`, `service`, `pod`, `container`, `node`, `startsAt`) and use `enrich_alert` / `POST /incidents/{incident_id}/enrich` to add fields.
     - **Extraction** — regex from alert text (complements logs, does not replace them).
     - **Mapping** — join alerts to CSV/topology metadata (owners, runbooks, tiers).
   - Log correlation depends on **join keys on the alert**: at minimum `namespace`, `pod`, `container`, `service`, and ideally a time window around `startsAt` (e.g. −10m to +5m).
   - Suggested PoC for this item: pick the real log backend → confirm Keep provider → workflow on `checkout-demo` (or similar) alerts → query by `namespace`/`service`/`pod` → enrich incident with log link + short error summary.
   - Open questions: which log backend we standardize on; whether provider exists or needs a generic webhook/API; whether enrichment is per-alert only or also surfaced on the incident UI in one place.

   **Findings (shop-checkout PoC, 2026-06-08):**

   - **Log backend:** `qubership-logging-operator` with FluentBit → Graylog → OpenSearch works on Kind. Shop services emit structured JSON to stdout; FluentBit parses JSON fields (`application`, `service`, `namespace`) into Graylog.
   - **Keep provider:** Graylog provider installs and validates when given a Graylog 5 API token (`POST /api/users/{id}/tokens/{name}`) plus `deployment_url` pointing at `graylog-service.logging.svc:9000`.
   - **Enrichment workflow:** `keep/graylog-enrichment-workflow.yaml` queries Graylog via `events_search_parameters` with an Elasticsearch query on `application`, `service`, and `namespace`. Workflow installs through `POST /workflows?lookup_by_name=true` with a YAML file upload.
   - **Artifacts:** [`docs/examples/keep-shop-checkout-poc/`](../examples/keep-shop-checkout-poc/) — manifests, `values-logging-kind.yaml`, `keep/apply-keep-config.sh`, `validate.sh`.
   - **Kind caveats:** Graylog plugins init container fails with the default image; use `graylog.initContainerDockerImage: alpine:3.17.2`. FluentBit audit inputs fail on Kind unless `systemAuditLogging`, `kubeAuditLogging`, and `kubeApiserverAuditLogging` are set to `false`.

2. **Topology setup**
   - Check how Keep models service, namespace, node, pod, and dependency topology.
   - Determine whether topology can be imported from Kubernetes, labels, CMDB data, or other sources.

   **Findings (initial):**

   - Keep topology is **service-centric**, not a full Kubernetes object graph. The model has three parts:
     - **Services** — logical components (id, `service` code, `display_name`, `namespace`, `team`, `environment`, contacts, tags, optional `ip_address`, etc.).
     - **Applications** — business/logical groupings that reference a list of service ids.
     - **Dependencies** — directed edges between services (`service_id` → `depends_on_service_id`, plus `protocol` such as HTTP/GRPC/TCP).
   - **Import/export format is YAML** (UI: Service Topology → Import/Export). Minimal shape:

     ```yaml
     applications:
       - id: <uuid>
         name: monitoring-app
         services: [<service-id>, ...]
     dependencies:
       - id: <id>
         service_id: <from>
         depends_on_service_id: <to>
         protocol: HTTP
     services:
       - id: <id>
         service: <short-code>
         display_name: Auth Service
         namespace: auth
         team: Auth Team
         environment: production
     ```

   - **Node and pod are not first-class topology objects** in Keep. They can appear as metadata on a service or on alerts, but correlation/mapping keys off **service name** (and matchers you define). Alerts must carry a `service` label (or equivalent matcher) that matches topology service names.
   - **How to build topology for a cloud solution** (typical options, often combined):
     1. **Manual YAML** — start from a curated service catalog (CMDB, architecture docs, team ownership matrix); good for PoC and stable platform services.
     2. **Provider pull** — Keep can ingest topology from providers with `pull_topology()` (documented: Datadog, PagerDuty, ArgoCD, Cilium/Hubble, Grafana, ServiceNow). Pick the source that already knows dependencies in your environment.
     3. **Kubernetes network discovery** — Cilium/Hubble provider discovers service-to-service edges from live flows (needs Cilium + Hubble relay access; beta, label-dependent).
     4. **GitOps discovery** — Flux CD / ArgoCD providers map deployable units and repo/chart relationships (deployment topology, not runtime call graph).
     5. **Generated YAML from K8s inventory** — script over `Service`/`Deployment` labels (`app.kubernetes.io/name`, `namespace`) plus optional mesh/trace data; export to Keep YAML. This is custom glue, not built into the monitoring-operator.
   - **Topology-based correlation** is separate from the graph itself: enable `KEEP_TOPOLOGY_PROCESSOR=true`. It groups alerts affecting multiple services **within the same application** into one application-level incident. Limitations today: application-based only, one active incident per application, requires `service` on alerts.
   - **Practical path for our stack:** define applications aligned to Netcracker/cloud products → map each deployable to a Keep service using the same `service` label used in Prometheus rules and ServiceMonitors → add dependencies manually or from a supported provider → import YAML → enable topology processor and verify alert `service` labels match.

   **Feasibility summary (for our context):**

   | Source | Feasibility | Notes |
   |--------|-------------|-------|
   | **Manual Keep YAML** | High | Fastest for PoC; no external deps. Enough to validate topology processor and correlation. Local PoC already proved label-based correlation without topology YAML. |
   | **Keep topology providers** | High (if backend exists) | Cilium/Hubble, ArgoCD/Flux, Datadog, Grafana, ServiceNow, PagerDuty — use when the cloud already runs a supported provider. |
   | **Keep mapping / CSV** | High | Good for owner, team, runbook, severity — lighter than a full dependency graph. Complements topology; see item 4. |
   | **CMDB** | Low | Referenced in deployment docs as the platform parameter catalog, but no public spec and **no direct access from our location**. In-cluster mirror: `PlatformMonitoring` CR. Not a turnkey Keep topology source. |
   | **inventory-tool-cli** | Medium (future) | Strong design-time HTTP dependency graph via per-repo `inventory.json`, but **no existing Keep export**. Requires CI graph artifacts (`ci-exec` / `ci-assembly`) plus a custom converter and `dnsName` → Prometheus `service` mapping. Batch CLI, not a deployed service — full Confluence/super-repo mode is optional. |
   | **Raw Kubernetes inventory** | Low for topology | Useful for alert labels (`namespace`, `pod`, `service`), but not Keep’s native dependency model without custom glue. |

   **Recommended phasing:**

   1. **Now:** manual Keep YAML for 1–2 apps (e.g. `checkout-demo`, monitoring stack) plus label-based correlation rules (already demonstrated in local PoC).
   2. **Next:** mapping/CSV for ownership and runbook enrichment if topology alone is insufficient.
   3. **Later (if justified):** provider pull (e.g. Cilium/Hubble) and/or inventory-tool graph → Keep YAML pipeline — only after topology-based correlation proves worth maintaining.

   - Open questions: which supported topology provider (if any) exists in target clouds; whether builder CI already publishes inventory-tool graph artifacts; how to keep manual/provider topology in sync as deployments change; overlap with item 4 (mapping/CSV) for ownership/runbooks vs full dependency graph.

   **Findings (shop-checkout PoC, 2026-06-08):**

   - **Manual YAML import:** `POST /topology/import` with `curl -F file=@topology.yaml`. Service ids must be integers; application id must be a UUID. Example: [`keep/topology.yaml`](../examples/keep-shop-checkout-poc/keep/topology.yaml).
   - **Correlation rules:** Complement topology. Application-level rule (`application == "shop-checkout"`, threshold ≥ 2) groups multi-symptom checkout-demo alerts into one incident. Service-level rules per component also work.
   - **Alert label contract:** PrometheusRule labels (`service`, `namespace`, `application`) must match topology `service` names and workflow matchers exactly.
   - **No Grafana/Jaeger required:** Topology is hand-authored; traces and Grafana datasources are not part of this PoC path.

   **Findings (shop-checkout PoC, 2026-06-09 — topology processor behavior):**

   - **One incident per application is by design.** The topology processor supports only one active incident per `TopologyApplication` (same id is reused across outage waves). That is acceptable for the PoC as long as all application alerts and metadata stay current.
   - **Leaf services are invisible to the processor (Keep 0.52.x).** `TopologiesService.get_all_topology_data()` returns only services with at least one **outgoing** dependency (`if service.dependencies or include_empty_deps`). The processor uses that list to match alerts by `alert.service`. A leaf such as `payments-api` (only a dependency *target*, no outgoing edge) appears in `GET /topology` and in the application’s service list, but is **excluded** from processor matching — so root-cause alerts never attach to the topology incident.
   - **Symptom observed:** topology incident `Application incident: shop-checkout` showed only `checkout-demo` + `storefront`; `PaymentsApiUnavailable` was missing. Rule incident `shopchk-*` had all three services. In-cluster check: `get_all_topology_data()` returned `['storefront', 'checkout-demo']` while `GET /topology` returned all three services.
   - **Workaround (implemented):** add a synthetic leaf dependency so the real root service has an outgoing edge. In [`keep/topology.yaml`](../examples/keep-shop-checkout-poc/keep/topology.yaml): `payments-api → external-psp` (HTTPS) plus service `external-psp` in the application. After re-import, processor services became `['checkout-demo', 'payments-api', 'storefront']` and `PaymentsApiUnavailable` linked to the topology incident within one 10s interval.
   - **Re-import guard:** [`keep/apply-keep-config.sh`](../examples/keep-shop-checkout-poc/keep/apply-keep-config.sh) no longer skips import when service count ≥ 3; it re-imports when `payments-api` has empty `dependencies[]` or `external-psp` is missing. [`validate.sh`](../examples/keep-shop-checkout-poc/validate.sh) checks the same processor-ready condition.
   - **Stale incident metadata on reopen (separate from leaf-service bug).** After manual incident resolve while VMAlertmanager still has active alerts:
     - Keep marks linked alerts `resolved`; AM keeps firing and webhooks are **deduplicated** (`num_of_alerts: 0`), so alert `lastReceived` and incident `last_seen_time` stop advancing.
     - Topology processor flips `resolved → firing` on the **same incident id** but often leaves `end_time` set, `start_time`/`last_seen_time` from the first wave, and old resolved alerts still linked.
     - `add_alerts_to_incident()` returns early when all fingerprints are already linked, so metadata is not refreshed unless a **new** fingerprint is added (which is why `last_seen` jumped only when `payments-api` was first attached).
   - **Graylog enrichment on topology incidents:** incident `updated` workflow events still run (log_summary refreshed), but incident header fields in the UI can look stale relative to linked alerts.
   - **Topology vs rule incidents in practice:**

     | Aspect | Topology incident | Rule incident (`shopchk-*`) |
     |--------|-------------------|---------------------------|
     | Id reuse | Same id per application | New `shopchk-N` per wave (same `rule_fingerprint`) |
     | Service coverage (before fix) | Symptom services only | All firing services including root cause |
     | `resolve_on` | `all_resolved` | `never` (manual resolve only) |
     | Reliability for ops | Good after leaf-service workaround; metadata refresh still weak | More reliable for full grouping |

   - **Operational workarounds:**
     1. Do **not** manually resolve topology/rule incidents while VMAlertmanager still shows active alerts.
     2. For a clean re-test: `./shop-control.sh recover <service>` → wait ~60s for AM resolve webhooks → `./shop-control.sh trigger-outage <service>` → wait ~90s; or `DELETE /incidents/{id}` via API (UI delete for topology incidents is unreliable).
     3. Re-apply topology after YAML edits: `KEEP_API_URL=http://127.0.0.1:18080 ./keep/apply-keep-config.sh`.
     4. Use **rule correlation** as the primary ops incident; use **topology** for application-level view once leaf services have outgoing dependencies.
   - **Config notes:** topology processor interval is 10s (`KEEP_TOPOLOGY_PROCESSOR_INTERVAL`). Correct lookback env name is `KEEP_TOPOLOGY_PROCESSOR_LOOK_BACK_WINDOW` (not `LOOKBACK`); fixed in [`values-keep-kind.yaml`](../examples/keep-shop-checkout-poc/values-keep-kind.yaml). No public “reprocess topology” API — background loop only.
   - **Open questions / upstream:** whether Keep will add `include_empty_deps=True` in the processor or refresh incident metadata when deduplicated alerts keep firing; whether synthetic external dependencies are acceptable in production topology YAML vs a proper upstream fix.

3. **Alert suppression and inhibiting rules**
   - Compare Keep suppression/deduplication behavior with Alertmanager inhibition.
   - Decide which suppressions should remain in Alertmanager and which belong in Keep.

   **Findings (initial):**

   - **Naming:** monitoring-operator supports two alertmanager deployments with the same *protocol* (Prometheus Alertmanager config model) but different operators:
     - **VMAlertmanager** — `PlatformMonitoring.spec.victoriametrics.vmAlertManager` (VictoriaMetrics operator). **This is the PoC path:** `vmalert → VMAlertmanager → keep-shadow → Keep`.
     - **Prometheus AlertManager** — `PlatformMonitoring.spec.alertManager` (prometheus-operator, `install: false` by default). Same inhibition/silence concepts, different CR/deployment. Typically one stack per alert flow, not both.
   - When this doc says “alertmanager layer,” it means **VMAlertmanager** unless the Prometheus `alertManager` path is explicitly enabled.

   **Pipeline and where noise is reduced:**

   ```text
   vmalert (rules fire)
     → VMAlertmanager (inhibition, silences, grouping, routing)
     → receivers (email, webhook, keep-shadow, …)
     → Keep (dedup, maintenance windows, correlation, workflows)
   ```

   **VMAlertmanager (upstream — before Keep receives alerts):**

   | Mechanism | What it does | Config | Example |
   |-----------|--------------|--------|---------|
   | **Inhibition** | If source alert A is firing, mute notifications for target alert B (causal/structural) | `inhibit_rules` in `VMAlertmanagerConfig` / `AlertmanagerConfig` / `alertmanager.yaml` secret | NodeNotReady inhibits PodCrashLooping on same `node` |
   | **Silences** | Temporary mute by label matchers | Alertmanager API / UI | Planned maintenance on etcd |
   | **Grouping** | Bundle alerts into one notification | `route.group_by`, `group_wait`, etc. | Many pod alerts → one notification batch |

   - Inhibited alerts are **suppressed in VMAlertmanager** before dispatch. If `keep-shadow` is a normal receiver, **Keep may never see** inhibited symptom alerts — good for noise reduction, but limits Keep correlation if it needs those child alerts.
   - VM path note (from operator troubleshooting): `inhibit_rules` require a valid route + receivers in config; Prometheus `AlertmanagerConfig` without route/receivers may fail to apply inhibit rules when converted to `VMAlertmanagerConfig`.

   **Keep (downstream — on alerts that arrive via webhook):**

   | Mechanism | What it does | Closest VMAlertmanager analogue |
   |-----------|--------------|--------------------------------|
   | **Deduplication** | Collapse repeated identical/similar alert events by fingerprint fields | Partial overlap with AM grouping; discards re-processing, not causal suppression |
   | **Maintenance windows** | Suppress by CEL matchers + time window; skip workflows/incidents | Silences (planned/expected noise) |
   | **Workflows / dismiss** | Mark alerts dismissed via enrichment (e.g. `dismissed: true`) | Custom operational suppression |
   | **Correlation rules** | Group alerts *into* incidents (more visibility, not less) | Opposite of suppression — combines noise into context |

   - Keep has **no first-class inhibition** equivalent (“source alert X suppresses target alert Y by label equality”). Closest Keep features are maintenance windows (time + matchers) and workflow-based dismiss.

   **Key distinction:**

   | | VMAlertmanager | Keep |
   |---|----------------|------|
   | **Inhibition** | Yes — causal parent → child mute | No native equivalent |
   | **Silence / maintenance** | Silences (API/UI) | Maintenance windows (CEL + schedule) |
   | **Duplicate events** | Grouping at notify time | Dedup by fingerprint |
   | **Symptom handling** | Hide symptoms early | Correlate symptoms into one incident |

   **Trade-off for alert noise (issue #330):**

   - **More inhibition in VMAlertmanager** → fewer alerts reach Keep; less material for correlation/incident context.
   - **More correlation in Keep** → keep symptom alerts; group into incidents downstream.
   - These approaches compete unless deliberately split by alert type.

   **Suggested ownership split to validate:**

   | Keep in VMAlertmanager | Prefer in Keep |
   |------------------------|----------------|
   | Structural inhibition (node → pods, platform → dependents) | Maintenance-window suppression during change windows |
   | Infra/operator-managed silences | Dedup of repeated identical webhook events |
   | Grouping before traditional notification channels (email, etc.) | Correlation into incidents (not suppression) |
   | Routing to correct receivers | Workflow-based dismiss for known benign alerts |

   - Open questions: which OOB inhibit rules already exist in cloud VMAlertmanager configs; whether `keep-shadow` receives inhibited alerts or only active ones; whether maintenance windows should mirror existing AM silences or replace them for Keep-only handling; dedup overlap if both AM grouping and Keep dedup run on the same flow.

   **Recommendation (architecture):**

   - **Prefer `vmalert → VMAlertmanager → keep-shadow → Keep`** over bypassing VMAlertmanager. vmalert notifies Alertmanager-compatible receivers (`/api/v2/alerts`); Keep’s documented VictoriaMetrics ingest is the **Alertmanager webhook** format (`/alerts/event/victoriametrics`), not vmalert’s native push API.
   - Use **VMAlertmanager as a light router on the Keep path**, not a heavy filter. Aggressive `inhibit_rules` or silences before `keep-shadow` mean Keep never sees symptom alerts — correlation, topology grouping, and log enrichment cannot run on muted events.
   - **Split suppression by route:**
     - **`keep-shadow` route:** minimal inhibition; `continue: true` so Keep receives alerts in parallel with other receivers; `send_resolved: true` where auto-resolution in Keep is desired.
     - **Primary ops routes** (email, tickets, paging): may keep stronger grouping/inhibition to reduce on-call noise — independent of what Keep needs for incident context.
   - **Prefer downstream intelligence in Keep:** dedup (fingerprint), maintenance windows (CEL), correlation rules, workflow dismiss — rather than duplicating the same logic in VMAlertmanager for the shadow path.
   - Mental model: **VMAlertmanager delivers fidelity to Keep; Keep delivers correlation and enrichment on top.**

4. **Mapping**
   - Learn how Keep mapping rules transform incoming alert fields.
   - Check whether mappings can normalize labels such as `service`, `namespace`, `node`, `pod`, `team`, and `severity`.

   **Findings (initial):**

   - **What mapping is:** per-alert lookup enrichment — matchers (e.g. `service`) join to a CSV row; Keep adds columns from that row as extra alert fields. Not correlation, suppression, or log fetch.
   - **shop-checkout PoC:** [`keep/shop-checkout-mapping.csv`](../examples/keep-shop-checkout-poc/keep/shop-checkout-mapping.csv) maps `labels.service` → `runbook_url`, `owner`, `escalation_tier`; applied by `apply-keep-config.sh` via `POST /mapping` (rule name `shop-checkout-ops`). Matcher uses nested path because VictoriaMetrics webhook ingest does not promote `labels.service` to top-level `service` at enrichment time (Keep 0.52.x).
   - **Overlap with topology:** topology already has `team` and `display_name` per service; mapping adds ops fields (runbook link, on-call, tier) without duplicating the dependency graph.
   - **Does not replace:** topology processor, correlation rules, or Graylog workflows. Alerts still need the matcher key (`service` label) present on the payload.
   - **Higher value later:** normalize weak OOB alerts (node/platform rules) where Prometheus labels lack `team` / `service` — may need extraction (item 5) first to derive matcher keys.
   - Open questions: whether enriched fields surface in notification templates (item 7); override behavior when mapping columns collide with existing alert labels.

   **Findings (shop-checkout PoC, 2026-06-10 — mapping enrichment and UI):**

   - **Mapping works; logs confirm enrichment.** Keep logs show mapping runs on alert ingest. Verified on shop-checkout alerts after `shop-checkout-ops` mapping was installed.
   - **Fields are top-level alert properties, not `labels`.** CSV columns become root keys on the alert DTO: `runbook_url`, `owner`, `escalation_tier`. The Prometheus **`labels`** block is unchanged — so the default alert detail **Labels** section in the UI looks the same even when mapping succeeded.
   - **`enriched_fields` audit list.** Each alert exposes which enrichments were applied, e.g. `['runbook_url', 'owner', 'escalation_tier', 'log_snippet', 'graylog_query', ...]`. Mapping adds the first three; Graylog workflow adds `log_snippet` / `graylog_query`.
   - **Example values (verified via API):**

     | `labels.service` | `runbook_url` | `owner` | `escalation_tier` |
     |------------------|---------------|---------|-------------------|
     | `checkout-demo` | `https://wiki.example/shop/checkout` | `payments-oncall` | `P1` |
     | `payments-api` | `https://wiki.example/shop/payments` | `payments-oncall` | `P1` |
     | `storefront` | `https://wiki.example/shop/storefront` | `payments-oncall` | `P2` |

   - **Verify via API** (not only the UI Labels panel):

     ```bash
     curl -H 'Authorization: Bearer api_key:any-local-key' \
       'http://<keep-api>/alerts/<fingerprint>' | jq '{name, runbook_url, owner, escalation_tier, enriched_fields}'
     ```

   - **Workflows and templates can consume mapping fields.** Enriched top-level keys are available in workflow expressions (e.g. `{{ alert.runbook_url }}`, `{{ alert.owner }}`). Same surface as `enrich_alert` workflow output. Notification template support still to validate under item 7.
   - **UI visibility requires frontend configuration (Keep 0.52.x).** Mapping does not auto-add columns to the alerts table or the Labels panel. Options:
     1. **`ALERT_SIDEBAR_FIELDS`** — frontend env var listing fields to show in the alert detail sidebar (documented in [Keep deployment configuration](https://docs.keephq.dev/deployment/configuration)). PoC sets this in [`values-keep-kind.yaml`](../examples/keep-shop-checkout-poc/values-keep-kind.yaml): default sidebar fields plus `runbook_url`, `owner`, `escalation_tier`, `graylog_query`.
     2. **Alert table column picker** — user-configurable columns in the alerts table UI; arbitrary enriched keys may or may not appear as options.
     3. **No custom Keep fork required** for sidebar fields — configuration only. Custom frontend work only if sidebar/table config is insufficient.
   - **Not retroactive on deduplicated alerts.** Mapping runs at **ingest time** on new alert events. Alerts that fired before mapping was installed, or repeat webhook deliveries deduplicated by Keep (`Alert is deduplicated` → `num_of_alerts: 0`), keep only workflow enrichments (e.g. `log_snippet`) without mapping fields. To see mapping on a service: wait for a fresh firing cycle after mapping exists, or POST a test alert.
   - **PoC test alerts** (`MappingPocTest*`) confirmed mapping end-to-end when sent after rule install.
   - **Resolved open questions (partial):** mapping fields are real and workflow-visible; UI Labels panel alone is misleading for verification. **Still open:** label collision if mapping column names match existing Prometheus labels. Notification templates (SMTP, incident-scoped) validated under item 7.

5. **Extraction**
   - Learn how Keep extraction rules derive structured fields from alert descriptions, labels, or payloads.
   - Check whether extraction can recover useful metadata from current OOB alerts with weak labels.

   **Findings (initial):**

   - **What extraction is:** regex on a single **event attribute** at ingest — named groups become new top-level alert fields. Data source is **only the incoming alert/event** (not CMDB, logs, or CSV). Complements mapping (external lookup) and workflows (provider queries). See [Keep extraction docs](https://docs.keephq.dev/overview/enrichment/extraction).
   - **`pre` flag:** `pre=false` (default) parses the **standardized** Keep alert; `pre=true` parses the **raw provider payload before normalization** (e.g. nested Alertmanager `annotations`, `commonLabels`). Does not make Alertmanager send more data — only accesses webhook fields before Keep flattens/drops them.
   - **Provider-local extraction:** some providers (e.g. Mailgun) define extraction on inbound email keys (`subject`, body) separately from global `POST /extraction` rules.

   **Findings (shop-checkout PoC, 2026-06-10 — extraction vs visibility):**

   - **Compared live:** `GET /v2/alerts` on firing shop alerts vs VMAlertmanager `/api/v2/alerts` for the same fingerprints. For `vmalert → VMAlertmanager → keep-shadow → Keep`, Keep receives and retains almost all **per-alert** AM fields; gaps are mostly **UI visibility**, not missing ingest.
   - **Extraction not needed for shop-checkout.** Rule labels (`service`, `namespace`, `application`, `team`, `severity`, `symptom`, `component`) and annotation `description` are already on the alert DTO. Mapping and Graylog workflow add top-level `runbook_url`, `owner`, `escalation_tier`, `log_snippet`, `graylog_query`. Prefer **`ALERT_SIDEBAR_FIELDS`** in [`values-keep-kind.yaml`](../examples/keep-shop-checkout-poc/values-keep-kind.yaml) for anything already top-level.
   - **Sidebar-first candidates** (present on alert API, not yet in sidebar): `log_snippet`, `generatorURL`, `symptom`, `pod`, `instance`, `startsAt`, `firingStartTime`, `component`.
   - **Buried in nested structure — only edge case for extraction:** `summary` from Prometheus annotations arrives as **`annotations.summary`**, not top-level `summary` (verified: 13/15 local alerts had summary in `annotations`, 0 at top-level). Try `annotations.summary` in `ALERT_SIDEBAR_FIELDS` first; if unsupported, one extraction rule to promote to top-level `summary`, or rely on `description` (already top-level and in sidebar).
   - **In `labels` only:** fields such as `team` / `application` may appear in the **Labels** panel without being top-level; no extraction required — either sidebar if Keep resolves label keys, or accept Labels panel.
   - **Dropped after ingest (not a sidebar fix):** AM group metadata (`externalURL`, `receiver`, `commonLabels`, `groupLabels`) is not persisted in stored `payload` (only `startsAt`, `endsAt`, `generatorURL` retained). Recover only via `pre=true` extraction at ingest if ever needed — not required for shop-checkout.
   - **`message` and `url`:** empty or rarely set on our Prometheus path; low value.

   **OOB / platform alerts (different from shop PoC):**

   - Example `KubernetesPodNotHealthy`: weak labels (`alertgroup`, `alertname`, `exported_namespace`, `exported_pod`, `severity`); no `service` / `team`; description contains rendered template text (`VALUE = …`, `LABELS: map[…]`). No mapping/workflow enrichment until matchers exist.
   - **Prefer fixing `PrometheusRule` labels** over extraction when possible. Extraction from `description` (or `pre=true` on raw webhook) only when metadata is **in text** and cannot be added as labels. Then **mapping** on derived or native keys for owner/runbook.
   - Default OOB rules in [`docs/defaults/alerts.md`](../defaults/alerts.md) often put `node`, `mountpoint`, `VALUE` in description/summary templates but not as structured labels — extraction or rule-template fixes are relevant here, not for shop-checkout.

   **Decision rule (our stack):**

   | Situation | Action |
   |-----------|--------|
   | Field already top-level on alert | Add to `ALERT_SIDEBAR_FIELDS` |
   | Field in `labels` | Labels panel and/or sidebar (no extraction) |
   | Field only in nested `annotations` | Sidebar nested path, or extraction to promote |
   | Metadata in freeform description (OOB) | Fix rule labels, or extraction |
   | Owner/runbook/ops context | Mapping CSV (item 4) |
   | Live logs | Graylog workflow (item 1) |

   - **Resolved for shop-checkout:** extraction rules are **not** required for the PoC; visibility is a frontend config concern. **Still open for platform OOB:** whether extraction from description beats upstream label fixes; whether `pre=true` adds value on our AM webhook shape.

6. **Chain of events and root cause**
   - Check whether Keep can show relationships between alerts inside one incident.
   - Investigate whether Keep can identify one incident as the root cause of another, or only correlate alerts into the same incident.

   **Findings (initial):**

   - Keep is strong at **symptom correlation** (many alerts → one incident) and **context assembly**; it does **not** provide deterministic automated root-cause analysis in open source.
   - Relevant incident UI features ([incident overview](https://docs.keephq.dev/incidents/overview)): related alerts list, involved services, incident activity, **incident timeline** (incident lifecycle — created/updated/resolved/workflow runs, not a causal alert chain), **incident topology** (dependency graph with affected services), link similar incidents.
   - **AI correlation** ([docs](https://docs.keephq.dev/overview/ai-correlation)): ML clustering from historical alerts — **Keep Cloud / Enterprise only**, not OSS.
   - **AI Incident Assistant** ([docs](https://docs.keephq.dev/overview/ai-incident-assistant)): chat on the incident page can suggest root cause from alerts + topology + descriptions — **experimental in OSS**; LLM-assisted, not a built-in RCA engine.

   **Findings (shop-checkout PoC, 2026-06-10 — chain of events and RCA):**

   - **Correlate symptoms — yes.** Rule incident `shopchk-*` and topology incident `Application incident: shop-checkout` both group payments + checkout + storefront alerts. Correlation answers “one outage?” not “which service caused it?”
   - **Alert relationships inside an incident — partial.** Keep shows a **flat list** of linked alerts (name, service, severity, status, `startsAt`). No native parent/child alert graph, no “root alert” badge, no automatic causal ordering. Operators can sort by `startsAt` or `firingStartTime`, but that is a weak signal (recovery/re-fire cycles can reorder timestamps vs real causality).
   - **Topology-assisted RCA — human-in-the-loop.** With [`keep/topology.yaml`](../examples/keep-shop-checkout-poc/keep/topology.yaml) (`storefront → checkout-demo → payments-api`) and **Incident topology** in the UI, upstream dependency direction hints at likely root (e.g. `payments-api` outage → downstream checkout/storefront symptoms). Keep does **not** auto-rank or label upstream services as root cause — interpretation only. See item 2 for leaf-service processor caveat and workaround.
   - **Logs as evidence — yes (item 1).** Graylog `log_snippet` / incident `log_summary` help confirm ordering (`payments_outage_started` before `payment_charge_failed`) — supporting evidence for humans or AI assistant, not built-in RCA.
   - **Cross-incident root cause — no.** “Link similar incidents” connects recurring/related incidents; there is **no** documented parent/child model (“incident A caused incident B”) or incident hierarchy in OSS.
   - **VMAlertmanager inhibition (item 3) is separate.** AM `inhibit_rules` suppress causal child alerts on **ops routes**; Keep shadow should stay permissive so correlation/RCA context retains symptom alerts. Keep itself does not replace AM inhibition for causal mute.

   **What Keep does vs does not do (OSS):**

   | Expectation | Keep OSS |
   |-------------|----------|
   | Group related alerts into one incident | **Yes** — correlation rules + topology processor |
   | Show all symptoms + involved services | **Yes** |
   | Topology map on incident | **Yes** — dependency visualization |
   | Chronological alert causality chain | **No** — flat list; time sort only |
   | Auto-identify root-cause alert | **No** |
   | One incident as root cause of another | **No** — similar-incident linking only |
   | Deterministic RCA from topology edges | **No** — visual aid only |
   | AI-suggested RCA | **Partial** — Incident Assistant (experimental OSS / Enterprise) |

   **Practical RCA workflow (shop-checkout):**

   1. Open `shopchk-*` or topology incident.
   2. Check **incident topology** — upstream service in the dependency chain (after leaf-service fix, include `payments-api`).
   3. Review **related alerts** — `PaymentsApiUnavailable` vs downstream `CheckoutDemo*` / `Storefront*`.
   4. Check **log enrichments** — outage start / charge-failure ordering.
   5. On a clean wave, compare alert `startsAt` (recover → wait → re-trigger — see item 2 notes).

   - **Resolved for shop-checkout:** Keep helps RCA **indirectly** (one pane of glass, topology, logs, timestamps); it does **not** auto-pick root cause. **Still open:** whether Enterprise AI correlation/assistant is worth it; whether custom workflows could tag a “probable root” field from topology + `startsAt` rules.

7. **Notification templates**
   - Check template support for Jira, webhooks, and other notification targets.
   - Validate whether templates can include incident summaries, correlated alerts, labels, links, and runbook context.

   **Findings (initial):**

   - Keep “templates” are **workflow `with` blocks** plus Mustache context (`{{ alert.* }}`, `{{ incident.* }}`, `{{ steps.* }}`), executed via provider actions — not VMAlertmanager `email.tmpl` files. See [workflow syntax](https://docs.keephq.dev/workflows/syntax/overview) and provider docs (SMTP, Jira, Slack, Teams, Webex, webhook).
   - Mapping-enriched fields (`runbook_url`, `owner`, `escalation_tier`) and Graylog enrichments (`log_snippet` on alerts, `log_summary` on incidents) are available in templates **when present on the DTO at trigger time**.

   **Findings (shop-checkout PoC, 2026-06-11 — SMTP, one email per incident):**

   - **PoC artifacts:** Mailpit in `keep` namespace ([`k8s/mailpit.yaml`](../examples/keep-shop-checkout-poc/k8s/mailpit.yaml)), SMTP provider + workflow via [`keep/apply-keep-config.sh`](../examples/keep-shop-checkout-poc/keep/apply-keep-config.sh), verify with [`keep/test-smtp-notification.sh`](../examples/keep-shop-checkout-poc/keep/test-smtp-notification.sh). Mailpit UI: `kubectl -n keep port-forward svc/mailpit 18025:8025` → `http://127.0.0.1:18025/`.
   - **Per-alert vs per-incident:** `type: alert` trigger → one email per firing alert (noisy during outages). **`type: incident` + `events: [created]`** → one email per correlated incident — verified: payments outage produced **1** email (`[critical] shopchk-8 - shop-checkout outage in shop`) while 3+ alerts linked to the incident.
   - **Rule + topology emails (two workflows):** **Rule** `shopchk-*` → `smtp-notification-workflow.yaml`, trigger **`created`** only. **Topology** `Application incident: shop-checkout` → `smtp-topology-notification-workflow.yaml`, trigger **`updated`** only; **one email per firing episode** guarded by **`topology_smtp_sent`** read via workflow HTTP step `GET http://keep-backend:8080/incidents/{id}` (`steps.fetch-incident-enrichment.results.body.topology_smtp_sent` — API uses SQL join). Clear/set flag via `POST .../enrich`. Do not use `incident.enrichments.*` in `if` (workflow pre-load still broken — hyphenless write vs hyphenated read). **Spam root cause (2026-06-11):** same fingerprint mismatch; HTTP fetch is the workflow-only workaround. Use quoted string comparison (bare `{{ incident.incident_type == 'rule' }}` renders empty and fails).
   - **Template keys must exist in context:** Keep fails the action if the template references missing keys (e.g. `alert.*` on incident `created` — no alert context; `incident.log_summary` before Graylog enrichment runs). Use **incident-only fields** at `created` (`user_generated_name`, `severity`, `status`, `alerts_count`, `services`, `rule_name`, `id`) or trigger on `updated` after enrichments with a `notification_sent` guard.
   - **Manual `/workflows/{id}/run`:** still uses `AlertDto` (`incident` null) — `if` and incident templates do not work for manual test; rely on real incident events or future Keep API for incident-scoped manual runs.
   - **Topology one-shot pattern (2026-06-08):** HTTP step fetches incident JSON; send if `topology_smtp_sent != 'true'`; `POST /enrich` clears flag on resolve and sets flag after send. Per-incident state (safe for multiple topology apps). PoC auth: `consts.keep_api_auth` = Basic `api_key:any-local-key`.
   - **Human-readable email (2026-06-11):** Keep function syntax is `keep.join({{ incident.services }}, ', ')` (arguments in `{{ }}`, not the whole expression). Status via `keep.lowercase(keep.replace({{ incident.status }}, 'IncidentStatus.', ''))`; scope via `rule_fingerprint` (`shop-checkout / namespace shop`). Clickable link: `consts.keep_ui_base` + `/incidents/{{ incident.id }}`. Duplicate guard: `incident.enrichments.notification_sent`.
   - **Still open:** Jira/Webex/Slack providers not exercised in shop-checkout PoC (SMTP only); richer templates with `alert.*` + `log_summary` via `updated` trigger; whether VMAlertmanager email templates remain primary for ops and Keep workflows only for incident-shaped notifications.

   **Jira ticket + messenger notification (cross-team concern, 2026-06-08):**

   Common production symptom: Alertmanager (or equivalent) raises an alert; a ticketing integration creates a Jira issue; a separate channel (Webex, Slack, email) notifies on-call — but the **messenger message has no ticket key or link**. This is usually **architecture or template misconfiguration**, not Jira withholding the id.

   **Why it happens without Keep (Alertmanager-style stacks):**

   - Receivers are **independent, parallel channels**. `jira_configs`, `webex_configs`, `slack_configs`, etc. each get the **same alert payload**. Alertmanager does **not** wait for Jira to return `PROJ-123` and inject it into the Webex template.
   - **Different systems** on the same alert (custom ITSM script + messenger webhook) with **no shared state** between them.
   - **Timing:** messenger fires on first alert; ticket creation is async or seconds later.
   - **Template gap:** Webex body never references a ticket field even when a ticket exists.
   - **Grouping mismatch:** messenger uses raw alert text; ticketing uses group/dedup logic — they diverge.

   **Would Keep have the same issue?**

   - **Yes**, if wired like Alertmanager: two workflows both on `incident:created` (or `alert:firing`) — one creates Jira, one sends Webex — with **no ordering guarantee**.
   - **No**, if one workflow runs **sequentially**: Jira action → enrich → notify in the same run, using `{{ steps.<jira-action>.results.issue.key }}` / `results.ticket_url` in the messenger template. See [Keep Jira provider](https://docs.keephq.dev/providers/documentation/jira-provider) (`enrich_alert` with `ticket_id`, `ticket_url`; later actions use `{{ alert.ticket_id }}`).

   **Recommended Keep pattern:**

   1. **Single workflow, ordered actions:** `create-jira` → `enrich_alert` or `enrich_incident` (`ticket_id`, `ticket_url`) → `notify` (Webex/SMTP/Slack) in the **same** workflow run. Reference ticket via `steps.*.results`, not a parallel workflow.
   2. **Split workflows only with a bridge:** workflow A creates Jira and enriches; workflow B triggers on `incident:updated` and sends only when ticket enrichment exists — same guard pattern as `topology_smtp_sent` / `notification_sent` (HTTP `GET /incidents/{id}` if `incident.enrichments.*` in `if` is unreliable — see topology SMTP notes above).
   3. **Explicit policy when Jira fails:**
      - **Fail closed:** `if` requires non-empty ticket before notify — no messenger ping without Jira.
      - **Fail open:** first notify with Keep incident link only; follow-up `updated` workflow adds Jira link when ticket appears.
   4. **Never** notify on `incident:created` with `{{ incident.ticket_id }}` if Jira runs on a different trigger or parallel workflow — field will be empty at send time.
   5. Include **both** links in templates when possible: `ticket_url` (Jira) and `consts.keep_ui_base`/incidents/`{{ incident.id }}` (Keep).

   **If Jira does not return ticket id:**

   | Scenario | Typical outcome |
   |----------|-----------------|
   | Jira API error / timeout | Jira action fails; workflow run fails unless handled — notify should not run if guarded by `if` on `steps.*.results` |
   | Jira succeeds, parallel notify workflow | Same bug as today — empty ticket in messenger |
   | Template references missing key | Keep **fails the action** (strict) — better than silent empty field |
   | Jira succeeds, sequential notify with `steps.*` | Ticket key + URL in messenger |

   **Questions to ask the other team (likely misconfiguration checklist):**

   1. Are Jira and Webex triggered **in parallel** from the same Alertmanager receiver (or two automations on the same alert event)?
   2. Does the Webex template **define** a placeholder for ticket key/URL?
   3. Is ticket creation **async** relative to the first messenger notification?
   4. If using Keep: are Jira and notify in **one workflow** or two independent `created` workflows?

   **PoC note:** shop-checkout validated SMTP + enrichment guards only; Jira/Webex providers were not deployed on Kind. The sequential-workflow recommendation follows Keep docs and the same ordering lessons as topology SMTP (downstream step must see upstream result before send).

8. **Keep as event or alert handler**
   - Validate the `vmalert -> VMAlertmanager -> Keep` path.
   - Check whether `vmalert -> Keep` directly is possible and desirable.
   - Define operational risks, fallback behavior, and ownership if Keep becomes part of the primary alert handling path.

   **Findings (initial):**

   - **Supported alert path:** `vmalert → VMAlertmanager → webhook (keep-shadow) → Keep`. This matches [Keep VictoriaMetrics provider docs](https://docs.keephq.dev/providers/documentation/victoriametrics-provider) and local PoC (`api_key` basic auth to `/alerts/event/victoriametrics`).
   - **`vmalert → Keep` direct (standard path):** not a drop-in replacement for VMAlertmanager. vmalert pushes to Alertmanager’s `/api/v2/alerts` API; Keep expects Alertmanager **outbound webhook** payloads on `/alerts/event/victoriametrics`.
   - **Alternatives without VMAlertmanager:** Keep workflows with the VictoriaMetrics provider (query metrics, create alerts inside Keep) or `POST /event` with custom payloads — different model, not consumption of existing `PrometheusRule` / VMAlert fires.
   - **Why keep VMAlertmanager:** HA dedup when vmalert has multiple replicas; routing to multiple receivers; optional structural inhibition on *ops* routes while Keep shadow stays permissive (see item 3).
   - **Desirable default:** VMAlertmanager with **minimal suppressions on the Keep shadow route**; heavier noise control in Keep (dedup, maintenance, correlation) or on primary notification receivers only.

## Current Local PoC Context

- Keep receives alerts through the Prometheus/Alertmanager **webhook** (`vmalert → VMAlertmanager → keep-shadow → Keep`). Step-by-step config: [`keep-shop-checkout-poc/README.md` — VMAlertmanager → Keep](../examples/keep-shop-checkout-poc/README.md#vmalertmanager--keep-alert-webhook); manifest: `k8s/vmalertmanager-keep-shadow.yaml`.
- VMAlertmanager is configured with a shadow receiver named `keep-shadow`; **keep AM suppression light on that route** so Keep sees symptom alerts for correlation (see item 3).
- Service-side correlation was demonstrated with `checkout-demo`, where one service behavior change produced multiple alerts that Keep grouped into one incident.
- Real OOB alert correlation was demonstrated with node disk usage alerts grouped into a node-level disk pressure incident.
- **shop-checkout PoC** ([`docs/examples/keep-shop-checkout-poc/`](../examples/keep-shop-checkout-poc/)): three-service app (`storefront` → `checkout-demo` → `payments-api`), manual Keep topology YAML, CSV mapping (`runbook_url`, `owner`, `escalation_tier` on top-level alert fields — see item 4), `ALERT_SIDEBAR_FIELDS` in `values-keep-kind.yaml` for UI sidebar visibility (extraction not needed for shop alerts — see item 5), Graylog log enrichment workflow, topology/rule correlation for symptom grouping (RCA is human/AI-assisted, not automatic — see item 6), and Kind logging stack (OpenSearch + logging-operator). Reproduce with `keep/apply-keep-config.sh` and `validate.sh`.
