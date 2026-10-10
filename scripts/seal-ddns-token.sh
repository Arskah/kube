#!/usr/bin/env bash
# Seal the DigitalOcean API token of the ddns CronJob as ddns/digitalocean-token (key token).
# The token needs the custom scopes domain:read and domain:update, nothing else.
#
# Run from the repo root with kubectl pointing at the cluster. The token is read from a hidden
# prompt and is never printed or written to disk.
set -euo pipefail

DOMAINS=(aarnihalinen.fi halinen.dev)
OUT=sealed-secrets/sealed-ddns-digitalocean-token.json
KUBESEAL=(kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system -o json)

cd "$(git rev-parse --show-toplevel)"

read -rsp "DigitalOcean API token: " TOKEN
echo
[ -n "$TOKEN" ] || {
  echo "no token given" >&2
  exit 1
}

# Check that the token can read the records the job is going to manage.
for domain in "${DOMAINS[@]}"; do
  count="$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "https://api.digitalocean.com/v2/domains/$domain/records?type=A&name=$domain" |
    jq '.domain_records | length')"
  [ "$count" = 1 ] || {
    echo "$domain: expected one apex A record, found $count" >&2
    exit 1
  }
  echo "$domain: token can read the apex A record"
done

printf '%s' "$TOKEN" |
  kubectl create secret generic digitalocean-token --namespace ddns \
    --from-file=token=/dev/stdin --dry-run=client -o json |
  "${KUBESEAL[@]}" >"$OUT"

unset TOKEN

printf '%s: ' "$OUT"
kubeseal --validate --controller-name sealed-secrets-controller --controller-namespace kube-system <"$OUT" &&
  echo ok
