#!/usr/bin/env bash
# Forward Keep ingress to localhost. With "127.0.0.1 keep.local" in /etc/hosts, open http://keep.local/
set -euo pipefail

INGRESS_NS="${INGRESS_NS:-ingress-nginx}"
REMOTE_PORT="${REMOTE_PORT:-80}"
# Default 30080 — port 80 is often taken (other kubectl forwards, local web servers).
LOCAL_PORT="${LOCAL_PORT:-30080}"

if pgrep -f "port-forward -n ${INGRESS_NS} svc/ingress-nginx-controller .*:${REMOTE_PORT}" >/dev/null 2>&1; then
  existing="$(pgrep -af "port-forward -n ${INGRESS_NS} svc/ingress-nginx-controller" | head -1)"
  echo "ingress port-forward already running:"
  echo "  ${existing}"
  echo "Try http://keep.local/ (if LOCAL_PORT=80) or http://keep.local:30080/"
  exit 0
fi

echo "Starting: kubectl port-forward -n ${INGRESS_NS} svc/ingress-nginx-controller ${LOCAL_PORT}:${REMOTE_PORT}"
echo "Keep UI:  http://keep.local:${LOCAL_PORT}/"
echo "Keep API: http://keep.local:${LOCAL_PORT}/v2"
echo "(Leave this terminal open, or run in background with: nohup $0 >/tmp/keep-ingress-pf.log 2>&1 &)"
echo
echo "If the UI redirects to http://keep.local/ (port 80) and fails, run:"
echo "  kubectl -n keep set env deploy/keep-frontend NEXTAUTH_URL=http://keep.local:${LOCAL_PORT}"
exec kubectl port-forward -n "${INGRESS_NS}" svc/ingress-nginx-controller "${LOCAL_PORT}:${REMOTE_PORT}"
