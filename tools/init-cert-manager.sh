#!bash

ROOT=$(dirname $0)
CMROOT="$ROOT/../apps/cert-manager"

$SHELL $ROOT/check-requirements.sh || exit 1

# We'll use this inspect_cert function later.
inspect_cert () {
  sub_selector='\(.extensions.subject_key_id | .[0:16])... \(.subject_dn)'
  iss_selector='\(.extensions.authority_key_id | .[0:16])... \(.issuer_dn)'

  step certificate inspect --format json \
    | jq -r "\"Issuer:  $iss_selector\",\"Subject: $sub_selector\""
}

# Start by grabbing the address of the Vault server so that we can tell
# cert-manager where to find it. We can get that from Docker.

VAULT_DOCKER_ADDRESS=$(docker inspect argo-network \
                       | jq -r '.[0].Containers | .[] | select(.Name == "vault") | .IPv4Address' \
                       | cut -d/ -f1)

echo Vault is running at ${VAULT_DOCKER_ADDRESS}

# Use that address to create a ClusterIssuer that tells cert-manager how to
# use Vault to issue certificates.

sed -e "s/%VAULTADDR%/$VAULT_DOCKER_ADDRESS/" <<EOF > $CMROOT/vault-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-issuer
  namespace: cert-manager
spec:
  vault:
    path: pki/root/sign-intermediate
    server: http://%VAULTADDR%:8200
    auth:
      tokenSecretRef:
         name: vault-pki-token
         key: token
EOF

# Next up, cert-manager needs a token for the pki_policy from Vault. We'll
# save the token in a SealedSecret which will be unwrapped into the
# vault-pki-token Secret referenced in our ClusterIssuer above.
#
# Convenience so we don't have to repeat this for all our Vault commands.
export VAULT_ADDR=http://0.0.0.0:8200/

# Grab the token...
VAULT_TOKEN=$(vault write -field=token /auth/token/create \
                          policies="pki_policy" \
                          no_parent=true no_default_policy=true \
                          renewable=true ttl=767h num_uses=0)

# ...and write it as a SealedSecret into $CMROOT/sealed-token.yaml. This
# kubectl create --dry-run=client -o yaml bit is a neat trick that just
# writes out the YAML we want without applying it to the cluster.

echo "==== Saving cert-manager token ===="
kubectl create secret generic --dry-run=client -o yaml \
        -n cert-manager vault-pki-token \
        --from-literal="token=$VAULT_TOKEN" \
    | kubeseal \
        --controller-namespace=sealed-secrets \
        --format yaml > $CMROOT/sealed-token.yaml

# Finally, tell Vault to actually create our Linkerd trust anchor. This cert
# only exists within Vault, we're explicitly giving it the common name of the
# Linkerd trust anchor ("root.linkerd.cluster.local"), it uses our maximum TTL
# of 2160 hours, and we want Vault to generate it using elliptic-curve crypto.
#
# The "-field=certificate" argument tells Vault to output only the
# certificate. This is safe because there's no secret information in the
# certificate.

echo "==== Creating trust anchor ===="
CERT=$(vault write -field=certificate pki/root/generate/internal \
      common_name=root.linkerd.cluster.local \
      ttl=2160h key_type=ec)

# Dump some information about the trust anchor certificate...
echo "Trust anchor certificate:"
echo "$CERT" | inspect_cert

# ...and then write it as a ConfigMap into $CMROOT/linkerd-trust-bundle.yaml,
# using the --dry-run=client -o yaml trick again.
#
# We could also install trust-manager and let it do this bit for us, but in
# practice, it's often better to scope the trust anchor's lifespan to the
# cluster lifespan, and this is a simple way to do that.

kubectl create configmap --dry-run=client -o yaml \
        -n linkerd linkerd-identity-trust-roots \
        --from-literal="ca-bundle.crt=$CERT" \
    > $CMROOT/linkerd-trust-bundle.yaml
