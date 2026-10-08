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
| Persistent volumes             | NAS `192.168.86.87`, NFS export `/k8s`              | tp-rent database, registry images                    | data is gone                                                    |
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

   | File in `sealed-secrets/`                 | Secret                                 | Keys                                                | Source of the values                     |
   | ----------------------------------------- | -------------------------------------- | --------------------------------------------------- | ---------------------------------------- |
   | `sealed-gitlab-runner.json`               | `gitlab-runner/gitlab-runner`          | `runner-registration-token`, `runner-token`         | GitLab runner settings                   |
   | `sealed-regcred-argocd.json`              | `argocd/regcred-argocd`                | `.dockerconfigjson`                                 | user of `registry.aarnihalinen.fi`       |
   | `sealed-regcred-homepage-production.json` | `homepage-production/regcred-homepage` | `.dockerconfigjson`                                 | user of `registry.aarnihalinen.fi`       |
   | `sealed-regcred-homepage-staging.json`    | `homepage-staging/regcred-homepage`    | `.dockerconfigjson`                                 | user of `registry.aarnihalinen.fi`       |
   | `sealed-registry-htpasswd.json`           | `docker-registry/registry-htpasswd`    | `htpasswd`                                          | bcrypt hash of the registry password     |
   | `sealed-tp-rent-db.json`                  | `tp-rent/db-password`                  | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` | has to match the existing database files |

   All four registry secrets come from the same user and password: `registry-htpasswd` is the bcrypt hash the registry
   checks against, the three `regcred` secrets are what the cluster logs in with. They have to be sealed again together
   when the password changes.

4. A dump of the tp-rent database, taken regularly:

   ```sh
   kubectl -n tp-rent exec deploy/db -- sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' > tp-rent.sql
   ```

### Persistent volumes

Volumes are directories on the NAS, created by the NFS CSI driver and named after the PersistentVolume. The reclaim
policy is `Retain`, so the directories survive the cluster, but a new cluster creates new, empty directories with new
names. Without this table there is no way to tell which old directory belonged to what.

| Claim                                      | Directory on the NAS                            |
| ------------------------------------------ | ----------------------------------------------- |
| `tp-rent/db-pvc`                           | `/k8s/pvc-a17cd4de-4761-4060-9967-be89708a50a5` |
| `docker-registry/docker-registry-pv-claim` | `/k8s/pvc-aa6d6c15-3c85-4950-92ed-eaf6ab74c855` |

Update the table when claims are added:

```sh
kubectl get pv -o custom-columns=CLAIM_NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,SUBDIR:.spec.csi.volumeAttributes.subdir
```

### Network

Checked from the outside, the router configuration itself has not been reviewed:

- All public hostnames are CNAMEs to `aarnihalinen.fi` (or `halinen.dev` for `kube.halinen.dev`), which have an A record
  with the public address of the home connection. The address has changed before. When it changes, the A records have to
  follow.
- Ports 80, 443 and 6443 are open on the public address. Google Wifi can only forward ports to devices it knows from
  DHCP, so the forwards have to point at the control plane node: 80 to `192.168.86.73:30080`, 443 to
  `192.168.86.73:30443` and 6443 to `192.168.86.73:6443`.
- The node addresses come from DHCP and are hardcoded in this repo, so they need DHCP reservations: `192.168.86.73`
  (`kube-control`), `192.168.86.76` (`kube-node1`) and `192.168.86.87` (NAS). New VMs get new MAC addresses, so the
  reservations have to be made again.
- The DHCP pool of the router is `192.168.86.20`-`192.168.86.99`. `192.168.86.100`-`192.168.86.254` is handed out by
  Cilium to LoadBalancer services (`apps/templates/ip-pool.yml`), so the DHCP pool must not grow into it.

### Virtual machines

Sizes of the current nodes as Kubernetes sees them. The other VM settings are in the
[Talos guide for Proxmox](https://docs.siderolabs.com/talos/v1.11/platform-specific-installations/virtualized-platforms/proxmox).

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

   The homepage images are pulled from the registry in the cluster, so those pods stay in
   `ImagePullBackOff` until the registry volume is restored or the images are pushed again from CI.

   Restoring the database from a dump instead of the files:

   ```sh
   kubectl -n tp-rent exec -i deploy/db -- sh -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB"' < tp-rent.sql
   ```

6. **Check.**

   ```sh
   kubectl get nodes
   kubectl -n argocd get applications
   kubectl get certificates -A
   kubectl get sealedsecrets -A
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

kubectl create secret docker-registry regcred-homepage --namespace homepage-production \
  --docker-server=registry.aarnihalinen.fi --docker-username=... --docker-password=... \
  --dry-run=client -o json |
  kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system -o json \
    > sealed-secrets/sealed-regcred-homepage-production.json
```

The name and namespace are part of the encryption, so they have to be exactly the ones in the table.
