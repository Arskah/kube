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
- [x] **Container and package registry.** All images are on `forge.aarnihalinen.fi/public/` (`homepage`, `music-library`, `tp-rent-*`) and pulled without a login; `docker-registry` is removed. Renovate skips `forge.aarnihalinen.fi/**`, it has no login.
- [x] **Registry credentials.** Packages belong to the orgs `public` (public) and `private` (members only), since Forgejo decides visibility per owner. The `ci` bot user writes to both (team `ci`, Packages: Write), and its `write:package` token is what CI pushes with. The `cluster-pull` bot user reads `private` (team `cluster`, Packages: Read); `scripts/seal-forge-pull.sh` seals its token as `forge-pull` for the namespaces that run private images.
- [x] **Public view.** `REQUIRE_SIGNIN_VIEW: false`, so public repos and profiles, and the packages of public owners, can be viewed and pulled without logging in. New repos start private (`DEFAULT_PRIVATE: private`). `robots.txt` (`robots.yml`) keeps AI training crawlers out and other crawlers off the per-commit pages.
- [x] **Metrics.** Enable `gitea.config.metrics` and add a ServiceMonitor with the `release: monitoring` label, like Cilium.

## Things to watch

- [x] **Chart source.** `code.forgejo.org/forgejo-helm`, the source the Forgejo docs verify. It serves the same chart as `data.forgejo.org`, which was used at first (17.1.5 has the same digest on both).
- [x] **Postgres image pin.** Pinned with a `@sha256:` digest, along with the runner images, so Renovate tracks them.
- [ ] **Postgres password.** `POSTGRES_PASSWORD` only applies when the database is first initialized. Changing the sealed secret later does not change the password of the existing database.
