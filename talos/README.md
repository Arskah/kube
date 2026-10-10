# Talos

The cluster nodes are [Talos Linux](https://www.talos.dev/) VMs running on Proxmox.

| Node           | Role          | IP              |
| -------------- | ------------- | --------------- |
| `kube-control` | control plane | `192.168.86.73` |
| `kube-node1`   | worker        | `192.168.86.76` |

The nodes get their addresses from DHCP, so the addresses need to be reserved in the router.

The Talos API (port 50000) is only reachable from the LAN, so `talosctl` only works there.

## Files

Machine configs contain the cluster secrets, so they are not committed. The repo only has the patches, and the full
configs are generated from them together with a local secrets bundle.

| File                        | Committed | Content                                                                                         |
| --------------------------- | --------- | ----------------------------------------------------------------------------------------------- |
| `patches/all.yaml`          | yes       | install disk and image, `eth0` NIC naming                                                       |
| `patches/controlplane.yaml` | yes       | hostname, API server cert SANs, no default CNI, kube-proxy disabled, Talos API access for tuppr |
| `patches/worker.yaml`       | yes       | hostname                                                                                        |
| `secrets.yaml`              | no        | cluster CAs, keys and tokens. Keep a backup outside of this machine                             |
| `controlplane.yaml`         | no        | generated                                                                                       |
| `worker.yaml`               | no        | generated                                                                                       |
| `talosconfig`               | no        | generated, `talosctl` client config                                                             |
| `kubeconfig`                | no        | from `talosctl kubeconfig`                                                                      |

All commands below are run from the repo root.

## Generating the machine configs

```sh
talosctl gen config talos https://192.168.86.73:6443 \
  --with-secrets talos/secrets.yaml \
  --talos-version v1.14.2 \
  --kubernetes-version 1.36.5 \
  --config-patch @talos/patches/all.yaml \
  --config-patch-control-plane @talos/patches/controlplane.yaml \
  --config-patch-worker @talos/patches/worker.yaml \
  --output talos
```

Add `--force` to overwrite existing configs.

If `talos/secrets.yaml` is lost but a control plane config still exists, it can be recovered with

```sh
talosctl gen secrets --from-controlplane-config talos/controlplane.yaml --output-file talos/secrets.yaml
```

## Changing the configuration of a running node

Edit the patches, generate the configs again and apply them:

```sh
export TALOSCONFIG=talos/talosconfig
talosctl apply-config --nodes 192.168.86.73 --file talos/controlplane.yaml
talosctl apply-config --nodes 192.168.86.76 --file talos/worker.yaml
```

The generated configs also carry the Kubernetes version (the images of the kubelet and the control plane components),
which [tuppr](#upgrades) changes on the nodes when it upgrades. So before applying: pull `main`, check that no upgrade
is running (`kubectl get talosupgrade,kubernetesupgrade`), generate, and run `apply-config` with `--dry-run` first. The
diff it prints should have your change and nothing else; image tags in it mean the local files are older than the
nodes, and applying them would move Kubernetes to another version behind tuppr's back. The diff contains keys when a
document with secrets changes, so do not paste it anywhere.

Most changes apply without a reboot. Some only take effect after one although `apply-config` does not say so
(workload isolation and the mount options of `/var` did); `talosctl reboot` does not drain the node, and the pods
that ran on it are left behind as `Completed` or `Error` next to their replacements.

The machine config a node is currently running can be checked with

```sh
talosctl --nodes 192.168.86.73 get machineconfig -o yaml
```

## Setting up a new cluster

Follows <https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/virtualized-platforms/proxmox>, which
also has the recommended VM settings.

1. Create the VMs in Proxmox and boot them from the Talos ISO. The image comes from
   [Image Factory](https://factory.talos.dev/) with the `siderolabs/qemu-guest-agent` extension, so enable the QEMU
   guest agent in the VM options.

   <https://factory.talos.dev/image/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515/v1.14.2/metal-amd64.iso>

2. Create new cluster secrets. Skip this to rebuild the existing cluster with its current secrets.

   ```sh
   talosctl gen secrets --output-file talos/secrets.yaml
   ```

3. Check the node addresses and the install disk, update them in the patches and in the commands here, and
   [generate the machine configs](#generating-the-machine-configs).

   ```sh
   talosctl get disks --insecure --nodes 192.168.86.73
   ```

4. Apply the configs. The nodes install Talos to disk and reboot.

   ```sh
   talosctl apply-config --insecure --nodes 192.168.86.73 --file talos/controlplane.yaml
   talosctl apply-config --insecure --nodes 192.168.86.76 --file talos/worker.yaml
   ```

5. Bootstrap etcd on the control plane node and fetch the kubeconfig.

   ```sh
   export TALOSCONFIG=talos/talosconfig
   talosctl config endpoint 192.168.86.73
   talosctl config node 192.168.86.73
   talosctl bootstrap
   talosctl kubeconfig talos
   ```

6. Install Cilium. The default CNI (Flannel) and kube-proxy are disabled in the patches, so the nodes stay `NotReady`
   until Cilium is running, and ArgoCD pods cannot be scheduled before that. Cilium only starts its Gateway API support
   when the Gateway API CRDs exist, so install them first. Use the versions and values of the ArgoCD Applications, so
   that ArgoCD takes over the same resources afterwards:

   ```sh
   export KUBECONFIG=talos/kubeconfig
   kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$(yq '.spec.source.targetRevision' apps/templates/gateway-api.yml)/standard-install.yaml"
   yq '.spec.source.helm.valuesObject' apps/templates/cilium.yml > /tmp/cilium-values.yaml
   helm template cilium cilium \
     --repo https://helm.cilium.io \
     --version "$(yq '.spec.source.targetRevision' apps/templates/cilium.yml)" \
     --namespace kube-system \
     --values /tmp/cilium-values.yaml \
     --set prometheus.serviceMonitor.enabled=false \
     --set operator.prometheus.serviceMonitor.enabled=false \
     --set envoy.prometheus.serviceMonitor.enabled=false |
     kubectl apply -f -
   ```

   The ServiceMonitors are left out because their CRD only arrives with the monitoring application. For the same
   reason ArgoCD cannot render the `cilium` application until `monitoring` has synced once; it retries on its own.

   The values are the Talos-specific ones from <https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium>.

7. Install ArgoCD as described in the [main README](../README.md#argocd). It installs everything else and manages
   Cilium from then on.

   That includes tuppr, which brings the nodes to the versions in [`tuppr/`](../tuppr) as soon as it runs. The ISO
   link and the `talosctl gen config` command here are kept at the same versions, so it finds nothing to do. With
   another ISO or `--kubernetes-version`, change `tuppr/` to match first, or the new nodes are upgraded and rebooted
   in the middle of the setup.

## Upgrades

[tuppr](https://tuppr.home-operations.com/) upgrades Talos and Kubernetes. The versions are in
[`tuppr/`](../tuppr) in the repo root; Renovate opens a PR when there is a new one and bumps the image tag in
`patches/all.yaml` and the versions in this file with it. **Merging the PR starts the upgrade**, there is no
maintenance window: a Talos upgrade reboots one node after the other, and while `kube-control` reboots the API and
the public sites are down.

- Patch releases come as PRs. Minor releases wait in the Dependency Dashboard until they are ticked there.
- tuppr does not check that a step is supported. Talos has to go through the latest patch of every minor version,
  and the release notes of a new minor are worth reading first (1.14 changed the machine config format). Kubernetes
  can only go as far as Talos, Cilium, ArgoCD and cert-manager support.
- tuppr takes no etcd snapshot. A Talos minor can bring a new etcd minor (1.14 did), after which
  `talosctl rollback` of the control plane node is not clean. Before merging one:
  `talosctl --nodes 192.168.86.73 etcd snapshot <file>`, and keep `talos/secrets.yaml` at hand, restoring needs both.
- `--talos-version` above also selects the format of the generated machine config. After a Talos minor, generate
  the configs again and compare them with the nodes before applying anything.
- After the control plane node has rebooted, cilium-operator has repeatedly come up without its Gateway API
  controller. The alert `CiliumGatewayControllerNotRunning` fires then; restart it with
  `kubectl -n kube-system rollout restart deploy/cilium-operator`.

```sh
kubectl get talosupgrade,kubernetesupgrade
kubectl describe talosupgrade cluster
kubectl -n system-upgrade logs deploy/tuppr
```

By hand it is `talosctl upgrade` per node with the installer image of the new version, and `talosctl upgrade-k8s`
for the whole cluster through the control plane node. Suspend tuppr first
(`kubectl annotate talosupgrade cluster tuppr.home-operations.com/suspend=true`, same for `kubernetesupgrade
kubernetes`), so that it does not act on the nodes at the same time, and bring the versions in `tuppr/` in line
afterwards.

```sh
talosctl upgrade --nodes 192.168.86.73 \
  --image factory.talos.dev/installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:<version>
talosctl upgrade-k8s --nodes 192.168.86.73 --to <version>
```

## Notes

- The install image ID is the Image Factory schematic, which only adds the `qemu-guest-agent` extension.
- `net.ifnames=0` keeps the NIC named `eth0`, which the Cilium configuration relies on (`devices` in
  `apps/templates/cilium.yml`, the L2 announcement policy in `apps/templates/ip-pool.yml`).
- The patches are written for the configuration documents of Talos 1.14, which `talosctl gen config` generates next to
  a small `v1alpha1` document when `--talos-version` is 1.14 or later. One thing differs from what it generates by
  default: the installer is still configured in `machine.install`, because the `UnattendedInstallConfig` document has no
  field for kernel arguments.
- Workload isolation is on (`SecurityProfileConfig`, generated by default): containerd, the kubelet and the pods run in
  their own PID and mount namespace. `talosctl logs sandboxd` has the logs of the service that holds it.
- The client certificates in `talosconfig` and `kubeconfig` are valid for one year. Generating the machine configs
  again gives a new `talosconfig` (run `talosctl config endpoint 192.168.86.73` on it afterwards, a fresh one points
  at `127.0.0.1`), and `talosctl kubeconfig talos --force` a new `kubeconfig`. tuppr gets its own credentials from
  Talos and is not affected.
- The worker patch sets the hostname of the only worker. For more workers, generate with a different hostname per node.
- The current cluster was not set up exactly like above. It was bootstrapped with the Talos defaults (Flannel and
  kube-proxy), ArgoCD installed Cilium on top of that, and the defaults were disabled in the machine config afterwards.
  What they left behind in the cluster has been removed.
