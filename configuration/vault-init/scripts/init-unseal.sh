#!/bin/bash
VAULT_API="http://vault.vault.svc.cluster.local:8200/v1/sys"

echo "Waiting for Vault API..."
while ! curl -s $VAULT_API/health > /dev/null; do sleep 2; done

echo "Vault API is up. Sleeping for 30 seconds to allow observation..."
sleep 30

INIT_STATUS=$(curl -s $VAULT_API/init | jq -r '.initialized')

if [ "$INIT_STATUS" = "false" ]; then
echo "Initializing Vault with 1 share and threshold 1..."
INIT_JSON=$(curl -s --request POST --data '{"secret_shares": 1, "secret_threshold": 1}' $VAULT_API/init)

UNSEAL_KEY=$(echo $INIT_JSON | jq -r '.keys_base64[0]')
ROOT_TOKEN=$(echo $INIT_JSON | jq -r '.root_token')

echo "Storing keys in vault-keys Secret..."
kubectl create secret generic vault-keys \
--from-literal=unseal-key="$UNSEAL_KEY" \
--from-literal=root-token="$ROOT_TOKEN" \
-n vault
fi

echo "Fetching Unseal Key from K8s Secret..."
UNSEAL_KEY=$(kubectl get secret vault-keys -n vault -o jsonpath='{.data.unseal-key}' | base64 -d)

SEAL_STATUS=$(curl -s $VAULT_API/seal-status | jq -r '.sealed')
if [ "$SEAL_STATUS" = "true" ]; then
echo "Unsealing Vault..."
curl -s --request POST --data "{\"key\": \"$UNSEAL_KEY\"}" $VAULT_API/unseal
echo "Vault is unsealed!"
else
echo "Vault is already unsealed."
fi
