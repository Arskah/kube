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

| File                        | Committed | Content                                                             |
| --------------------------- | --------- | ------------------------------------------------------------------- |
| `patches/all.yaml`          | yes       | install disk and image, `eth0` NIC naming, no default CNI           |
| `patches/controlplane.yaml` | yes       | hostname, API server cert SANs, kube-proxy disabled                 |
| `patches/worker.yaml`       | yes       | hostname                                                            |
| `secrets.yaml`              | no        | cluster CAs, keys and tokens. Keep a backup outside of this machine |
| `controlplane.yaml`         | no        | generated                                                           |
| `worker.yaml`               | no        | generated                                                           |
| `talosconfig`               | no        | generated, `talosctl` client config                                 |
| `kubeconfig`                | no        | from `talosctl kubeconfig`                                          |

All commands below are run from the repo root.

## Generating the machine configs

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

The machine config a node is currently running can be checked with

```sh
talosctl --nodes 192.168.86.73 get machineconfig -o yaml
```

## Setting up a new cluster

Follows <https://docs.siderolabs.com/talos/v1.11/platform-specific-installations/virtualized-platforms/proxmox>, which
also has the recommended VM settings.

1. Create the VMs in Proxmox and boot them from the Talos ISO. The image comes from
   [Image Factory](https://factory.talos.dev/) with the `siderolabs/qemu-guest-agent` extension, so enable the QEMU
   guest agent in the VM options.

   <https://factory.talos.dev/image/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515/v1.11.5/metal-amd64.iso>

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
   until Cilium is running, and ArgoCD pods cannot be scheduled before that. Render the chart with the version and
   values of the ArgoCD Application, so that ArgoCD takes over the same resources afterwards:

   ```sh
   export KUBECONFIG=talos/kubeconfig
   yq '.spec.source.helm.valuesObject' apps/templates/cilium.yml > /tmp/cilium-values.yaml
   helm template cilium cilium \
     --repo https://helm.cilium.io \
     --version "$(yq '.spec.source.targetRevision' apps/templates/cilium.yml)" \
     --namespace kube-system \
     --values /tmp/cilium-values.yaml |
     kubectl apply -f -
   ```

   The values are the Talos-specific ones from <https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium>.

7. Install ArgoCD as described in the [main README](../README.md#argocd). It installs everything else and manages
   Cilium from then on.

## Upgrades

Talos is upgraded one node at a time with the installer image of the new version. Update the image tag in
`patches/all.yaml` and `--talos-version` in the command above to match.

```sh
talosctl upgrade --nodes 192.168.86.73 \
  --image factory.talos.dev/installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:<version>
```

Kubernetes is upgraded for the whole cluster through the control plane node. Update `--kubernetes-version` in the
command above to match.

```sh
talosctl upgrade-k8s --nodes 192.168.86.73 --to <version>
```

## Notes

- The install image ID is the Image Factory schematic, which only adds the `qemu-guest-agent` extension.
- `net.ifnames=0` keeps the NIC named `eth0`, which the Cilium configuration relies on (`devices` in
  `apps/templates/cilium.yml`, the L2 announcement policy in `apps/templates/ip-pool.yml`).
- The worker patch sets the hostname of the only worker. For more workers, generate with a different hostname per node.
- The current cluster was not set up exactly like above. It was bootstrapped with the Talos defaults (Flannel and
  kube-proxy), ArgoCD installed Cilium on top of that, and the defaults were disabled in the machine config afterwards.
  Leftovers from that are still in the cluster: `kube-flannel-cfg` ConfigMap, `flannel` and `kube-proxy`
  ServiceAccounts with their ClusterRoles and ClusterRoleBindings, and `flannel.alpha.coreos.com/*` node annotations.
- `87.92.101.169` in the API server cert SANs is an old public address and can be dropped.
