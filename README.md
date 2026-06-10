# dmf-env

Generic **environment provisioning + bootstrap tooling** for the DMF Platform.
This repo holds only reusable, non-secret tooling: wrapper scripts (`bin/`),
OpenTofu roots/modules (`terraform/`), and neutral task/template includes. It
pairs with [`dmf-infra`](../dmf-infra) (generic Ansible roles/playbooks).

> **No environment data lives here.** Per ADR-0035 every environment (cloud or
> sandbox) is entirely **operator-local** under `~/.dmfdeploy/envs/<env>/` —
> inventory, manifest, encrypted secrets bundle, per-env SSH keypair, and
> OpenTofu state. Nothing per-env is ever committed to this repo. Tearing an
> env down is one `rm -rf ~/.dmfdeploy/envs/<env>`.

## Providers (v0.1)

| Provider | Use |
|---|---|
| `sandbox` | single-node deploy for local experimentation — a Lima VM on macOS, multipass/KVM on Linux, WSL2 on Windows, or any cheap VPS reachable over SSH. The v0.1 release gate. |
| `hetzner` | cloud ARM64 cluster via OpenTofu (`terraform/hetzner` + `terraform/modules/hetzner`). |

Secrets are produced or fetched by the `bin/` wrappers immediately before each
`ansible-playbook` / `tofu` run — never stored in the repo.

## Layout

```
bin/                         wrapper scripts + secrets discipline
  init-wizard.sh             interactive greenfield env bootstrap (renders the env under ~/.dmfdeploy)
  run-playbook.sh            sanctioned ansible entry point (ADR-0010); injects secrets, enforces timeouts
  tf-apply.sh / tf-destroy.sh  OpenTofu wrappers (hetzner)
  tf-render-inventory.sh     regenerate hosts.ini from tofu state
  bootstrap-secrets.sh       doctor / seed-bao / export-vars subcommands
  unseal-openbao.sh          Shamir-quorum OpenBao unseal
  monitor-playbook.sh        stream a filtered playbook log
  lib/_resolve_env_paths.sh  resolves the operator-local env layout
terraform/
  hetzner/                   env root (yamldecode manifest → module call → render inventory)
  modules/hetzner/           provider resources: SSH key, network, firewall, servers, DNS
  README.md
tasks/hetzner/               provider-specific task includes
templates/                   Jinja2 templates
tests/                       offline unit tests for the wrappers
```

## The operator-local env layout

Everything for one env lives under `~/.dmfdeploy/envs/<env>/` (created by the
wizard, never committed):

```
~/.dmfdeploy/
  env                        optional shell-sourceable operator config
  envs/<env>/
    .sops.yaml               per-env SOPS creation rule (matches bundle.sops.yaml)
    bundle.sops.yaml         encrypted secrets bundle
    manifest.yaml            Resource Profile (EBU "Design" stage)
    openbao-keys.json        break-glass material (written at pre-seed; never committed)
    inventory/
      hosts.ini
      group_vars/all/main.yml
    terraform-state/         per-env OpenTofu local backend
    ssh/                     per-env keypair (private key lives in the sops bundle)
```

Live env ids rotate; the current id (if any) is recorded in the umbrella's
`STATUS.md`, not in this repo.

## Quick start

### Sandbox (the v0.1 release gate)

```bash
cd dmf-env
bin/init-wizard.sh            # choose `sandbox` at the provider prompt
# Provide: env label, node IP, ssh user + private-key path.
# Auto-generated: bootstrap admin password, k3s token, all DB/app passwords.
# Output: ~/.dmfdeploy/envs/<env>/

bin/bootstrap-secrets.sh doctor <env>     # verify the bundle decrypts
bin/run-playbook.sh <env> ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-provision-pre-seed.yml
bin/bootstrap-secrets.sh seed-bao <env>
bin/run-playbook.sh <env> ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-provision-post-seed.yml
bin/run-playbook.sh <env> ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-configure.yml
bin/run-playbook.sh <env> ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-verify.yml
```

Teardown: `rm -rf ~/.dmfdeploy/envs/<env>`.

### Hetzner (cloud)

Pre-reqs: `sops` + `age` installed, an age key at `~/.config/sops/age/keys.txt`.

```bash
cd dmf-env
bin/init-wizard.sh            # choose `hetzner`
# Provide: base domain, Cloudflare token, provider credentials, optional Tailscale.
# Auto-generated: bootstrap admin password, k3s token, all DB/app passwords.

bin/bootstrap-secrets.sh doctor <env>
bin/tf-apply.sh <env> init
bin/tf-apply.sh <env> plan -out=plan.bin
bin/tf-apply.sh <env> apply plan.bin
bin/run-playbook.sh <env> ../dmf-infra/k3s-lab-bootstrap/bootstrap-provision-pre-seed.yml
# capture the 5 Shamir shares at init (operator-only, manual)
bin/unseal-openbao.sh <env>
bin/bootstrap-secrets.sh seed-bao <env>
bin/run-playbook.sh <env> ../dmf-infra/k3s-lab-bootstrap/bootstrap-provision-post-seed.yml
```

See `terraform/README.md` for the OpenTofu (Layer-1) detail.

## Cross-platform notes

- macOS / Linux: `$HOME/.dmfdeploy/` is honoured natively.
- Windows: run the wizard under **WSL2** or **Git Bash**, using the POSIX home
  (`$HOME`). Don't point bash at a DrvFS mount — it drops `chmod 0600` semantics.
- All path operations use `${HOME}` + POSIX `mkdir -p` / `install -d` / `chmod`.
  In sandbox mode no OS keychain is touched
  (`openbao_breakglass_distribution_enabled: false`).

## Playbook runner + monitor

`bin/run-playbook.sh` logs each run to `/tmp/dmf-playbook-logs/<name>-<timestamp>.log`
and caps runtime (15 min ordinary, 30 min `lifecycle-*`, 90 min `site.yml`);
override with `RUNBOOK_TIMEOUT=<seconds>`. In a second terminal,
`bin/monitor-playbook.sh <logfile>` streams only PLAY/TASK/fatal/RECAP lines.

## Secrets the playbooks expect

Produced by `bin/bootstrap-secrets.sh` (local config + ephemeral generation) and,
post-bootstrap, re-resolved from each cluster's in-cluster OpenBao via ESO.
The wrapper writes a temp JSON of `vault_*` keys injected with `-e @file`.

| Key | Used by |
|-----|---------|
| `hcloud_token` | Hetzner CCM API token for cloud-native ingress |
| `cloudflare_dns_token` | cert-manager DNS-01 + Layer-1 DNS records |
| `tailscale_authkey` | private-lane node registration |
| `k3s_token` | k3s cluster join token (ephemeral, generated per run) |
| `zot_admin_password` | Zot OCI registry admin |
| `awx_admin_password` | AWX admin user |
| `netbox_secret_key` | NetBox Django secret key |
| `netbox_superuser_password` | NetBox admin user |
| `netbox_db_password` | PostgreSQL password for NetBox |
| `netbox_valkey_password` | Valkey (Redis) password |
| `api_token_pepper` | NetBox v4 API token pepper (≥50 chars) |
| `forgejo_admin_password` | Forgejo admin user |
| `grafana_admin_password` | Grafana admin user |
| `librenms_admin_password` | LibreNMS admin user |
| `alertmanager_ntfy_url` | Alertmanager primary receiver |
| `alertmanager_watchdog_url` | dead-man's-switch receiver |

## License

Apache 2.0 — see `LICENSE` (added at first public release).
