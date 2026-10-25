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
  management token is stored in `consul/consul-bootstrap-acl-token` (`token`).
  Keep this administrative token private and issue scoped tokens for workloads.
- Gossip encryption is enabled. The chart generates and reuses the key in
  `consul/consul-gossip-encryption-key` (`key`).
- TLS verification and HTTPS-only API access are enabled. The chart generates
  its own Consul CA and server certificates; this is separate from Vault PKI
  and cert-manager. Gossip encryption alone does not protect API/RPC traffic.
- Service-mesh injection is disabled. No Vault storage or cert-manager settings
  are changed by this application.

### Verification

```sh
kubectl -n argocd get application consul
kubectl -n consul get pods,pvc,daemonsets
kubectl -n consul rollout status daemonset/consul-client --timeout=300s
kubectl -n consul exec consul-server-0 -- consul members
```

Expect `Synced/Healthy`, one `consul-server-0` pod, a bound PVC, and one ready
`consul-client` pod per eligible node. The member list should show one server
and the client agents, all `alive`. If ACLs deny membership inspection, use a
token with `node:read` through `CONSUL_HTTP_TOKEN` inside the pod; do not put
tokens in command arguments or commit them to Git.

The UI is private (ClusterIP). For local access:

```sh
kubectl -n consul port-forward svc/consul-ui 18501:443
```

Open `https://localhost:18501`. The browser will not initially trust the
chart-generated CA. Obtain the CA securely and configure client trust rather
than disabling certificate verification. Sign in with an appropriately scoped
ACL token; the bootstrap token is for administration, not routine workloads.

### Limitations and recovery

One server is sufficient for a lab, but has no failure tolerance. Restarts,
upgrades, and node outages interrupt service. Use three or five servers across
failure domains for HA.

The PVC uses the cluster's default storage class (k3d local-path here). It does
not survive deleting the cluster. Back up Consul snapshots and the generated
Secrets externally: Kubernetes Secrets alone are not a DR backup. In particular,
retain the ACL bootstrap token, gossip key and TLS material when restoring data.
The Helm bootstrap hooks reuse existing credentials, but are not an external
backup service or a planned key/CA rotation controller.
