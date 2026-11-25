#!/usr/bin/env bash
# Validate the manifests against the schemas of Kubernetes and of the CRDs (the CRDs catalog of
# datree), so that a typo in a field fails the PR instead of the ArgoCD sync after the merge.
#
# Checks the files of the repo, the Kustomize directories rendered with kubectl, and the charts in
# .rendered/, so scripts/render-charts.sh has to run first. Resources that have no schema in either
# place are skipped. Needs kubeconform and kubectl. Run from anywhere; used by CI.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

args=(
  -strict
  -summary
  -ignore-missing-schemas
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
  # The catalog has an older ImageUpdater schema, without the spec.namespace of argocd-image-updater 1.1
  -skip ImageUpdater
)

# All three run, so that one failing does not hide what the others find
status=0

# Everything but the files that are not manifests (Talos patches look like manifests but are not), and
# the Kustomize directories, which hold patches and are rendered below instead
git ls-files -z '*.yml' '*.yaml' '*.json' \
  ':!.github' ':!talos' ':!argocd' ':!argocd-image-updater' \
  ':!package.json' ':!pnpm-lock.yaml' ':!renovate.json' ':!.oxfmtrc.json' ':!.kube-linter.yml' |
  xargs -0 kubeconform "${args[@]}" || status=1

kubeconform "${args[@]}" .rendered || status=1

for dir in argocd argocd-image-updater; do
  kubectl kustomize "$dir" | kubeconform "${args[@]}" - || status=1
done

exit "$status"
