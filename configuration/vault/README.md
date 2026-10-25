# Automated Vault CA bootstrap

This configuration uses one root CA for Vault's HTTPS listener and its `pki`
secrets engine. The private key is stored in the `vault/vault-tls` Kubernetes
Secret and imported into Vault. This is a local-development design: compromise
of either copy compromises both uses of the CA.

## Startup order

The [Vault application](../../infra/vault-instance-app.yaml) syncs this directory.
Commit and push the manifests before relying on Argo CD; it reads GitHub, not
the local working tree.

1. Wave `-1` creates the bootstrap and Vault service accounts and RBAC.
2. The wave `0` [bootstrap hook](vault-ca-bootstrap.yaml) reads `vault-tls`.
   If absent, it creates a 3072-bit RSA root valid for 3,650 days. If present,
   it validates and reuses the CA. Invalid, mismatched, incomplete, or
   near-expiry CA material fails the hook instead of being silently replaced.
3. Bootstrap also supplies the initial server certificate, or recreates it
   when restoring a CA-only Secret. Operator v1.22.1 expects `server.crt` to
   exist when it encounters an existing TLS Secret; a CA-only Secret cannot
   be handed directly to the operator.
4. Wave `2` applies the [Vault resource](vault-cr.yaml). The operator uses
   `vault-tls` and subsequently renews server certificates with its CA.
   `existingTlsSecretName` is intentionally unset: setting it would disable
   operator-managed certificate generation.
5. Vault initializes and unseals using `vault-unseal-keys`. The configurer
   imports the CA certificate and key from the mounted TLS Secret into
   `pki/config/ca`. There is no separate `root/generate` operation.

The bootstrap hook runs on each sync. A valid, unchanged Secret is left
untouched. Temporary key files live on a memory-backed volume. No private
key is embedded in the manifests or printed by the bootstrap scripts.

## Restore the CA before starting Vault

Keep `ca.crt` and `ca.key` in an external secret store or encrypted backup.
On a replacement cluster, restore them **before the first Vault application
sync**:

```sh
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -
kubectl -n vault create secret generic vault-tls \
  --from-file=ca.crt=/secure/restore/ca.crt \
  --from-file=ca.key=/secure/restore/ca.key
```

The second command intentionally fails if the Secret already exists. Do not
overwrite a running cluster's CA as a restore shortcut.

Then sync the application. Bootstrap validates the restored pair, normalizes
the RSA private key to the operator's PKCS#1 format if needed, and issues a
new server certificate without changing the root certificate. Without a
restored Secret, a fresh cluster gets a **new** CA identity.

A future cloud secret-store integration must restore the pair atomically
before the bootstrap hook runs. Do not let another controller continuously
overwrite operator-managed `server.crt` and `server.key`.

## Verification

These commands display only public certificates. Their SHA-256 fingerprints
must match:

```sh
kubectl -n vault get secret vault-tls -o jsonpath='{.data.ca\.crt}' |
  base64 -d | openssl x509 -noout -fingerprint -sha256

kubectl -n vault exec vault-0 -c vault -- sh -ec '
  export VAULT_ADDR=https://127.0.0.1:8200
  export VAULT_CACERT=/vault/tls/ca.crt
  vault read -field=certificate pki/cert/ca
' | openssl x509 -noout -fingerprint -sha256
```

## Limitations

- Kubernetes Secrets are not an external backup; base64 is not encryption.
  Restrict Secret access and configure encryption at rest as appropriate.
- CA backup alone does not restore Vault data. Preserve Vault storage and
  the matching unseal material as well. This configuration uses a local-path
  PVC, not replicated or externally backed-up storage.
- Bootstrap checks are not a CA rotation controller. The operator can replace
  its CA near expiry independently of Argo CD. Plan root rotation well before
  the seven-day renewal threshold, with overlapping client trust.
- The single Vault replica and file storage do not provide HA or guaranteed
  zero downtime during server restarts or certificate renewal.
- PKI URLs currently point to the default issuer. Before introducing multiple
  issuers for rotation, configure issuer-specific URLs and handle certificates
  already issued with the old URLs.
