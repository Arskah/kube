# Install steps

```sh
kubectl apply namespace.yml
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

## Exclude Cilium resources

<https://medium.com/@rojenshrestha100/argo-cd-out-of-sync-due-to-cilium-identity-f9d6188aa056>

```sh
kubectl edit configmap argocd-cm -n argocd
```

and add

```yaml
apiVersion: v1
data:
  resource.exclusions: |
    - apiGroups:
      - cilium.io
      kinds:
      - CiliumIdentity
      clusters:
      - "*"
kind: ConfigMap
```
