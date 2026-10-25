# Infrastructure applications

## Consul

[consul.yaml](consul.yaml) deploys the official HashiCorp Helm chart through
Argo CD into the `consul` namespace. Server-side comparison accounts for
Kubernetes-defaulted StatefulSet fields without ignoring configuration drift.

- One server agent, with `bootstrapExpect: 1` and a 1 GiB PVC.
- Client agents run as the chart-managed `consul-client` DaemonSet, one per
  eligible node. They join the single server and inherit the global ACL,
  gossip encryption, and TLS settings. Clients do not add voting servers or
  improve server failure tolerance.
- ACLs are automatically bootstrapped with a default-deny policy. The bootstrap
  management token is stored in Vault KV v2 at `secret/consul/bootstrap` (`token`).
  Keep this administrative token private and issue scoped tokens for workloads.
- Gossip encryption is enabled, using Vault KV v2 at `secret/consul/gossip` (`key`).
  [consul-credentials-app.yaml](consul-credentials-app.yaml) runs an idempotent
  bootstrap hook that imports existing Kubernetes credentials without changing
  them. On a fresh install it generates a gossip key and leaves an empty token
  for the chart's ACL bootstrap job to populate. Mismatched credentials fail
  explicitly rather than overwriting either copy.
- TLS verification and HTTPS-only API access are enabled. Vault's `pki` engine
  issues server certificates using the restricted `consul-server` PKI role.
  Vault Agent refreshes them; `auto_reload_config` makes Consul reload the
  certificate/key files without requiring an Argo CD sync or pod restart.
- Client agents use auto-encryption. The chart requires the internal Connect
  CA for this feature, so `server.connect` remains enabled, but its provider is
  Vault: the dedicated `pki_consul` intermediate is signed by the existing
  Vault root in `pki`. This does not deploy a service mesh: Connect injection,
  proxies and gateways remain disabled.
- Applications need only the **Vault root CA** to verify either Vault or Consul
  HTTPS endpoints. Client-agent certificates include their intermediate chain.
  This establishes shared trust; it does not configure application trust stores
  automatically. Gossip encryption is separate from PKI and remains enabled.
- [vault-injector.yaml](vault-injector.yaml) deploys only the Vault Agent injector,
  using the existing Bank-Vaults-managed server. Its webhook is restricted to
  the `consul` namespace and fails closed. Injected agents verify Vault using
  `consul/vault-tls` (`ca.crt`), copied by the Vault operator. **No root private
  key is copied into the Consul namespace.** Vault roles are bound to individual
  Consul service accounts; only the server can issue its own certificates and
  manage the dedicated client intermediate.

### Deployment order and existing-cluster migration

Sync waves install Vault first, then the Vault injector, the Consul credential
bootstrap application, and finally Consul. For an existing cluster, deploy the
Vault prerequisites and wait for the credential hook and injector to be healthy
before switching the Consul chart values. Back up a Consul snapshot, ACL token,
gossip key and existing TLS Secrets securely before starting.

An existing Connect CA configuration is persisted in Consul's Raft state;
changing the Helm values alone does not migrate it. After the Vault-backed
server starts, an administrator must update `/v1/connect/ca/config` with
`Provider: vault` and the `Config` rendered in
`consul-server-config` / `connect-ca-config.json`. Use the existing Consul ACL
management token securely, not in command arguments. The configuration uses
Kubernetes auth (`consul-server` role), the public CA file
`/consul/vault-ca/tls.crt`, root mount `pki`, intermediate mount `pki_consul`,
`IntermediateCertTTL: 168h` and `LeafCertTTL: 24h`. Provider migration can require
`ForceWithoutCrossSigning: true`; this intentionally permits an abrupt CA
transition. Schedule downtime for this single-server setup.

Restart the client DaemonSet after switching the persisted CA so it obtains
Vault-rooted certificates. Verify both server and client HTTPS endpoints using
only the Vault root, including hostname verification, and confirm membership
and DNS discovery. Retain the old credentials securely for rollback; the
credential bootstrap hook compares the old Kubernetes copies with Vault on
subsequent syncs. Do not rotate one copy independently while retaining the other.

### Verification

```sh
kubectl -n argocd get application consul
kubectl -n argocd get application vault-injector consul-credentials
kubectl -n consul get pods,pvc,daemonsets
kubectl -n consul rollout status daemonset/consul-client --timeout=300s
kubectl -n consul exec consul-server-0 -- consul members
```

Expect `Synced/Healthy`, one `consul-server-0` pod, a bound PVC, and one ready
`consul-client` pod per eligible node (plus Vault Agent containers). The member list should show one server
and the client agents, all `alive`. If ACLs deny membership inspection, use a
token with `node:read` through `CONSUL_HTTP_TOKEN` inside the pod; do not put
tokens in command arguments or commit them to Git.

The UI is private (ClusterIP). For local access:

```sh
kubectl -n consul port-forward svc/consul-ui 18501:443
```

Open `https://localhost:18501`. The browser will not initially trust the
Vault root CA. Obtain the CA securely and configure client trust rather
than disabling certificate verification. Sign in with an appropriately scoped
ACL token; the bootstrap token is for administration, not routine workloads.

### Limitations and recovery

One server is sufficient for a lab, but has no failure tolerance. Restarts,
upgrades, and node outages interrupt service. Use three or five servers across
failure domains for HA.

The chart gracefully removes a terminating server from gossip membership. With
only one server, existing clients can remain without a known server after that
pod is replaced. If they do not recover, restart the client DaemonSet after the
server is ready, then verify membership and discovery again:

```sh
kubectl -n consul rollout status statefulset/consul-server --timeout=300s
kubectl -n consul rollout restart daemonset/consul-client
kubectl -n consul rollout status daemonset/consul-client --timeout=300s
```

The PVC uses the cluster's default storage class (k3d local-path here). It does
not survive deleting the cluster. Back up Consul snapshots and the generated
Secrets and Vault data externally: Kubernetes Secrets alone are not a DR backup.
In particular, retain the ACL bootstrap token, gossip key, Vault root and
intermediate signing material when restoring data. Do not recreate the Vault
root during recovery if existing applications must continue to trust it.

Vault must be available to start new Consul pods and renew certificates. Running
agents continue to operate during short Vault outages, but certificate expiry
eventually interrupts TLS. Server certificates last 24 hours; client certificates
last 24 hours and their intermediate lasts 7 days. Monitor certificate expiry,
Vault Agent errors, and Consul CA renewal. The existing Vault storage and
cert-manager issuer remain unchanged; Consul uses its own scoped PKI role.
