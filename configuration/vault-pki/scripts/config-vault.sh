#!/bin/bash
NAMESPACE="vault"
POD="vault-0"

echo "Waiting for $POD to be Ready..."
kubectl wait --for=condition=Ready pod/$POD -n $NAMESPACE --timeout=120s

# Retrieve the root token from the k8s secret
ROOT_TOKEN=$(kubectl get secret vault-keys -n $NAMESPACE -o jsonpath='{.data.root-token}' | base64 -d)
EXEC="kubectl exec $POD -n $NAMESPACE -- env VAULT_TOKEN=$ROOT_TOKEN vault"

echo "Checking if PKI engine is enabled..."
if ! $EXEC secrets list | grep -q "pki/"; then
  echo "Configuring PKI Engine..."
  $EXEC secrets enable pki
  $EXEC secrets tune -max-lease-ttl=87600h pki
  $EXEC write -field=certificate pki/root/generate/internal common_name="gitops-cluster-ca" ttl=87600h
  $EXEC write pki/config/urls issuing_certificates="http://vault.vault.svc:8200/v1/pki/ca" crl_distribution_points="http://vault.vault.svc:8200/v1/pki/crl"
  $EXEC write pki/roles/cert-manager allowed_domains="*" allow_subdomains=true allow_any_name=true max_ttl="72h"
fi

echo "Checking if Kubernetes Auth is enabled..."
if ! $EXEC auth list | grep -q "kubernetes/"; then
  echo "Configuring Kubernetes Auth..."
  $EXEC auth enable kubernetes
  $EXEC write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"
fi

echo "Configuring Vault Policy and Role for cert-manager..."
# Write policy to a temporary file and copy it into the pod
echo 'path "pki/sign/cert-manager" { capabilities = ["create", "update"] }' > /tmp/cert-manager-policy.hcl
kubectl cp /tmp/cert-manager-policy.hcl $NAMESPACE/$POD:/tmp/cert-manager-policy.hcl

$EXEC policy write cert-manager-policy /tmp/cert-manager-policy.hcl
$EXEC write auth/kubernetes/role/cert-manager \
  bound_service_account_names=vault-issuer \
  bound_service_account_namespaces=cert-manager \
  policies=cert-manager-policy \
  ttl=24h
  
echo "Vault PKI Configuration Complete!"
