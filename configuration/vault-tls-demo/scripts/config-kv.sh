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

echo "Writing demo secret to secret/vault-tls-demo/config..."
$EXEC kv put secret/vault-tls-demo/config message="hello from vault kv2"

echo "Writing Vault policy for vault-tls-demo..."
echo 'path "secret/data/vault-tls-demo/config" { capabilities = ["read"] }' > /tmp/vault-tls-demo-policy.hcl
kubectl cp /tmp/vault-tls-demo-policy.hcl $NAMESPACE/$POD:/tmp/vault-tls-demo-policy.hcl
$EXEC policy write vault-tls-demo-policy /tmp/vault-tls-demo-policy.hcl

echo "Writing Kubernetes auth role for vault-tls-demo..."
$EXEC write auth/kubernetes/role/vault-tls-demo \
  bound_service_account_names=vault-tls-demo \
  bound_service_account_namespaces=default \
  policies=vault-tls-demo-policy \
  ttl=24h

echo "vault-tls-demo Vault configuration complete!"
