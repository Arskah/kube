# kube

K8s setup with Talos & ArgoCD

## Talos

The cluster nodes are [Talos Linux](https://www.talos.dev/) VMs running on Proxmox. See [talos/README.md](talos/README.md)
for the machine configuration and how to set up, change and upgrade the nodes.

Node and LAN IP addresses are hardcoded in a couple of config files, grep the repo for them when they change.

## Disaster recovery

[docs/disaster-recovery.md](docs/disaster-recovery.md) has the procedure for rebuilding the whole cluster from scratch, and
lists the secrets, data and network configuration that are not in this repository.

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
