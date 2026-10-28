#!/usr/bin/env bash
# Seal the token of the Forgejo runner as forgejo-runner/forgejo-runner-token (key token), and write
# the UUID of the runner into its config in forgejo-runner/runner.yml.
#
# Create the runner in the Forgejo user settings of arska (Settings -> Actions -> Runners), not in
# Site Administration: a runner of the instance takes jobs from every repo on the forge, and jobs
# get a Docker daemon. Forgejo shows the UUID and the token once.
#
# Run from the repo root with kubectl pointing at the cluster. The token is read from a hidden
# prompt and is never printed or written to disk. The UUID is not secret.
set -euo pipefail

OUT=sealed-secrets/sealed-forgejo-runner-token.json
CONFIG=forgejo-runner/runner.yml
KUBESEAL=(kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system -o json)

cd "$(git rev-parse --show-toplevel)"

read -rp "Runner UUID: " UUID
[[ "$UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
  echo "not a UUID: $UUID" >&2
  exit 1
}

read -rsp "Runner token: " TOKEN
echo
[ -n "$TOKEN" ] || {
  echo "no token given" >&2
  exit 1
}

printf '%s' "$TOKEN" |
  kubectl create secret generic forgejo-runner-token --namespace forgejo-runner \
    --from-file=token=/dev/stdin --dry-run=client -o json |
  "${KUBESEAL[@]}" >"$OUT"

unset TOKEN

printf '%s: ' "$OUT"
kubeseal --validate --controller-name sealed-secrets-controller --controller-namespace kube-system <"$OUT" &&
  echo ok

# sed -i differs between GNU and BSD, so go through a temporary file
tmp="$(mktemp)"
sed -E "s/^( +uuid:).*/\1 $UUID/" "$CONFIG" >"$tmp"
cat "$tmp" >"$CONFIG"
rm "$tmp"
printf '%s: uuid %s\n' "$CONFIG" "$(grep -E '^ +uuid:' "$CONFIG" | awk '{print $2}')"
