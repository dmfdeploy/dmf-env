# Hetzner provider tasks

Per-role task files included from generic `dmf-infra` roles via the
`*_provider_tasks` indirection in inventory `main.yml`.

| File | Consumed by | Purpose |
|---|---|---|
| `ccm.yml` | `cluster_ingress_provider_tasks` (in `roles/base/ingress`) | Install Hetzner Cloud Controller Manager + patch node providerIDs so `Service: type=LoadBalancer` provisions a real Hetzner LB. |
| `firewall.yml` | `harden_cloud_firewall_tasks` (in `playbooks/210-harden.yml`) | Reconcile the Hetzner Cloud Firewall ruleset (SSH allow-list, ICMP, HTTP/HTTPS, intra-private-net) to match inventory vars. |

## Provider contract

Every `tasks/<provider>/<role>.yml` file MUST:

- Be includable from a generic role via `include_tasks` with no other coupling.
  Reuses `cluster_ingress_provider_tasks` / `harden_cloud_firewall_tasks`
  indirection — no role-side knowledge of the provider.
- Read inputs from inventory vars namespaced `<provider>_<role>_<key>`
  (here: `hcloud_ccm_*`, vendor SDK names preserved) plus `vault_*`
  (OpenBao-sourced secrets) plus `tofu_outputs.yml` keys for IDs that come
  from Tofu state.
- Open with `set_fact` defaults + `assert` block — fail-closed when required
  inputs are missing. Both files here follow this pattern; preserve.
- Be idempotent (`kubernetes.core.k8s state: present`).
- Never read `~/.secure/*` or `~/.config/*` directly. Localhost-delegated
  CLI calls (the `hcloud server list` pattern in `ccm.yml`) are allowed but
  must document the host-side prerequisite.
- Emit only kube state (CCM/RBAC/secrets) or cloud-API state (firewall
  rules) — no node-level OS changes (those belong to `dmf-infra` roles).

## Required vars (`hcloud` namespace, vendor-driven)

| Var | Source | Used by |
|---|---|---|
| `hcloud_ccm_token` | `vault_hcloud_token` (OpenBao via `bootstrap-secrets.sh export-vars`) | `ccm.yml` |
| `hcloud_ccm_network` | inventory `main.yml` (private network name) | `ccm.yml` |
| `hcloud_ccm_version` | inventory or default | `ccm.yml` |

The `hcloud_*` namespace is preserved (matches the official Hetzner CLI/SDK
naming; operators already know it).

## See also

- ADR-0018: stay self-managed k3s, no managed Kubernetes
- `docs/plans/playful-sprouting-falcon.md` (provider directory restructure plan)
