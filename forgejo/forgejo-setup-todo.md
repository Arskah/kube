# Forgejo setup checklist

Instance: https://forge.aarnihalinen.fi/ (Forgejo 15.0.7, chart in `apps/templates/forge.yml`, extra manifests in `forgejo/`).

Status when written (2026-10-28): the instance is up over HTTPS and `ROOT_URL` is correct. Nothing below is done yet.

## Do first

- [x] **Admin login.** Read the generated password from the chart's admin secret in the `forge` namespace (probably `forgejo-admin`, username `gitea_admin`). Log in and change the password right away. Optionally rename the admin, and create a normal user for daily use.
- [x] **Two-factor auth** on the admin account (Settings -> Security).
- [x] **Close registration.** Set `gitea.config.service.DISABLE_REGISTRATION: true` in the chart values. Optionally `REQUIRE_SIGNIN_VIEW: true` to make the whole instance private.
- [x] **Confirm the database.** Site Administration -> Configuration should show PostgreSQL, not SQLite.

## Soon

- [ ] **Backups.** Repos live on the chart's 50Gi volume (`gitea-shared-storage`), the database on `data-forgejo-db-0`, both on NFS (`nfs-retain`). Decide how to get a consistent copy: a CronJob with `pg_dump` plus NAS snapshots, or `forgejo dump`. A Postgres volume restored alone may not match the repo files.
- [ ] **Update `docs/disaster-recovery.md`.** Add `sealed-forgejo-postgres.json` (`forge/forgejo-postgres-secret`, key `postgres-password`) to the secrets table, and the NAS directories of the two volumes to the PVC table.
- [x] **Email** (password resets, notifications). Add a `gitea.config.mailer` block. The Alertmanager SMTP account could be reused, with its own sealed secret.
- [ ] **Import repos.** New migration -> GitHub for `homepage` and `music-library`. Migrating `kube` is optional, since ArgoCD still reads it from GitHub.

## Later / optional

- [ ] **CI.** Forgejo Actions needs a separate runner. Only worth it to move off GitHub Actions or the GitLab runners.
- [ ] **SSH access.** Currently off (`DISABLE_SSH: true`). Needs a TCP route in the Gateway (the chart has none), a router port forward, and removing `DISABLE_SSH`. HTTPS with access tokens works until then.
- [ ] **Container and package registry.** Forgejo has one built in; could replace the separate `docker-registry`, but it is a bigger change.
- [x] **Metrics.** Enable `gitea.config.metrics` and add a ServiceMonitor with the `release: monitoring` label, like Cilium.

## Things to watch

- [ ] **Chart source.** `data.forgejo.org/forgejo-helm` at 17.1.5 works today. The verified source in the docs is `oci://code.forgejo.org/forgejo-helm/forgejo`. If Renovate bumps or a sync fails, change the repo URL here and in `argocd-projects/apps.yml` together.
- [ ] **Postgres image pin.** `postgres:17` in `forgejo/db.yml` is unpinned. Add a `@sha256:` digest if Renovate should track it.
- [ ] **Postgres password.** `POSTGRES_PASSWORD` only applies when the database is first initialized. Changing the sealed secret later does not change the password of the existing database.
