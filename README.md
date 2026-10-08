# kube

K8s setup with Talos & ArgoCD

## Talos

The cluster nodes are [Talos Linux](https://www.talos.dev/) VMs running on Proxmox, set up following
<https://docs.siderolabs.com/talos/v1.11/platform-specific-installations/virtualized-platforms/proxmox>.

| Node           | Role          | IP              |
| -------------- | ------------- | --------------- |
| `kube-control` | control plane | `192.168.86.73` |
| `kube-node1`   | worker        | `192.168.86.76` |

### Machine configuration

Machine configs contain the cluster secrets, so they are not committed. The repo only has the patches in
`talos/patches/`, and the full configs are generated from them together with a local secrets bundle:

| File                              | Committed | Content                                                             |
| --------------------------------- | --------- | ------------------------------------------------------------------- |
| `talos/patches/all.yaml`          | yes       | install disk and image, `eth0` NIC naming, no default CNI           |
| `talos/patches/controlplane.yaml` | yes       | hostname, API server cert SANs, kube-proxy disabled                 |
| `talos/patches/worker.yaml`       | yes       | hostname                                                            |
| `talos/secrets.yaml`              | no        | cluster CAs, keys and tokens. Keep a backup outside of this machine |
| `talos/controlplane.yaml`         | no        | generated                                                           |
| `talos/worker.yaml`               | no        | generated                                                           |
| `talos/talosconfig`               | no        | generated, `talosctl` client config                                 |
| `talos/kubeconfig`                | no        | from `talosctl kubeconfig`                                          |

Generate the configs (add `--force` to overwrite existing ones):

```sh
talosctl gen config talos https://192.168.86.73:6443 \
  --with-secrets talos/secrets.yaml \
  --talos-version v1.11.5 \
  --kubernetes-version 1.34.1 \
  --config-patch @talos/patches/all.yaml \
  --config-patch-control-plane @talos/patches/controlplane.yaml \
  --config-patch-worker @talos/patches/worker.yaml \
  --output talos
```

Apply a changed config to a running node:

```sh
export TALOSCONFIG=talos/talosconfig
talosctl apply-config --nodes 192.168.86.73 --file talos/controlplane.yaml
talosctl apply-config --nodes 192.168.86.76 --file talos/worker.yaml
```

The Talos API (port 50000) is only reachable from the LAN.

If `talos/secrets.yaml` is lost but a control plane config still exists, it can be recovered with

```sh
talosctl gen secrets --from-controlplane-config talos/controlplane.yaml --output-file talos/secrets.yaml
```

For a completely new cluster, create new secrets with `talosctl gen secrets --output-file talos/secrets.yaml` instead.

### Notes

- The install image comes from [Image Factory](https://factory.talos.dev/) with the `qemu-guest-agent` extension. The
  tag is the Talos version, and has to be updated together with `--talos-version`.
- `net.ifnames=0` keeps the NIC named `eth0`, which the Cilium configuration relies on.
- The worker patch sets the hostname of the only worker. For more workers, generate with a different hostname per node.
- Cilium is the CNI and replaces kube-proxy, so both are disabled in Talos and nodes stay `NotReady` until Cilium is
  installed. The Talos-specific Helm values from <https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium>
  are set in `apps/templates/cilium.yml`.
- LAN IP addresses are hardcoded in a couple of config files, grep the repo for them when they change.

## ArgoCD

Install `argocd` CLI

```sh
brew install argocd
```

Install ArgoCD with Kustomize

```sh
kubectl kustomize argocd | kubectl apply -f -
kubectl apply -f apps/templates/argo-projects.yml
kubectl apply -f app-of-apps.yml
```

Port forward to the ArgoCD server

```sh
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open ArgoCD UI with

```sh
argocd admin dashboard -n argocd
```

and login (set new password as well)

```sh
argocd admin initial-password -n argocd
argocd login localhost:8080
argocd account update-password
```

Argo should install all other apps (they are included in the app-of-apps).

### Notes

Cilium and cert-manager are by default multi-node => scale down deployments to 1.
Ingress ports might need to be edited to service, seems like a bug.
