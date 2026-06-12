---
marp: true
theme: default
paginate: true
title: Keep PoC — Findings for the Team
description: Shop-checkout Kind PoC — what Keep can do and what it solves for us
style: |
  section { font-size: 30px; }
  section table { font-size: 24px; }
  section li { margin-bottom: 0.15em; }
---

## Agenda

1. Log enrichment
2. Service topology & correlation
3. Suppression vs Alertmanager
4. Mapping (runbook / owner)
5. Extraction
6. Root cause & alert chains
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

- Enrichment is **explicit** (provider + workflow), not automatic
- **PoC:** Graylog provider → `log_snippet` on alerts, `log_summary` on incidents
- Join keys: `service`, `namespace`, `pod` (+ time around `startsAt`)

**Solves:** log evidence on the incident — faster triage & RCA

---

# 2. Topology & correlation

---

## Topology — findings

- Service graph (YAML or providers) + **topology processor** → one app-level incident
- **Correlation rules** also group by labels (`application=shop-checkout`)
- Alerts need a `service` label matching the graph

**PoC:** 3-service outage → **one incident** (`shopchk-*` + topology views)

**Solves:** one checkout outage view, not 3+ separate fires

---

## Topology — caveats

- **Leaf services:** no outgoing edge → alerts may miss topology incident  
  → workaround: synthetic dependency (`payments-api → external-psp`)
- **One incident per app** — same id reused across waves
- **Don't manual-resolve** while Alertmanager still firing
- **Sources:** manual YAML now; Cilium/Hubble / inventory-tool later

**Ops split:** rule incidents for grouping; topology for app-level view

---

# 3. Suppression & inhibition

---

## Suppression — findings

| | VMAlertmanager | Keep |
|---|----------------|------|
| Inhibition | ✅ | ❌ |
| Silences | ✅ | Maintenance windows |
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

**Keep OSS does:** group alerts, topology map, log evidence, time-sorted alert list  
**Keep OSS does not:** auto root-cause, alert parent/child graph, incident hierarchy

**Practical RCA:** topology (upstream) → alert names → log ordering → `startsAt`

**Solves:** one triage pane — RCA stays human, not automated

---

# 7. Notifications

---

## Notifications — findings

- Workflows + providers (SMTP, Jira, Webex, …); templates use `{{ incident.* }}`, `{{ steps.* }}`
- **PoC (SMTP):** 1 email per incident (not per alert); topology guarded by `topology_smtp_sent`
- Emails include Keep incident link, services, severity

**Solves:** incident-shaped notifications — less noise than per-alert email

---

## Jira + messenger (cross-team concern)

**Symptom today:** Webex/Slack message has **no Jira ticket** — usually parallel Alertmanager receivers with **no shared state**, not Jira hiding the id.

**Keep fix:** **One sequential workflow**

```
create Jira → enrich (ticket_id, ticket_url) → notify (Webex/SMTP)
```

Use `{{ steps.create-jira.results.ticket_url }}` in the same run.

**Avoid:** two workflows both on `incident:created` — same race as Alertmanager.

*Jira/Webex not deployed in PoC — pattern from Keep docs + same ordering lessons as topology SMTP.*

---

# 8. Integration path

---

## Integration path — findings

**Validated:** `vmalert → VMAlertmanager → keep-shadow → Keep`

- Keeps VMAlertmanager HA, routing, ops-route inhibition
- **Not recommended:** `vmalert → Keep` direct (different API)

**Solves:** add Keep without replacing VMAlertmanager

---

# Side notes

---

## Known quirks & workarounds

- Enrichment in `if` (UUID hyphen bug) → HTTP `GET /incidents/{id}`
- `contains` in `if` broken → use `== 'IncidentStatus.FIRING'`
- Leaf topology service → synthetic outgoing dependency
- Stale incident → don't resolve while AM firing; recover → wait ~60s
- Mapping invisible → `ALERT_SIDEBAR_FIELDS`

**PoC:** [`keep-shop-checkout-poc/`](../examples/keep-shop-checkout-poc/)

---

## What Keep solves — summary

| Problem | Answer | Status |
|---------|--------|--------|
| Alert storm | One correlated incident | ✅ |
| Missing logs / owner | Graylog + CSV mapping | ✅ |
| App-level view | Topology + rules | ✅ |
| Noisy email | Per-incident SMTP | ✅ |
| Ticket not in messenger | Jira → notify (sequential) | 📋 |
| Auto RCA | Human + topology/logs | ⚠️ |
| Replace Alertmanager | Shadow route | ✅ |

---

## Recommended phasing

1. **Now:** VMAlertmanager `keep-shadow` + correlation rules + mapping CSV for key apps.
2. **Next:** Graylog (or standard log backend) enrichment workflows; incident notifications (SMTP/Webex).
3. **Later:** Topology YAML maintenance or provider pull (Cilium/Hubble); inventory-tool → Keep graph pipeline.
4. **Per app:** Manual topology for 1–2 pilots; expand if topology incidents prove worth the upkeep.

**Label contract:** Prometheus `service`, `namespace`, `application` must match Keep topology & matchers.

---

## Open questions

- Topology source in prod clouds? (manual vs Cilium vs inventory-tool)
- Upstream Keep fixes (leaf services, enrichment fingerprint)?
- Enterprise AI worth it? Keep vs VMAlertmanager for ops email?
- Auto-tag probable root via workflow rules?

---

## Takeaways for the team

1. **Keep fits as a correlation + enrichment layer** on top of VMAlertmanager — not a replacement.
2. **Biggest wins validated:** one incident per outage, logs + runbooks on the incident, quieter incident emails.
3. **RCA stays human** — Keep assembles context; topology & timestamps guide, not decide.
4. **Notifications need ordering** — Jira then messenger in one workflow fixes the ticket-link gap.
5. **Invest in labels** — `service` on alerts unlocks topology, mapping, and log joins.

**Full detail:** [`follow-up-checklist.md`](follow-up-checklist.md)
