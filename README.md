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

4. Use `argocd` to tell Argo CD to do its thing?
