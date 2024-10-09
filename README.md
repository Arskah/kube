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

UPDATE IP ADDRESS!!!

```shell
sudo kubeadm init \
--skip-phases=addon/kube-proxy \
--apiserver-advertise-address="192.168.86.22" \
--apiserver-cert-extra-sans="kube.aarnihalinen.fi,87.92.163.107"
```

We are running single-node cluster => need to untaint the control-plane

```shell
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

## ArgoCD

Install resources inside <./argocd>. See README in the directory.

Let ArgoCD setup all applications.

### Smaller tweaks

Enable Hubble (try to make this declarative)

```shell
cilium hubble enable
```

#### Notes

Cilium and cert-manager are by default multi-node => scale down deployments to 1.
Ingress ports might need to be edited to service, seems like a bug.
