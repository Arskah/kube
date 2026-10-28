# Forgejo setup checklist

Instance: https://forge.aarnihalinen.fi/ (Forgejo 15.0.7, chart in `apps/templates/forge.yml`, extra manifests in `forgejo/`).

Started 2026-10-28 with the instance up over HTTPS and `ROOT_URL` correct.

## Do first

- [x] **Admin login.** Read the generated password from the chart's admin secret in the `forge` namespace (probably `forgejo-admin`, username `gitea_admin`). Log in and change the password right away. Optionally rename the admin, and create a normal user for daily use.
- [x] **Two-factor auth** on the admin account (Settings -> Security).
- [x] **Close registration.** Set `gitea.config.service.DISABLE_REGISTRATION: true` in the chart values. `REQUIRE_SIGNIN_VIEW` was `true` at first and is now `false`, see the public view below.
- [x] **Confirm the database.** Site Administration -> Configuration should show PostgreSQL, not SQLite.

## Soon

- [x] **Backups.** Done: the NAS backs up the volumes daily, and `backup.yml` dumps the database nightly so that a consistent copy exists. Restore steps are in `docs/disaster-recovery.md`. Original note: Repos live on the chart's 50Gi volume (`gitea-shared-storage`), the database on `data-forgejo-db-0`, both on NFS (`nfs-retain`). Decide how to get a consistent copy: a CronJob with `pg_dump` plus NAS snapshots, or `forgejo dump`. A Postgres volume restored alone may not match the repo files.
- [x] **Update `docs/disaster-recovery.md`.** Add `sealed-forgejo-postgres.json` (`forge/forgejo-postgres-secret`, key `postgres-password`) to the secrets table, and the NAS directories of the two volumes to the PVC table.
- [x] **Email** (password resets, notifications). Add a `gitea.config.mailer` block. The Alertmanager SMTP account could be reused, with its own sealed secret.
- [x] **Import repos.** The GitHub repos are mirrors of their public GitHub originals, the GitLab repos (`configs`, `toiletpaper.rent`) were migrated. ArgoCD still reads `kube`, `homepage` and `music-library` from GitHub. `gitlab-runner` was removed from the cluster, since nothing builds on GitLab anymore.

## Later / optional

- [x] **CI.** Forgejo Actions needs a separate runner. Only worth it to move off GitHub Actions or the GitLab runners.
- [x] **SSH access.** Done: router forwards public 2222 to NodePort 32222 on `kube-control` (the host network Gateway cannot do TCP listeners). Clone URLs use `ssh://git@forge.aarnihalinen.fi:2222/...`.
- [x] **Container and package registry.** All images are on `forge.aarnihalinen.fi/arska/` (`homepage`, `music-library`, `tp-rent-*`), public, and `docker-registry` is removed. homepage CI pushes with a `write:package` token of `arska` (GitHub secrets `REGISTRY_USER`/`REGISTRY_PWD`), tp-rent still pulls with the `cluster-pull` token although its images are public now. Renovate skips `forge.aarnihalinen.fi/**`, it has no login.
- [ ] **Unify registry and CI credentials.** The personal CI token, the `cluster-pull` secret that tp-rent no longer needs, and maybe an organization that owns the packages, so that a bot can push.
- [x] **Public view.** `REQUIRE_SIGNIN_VIEW: false`, so public repos and profiles, and the packages of public owners, can be viewed and pulled without logging in. New repos start private (`DEFAULT_PRIVATE: private`). `robots.txt` (`robots.yml`) keeps AI training crawlers out and other crawlers off the per-commit pages.
- [x] **Metrics.** Enable `gitea.config.metrics` and add a ServiceMonitor with the `release: monitoring` label, like Cilium.

## Things to watch

- [ ] **Chart source.** `data.forgejo.org/forgejo-helm` at 17.1.5 works today. The verified source in the docs is `oci://code.forgejo.org/forgejo-helm/forgejo`. If Renovate bumps or a sync fails, change the repo URL here and in `argocd-projects/apps.yml` together.
- [x] **Postgres image pin.** Pinned with a `@sha256:` digest, along with the runner images, so Renovate tracks them.
- [ ] **Postgres password.** `POSTGRES_PASSWORD` only applies when the database is first initialized. Changing the sealed secret later does not change the password of the existing database.
