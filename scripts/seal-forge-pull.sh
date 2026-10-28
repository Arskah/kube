#!/usr/bin/env bash
# Seal the pull secret for private images in the Forgejo registry as forge-pull (type
# kubernetes.io/dockerconfigjson) in every namespace of NAMESPACES.
#
# Images under forge.aarnihalinen.fi/public/ are pulled without a login. Images under
# forge.aarnihalinen.fi/private/ need this secret in the namespace and `imagePullSecrets: [{name: forge-pull}]`
# in the pod. The login is the cluster-pull bot user, a member of the private org's team with Packages: Read, with a
# token that has the read:package scope and nothing else.
#
# The secret is sealed once with cluster-wide scope, so the same encrypted value works in every namespace, and
# written once per namespace. To add a namespace, add it to NAMESPACES and run the script again; that also rotates the
# token everywhere.
#
# Run from the repo root with kubectl pointing at the cluster. The token is read from a hidden prompt and is never
# printed or written to disk.
set -euo pipefail

NAMESPACES=()
REGISTRY=forge.aarnihalinen.fi
USERNAME=cluster-pull
KUBESEAL=(kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system -o json)

cd "$(git rev-parse --show-toplevel)"

[ "${#NAMESPACES[@]}" -gt 0 ] || {
  echo "NAMESPACES is empty: add the namespaces that run private images first" >&2
  exit 1
}

read -rsp "Forgejo token of $USERNAME: " TOKEN
echo
[ -n "$TOKEN" ] || {
  echo "no token given" >&2
  exit 1
}

# The registry hands out a pull token only for a valid login.
curl -fsS -o /dev/null -u "$USERNAME:$TOKEN" "https://$REGISTRY/v2/token" || {
  echo "$REGISTRY does not accept the login of $USERNAME" >&2
  exit 1
}
echo "$REGISTRY accepts the login of $USERNAME"

# The docker config is built from stdin so that the token is not in the arguments of any process.
sealed="$(
  printf '%s' "$TOKEN" |
    jq -Rs --arg registry "$REGISTRY" --arg user "$USERNAME" \
      '{auths: {($registry): {username: $user, password: ., auth: ("\($user):\(.)" | @base64)}}}' |
    kubectl create secret generic forge-pull --namespace "${NAMESPACES[0]}" \
      --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin \
      --dry-run=client -o json |
    "${KUBESEAL[@]}" --scope cluster-wide
)"

unset TOKEN

for ns in "${NAMESPACES[@]}"; do
  out="sealed-secrets/sealed-$ns-forge-pull.json"
  jq --arg ns "$ns" '.metadata.namespace = $ns | .spec.template.metadata.namespace = $ns' <<<"$sealed" >"$out"
  printf '%s: ' "$out"
  kubeseal --validate --controller-name sealed-secrets-controller --controller-namespace kube-system <"$out" &&
    echo ok
done
