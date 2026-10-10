#!/usr/bin/env bash
# Generate a password for the Grafana admin user and seal it as monitoring/grafana-admin
# (keys admin-user, admin-password), which the monitoring chart is pointed at with
# grafana.admin.existingSecret.
#
# Run from the repo root with kubectl pointing at the cluster. The password is never printed,
# it is written to secrets/grafana-admin-password (gitignored).
set -euo pipefail
umask 077

GRAFANA_USER="admin"
OUT=sealed-secrets/sealed-grafana-admin.json
KUBESEAL=(kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system -o json)

cd "$(git rev-parse --show-toplevel)"
git check-ignore -q secrets/grafana-admin-password || {
  echo "secrets/ is not gitignored, refusing to write the password there" >&2
  exit 1
}

PW="$(openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-40)"
[ "${#PW}" -eq 40 ] || {
  echo "password generation failed" >&2
  exit 1
}
printf '%s\n' "$PW" >secrets/grafana-admin-password

printf '%s' "$PW" |
  kubectl create secret generic grafana-admin --namespace monitoring \
    --from-literal=admin-user="$GRAFANA_USER" \
    --from-file=admin-password=/dev/stdin --dry-run=client -o json |
  "${KUBESEAL[@]}" >"$OUT"

unset PW

printf '%s: ' "$OUT"
kubeseal --validate --controller-name sealed-secrets-controller --controller-namespace kube-system <"$OUT" &&
  echo ok

echo
echo "User is '$GRAFANA_USER', the password is in secrets/grafana-admin-password."
echo "Move it to the password manager and delete the file."
echo "After the change is merged and synced, restart Grafana to pick the password up:"
echo "  kubectl -n monitoring rollout restart deploy/monitoring-grafana"
