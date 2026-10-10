#!/usr/bin/env bash
# Rotate the password of the docker registry user and seal the five secrets that depend on it:
#   docker-registry/registry-htpasswd       bcrypt hash the registry checks against
#   argocd/regcred-argocd                   pull secret of argocd-image-updater
#   homepage-production/regcred-homepage    pull secret
#   homepage-staging/regcred-homepage       pull secret
#   music-library/regcred                   pull secret
#
# Run from the repo root with kubectl pointing at the cluster. The new password is never printed,
# it is written to secrets/registry-password (gitignored).
set -euo pipefail
umask 077

REGISTRY=registry.aarnihalinen.fi
REGISTRY_USER=arskah
KUBESEAL=(kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system -o json)

cd "$(git rev-parse --show-toplevel)"
git check-ignore -q secrets/registry-password || {
  echo "secrets/ is not gitignored, refusing to write the password there" >&2
  exit 1
}

PW="$(openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-40)"
[ "${#PW}" -eq 40 ] || {
  echo "password generation failed" >&2
  exit 1
}
export PW
printf '%s\n' "$PW" >secrets/registry-password

tmp="$(mktemp secrets/htpasswd.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

printf '%s' "$PW" | htpasswd -niB -C 12 "$REGISTRY_USER" | tr -d '\n' >"$tmp"
printf '%s' "$PW" | htpasswd -vi "$tmp" "$REGISTRY_USER"

kubectl create secret generic registry-htpasswd --namespace docker-registry \
  --from-file=htpasswd="$tmp" --dry-run=client -o json |
  "${KUBESEAL[@]}" >sealed-secrets/sealed-registry-htpasswd.json

seal_regcred() {
  local namespace=$1 name=$2 file=$3
  REGISTRY=$REGISTRY REGISTRY_USER=$REGISTRY_USER jq -n \
    '{auths: {(env.REGISTRY): {username: env.REGISTRY_USER, password: env.PW, auth: ("\(env.REGISTRY_USER):\(env.PW)" | @base64)}}}' |
    kubectl create secret generic "$name" --namespace "$namespace" \
      --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson=/dev/stdin --dry-run=client -o json |
    "${KUBESEAL[@]}" >"$file"
}

seal_regcred argocd regcred-argocd sealed-secrets/sealed-regcred-argocd.json
seal_regcred homepage-production regcred-homepage sealed-secrets/sealed-regcred-homepage-production.json
seal_regcred homepage-staging regcred-homepage sealed-secrets/sealed-regcred-homepage-staging.json
seal_regcred music-library regcred sealed-secrets/sealed-music-library-regcred.json

unset PW

for f in sealed-secrets/sealed-registry-htpasswd.json sealed-secrets/sealed-regcred-*.json sealed-secrets/sealed-music-library-regcred.json; do
  printf '%s: ' "$f"
  kubeseal --validate --controller-name sealed-secrets-controller --controller-namespace kube-system <"$f" &&
    echo ok
done

echo
echo "New password is in secrets/registry-password. Move it to the password manager and delete the file."
echo "The same password has to go to the REGISTRY_PWD secret of the GitHub repositories that push"
echo "images, and to docker login on machines that use the registry."
