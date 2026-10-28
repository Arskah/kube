#!/usr/bin/env bash
# Render the Helm charts of the ArgoCD Applications into .rendered/, one file per Application, so
# that kube-linter can check the pods they create. kube-linter only knows charts that are in the
# repo; ours are pulled by ArgoCD with the values inlined under helm.valuesObject.
#
# Only chart sources are rendered. Directories of this repo are linted as they are (kube-linter
# renders the Kustomize ones itself), and nfs-storage, which takes its chart from a git tag, is
# skipped. Needs helm and yq (mikefarah). Run from anywhere; used by CI.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

OUT=.rendered
rm -rf "$OUT"
mkdir -p "$OUT"

for app in apps/templates/*.yml; do
  # One line per chart source: repo, chart, version, release name, namespace
  yq -N 'select(.kind == "Application") | .spec.destination.namespace as $ns |
    ([.spec.source] + (.spec.sources // [])) | .[] | select(. != null and .chart != null) |
    [.repoURL, .chart, .targetRevision, (.helm.releaseName // .chart), $ns] | join(" ")' "$app" |
    while read -r repo chart version release namespace; do
      # yq prints an empty line for an Application without a chart
      [ -n "$repo" ] || continue
      name="$(basename "$app" .yml)"
      values="$(mktemp)"
      yq "([.spec.source] + (.spec.sources // [])) | .[] | select(. != null and .chart == \"$chart\") |
        .helm.valuesObject // {}" "$app" >"$values"

      # Helm repositories have a scheme, OCI registries do not
      if [[ "$repo" == http* ]]; then
        source=(--repo "$repo" "$chart")
      else
        source=("oci://$repo/$chart")
      fi

      # The API versions let charts render the ServiceMonitors that need the CRDs of the monitoring stack
      helm template "$release" "${source[@]}" --version "$version" --namespace "$namespace" \
        --values "$values" --skip-tests --api-versions monitoring.coreos.com/v1 >"$OUT/$name.yml"
      rm "$values"
      echo "$OUT/$name.yml: $chart $version"
    done
done
