# Disaster recovery

How to rebuild the cluster from nothing, and what has to exist outside of this repository for that to work.

The repository describes everything that runs in the cluster, but not the secrets, the data or the network around it.
Those are listed in [What is not in git](#what-is-not-in-git). If the backups there do not exist, parts of the rebuild
turn from "restore" into "recreate by hand".

## What is not in git

| What                           | Where it lives                                      | Needed for                                           | If lost                                                         |
| ------------------------------ | --------------------------------------------------- | ---------------------------------------------------- | --------------------------------------------------------------- |
| Talos secrets bundle           | `talos/secrets.yaml` on the admin machine           | regenerating machine configs, adding nodes           | new cluster identity, see [talos/README.md](../talos/README.md) |
| Sealed Secrets private keys    | Secrets in `kube-system`                            | decrypting everything in `sealed-secrets/`           | every secret has to be recreated and sealed again               |
| Plaintext of the sealed values | nowhere in the repo                                 | sealing the secrets again                            | new credentials have to be issued                               |
| Persistent volumes             | NAS `192.168.86.87`, NFS export `/k8s`              | tp-rent database, Forgejo                            | data is gone                                                    |
| Static files                   | NAS `/k8s/www`, `/k8s/caddy`, `/k8s/icecast`        | caddy and icecast pods mount these directly          | sites serve nothing                                             |
| Router configuration           | Google Wifi                                         | public traffic reaching the cluster, stable node IPs | nothing is reachable from outside                               |
| DNS records                    | DigitalOcean DNS (`aarnihalinen.fi`, `halinen.dev`) | every public hostname, certificate issuance          | nothing is reachable from outside                               |
| Proxmox VM definitions         | Proxmox host                                        | the nodes themselves                                 | recreate from the table below                                   |

### Backups to keep

Store these in the password manager. None of them is taken automatically.

1. `talos/secrets.yaml`.

2. The Sealed Secrets keys. The controller creates a new key every 30 days and keeps the old ones. New secrets are
   sealed with the newest key, so the backup is only out of date when something has been sealed with a key that is not
   in it yet. Taking the backup again after every sealing covers that. The output is private key material.

   ```sh
   kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-keys.yaml
   ```

3. The plaintext values behind the sealed secrets, as a fallback for losing the keys:

   | File in `sealed-secrets/`                  | Secret                                | Keys                                                | Source of the values                                             |
   | ------------------------------------------ | ------------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------- |
   | `sealed-alertmanager-smtp.json`            | `monitoring/alertmanager-smtp`        | `password`                                          | SMTP password of the address Alertmanager sends from             |
   | `sealed-ddns-digitalocean-token.json`      | `ddns/digitalocean-token`             | `token`                                             | DigitalOcean API token, scopes `domain:read` and `domain:update` |
   | `sealed-forgejo-postgres.json`             | `forge/forgejo-postgres-secret`       | `postgres-password`                                 | has to match the existing database files                         |
   | `sealed-forgejo-runner-token.json`         | `forgejo-runner/forgejo-runner-token` | `token`                                             | runner of the user `arska` (Settings -> Actions -> Runners)      |
   | `sealed-forgejo-smtp.json`                 | `forge/forgejo-smtp`                  | `password`                                          | SMTP password of the address Forgejo sends from                  |
   | `sealed-grafana-admin.json`                | `monitoring/grafana-admin`            | `admin-user`, `admin-password`                      | any, it is the login of Grafana                                  |
   | `sealed-music-library-admin-password.json` | `music-library/admin-password`        | `password`                                          | has to match the existing database files                         |
   | `sealed-music-library-web-db.json`         | `music-library/web-db`                | `password`                                          | any value: the page sets it in the database on start             |
   | `sealed-music-library-web-login.json`      | `music-library/web-login`             | `login`                                             | shared login of the page, `user:password`                        |
   | `sealed-music-library-web-webhook.json`    | `music-library/web-webhook`           | `secret`                                            | shared secret of the webhook of the page                         |
   | `sealed-tp-rent-db.json`                   | `tp-rent/db-password`                 | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` | has to match the existing database files                         |

   `scripts/` has a script for each secret that gets rotated: it asks for or generates the value, seals it and checks
   the result. `scripts/seal-forge-pull.sh` writes `sealed-<namespace>-forge-pull.json`, the pull secret for private
   images in the Forgejo registry, for each namespace in its list; the value is the token of the `cluster-pull` user. The others are sealed with the commands under [Sealing the secrets again](#sealing-the-secrets-again).

4. A dump of the tp-rent database, taken regularly:

   ```sh
   kubectl -n tp-rent exec deploy/db -- sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' > tp-rent.sql
   ```

   The Forgejo database is dumped every night by the `forge/forgejo-db-backup` CronJob into its own volume (see
   [Persistent volumes](#persistent-volumes)), which keeps 14 days. The NAS backup of that directory is the backup.

### Persistent volumes

Volumes are directories on the NAS, created by the NFS CSI driver and named after the PersistentVolume. The reclaim
policy is `Retain`, so the directories survive the cluster, but a new cluster creates new, empty directories with new
names. Without this table there is no way to tell which old directory belonged to what.

| Claim                           | Directory on the NAS                            |
| ------------------------------- | ----------------------------------------------- |
| `tp-rent/db-pvc`                | `/k8s/pvc-a17cd4de-4761-4060-9967-be89708a50a5` |
| `forge/gitea-shared-storage`    | `/k8s/pvc-aea39d3d-af29-4ba4-bf64-e8167a31d202` |
| `forge/data-forgejo-db-0`       | `/k8s/pvc-f212e744-2350-4ba5-b9dc-b06e9341d201` |
| `forge/forgejo-db-backup`       | `/k8s/pvc-a5d97835-7905-41c4-9a20-cd6fccdefbaa` |
| `music-library/data-postgres-0` | `/k8s/pvc-0ff2de14-ff60-410a-8385-dadfe31886e0` |

Update the table when claims are added:

```sh
kubectl get pv -o custom-columns=CLAIM_NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,SUBDIR:.spec.csi.volumeAttributes.subdir
```

### Network

Checked from the outside, the router configuration itself has not been reviewed:

- All public hostnames are CNAMEs to `aarnihalinen.fi` (or `halinen.dev` for `kube.halinen.dev`), which have an A record
  with the public address of the home connection. The address is dynamic. The `ddns` CronJob compares the two A records
  with the current public address every five minutes and updates them through the DigitalOcean API, so they follow on
  their own as long as the cluster runs. While rebuilding, set them by hand.
- Ports 80, 443, 2222 and 6443 are open on the public address. Google Wifi can only forward ports to devices it knows from
  DHCP, so the forwards have to point at the control plane node: 80 to `192.168.86.73:80` and 443 to
  `192.168.86.73:443`, where the Gateway listens, 2222 to `192.168.86.73:32222` (Forgejo SSH, a NodePort), and 6443 to `192.168.86.73:6443`. The API server answers
  `/livez`, `/readyz` and `/healthz` without credentials (the default of Talos 1.14) and nothing else.
- The node addresses come from DHCP and are hardcoded in this repo, so they need DHCP reservations: `192.168.86.73`
  (`kube-control`), `192.168.86.76` (`kube-node1`) and `192.168.86.87` (NAS). New VMs get new MAC addresses, so the
  reservations have to be made again.
- The DHCP pool of the router is `192.168.86.20`-`192.168.86.99`. `192.168.86.100`-`192.168.86.254` is handed out by
  Cilium to LoadBalancer services (`apps/templates/ip-pool.yml`), so the DHCP pool must not grow into it.

### Virtual machines

Sizes of the current nodes as Kubernetes sees them. The other VM settings are in the
[Talos guide for Proxmox](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/virtualized-platforms/proxmox).

| Node           | CPU | Memory | Disk                                |
| -------------- | --- | ------ | ----------------------------------- |
| `kube-control` | 2   | 4 GB   | about 10 GB (8 GB usable for pods)  |
| `kube-node1`   | 2   | 8 GB   | about 32 GB (28 GB usable for pods) |

## Rebuild

Tools on the admin machine: `talosctl`, `kubectl`, `helm`, `yq`, `kubeseal`, `argocd`. The admin machine has to be on the
LAN, the Talos API is not reachable from anywhere else.

1. **Network.** Make the DHCP reservations and port forwards described in [Network](#network), and check that the NAS
   exports `/k8s` over NFS 4.1 to the nodes.

2. **Nodes and Kubernetes.** Follow [talos/README.md](../talos/README.md#setting-up-a-new-cluster) up to and including
   the Cilium step. Use the backed up `talos/secrets.yaml` if it exists. Continue when both nodes are `Ready`:

   ```sh
   kubectl get nodes
   ```

3. **Sealed Secrets keys.** Restore the keys before ArgoCD installs the controller, so that it starts with them:

   ```sh
   kubectl apply -f sealed-secrets-keys.yaml
   ```

   If the controller is already running, restart it afterwards with
   `kubectl -n kube-system rollout restart deploy/sealed-secrets-controller`.

   Without the backup, skip this and do [Sealing the secrets again](#sealing-the-secrets-again) after step 4.

4. **ArgoCD and everything else.** Follow the [ArgoCD section of the main README](../README.md#argocd). ArgoCD then
   installs the applications in the order of their sync waves. The first sync takes a while and some applications fail
   until the ones they depend on are up, which ArgoCD retries on its own.

   One of the applications is tuppr, which upgrades the nodes to the Talos and Kubernetes versions in `tuppr/` as soon
   as it runs, with a reboot of each node for Talos. Nodes installed as described in `talos/README.md` are on those
   versions already. If they are not, tuppr starts upgrading while the rest of the rebuild is still going on; to hold
   it back, `kubectl annotate talosupgrade cluster tuppr.home-operations.com/suspend=true` (and the same for
   `kubernetesupgrade kubernetes`) and remove the annotation when the rebuild is done.

   ```sh
   kubectl -n argocd get applications
   ```

5. **Data.** The new volumes are empty. For each claim in [Persistent volumes](#persistent-volumes), stop the workload,
   copy the content of the old directory into the new one on the NAS and start the workload again. The new directory
   names come from the command in that section.

   ```sh
   kubectl -n tp-rent scale deploy/db --replicas=0
   # on the NAS: copy /k8s/<old directory>/. to /k8s/<new directory>/
   kubectl -n tp-rent scale deploy/db --replicas=1
   ```

   ArgoCD scales the workload back up on its own if this takes longer than its next sync. Disable auto-sync for the
   application in the ArgoCD UI for the duration if that gets in the way.

   The homepage, music-library and tp-rent images are pulled from the Forgejo registry, which keeps them on the
   `forge/gitea-shared-storage` volume. Those pods stay in `ImagePullBackOff` until that volume is restored, or until
   the images are pushed again (homepage from its CI, the others by hand).

   Restoring the database from a dump instead of the files:

   ```sh
   kubectl -n tp-rent exec -i deploy/db -- sh -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB"' < tp-rent.sql
   ```

   Forgejo: the database files on the NAS are copied while Postgres runs, so they may not start. Restore the
   repositories (`forge/gitea-shared-storage`) and the dump volume (`forge/forgejo-db-backup`) as above, then load the
   newest dump into the empty database and let Forgejo check the result against the repositories:

   ```sh
   kubectl -n forge scale deploy/forgejo --replicas=0
   kubectl -n forge exec -i forgejo-db-0 -- pg_restore -U forgejo -d forgejo --clean --if-exists --no-owner \
     < forgejo-YYYY-MM-DD.dump
   kubectl -n forge scale deploy/forgejo --replicas=1
   kubectl -n forge exec deploy/forgejo -- forgejo doctor check --all
   ```

6. **Check.**

   ```sh
   kubectl get nodes
   kubectl -n argocd get applications
   kubectl get certificates -A
   kubectl get sealedsecrets -A
   kubectl get talosupgrade,kubernetesupgrade
   curl -I https://aarnihalinen.fi
   ```

   Certificates are issued again by Let's Encrypt, which needs DNS and port 80 to work.

### Sealing the secrets again

Only needed when the Sealed Secrets keys are lost. The files in `sealed-secrets/` are then useless, and each secret in
the table under [Backups to keep](#backups-to-keep) has to be created from its plaintext values, sealed with the key of
the new controller and committed.

```sh
kubectl create secret generic db-password --namespace tp-rent \
  --from-literal=POSTGRES_DB=... --from-literal=POSTGRES_USER=... --from-literal=POSTGRES_PASSWORD=... \
  --dry-run=client -o json |
  kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system -o json \
    > sealed-secrets/sealed-tp-rent-db.json
```

The name and namespace are part of the encryption, so they have to be exactly the ones in the table.
