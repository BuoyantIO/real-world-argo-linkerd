#!bash

ROOT=$(dirname $0)
$SHELL $ROOT/check-requirements.sh || exit 1

# Kill anything lingering from before...
docker kill vault
k3d cluster delete argo-cluster

# If anything fails after this, bail.
set -e

# Fire up our cluster. Use the "argo-network" Docker network, expose ports 80
# & 443 to the host network, and disable local-storage, traefik, and
# metrics-server.
echo "==== Creating k3d cluster ===="
k3d cluster create argo-cluster \
    --network=argo-network \
    -p "80:80@loadbalancer" -p "443:443@loadbalancer" \
    --k3s-arg '--disable=local-storage,traefik,metrics-server@server:*;agents:*'

# Install Bitnami's Sealed Secrets controller in the sealed-secrets namespace.
helm repo add bitnami-labs https://bitnami-labs.github.io/sealed-secrets/
helm install -n sealed-secrets --create-namespace --wait \
     sealed-secrets-controller bitnami-labs/sealed-secrets

# Run Vault in a container, attached to the same network as our cluster.
# Important things here:
# -dev: use development mode
# -dev-listen-address: listen on all interfaces, not just localhost
# -dev-root-token-id: set the root token (AKA password) to something we know
echo "==== Starting Vault ===="
docker run \
       --detach \
       --rm --name vault \
       -p 8200:8200 \
       --network=argo-network \
       --cap-add=IPC_LOCK \
       hashicorp/vault \
       server \
       -dev -dev-listen-address 0.0.0.0:8200 \
       -dev-root-token-id my-token

# Convenience so we don't have to repeat this for all our Vault commands.
export VAULT_ADDR=http://0.0.0.0:8200/

# Give Vault a few seconds to get ready.
sleep 5

# Configure Vault. Log in using the oh-so-secret root token, then enable the
# PKI secrets engine, and tune it to have a maximum lease of 2160 hours (90
# days).
echo "==== Logging into Vault (at $VAULT_ADDR) ===="
vault login my-token

echo "==== Configuring Vault ===="
vault secrets enable pki
vault secrets tune -max-lease-ttl=2160h pki

# Configure Vault's PKI engine to use the URLs that cert-manager will expect.
vault write pki/config/urls \
   issuing_certificates="http://127.0.0.1:8200/v1/pki/ca" \
   crl_distribution_points="http://127.0.0.1:8200/v1/pki/crl"

# Create a policy that allows pretty much unrestricted access to the PKI
# secrets engine...
echo 'path "pki*" {  capabilities = ["create", "read", "update", "delete", "list", "sudo"]}' \
   | vault policy write pki_policy -
