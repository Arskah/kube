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
- an upstream Helm chart with values inlined under `helm.valuesObject` (cilium, ingress-nginx, monitoring, nfs-storage, gitlab-runner),
- both at once via `sources:` — chart plus a repo directory of extra resources (cert-manager + its ClusterIssuers, sealed-secrets + the sealed secrets, docker-registry + its PVC/Certificate),
- another repo (`homepage-*` → `Arskah/homepage`, `k8s/prod` and `k8s/staging`).

ArgoCD manages itself: `argocd/` is a Kustomization that pulls the upstream `install.yaml` by version URL, adds the `argocd` namespace/AppProject/self-managing Application, and patches `argocd-cm`. `argocd-image-updater/` is a similar Kustomization, and holds the `ImageUpdater` resources that track `registry.aarnihalinen.fi/homepage` for the homepage apps.

### Projects and ordering

Three AppProjects: `argocd` (`argocd/base/`), and `infra` and `applications` (`argocd-projects/`).

- `infra` is unrestricted.
- `applications` whitelists source repos and destination namespaces explicitly. **Adding a new app under this project means also adding its namespace (and repo/chart URL if new) to `argocd-projects/apps.yml`**, otherwise the sync is rejected.

Startup order is expressed with `argocd.argoproj.io/sync-wave` annotations: 1 cilium, nfs-storage → 2 ingress-nginx, sealed-secrets → 3 cert-manager, monitoring → 4 docker-registry → 5 user-facing apps. Give new Applications a wave consistent with what they depend on.

### Cross-cutting conventions

- **Ingress/TLS**: apps use `ingressClassName: nginx` with the `cert-manager.io/cluster-issuer: letsencrypt-production` annotation (HTTP-01 solver is bound to the nginx class). Cilium's own ingress controller is also enabled, but nothing uses it.
- **Gateway API (migration from ingress-nginx in progress)**: ingress-nginx is retired upstream and is being replaced by Cilium's Gateway API implementation. `gateway/` has the shared `Gateway` `public`, which runs in host network mode (Envoy listens on 80/443 on the nodes, see the comment in `apps/templates/cilium.yml`). Each hostname has its own HTTPS listener there; the application keeps its `Certificate` in its own namespace, allows the Gateway to use the secret with a `ReferenceGrant`, and attaches an `HTTPRoute` to its listener with `sectionName` (`caddy/httproute.yml` is the template). Public traffic still enters through ingress-nginx until the router is repointed, so keep the `Ingress` of an application until then.
- **Storage**: default StorageClass is `nfs-retain` (csi-driver-nfs, NAS at `192.168.86.87:/k8s`); some pods also mount NFS from that host directly.
- **Secrets**: only Bitnami SealedSecrets are committed, as JSON in `sealed-secrets/`, each with its target namespace baked in. They are sealed against the in-cluster controller (`sealed-secrets-controller` in `kube-system`), so they cannot be created or edited without cluster access. `secrets/` (plaintext inputs) is gitignored.
- **Versions**: Renovate owns chart `targetRevision`s, image tags (pinned as `tag@sha256:digest`), GitHub Action SHAs, and the ArgoCD version in `argocd/kustomization.yaml` (custom regex manager). Keep the pin formats intact so Renovate keeps matching them.
- **File extension**: `.yml` everywhere except Kustomize directories (`argocd/`, `argocd-image-updater/`), which use `.yaml`.

### Environment-specific values

LAN addresses are hardcoded across manifests (`192.168.86.x`: control-plane node IP as externalIP in `ingress-nginx.yml`, LB pool and L2 announcement interface in `ip-pool.yml`, Cilium ingress LB IP, NFS server). When one changes, grep the repo for it.

The cluster runs on Talos nodes in Proxmox (see `talos/README.md`); it replaced an earlier single-node kubeadm install. `apps/templates/cilium.yml` carries the Talos-specific values (KubePrism at `localhost:7445`, dropped `SYS_MODULE`, cgroup settings). Nodes are `kube-control` (`192.168.86.73`, control plane) and `kube-node1` (`192.168.86.76`); ingress-nginx is exposed as a NodePort service with the control-plane IP as its externalIP. That is deliberate: the router is a Google Wifi, which can only port-forward to devices it knows from DHCP, so public traffic has to enter through a node IP and NodePorts (`30080`/`30443`) rather than a Cilium LoadBalancer IP. LoadBalancer IPs are only usable from inside the LAN. The node NIC is `eth0` (Talos is installed with `net.ifnames=0`); both `devices` in `cilium.yml` and the `CiliumL2AnnouncementPolicy` in `ip-pool.yml` depend on that name.

`docs/disaster-recovery.md` is the rebuild runbook and the inventory of state that lives outside git (Sealed Secrets keys, NFS volume directories, router and DNS setup). Keep its tables current when adding a SealedSecret or a PersistentVolumeClaim.

Talos machine configs are generated, not committed: `talos/patches/` holds the only tracked Talos configuration, and `talos/secrets.yaml`, the generated `controlplane.yaml`/`worker.yaml`, `talosconfig` and `kubeconfig` are gitignored because they contain cluster credentials (`talos/README.md` has the `talosctl gen config` command and the full setup procedure). Do not read them into context or stage them. `cilium-values.yml` is an old `helm get values` dump kept for reference, not a source of truth.
