# Keep evaluation package (shop-checkout on Kind)

Self-contained artifacts for the Keep evaluation ([issue #330](https://github.com/Netcracker/qubership-monitoring-operator/issues/330)).

## Contents

| Path | Purpose |
|------|---------|
| [`../examples/keep-shop-checkout-poc/`](../examples/keep-shop-checkout-poc/) | **Runnable example** — shop app, rules, Keep/Graylog overlays, workflows, scripts |
| [`follow-up-checklist.md`](follow-up-checklist.md) | Validation findings (8 topics), workarounds, open questions |
| [`presentation.md`](presentation.md) | Team presentation source (Marp markdown) |

**Not in git (generated locally):** `presentation.pptx`, `presentation.pdf` — export from `presentation.md` with [Marp](https://marketplace.visualstudio.com/items?itemName=marp-team.marp-vscode) or `marp-cli`.

## Quick start

```bash
cd docs/examples/keep-shop-checkout-poc

# 1. Shop app + monitoring rules
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/

# 2. Logging stack (optional, for log enrichment)
./deploy-logging.sh

# 3. Keep on Kind (ingress + bundled PostgreSQL)
./deploy-keep-ingress-kind.sh
# /etc/hosts: 127.0.0.1 keep.local

# 4. VMAlertmanager → Keep webhook (after Keep backend is up)
kubectl apply -f k8s/vmalertmanager-keep-shadow.yaml

# 5. Keep topology, rules, mapping, workflows
KEEP_API_URL=http://keep.local:30080/v2 ./keep/apply-keep-config.sh

# 6. End-to-end validation
./validate.sh
```

See the [example README](../examples/keep-shop-checkout-poc/README.md) for failure playbook, SMTP/Mailpit, VMAlertmanager webhook details, and troubleshooting.

## External dependencies (not in this repo)

These are installed separately on Kind; the example documents versions and values overlays:

- Keep Helm chart (`keephq/keep`) — `values-keep-kind-postgres.yaml` (default); optional `values-keep-kind.yaml` (SQLite PVC)
- qubership-logging-operator + OpenSearch — `values-logging-kind.yaml`, `values-opensearch-kind.yaml`
- VMAlert / VMAlertmanager / vmagent (from monitoring-operator stack)
- Mailpit — `k8s/mailpit.yaml` (in-namespace SMTP catcher for item 7)

## File inventory (`keep-shop-checkout-poc/`)

| Directory | Files |
|-----------|--------|
| `k8s/` | shop app (3 services), ServiceMonitors, PrometheusRules, Mailpit, VMAlertmanager keep-shadow |
| `keep/` | topology, correlation rules, mapping CSV, Graylog alert + integrated SMTP workflows, optional Aurora stub, `apply-keep-config.sh` |
| root | Kind Helm overlays, `shop-control.sh`, deploy/validate/port-forward scripts, README |
