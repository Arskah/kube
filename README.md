# kube

K8s setup with Kubeadm & ArgoCD

## Kubeadm

### Setup containerd

<https://github.com/kubernetes/kubernetes/issues/110177>

```shell
sudo mkdir /etc/containerd
sudo vim /etc/containerd/config.toml
```

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            BinaryName = ""
            CriuImagePath = ""
            CriuPath = ""
            CriuWorkPath = ""
            IoGid = 0
            IoUid = 0
            NoNewKeyring = false
            NoPivotRoot = false
            Root = ""
            ShimCgroup = ""
            SystemdCgroup = true
```

- <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/>
  - We use containerd, need to enable CRI (Docker installation disables this, delete /etc/containerd/config.toml file)
  - Install kubeadm, kubectl, kubelet
- <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/>

TODO: UPDATE IP ADDRESS!!!

Grep repo for IP, exists in couple of config files.

```shell
sudo kubeadm init \
--skip-phases=addon/kube-proxy \
--apiserver-advertise-address="192.168.86.73" \
--apiserver-cert-extra-sans="kube.aarnihalinen.fi,87.92.163.107"
```

We are running single-node cluster => need to untaint the control-plane

```shell
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

## Talos

TODO: New setup with proxmox with 2 nodes bootstrapped with talos <https://docs.siderolabs.com/talos/v1.11/platform-specific-installations/virtualized-platforms/proxmox>

Update README, figure out a way to commit talos configuration to repo

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
