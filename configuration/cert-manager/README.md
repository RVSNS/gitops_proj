# cert-manager with the Vault PKI issuer

[cert-manager](../../infra/cert-manager.yaml) is installed from the Jetstack Helm
chart (CRDs included). This directory is synced by the
[cert-manager-issuer application](../../infra/cert-manager-issuer-app.yaml) and
adds a `ClusterIssuer` named `vault-issuer` that signs certificates through
Vault's `pki/sign/cert-manager` role, which chains to the shared Vault root CA.

## How it authenticates

1. cert-manager requests a short-lived token for the `vault-issuer` service
   account (audience `vault://vault-issuer`). [vault-issuer-rbac.yaml](vault-issuer-rbac.yaml)
   allows only that.
2. Vault's Kubernetes auth role `cert-manager` accepts that token and grants
   the `cert-manager` policy, which can only call `pki/sign/cert-manager`.
3. The operator copies `vault-tls` with `ca.crt` only (no private keys) into the
   `cert-manager` namespace (`caNamespaces` in [vault-cr.yaml](../vault/vault-cr.yaml));
   the issuer uses it to trust Vault's HTTPS endpoint.

Vault configuration (auth method, policy, PKI role) lives in
[vault-cr.yaml](../vault/vault-cr.yaml).

## Requesting certificates

The PKI role allows subdomains of `svc`, `svc.cluster.local`, and `localhost`,
plus IP SANs; default TTL 24h, maximum 720h.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-app-tls
  namespace: my-app
spec:
  secretName: my-app-tls
  dnsNames:
    - my-app.my-app.svc
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: vault-issuer
```

## Verification

```sh
kubectl get clusterissuer vault-issuer
kubectl -n cert-manager get certificate vault-issuer-smoke-test
```

Both should report `Ready=True`.
