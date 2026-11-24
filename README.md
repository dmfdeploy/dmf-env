# dmf-env

[![CI](https://github.com/dmfdeploy/dmf-env/actions/workflows/ci.yml/badge.svg)](https://github.com/dmfdeploy/dmf-env/actions/workflows/ci.yml)

**Environment provisioning and bootstrap tooling** for the dmfdeploy platform: wrapper scripts, OpenTofu roots and templates.

Part of [dmfdeploy](https://github.com/dmfdeploy/dmfdeploy), an independent open prototype that explores the ideas of the EBU Dynamic Media Facility on commodity infrastructure. Status: prototype, single-node sandbox.

This repo holds only reusable, non-secret tooling: wrapper scripts (`bin/`),
OpenTofu roots/modules (`terraform/`), and neutral task/template includes. It
pairs with [`dmf-infra`](https://github.com/dmfdeploy/dmf-infra) (generic Ansible roles/playbooks).

> **New to the project vocabulary?** See the [DMF Glossary](https://github.com/dmfdeploy/dmfdeploy/blob/main/docs/GLOSSARY.md) for project-coined terms (env, sandbox / hetzner provider, age key, …).

> **No environment data lives here.** Per [ADR-0035](https://github.com/dmfdeploy/dmfdeploy/blob/main/docs/decisions/0035-operator-local-self-contained-envs.md) every environment (cloud or
> sandbox) is entirely **operator-local** under `~/.dmfdeploy/envs/<env>/`:
> inventory, manifest, encrypted secrets bundle, per-env SSH keypair, and
> OpenTofu state. Nothing per-env is ever committed to this repo. Tearing an
> env down is one `rm -rf ~/.dmfdeploy/envs/<env>`.

## Providers (v0.1)

| Provider | Use |
|---|---|
| `sandbox` | single-node deploy for local experimentation: a Lima VM on macOS, multipass/KVM on Linux, WSL2 on Windows, or any cheap VPS reachable over SSH. The v0.1 release gate. |
| `hetzner` | cloud ARM64 cluster via OpenTofu (`terraform/hetzner` + `terraform/modules/hetzner`). |

Secrets are produced or fetched by the `bin/` wrappers immediately before each
`ansible-playbook` / `tofu` run; never stored in the repo.

## Layout

```
bin/                         wrapper scripts + secrets discipline
  init-wizard.sh             interactive greenfield env bootstrap (renders the env under ~/.dmfdeploy)
  run-playbook.sh            sanctioned ansible entry point (ADR-0010); injects secrets, enforces timeouts
  tf-apply.sh / tf-destroy.sh  OpenTofu wrappers (hetzner); tf-destroy.sh refuses for now (#997)
  tf-render-inventory.sh     regenerate hosts.ini from tofu state
  bootstrap-secrets.sh       doctor / seed-install / export-vars subcommands
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
scripts/check.sh             runs the checks that CI runs (see CONTRIBUTING.md)
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

## Prerequisites

Install these tools before you run the wizard, the wrappers or the tests:

| Tool | Used for |
|---|---|
| `sops` and `age` | Encrypting and decrypting the secrets bundle. The wizard also needs `age-keygen`, which ships with `age`. |
| [`yq`](https://github.com/mikefarah/yq) v4 (the Go version) | Reading the manifest in the non-interactive wizard, and in `tests/wizard-noninteractive-parity.sh`. |
| `jq` | The `bin/` scripts and the tests that parse JSON. |

Install the Go `yq` from [mikefarah/yq](https://github.com/mikefarah/yq). Don't
use the Python `yq` wrapper that some package managers and Linux distributions
provide. It has the same name, but it doesn't accept `-o=json`, which the tests
call. It fails with `jq: Unknown option -o=json`. To check which one you have,
run `yq --version`.
The Go version prints `yq (https://github.com/mikefarah/yq/) version v4.x.x`.

## Quick start

> **Check out the sibling repos first.** These commands expect `dmf-env` to sit
> next to a checkout of [`dmf-infra`](https://github.com/dmfdeploy/dmf-infra)
> (and the other component repos) in the same parent directory. That layout is
> what lets the `../dmf-infra/…` playbook paths resolve. Playbooks always run through `bin/run-playbook.sh`, the sanctioned
> `ansible-playbook` entry point ([ADR-0010](https://github.com/dmfdeploy/dmfdeploy/blob/main/docs/decisions/0010-run-playbook-as-sanctioned-entry.md)).

### Sandbox (the v0.1 release gate)

```bash
cd dmf-env
bin/init-wizard.sh            # choose `sandbox` at the provider prompt
# Provide: env label, node IP, ssh user + private-key path.
# Auto-generated: bootstrap admin password, k3s token, all DB/app passwords.
# Output: ~/.dmfdeploy/envs/<env>/

bin/bootstrap-secrets.sh doctor <env>     # verify the bundle decrypts
bin/run-playbook.sh <env> ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-provision-pre-seed.yml
bin/run-playbook.sh <env> ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-provision-post-seed.yml
bin/run-playbook.sh <env> ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-configure.yml
bin/run-playbook.sh <env> ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-verify.yml
```

#### Tear down a sandbox env

Teardown removes the env directory, `${DMF_DATA_ROOT:-$HOME/.dmfdeploy}/envs/<env>`, and never connects to the node. k3s, the DMF pods, and their volumes stay on the node until you clean it.

`bin/remove-env.sh --yes <env>` reads `metadata.provider` from the env's `manifest.yaml`. For `sandbox`, which today is always a sandbox on a host you bring (the wizard creates no cloud resources for it), it removes local files only. For `hetzner`, any other value, or no manifest, it stops with an error and removes nothing. Teardown of a Hetzner env is manual for now. For status, see [dmfdeploy/dmfdeploy#997](https://github.com/dmfdeploy/dmfdeploy/issues/997).

The manifest decides; the script doesn't cross-check the inventory. The wizard never creates a `terraform-state` path for a sandbox, so the script also stops when anything exists at `<env>/terraform-state`. If a sandbox env has one, look at it by hand before you remove the env dir yourself. The trade-off: if the manifest of an env with tool-created cloud resources wrongly says `sandbox` and it has nothing at that path (for example remote, custom-path or already-lost state), the script removes its whole env dir, including any local state, inventory, credentials and keys in it. It makes no cloud API call, so that env's cloud resources stay behind until you remove them by hand. The **Teardown** action in dmf-init runs the same script inside the dmf-init container. There, `DMF_DATA_ROOT` is the session data root in the container, not a directory on your workstation.

##### Before you re-image or wipe the node

Both options destroy the node's data. Check the target first:

1. Confirm the node address. For direct dmf-env use, read it from the env's inventory (see step 1 of the wipe below). With dmf-init, use the address you entered on the *Target node* step.
2. Confirm that you're on the right machine. Log in over SSH and check the hostname, or check the instance in your provider console.
3. Confirm that the node is a dedicated, disposable sandbox that you own, with no other workloads, and that you intend to lose its data.

If you can't establish the node's identity or ownership, stop and resolve that first. Don't re-image or wipe.

To get a clean node for the next install, re-image it. This is the reliable way and the one we recommend. Re-imaging removes everything on the node, including data outside k3s and the sandbox CA described below.

##### Fallback: wipe k3s on the node

Use this only if you can't re-image. It permanently destroys the cluster and the local PV data on the node, and it affects every pod that runs there.

1. Keep the node address and SSH access before you delete the env directory. The teardown deletes the env's `ssh/` directory and inventory.

   - **Direct dmf-env use.** On the workstation, run:

     ```bash
     ENV_DIR="${DMF_DATA_ROOT:-$HOME/.dmfdeploy}/envs/<env>"
     grep ansible_host "$ENV_DIR/inventory/hosts.ini"
     grep -h -E '^(ansible_user|ansible_ssh_private_key_file):' "$ENV_DIR"/inventory/group_vars/all/*.yml
     ```

     The last command prints the SSH user and the path of the private key the env logs in with. Keep that file:

     - If the path is outside the env directory, for example the key file you gave the wizard, the teardown leaves it in place.
     - If the path is inside the env directory, copy the file somewhere safe first, because the teardown deletes it.

     Don't print the key.
   - **dmf-init.** dmf-init has no command that exports the inventory or key from a running session. You supplied both on the *Target node* step: the node IP and the SSH private key. Keep the key file you pasted from. The encrypted backup holds a copy of the env directory, but only a Manage restore reads it.

   Before you start **Teardown**, confirm that your access works. From your workstation, log in with the key you kept:

   ```bash
   ssh -i <your-key-file> <ssh-user>@<node-address> hostname
   ```

   The command prints the node's hostname. If it can't reach the node, for example because only the container can, use another way in, such as provider console access, before you tear down.

2. Run the target checks in the previous section. The node address must match the one from step 1.
3. On the node, run the k3s uninstall script:

   ```bash
   sudo /usr/local/bin/k3s-uninstall.sh
   sudo rm -rf /var/lib/dmf
   ```

   If `/usr/local/bin/k3s-uninstall.sh` doesn't exist, k3s was never installed, was removed already, or the install stopped partway. Don't create the script by hand. Check for leftovers with the commands in step 5. If anything remains, re-image the node. For what the script does, see the [K3s uninstall documentation](https://docs.k3s.io/installation/uninstall).

4. Remove the sandbox CA. dmf-infra playbook `321-local-ca-trust.yml` installs it, and the wipe leaves it trusted. On the node, run:

   ```bash
   sudo rm -f /usr/local/share/ca-certificates/dmf-local-ca.crt
   sudo update-ca-certificates --fresh
   ```

5. On the node, check what's left:

   ```bash
   systemctl list-units 'k3s*'          # lists no units
   pgrep -a 'k3s|containerd-shim'       # prints nothing
   mount | grep -E 'k3s|kubelet'        # prints nothing
   ls /var/lib/rancher/k3s /var/lib/dmf # both: No such file or directory
   ```

   Don't delete `/var/lib/rancher` as a whole. Other software can use it. The uninstall script removes only k3s's own files.

The wipe leaves these behind:

- The k3s service drop-ins in `/etc/systemd/system/k3s.service.d/`. The next install removes them.
- Data on a storage backend other than the default local-path, for example Longhorn volumes or external disks. The k3s uninstall doesn't delete it. Check your backend and remove only data that you know belongs to the sandbox.
- Your host preparation: the cgroup boot parameter, swap settings, and SSH hardening. dmf-init applies the hardening again on the next install.

If you can't confirm that the node is clean, re-image it.

### Hetzner (cloud)

Pre-reqs: the [prerequisite tools](#prerequisites) installed, an age key at `~/.config/sops/age/keys.txt`.

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
bin/run-playbook.sh <env> ../dmf-infra/k3s-lab-bootstrap/bootstrap-provision-post-seed.yml
```

See `terraform/README.md` for the OpenTofu (Layer-1) detail.

Teardown is manual for now (dmfdeploy/dmfdeploy#997). `bin/remove-env.sh` and
`bin/tf-destroy.sh` refuse a Hetzner env. In the Hetzner console, delete the
servers, network, load balancer and SSH key, then remove the env dir with
`rm -rf ~/.dmfdeploy/envs/<env>`.

### Seeding OpenBao

The seed writes `secret/platform/*` and the per-app admin paths, which no standing
identity may write, so it needs a root token. Nothing makes one after an install: only
the approval executor generates root tokens, and `ops-admin` doesn't hold the
`generate-root` policy. So the seed runs inside the install, while the installer's own
token is live.

`bin/run-playbook.sh` names the command (`bootstrap-secrets.sh seed-install <env>`) for
the pre-seed playbooks and `100-openbao.yml`. The openbao role of dmf-infra runs it on
this host just before it revokes its write token, and pipes the token to its stdin. The
seed never takes the token in an argument and revokes nothing. That is why the sequences
above have no separate seed step.

`seed-bao`, `seed-awx-control-node-ssh` and `seed-install` read the token from the first
line of stdin. Run from a terminal, or with an empty stdin, they stop with a message
before they call OpenBao. `seed-install` runs `seed-bao` only: the awx-integration role
of dmf-infra writes the AWX control-node key during the install. An environment that needs a seed after its
install is rebuilt.

`bin/upgrade-in-place.sh` seeds nothing. It applies the current playbooks to an
environment that the install of this release seeded. The pre-seed wrapper that it runs
makes no token and runs no seed on an initialized OpenBao. An environment installed
before the seed moved into the install is rebuilt: the upgrade doesn't backfill it.

## Cross-platform notes

- macOS / Linux: `$HOME/.dmfdeploy/` is honoured natively.
- Windows: run the wizard under **WSL2** or **Git Bash**, using the POSIX home
  (`$HOME`). Don't point bash at a DrvFS mount. It drops `chmod 0600` semantics.
- All path operations use `${HOME}` + POSIX `mkdir -p` / `install -d` / `chmod`.
  In sandbox mode no OS keychain is touched
  (`openbao_breakglass_distribution_enabled: false`).

## Playbook runner + monitor

`bin/run-playbook.sh` logs each run to `/tmp/dmf-playbook-logs/<name>-<timestamp>.log`
and caps runtime. The default is 15 minutes (900 seconds). `lifecycle-*`
playbooks get 30 minutes. `site.yml` and the eight bootstrap stage playbooks get
120 minutes (7200 seconds). The stage playbooks are the four sandbox and
non-sandbox pairs: `bootstrap-sandbox-provision-pre-seed.yml`,
`bootstrap-sandbox-provision-post-seed.yml`, `bootstrap-sandbox-configure.yml`,
`bootstrap-sandbox-verify.yml`, and the matching `bootstrap-provision-pre-seed.yml`,
`bootstrap-provision-post-seed.yml`, `bootstrap-configure.yml` and
`bootstrap-verify.yml`. Other `bootstrap-*` playbooks keep the 15-minute default.
Override any default with `RUNBOOK_TIMEOUT=<seconds>`. In a second terminal,
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

## For contributors

[CONTRIBUTING.md](CONTRIBUTING.md) covers setup, the test command, the git hooks, and what a pull request needs. `AGENTS.md`, `CLAUDE.md` and `QWEN.md` hold instructions for AI coding agents that help maintain this repository.

## License

Apache 2.0. See [`LICENSE`](LICENSE).
