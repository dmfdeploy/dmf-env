# OpenTofu — Layer 1 (Infrastructure)

Owns Layer 1 for a Hetzner environment. Tofu provisions servers, network,
firewall, SSH key, and the cloud-init bootstrap that creates the `k3s-admin`
user. Ansible Layers 2+ are unchanged — `tofu apply` runs *before*
`bin/run-playbook.sh` and renders the env's `inventory/hosts.ini` (under
`~/.dmfdeploy/envs/<env>/`) that Ansible then consumes.

Source-of-truth chain:

```
~/.dmfdeploy/envs/<env>/manifest.yaml   (Resource Profile, EBU "Design" stage)
        │
        ▼
terraform/hetzner/                      (env root — yamldecode + module call)
        │
        ▼
terraform/modules/hetzner/              (resources: SSH key, network, firewall, servers, DNS)
        │
        ▼
~/.dmfdeploy/envs/<env>/inventory/hosts.ini   (rendered for Ansible)
```

## Layout

```
terraform/
├── README.md                       ← this file
├── modules/
│   └── hetzner/
│       └── cluster/
│           ├── versions.tf         ← required_providers (hcloud, cloudflare)
│           ├── variables.tf        ← var.spec + module knobs
│           ├── main.tf             ← resources
│           ├── outputs.tf          ← node list, control node, LB IP, IDs
│           └── templates/
│               └── hosts.ini.tftpl ← Ansible inventory template
└── hetzner/                        ← env root
    ├── versions.tf                 ← provider config + local state backend
    ├── variables.tf                ← manifest_path, output paths, tokens
    ├── main.tf                     ← yamldecode manifest, instantiate module, render inventory
    └── outputs.tf
```

The env root is **generic**: it reads `var.manifest_path` and writes
`var.hosts_ini_output_path`, both supplied by `bin/tf-apply.sh` per env. The
root never hardcodes a specific environment.

## State

Per-env local backend, supplied at apply time via `-backend-config` by
`bin/tf-apply.sh` — state lives operator-local under
`~/.dmfdeploy/envs/<env>/terraform-state/`, never in this repo.

- **Local, not remote** — single operator, no concurrent applies.
- **Operator-local, not the repo** — state contains resolved IPs and output
  values; keep it off git.
- **`.terraform.lock.hcl` IS committed** — pins provider versions.

If the state file is lost, re-import resources with `tofu import`; the manifest
plus the running cluster reconstruct it.

## Tokens

The wizard writes private provider tfvars at apply time (under the operator-local
env dir), never into the manifest and never into the repo:

| TF_VAR_* | Source |
|---|---|
| `hcloud_token` | `~/.dmfdeploy/envs/<env>/hetzner.tfvars` |
| `cloudflare_api_token` | `~/.dmfdeploy/envs/<env>/hetzner.tfvars` |

`bin/tf-apply.sh` exports `TF_VAR_*` from the env's tfvars. Per-cluster
in-cluster OpenBao + ESO covers runtime secrets inside the cluster itself.

## Day-to-day

```bash
bin/tf-apply.sh <env> init
bin/tf-apply.sh <env> plan -out=plan.bin
bin/tf-apply.sh <env> apply plan.bin

# Re-render the inventory only (no upstream changes)
bin/tf-render-inventory.sh <env>
```

`bin/tf-apply.sh` / `bin/tf-destroy.sh` support **hetzner** only in v0.1;
`sandbox` has no Terraform path and the wrappers refuse it early.

## Ignored attributes

Lifecycle ignores keep imports clean and prevent accidental destroy/replacement
(hetzner cluster module):

- `hcloud_server.node[*]` — `user_data`, `placement_group_id`, `ssh_keys`
- `hcloud_server_network.node[*]` — `ip` (auto-assigned by Hetzner)

`user_data` is still rendered into the create request so fresh nodes get the
`k3s-admin` cloud-init user, but it stays ignored after import (Hetzner does not
surface the bootstrap payload for reconciliation).

## Resources NOT in tofu

- **The public-ingress load balancer** is created reactively by the Hetzner CCM
  when the public-ingress Service of type LoadBalancer is applied (Ansible
  `310-ingress-public.yml`). Tofu reads it via a `data` source for the
  Cloudflare A records but does not own its lifecycle.

## Adding a provider (post-v0.1)

v0.1 ships Hetzner + sandbox only. To add a cloud provider later:

1. Add `terraform/modules/<provider>/cluster/` (versions/variables/main/outputs + templates).
2. Add a generic `terraform/<provider>/` env root mirroring `terraform/hetzner/`
   (manifest-var driven, output-path driven).
3. Extend the wizard's provider list and the `bin/tf-apply.sh` / `bin/tf-destroy.sh`
   guards.
