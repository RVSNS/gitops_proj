#!/bin/bash
set -euo pipefail
NAMESPACE="vault"
POD="vault-0"
DEFS_DIR="/vault-policies"

echo "Waiting for $POD to be Ready..."
kubectl wait --for=condition=Ready pod/$POD -n $NAMESPACE --timeout=120s

ROOT_TOKEN=$(kubectl get secret vault-keys -n $NAMESPACE -o jsonpath='{.data.root-token}' | base64 -d)
EXEC="kubectl exec $POD -n $NAMESPACE -- env VAULT_TOKEN=$ROOT_TOKEN vault"

# Every role file (<name>.json) must have a matching policy file (<name>.hcl).
# To register a new app's Vault access, drop both files here - no script changes needed.
for role_file in "$DEFS_DIR"/*.json; do
  name=$(basename "$role_file" .json)
  policy_file="$DEFS_DIR/${name}.hcl"

  if [ ! -f "$policy_file" ]; then
    echo "Skipping $name: no matching policy file $policy_file"
    continue
  fi

  policy_name="${name}-policy"
  role_name=$(jq -r '.role' "$role_file")
  bound_sa=$(jq -r '.bound_service_account_names' "$role_file")
  bound_ns=$(jq -r '.bound_service_account_namespaces' "$role_file")
  ttl=$(jq -r '.ttl' "$role_file")

  echo "Writing Vault policy '$policy_name' from $policy_file..."
  kubectl cp "$policy_file" "$NAMESPACE/$POD:/tmp/${policy_name}.hcl"
  $EXEC policy write "$policy_name" "/tmp/${policy_name}.hcl"

  echo "Writing Kubernetes auth role '$role_name' (sa=$bound_sa ns=$bound_ns, ttl=$ttl)..."
  $EXEC write "auth/kubernetes/role/${role_name}" \
    bound_service_account_names="$bound_sa" \
    bound_service_account_namespaces="$bound_ns" \
    policies="$policy_name" \
    ttl="$ttl"
done

echo "Vault policy sync complete!"
