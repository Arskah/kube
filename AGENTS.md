# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## What this repo is

GitOps configuration for a single home-lab Kubernetes cluster, reconciled by ArgoCD from `https://github.com/Arskah/kube.git` at `HEAD`. There is no application code, build step or test suite: everything is Kubernetes manifests, and **merging to `main` is the deploy** (every Application has `automated` sync with `prune` and `selfHeal`).

## Commands

Node is only used for formatting and commit linting (version in `.nvmrc`).

```sh
npm ci                      # installs husky hooks via `prepare`
npx prettier --check .      # what CI runs
npx prettier --write <file>
kubectl kustomize argocd    # render the ArgoCD install + patches locally
kubectl kustomize argocd-image-updater
```

- Pre-commit runs `prettier --write` on all staged files (lint-staged); commit-msg runs commitlint with `config-conventional`.
- CI (`.github/workflows/check-pr.yml`) runs Prettier and lints the **PR title** with commitlint, so PR titles must be Conventional Commits too.

Cluster bootstrap (from the README), only needed on a fresh cluster:

```sh
kubectl kustomize argocd | kubectl apply -f -
kubectl apply -f apps/templates/argo-projects.yml
kubectl apply -f app-of-apps.yml
```

## Architecture

### App-of-apps

`app-of-apps.yml` defines the root `apps` Application, which syncs `apps/` as a plain recursive directory. Despite the `apps/Chart.yml` + `templates/` layout, nothing in `apps/templates/` is Helm-templated; the files are applied as-is. Each file there is normally one ArgoCD `Application`, but the directory also holds raw cluster resources (`namespaces.yml`, `ip-pool.yml`).

An Application in `apps/templates/` points at one of:

- a directory in this repo with plain manifests (`caddy/`, `icecast/`, `tp-rent/`),
- an upstream Helm chart with values inlined under `helm.valuesObject` (cilium, monitoring, nfs-storage, gitlab-runner),
- both at once via `sources:` — chart plus a repo directory of extra resources (cert-manager + its ClusterIssuers, sealed-secrets + the sealed secrets, docker-registry + its PVC/Certificate),
- another repo (`homepage-*` → `Arskah/homepage`, `k8s/prod` and `k8s/staging`).

ArgoCD manages itself: `argocd/` is a Kustomization that pulls the upstream `install.yaml` by version URL, adds the `argocd` namespace/AppProject/self-managing Application, and patches `argocd-cm`. `argocd-image-updater/` is a similar Kustomization, and holds the `ImageUpdater` resources that track `registry.aarnihalinen.fi/homepage` for the homepage apps.

### Projects and ordering

Three AppProjects: `argocd` (`argocd/base/`), and `infra` and `applications` (`argocd-projects/`).

- `infra` is unrestricted.
- `applications` whitelists source repos and destination namespaces explicitly. **Adding a new app under this project means also adding its namespace (and repo/chart URL if new) to `argocd-projects/apps.yml`**, otherwise the sync is rejected.

Startup order is expressed with `argocd.argoproj.io/sync-wave` annotations: 0 gateway-api (CRDs) → 1 cilium, nfs-storage → 2 sealed-secrets → 3 cert-manager, monitoring, gateway → 4 docker-registry → 5 user-facing apps. Give new Applications a wave consistent with what they depend on.

### Cross-cutting conventions

- **Ingress/TLS**: HTTP(S) traffic enters through Cilium's Gateway API implementation; there is no Ingress controller (ingress-nginx is retired upstream and was removed). `gateway/` has the shared `Gateway` `public`, which runs in host network mode: Envoy listens on 80/443 on the nodes (see the comment in `apps/templates/cilium.yml`). Port 80 only redirects to HTTPS. Each hostname has its own HTTPS listener in `gateway/gateway.yml`, because a listener has exactly one certificate. To expose an application: add a listener there, and next to the application a `Certificate` (ClusterIssuer `letsencrypt-production`), a `ReferenceGrant` that lets the Gateway use the certificate secret, and an `HTTPRoute` attached to the listener with `sectionName` (`caddy/httproute.yml` is the template, including the HSTS header that every route sets). The ACME HTTP-01 solver is a `gatewayHTTPRoute` on the `http` listener.
- **Storage**: default StorageClass is `nfs-retain` (csi-driver-nfs, NAS at `192.168.86.87:/k8s`); some pods also mount NFS from that host directly.
- **Secrets**: only Bitnami SealedSecrets are committed, as JSON in `sealed-secrets/`, each with its target namespace baked in. They are sealed against the in-cluster controller (`sealed-secrets-controller` in `kube-system`), so they cannot be created or edited without cluster access. `secrets/` (plaintext inputs) is gitignored.
- **Versions**: Renovate owns chart `targetRevision`s, image tags (pinned as `tag@sha256:digest`), GitHub Action SHAs, and the ArgoCD version in `argocd/kustomization.yaml` (custom regex manager). Keep the pin formats intact so Renovate keeps matching them.
- **File extension**: `.yml` everywhere except Kustomize directories (`argocd/`, `argocd-image-updater/`), which use `.yaml`.

### Environment-specific values

LAN addresses are hardcoded across manifests and docs (`192.168.86.x`: LB pool in `ip-pool.yml`, NFS server, node addresses in `talos/` and `docs/`). When one changes, grep the repo for it.

The cluster runs on Talos nodes in Proxmox (see `talos/README.md`); it replaced an earlier single-node kubeadm install. `apps/templates/cilium.yml` carries the Talos-specific values (KubePrism at `localhost:7445`, dropped `SYS_MODULE`, cgroup settings). Nodes are `kube-control` (`192.168.86.73`, control plane) and `kube-node1` (`192.168.86.76`); The router is a Google Wifi, which can only port-forward to a port on a device it knows from DHCP, so public traffic has to enter through a node IP: it forwards 80 and 443 to `kube-control`, where the Gateway listens in host network mode. That is why the Gateway does not use a Cilium LoadBalancer IP; those are only usable from inside the LAN, and nothing uses one at the moment. The node NIC is `eth0` (Talos is installed with `net.ifnames=0`); both `devices` in `cilium.yml` and the `CiliumL2AnnouncementPolicy` in `ip-pool.yml` depend on that name.

`docs/disaster-recovery.md` is the rebuild runbook and the inventory of state that lives outside git (Sealed Secrets keys, NFS volume directories, router and DNS setup). Keep its tables current when adding a SealedSecret or a PersistentVolumeClaim.

Talos machine configs are generated, not committed: `talos/patches/` holds the only tracked Talos configuration, and `talos/secrets.yaml`, the generated `controlplane.yaml`/`worker.yaml`, `talosconfig` and `kubeconfig` are gitignored because they contain cluster credentials (`talos/README.md` has the `talosctl gen config` command and the full setup procedure). Do not read them into context or stage them. `cilium-values.yml` is an old `helm get values` dump kept for reference, not a source of truth.
