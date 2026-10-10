#!/usr/bin/env bash
# Seal the SMTP password Alertmanager sends mail with as monitoring/alertmanager-smtp (key
# password). The server and the user are not secret and are set in apps/templates/monitoring.yml;
# they are read from there, so that the check below uses what Alertmanager is going to use.
#
# Run from the repo root with kubectl pointing at the cluster. The password is read from a hidden
# prompt and is never printed or written to disk.
set -euo pipefail

OUT=sealed-secrets/sealed-alertmanager-smtp.json
KUBESEAL=(kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system -o json)

cd "$(git rev-parse --show-toplevel)"

GLOBAL='.spec.source.helm.valuesObject.alertmanager.config.global'
SMARTHOST="$(yq "$GLOBAL.smtp_smarthost" apps/templates/monitoring.yml)"
SMTP_USER="$(yq "$GLOBAL.smtp_auth_username" apps/templates/monitoring.yml)"

read -rsp "SMTP password or token of $SMTP_USER at $SMARTHOST: " PASSWORD
echo
[ -n "$PASSWORD" ] || {
  echo "no password given" >&2
  exit 1
}

# Log in without sending anything. The credentials go to curl on stdin, not on the command line.
# The verbose log is only searched for the server's "235 authenticated" answer and never printed,
# because it contains the credentials.
log="$(printf 'user = "%s:%s"\n' "$SMTP_USER" "$PASSWORD" |
  curl -sv --ssl-reqd --max-time 20 -K - "smtp://$SMARTHOST" 2>&1 >/dev/null || true)"
grep -q '^< 235' <<<"$log" || {
  echo "login to $SMARTHOST as $SMTP_USER failed" >&2
  exit 1
}
unset log
echo "login to $SMARTHOST as $SMTP_USER works"

printf '%s' "$PASSWORD" |
  kubectl create secret generic alertmanager-smtp --namespace monitoring \
    --from-file=password=/dev/stdin --dry-run=client -o json |
  "${KUBESEAL[@]}" >"$OUT"

unset PASSWORD

printf '%s: ' "$OUT"
kubeseal --validate --controller-name sealed-secrets-controller --controller-namespace kube-system <"$OUT" &&
  echo ok
