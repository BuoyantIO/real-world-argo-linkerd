# DEMO

<!-- @import tools/check-requirements.sh -->
<!-- @import tools/check-github.sh -->
<!-- @start_livecast -->
<!-- @SHOW -->

We have Vault and our k3d cluster already running, so let's start by setting
up the things that cert-manager and GitOps will need.

The first thing we need is the address of the Vault server, so that we can
tell cert-manager where to find it. We can get that from Docker.

```bash
VAULT_DOCKER_ADDRESS=$(docker inspect argo-network \
                       | jq -r '.[0].Containers | .[] | select(.Name == "vault") | .IPv4Address' \
                       | cut -d/ -f1)

#@immed
echo Vault is running at ${VAULT_DOCKER_ADDRESS}
```

We can use that address to create a ClusterIssuer that tells cert-manager how
to use Vault to issue certificates.

```bash
sed -e "s/%VAULTADDR%/${VAULT_DOCKER_ADDRESS}/" \
    < templates/vault-issuer.yaml \
    > apps/cert-manager-config/vault-issuer.yaml
bat apps/cert-manager-config/vault-issuer.yaml
```

Next up, cert-manager needs a token for the `pki_policy`` from Vault. We'll
save the token in a SealedSecret which will be unwrapped into the
`vault-pki-token` Secret referenced in our ClusterIssuer above.

We'll start by setting the `VAULT_ADDR` variable so we can more easily talk to
our Vault...

```bash
export VAULT_ADDR=http://0.0.0.0:8200/
```

Then we can grab the token...

```bash
VAULT_TOKEN=$(vault write -field=token /auth/token/create \
                          policies="pki_policy" \
                          no_parent=true no_default_policy=true \
                          renewable=true ttl=767h num_uses=0)
```

...and save it as the SealedSecret we mentioned. (This trick with `kubectl
create --dry-run=client -o yaml` just writes out the YAML we want without
applying it to the cluster.)

```bash
kubectl create secret generic --dry-run=client -o yaml \
        -n cert-manager vault-pki-token \
        --from-literal="token=$VAULT_TOKEN" \
    | kubeseal \
        --controller-namespace=sealed-secrets \
        --format yaml > apps/cert-manager-config/sealed-token.yaml
bat apps/cert-manager-config/sealed-token.yaml
```

Finally, tell Vault to actually create our Linkerd trust anchor. This cert
only exists within Vault, we're explicitly giving it the common name of the
Linkerd trust anchor ("root.linkerd.cluster.local"), it uses our maximum TTL
of 2160 hours, and we want Vault to generate it using elliptic-curve crypto.

We'll use the `-field=certificate` argument to tell Vault to output the
certificate's public half so that we can save that into the cluster. This is
safe because there's no secret information in the certificate.

```bash
CERT=$(vault write -field=certificate pki/root/generate/internal \
      common_name=root.linkerd.cluster.local \
      ttl=2160h key_type=ec)
```

Linkerd needs that saved into the ConfigMap `linkerd-identity-trust-roots` in
the `linkerd` namespace. We'll use the `--dry-run=client -o yaml` trick again
for this. One note here: we're still saving this into the
`apps/cert-manager-config` directory, because we'll let Argo CD actually apply
it while setting up to allow cert-manager to work.

(We could also install trust-manager and let it do this bit for us, but in
practice, it's often better to scope the trust anchor's lifespan to the
cluster lifespan, and this is a simple way to do that.)

```bash
kubectl create configmap --dry-run=client -o yaml \
        -n linkerd linkerd-identity-trust-roots \
        --from-literal="ca-bundle.crt=$CERT" \
    > apps/cert-manager-config/linkerd-trust-bundle.yaml
bat apps/cert-manager-config/linkerd-trust-bundle.yaml
```

That's cert-manager's config done! Next, let's switch our Applications to use
our own forks of both our repos. First we'll figure out the URL for our fork
of `real-world-argo-linkerd`:

```bash
TARGETREPO="https://github.com/${GITHUB_USER}/argocd-linkerd-demo-2.git"
```

Next, we'll use `yq` to update the `repoURL` field in the `spec.source`
section of each of our Applications.

```bash
yq e -i ".spec.source.repoURL = \"${TARGETREPO}\"" \
   argocd/applications/cert-manager-app.yaml
yq e -i ".spec.source.repoURL = \"${TARGETREPO}\"" \
   argocd/applications/linkerd-app.yaml
yq e -i ".spec.source.repoURL = \"${TARGETREPO}\"" \
   argocd/applications/rollouts-app.yaml
yq e -i ".spec.source.repoURL = \"${TARGETREPO}\"" \
   faces-app-of-apps.yaml
yq e -i ".spec.source.repoURL = \"${TARGETREPO}\"" \
   argocd/applications/emissary-app.yaml
```

The `faces-app.yaml` file is a little different, because it needs to point
to our fork of the `gitops-faces` repo:

```bash
TARGETREPO="https://github.com/${GITHUB_USER}/gitops-faces.git"

yq e -i ".spec.source.repoURL = \"${TARGETREPO}\"" \
   argocd/applications/faces-app.yaml
```

We'll have collected a few changes for our repo that we need to commit. First,
we've added a few files for cert-manager:

```bash
git status apps/cert-manager-config
git add apps/cert-manager-config
git commit -m "Set up for our Vault instance"
```

Next, we've updated the `repoURL` field in our Application definitions to
correctly point to this fork. (There may some random formatting changes here
too.)

```bash
git diff argocd/applications faces-app-of-apps.yaml
git add argocd/applications faces-app-of-apps.yaml
git commit -m "Set up for our GitHub repos"
git push
```

Finally, we'll repeat the `repoURL` edits for the Application definitions in
our `gitops-faces` clone, too.

```bash
TARGETREPO="https://github.com/${GITHUB_USER}/gitops-faces.git"

yq e -i ".spec.source.repoURL = \"${TARGETREPO}\"" \
   ../gitops-faces/argocd/applications/faces-bootstrap.yaml
yq e -i ".spec.source.repoURL = \"${TARGETREPO}\"" \
   ../gitops-faces/argocd/applications/faces-config.yaml
yq e -i ".spec.source.repoURL = \"${TARGETREPO}\"" \
   ../gitops-faces/argocd/faces.yaml

git -C ../gitops-faces diff
git -C ../gitops-faces add argocd
git -C ../gitops-faces commit -m "Set up for our GitHub repo"
git -C ../gitops-faces push
```

<!-- @SHOW -->

OK! Let's set up Argo CD. We'll start by creating the namespace and then
installing the Argo CD components.

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
        -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

We also want to explicitly change the delay between sync waves to 30 seconds
-- the default is 2, but this is a little fast for some of the things we're
running. We do this with an environment variable on the
`argocd-application-controller` StatefulSet, and we're going to do this now
since that will restart the StatefulSet.

```bash
kubectl set env statefulset \
        -n argocd argocd-application-controller \
        ARGOCD_SYNC_WAVE_DELAY=30
```

Let's wait for Argo to be running...

```bash
kubectl rollout status -n argocd deploy
kubectl rollout status -n argocd statefulset
```

Then we can use port-forwarding to make the Argo CD UI available:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443 > /dev/null 2>&1 &
```

We'll be using the `argocd` CLI for our next steps, which means that we need
to authenticate the CLI. We can do that by getting the initial admin password
from the `argocd-initial-admin-secret` in the `argocd` namespace.

```bash
password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

argocd login 127.0.0.1:8080 \
    --username=admin \
    --password="$password" \
    --insecure
```

This initial password is really meant only for the initial login, so let's
change it to something else. Input the old password when prompted, and then
input a new password.

```bash
argocd admin initial-password -n argocd
argocd account update-password
```

Now we can delete the `argocd-initial-admin-secret`.

```bash
kubectl delete secret argocd-initial-admin-secret -n argocd
```

Next, we need to tell Argo CD about the OCI Helm repo we'll be using for a
couple of things. This is important because we'll be using the `oci` protocol,
which is not supported unless we explicitly enable it.

```bash
bat dwflynn-repo.yaml
kubectl apply -f dwflynn-repo.yaml
```

Finally, we're going to set up a custom health check for Argo CD, so that it
can do a better job of keeping track of when Applications are ready.

```bash
bat argocd/configmap/argocd-cm.yaml
kubectl apply -f argocd/configmap/argocd-cm.yaml
```

And now, we can apply our app-of-apps and watch everything happen!

```bash
bat faces-app-of-apps.yaml
kubectl apply -f faces-app-of-apps.yaml
```

<!-- @browser_then_terminal -->

