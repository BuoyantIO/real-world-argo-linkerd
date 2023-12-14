# argocd-linkerd-demo-2

This demo uses an environment where a k3d cluster and a Vault server are
running on the same Docker network, mimicking a world where there's a secret
store outside Kubernetes that Kubernetes should use.

## Running the Demo

**WARNING:** Setting up the environment will destroy any existing k3d cluster
named `argo-cluster` and any existing Docker container named `vault`.

1. Run `bash tools/init-world.sh` to set up the environment. This will

   - Delete any existing k3d cluster named `argo-cluster` and any existing Docker
     container named `vault`.
   - Create a k3d cluster named `argo-cluster`, attached to a Docker network named
     `argo-network`.
   - Create a Docker container named `vault` attached to the `argo-network` Docker
     network, running a Vault server with a root token of `root`.
   - Configure the Vault server so that we can use it for Linkerd.
   - Install the Bitnami Sealed Secrets controller in the `sealed-secrets`
     namespace.

2. Run `bash tools/init-cert-manager.sh` to modify the YAML in
   `apps/cert-manager` to match the running Vault server. This will

   - Create `apps/cert-manager/sealed-token.yaml` containing a SealedSecret
     with the Vault token that cert-manager will use to communicate with
     Vault.
   - Create `apps/cert-manager/vault-issuer.yaml` containing a cert-manager
     ClusterIssuer telling cert-manager how to use the running Vault server to
     issue certificates.

3. Commit the changes made by `tools/init-cert-manager.sh` in the
   `apps/cert-manager` directory, and push the commit. This will permit Argo
   CD to see the correct information for cert-manager.

4. Installing & setting up Argo CD (manually):
```
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Then use port-forwarding to view the Argo CD UI:

```
kubectl -n argocd port-forward svc/argocd-server 8080:443 > /dev/null 2>&1 &
```

The Argo CD UI should now be visible when you visit https://localhost:8080/.

We’ll be using the argocd CLI for our next steps, which means that we need to authenticate the CLI:

```
password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

argocd login 127.0.0.1:8080 \
  --username=admin \
  --password="$password" \
  --insecure
```

To get the initial admin password, run:

```
argocd admin initial-password -n argocd
```

This password is only meant to be used to log in initially, so let’s update it with the `argocd account update-password` command and then delete the `argocd-initial-admin-secret` from the argocd namespace.

```
argocd account update-password
```

Input the old password when prompted, and then input your new password.

Now we can delete the `argocd-initial-admin-secret`:
```
kubectl delete secret argocd-initial-admin-secret -n argocd
```

5. Log into the Argo CD UI with your updated admin password

6. Set the environment variable for the sync wave delay to 30s. The default is 2, but this doesn't give resources enough time to come up.

```
kubectl set env statefulset argocd-application-controller -n argocd ARGOCD_SYNC_WAVE_DELAY=30s
```
7. Apply the argocd-cm configmap to add the custom lua health script:
```
kubectl apply -f argocd/configmap/argocd-cm.yaml
```
8. Apply the `faces-app-of-apps.yaml` to deploy the parent application, which in turn will create all the children applications:
```
kubectl apply -f faces-app-of-apps.yaml
```

