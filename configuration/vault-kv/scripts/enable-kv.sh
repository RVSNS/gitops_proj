#!/bin/bash
set -euo pipefail
NAMESPACE="vault"
POD="vault-0"

echo "Waiting for $POD to be Ready..."
kubectl wait --for=condition=Ready pod/$POD -n $NAMESPACE --timeout=120s

ROOT_TOKEN=$(kubectl get secret vault-keys -n $NAMESPACE -o jsonpath='{.data.root-token}' | base64 -d)
EXEC="kubectl exec $POD -n $NAMESPACE -- env VAULT_TOKEN=$ROOT_TOKEN vault"

echo "Checking if KV v2 engine is enabled at secret/..."
if ! $EXEC secrets list | grep -q "^secret/"; then
  echo "Enabling KV v2 engine..."
  $EXEC secrets enable -version=2 -path=secret kv
fi

echo "Seeding demo secret at secret/vault-tls-demo/config..."
$EXEC kv put secret/vault-tls-demo/config message="hello from vault kv2"

echo "Vault KV v2 setup complete!"
