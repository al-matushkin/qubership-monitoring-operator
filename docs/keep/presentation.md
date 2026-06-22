---
marp: true
theme: default
paginate: true
title: Keep PoC — Findings for the Team
description: Shop-checkout Kind PoC — what Keep can do and what it solves for us
style: |
  section { font-size: 30px; }
  section.compact { font-size: 26px; }
  section.compact li { margin-bottom: 0.08em; }
  section table { font-size: 22px; }
  section li { margin-bottom: 0.15em; }
---

## Agenda

1. Log enrichment
2. Service topology & correlation
3. Suppression vs Alertmanager
4. Mapping (runbook / owner)
5. Extraction
6. Root cause & alert chains (+ optional Aurora RCA)
7. Notifications (SMTP, Jira, messengers)
8. Integration path (`vmalert → Keep`)

**+ Side notes:** quirks, workarounds, open questions, recommendations

---

## Why we evaluated Keep

- **Alert storm** → one correlated incident
- **Scattered context** → logs, runbooks, topology in one place
- **Ticket + messenger gap** → sequential workflows with shared state
- **RCA** → human-in-the-loop with topology + logs

**PoC:** 3-service `shop-checkout` on Kind (Graylog, VMAlert, Keep)

---

## Architecture we validated

```
vmalert (PrometheusRules)
  → VMAlertmanager
      → keep-shadow (light filtering)  →  Keep
      → primary ops routes (email, etc.) →  on-call / tickets
```

**Recommendation:** Keep on a **shadow route** — VMAlertmanager stays; Keep adds correlation & enrichment downstream.

**Not validated as primary path:** `vmalert → Keep` direct (Keep expects Alertmanager webhook format).

---

# 1. Log enrichment

---

## Log enrichment — findings

- **Explicit** — provider + workflow, not automatic
- **Alerts:** Graylog → `log_snippet` (per-alert workflow)
- **Incidents:** `log_summary` on rule `created` — wait until `alerts_count ≥ 2`
- Join keys: `service`, `namespace`, `pod`

**Solves:** log evidence on the incident — faster triage

**Recommendation:** rollup on **rule** incidents, not topology `updated`

---

# 2. Topology & correlation

---

## Topology — findings

- Service graph (YAML or providers) + **topology processor** → one app-level incident
- **Correlation rules** also group by labels (`application=shop-checkout`)
- Alerts need a `service` label matching the graph

**PoC:** 3-service cascade → **one rule incident** (`shopchk-*`) + optional topology view (`Application incident: shop-checkout`)

**Solves:** one checkout outage view, not 3+ separate fires

---

<!-- class: compact -->

## Topology — rule vs topology

| | Rule incident (`shopchk-*`) | Topology incident |
|---|---------------------------|-------------------|
| Source | `correlation-rules.json` | Topology processor |
| Workflows | SMTP, Graylog rollup, Aurora (optional) | Graph + linked alerts (no workflows in PoC) |
| Trigger | `incident:created` | Processor ticks (~10s) |

**Recommendation:** run notifications and enrichment on **rule** incidents; use topology for the dependency graph.

**Ops split:** rule = actions; topology = visualization

---

## Topology — caveats (graph)

- **Leaf services:** no outgoing edge → may miss topology incident  
  → synthetic dependency (`payments-api → external-psp`)
- **One incident per app** — same id reused across waves
- **Sources:** manual YAML now; Cilium/Hubble later

---

## Topology — caveats (ops)

- **Don't manual-resolve** while Alertmanager still firing
- **Cascade:** stagger symptoms (~10–20s) to avoid duplicate `shopchk-*`
- **Recover:** all three services; wait ~60s for AM resolved webhooks

---

# 3. Suppression & inhibition

---

## Suppression — findings

| | VMAlertmanager | Keep |
|---|----------------|------|
| Inhibition | Yes | No |
| Silences | Yes | Maintenance windows |
| Symptoms | Can hide | Correlates |

- **`keep-shadow`:** light filtering — Keep needs symptom alerts
- **Ops routes:** can keep stronger inhibition/grouping

**Solves:** noise control without starving Keep of correlation context

---

# 4. Mapping (CSV lookup)

---

## Mapping — findings

- CSV on `service` → `runbook_url`, `owner`, `escalation_tier` (top-level fields)
- **PoC:** all 3 shop services enriched; usable in workflows & templates
- UI: set `ALERT_SIDEBAR_FIELDS` — Labels panel alone hides them

**Solves:** runbook + owner on alerts without changing Prometheus rules

---

# 5. Extraction

---

## Extraction — findings

- Regex at ingest → new top-level fields (`pre=true` for raw webhook)
- **Shop-checkout:** not needed — labels already sufficient
- **Platform OOB:** prefer fixing rule labels; extract from description only as fallback

**Solves:** weak-label platform alerts later; sidebar config covers shop-checkout today

---

# 6. Root cause & alert chains

---

## Root cause — findings

**Keep OSS does:** group alerts, topology map, logs, time-sorted list  
**Does not:** auto root-cause, parent/child alerts, incident hierarchy

**Practical RCA:** topology → alert names → logs → `startsAt`

**Optional:** Aurora stub — wait ≥2 alerts → enrich `rca_summary` / `root_cause`

**Solves:** one triage pane — RCA human unless external engine added

---

## Aurora RCA — enrich-back (optional)

```
shopchk-* created → wait (alerts_count ≥ 2)
                 → Graylog + Aurora poll → enrich incident
```

- Kind **stub** only — not production Aurora
- Use `mock` + `enrich_incident` (not HTTP `force: true`)
- Production: set `incident_url` for Keep External incident link

**Solves:** Keep as hub + RCA sidecar (same idea as Jira → notify)

---

# 7. Notifications

---

## Notifications — findings

- Workflows + providers (SMTP, Jira, Webex, …); templates use `{{ incident.* }}`, `{{ steps.* }}`
- **PoC (SMTP):** **rule incidents** (`shopchk-*` on `created`) — 1 email per incident, not per alert
- Topology incident: visualization only — same notification pattern as other enrichments (rule-first)
- Emails include Keep incident link, services, severity

**Solves:** incident-shaped notifications — less noise than per-alert email

---

## Jira + messenger

**Problem:** Webex/Slack has no Jira link — parallel receivers, no shared state.

**Fix:** one sequential workflow:

```
create Jira → enrich ticket_url → notify (Webex/SMTP)
```

**Avoid:** two workflows on `incident:created` (race).

*Not deployed in PoC — pattern from Keep docs.*

---

# 8. Integration path

---

## Integration path — findings

**Validated:** `vmalert → VMAlertmanager → keep-shadow → Keep`

- Keeps VMAlertmanager HA, routing, ops-route inhibition
- **Webhook path:** `/alerts/event/prometheus` — promotes `application`, `namespace`, `service` to top-level (required for CEL rules)
- **Not recommended:** `/alerts/event/victoriametrics` or `vmalert → Keep` direct

**Solves:** add Keep without replacing VMAlertmanager

---

# Side notes

---

<!-- class: compact -->

## Known quirks (workflows)

- Enrichment in `if` → HTTP `GET /incidents/{id}`
- `contains` in `if` broken → use `== 'IncidentStatus.FIRING'`
- Partial enrich → `mock` + `enrich_incident`, not HTTP `force: true`
- Correlation race → stagger cascade; `gunicorn --workers 1` on Kind

---

<!-- class: compact -->

## Known quirks (ops)

- Leaf topology → synthetic outgoing dependency
- Stale incident → don't resolve while AM firing; wait ~60s after recover
- Mapping hidden in UI → `ALERT_SIDEBAR_FIELDS`
- Platform K8s alerts → separate rules (node, deployment)

---

<!-- class: compact -->

## What Keep solves — summary

| Problem | Answer | Status |
|---------|--------|--------|
| Alert storm | One `shopchk-*` incident | In PoC |
| Logs / owner | Graylog + CSV mapping | In PoC |
| App view | Topology + rule incident | In PoC |
| Noisy email | Per-incident SMTP | In PoC |
| Ticket in messenger | Jira → notify | Planned |
| Auto RCA | Human; optional Aurora | Partial |
| Replace AM | Shadow route | In PoC |
| K8s noise | Platform rules | Planned |

---

## Recommended phasing (1/2)

1. **Now:** `keep-shadow` + correlation rules + mapping CSV
2. **Next:** Graylog + SMTP on rule `created` (wait-for-cascade)
3. **Later:** Topology provider or YAML; platform K8s rules

---

## Recommended phasing (2/2)

4. **Optional:** External RCA (Aurora) enrich-back on rule incidents
5. **Per app:** Manual topology for 1–2 pilots

**Labels:** `service`, `namespace`, `application` + **`/prometheus` webhook**

---

<!-- class: compact -->

## Open questions

- Topology in prod: manual vs Cilium vs inventory-tool?
- Upstream Keep fixes (leaf services, enrichment)?
- Enterprise AI vs external RCA (Aurora)?
- Platform rules: group by node / deployment?
- Auto-tag probable root in workflow?

---

<!-- class: compact -->

## Takeaways (1/2)

1. Keep = **correlation + enrichment** on VMAlertmanager — not a replacement
2. **Wins:** one rule incident, logs + runbooks, incident-shaped email
3. **Rule vs topology:** workflows on rule; graph for dependencies

---

<!-- class: compact -->

## Takeaways (2/2)

4. **RCA:** human in OSS; optional Aurora enrich-back
5. **Notify:** sequential workflows (Jira → messenger; enrich then email)
6. **Labels:** `service` unlocks topology, mapping, logs; use Prometheus webhook
