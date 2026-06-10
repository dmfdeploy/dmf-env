# init-wizard answers file schema

`bin/init-wizard.sh --non-interactive <answers.yaml>` consumes a YAML map of
operator inputs only. It does **not** carry generated secrets:

- no passwords or tokens from `gen_password` / `gen_token`
- no `env_id`
- no per-env SSH keypair material

The wizard still generates those internally and writes them into the bundle as
it does in interactive mode.

## Schema version

```yaml
schema_version: 1
```

## Key map

- `schema_version`:
  - Required
  - Must be `1`
- `provider`:
  - Required
  - One of `sandbox`, `hetzner`
- `architecture`:
  - Required for cloud providers
  - One of `arm64`, `amd64`
- `label`:
  - Optional for cloud providers
  - Human label shown in the manifest and inventory
- `posture`:
  - Required for cloud providers
  - One of `test`, `production`
- `operator.username`:
  - Required
- `operator.email`:
  - Required
- `operator.display`:
  - Optional
  - Defaults to `operator.username` if omitted
- `base_domain`:
  - Required for cloud providers
  - Sandbox derives `base_domain` from `sandbox.node_ip` via sslip.io by default;
    set `sandbox.base_domain` to override explicitly
- `sandbox.label`:
  - Optional when `provider: sandbox`
  - Cosmetic display label only; does NOT drive the base domain
  - When empty (default), `base_domain` auto-derives to `<node-ip-dashed>.sslip.io`
    and the label is derived from the dashed IP as well
- `sandbox.addressing`:
  - Optional when `provider: sandbox`
  - One of `sslip.io` (default) or `hosts`
  - `sslip.io`: `base_domain` = `<node-ip-dashed>.sslip.io` — resolves automatically,
    no `/etc/hosts` edits needed
  - `hosts`: `base_domain` = `<label>.dmf.test` — air-gapped opt-out, requires
    explicit `/etc/hosts` mapping; `sandbox.label` becomes required in this mode
- `sandbox.base_domain`:
  - Optional when `provider: sandbox`
  - Explicit override for the base domain (bypasses both sslip.io derivation and
    .dmf.test fallback)
- `sandbox.node_ip`:
  - Required when `provider: sandbox`
- `sandbox.ansible_user`:
  - Required when `provider: sandbox`
- `sandbox.iface`:
  - Required when `provider: sandbox`
- `sandbox.ssh_private_key_path`:
  - Required when `provider: sandbox`
  - Filesystem path to the operator's node-login SSH key
- `ssh.mode`:
  - Required for cloud providers
  - `generate` or `byo`
- `ssh.private_key_path`:
  - Required when `ssh.mode: byo`
- `ssh.public_key_path`:
  - Required when `ssh.mode: byo`
- `dns.cloudflare_api_token`:
  - Required for cloud providers
- `dns.cloudflare_zone_name`:
  - Optional
  - Defaults to the apex derived from `base_domain`
- `network.ssh_allow_ipv4`:
  - Required for cloud providers
- `network.ssh_allow_ipv6`:
  - Optional
- `hetzner.context`:
  - Required when `provider: hetzner`
- `hetzner.cloud_token`:
  - Required when `provider: hetzner`
- `object_storage.b2_key_id`:
  - Required for cloud providers
- `object_storage.b2_app_key`:
  - Required for cloud providers
- `object_storage.b2_region`:
  - Required for cloud providers
- `networking.tailscale_authkey`:
  - Optional for cloud providers
- `networking.headscale_host`:
  - Optional for cloud providers
- `openbao.breakglass_dir`:
  - Required for cloud providers
  - Absolute path
- `openbao.usb_base`:
  - Optional for cloud providers
  - Defaults to `/path/to/usb-storage` if omitted

## Sandbox example

```yaml
schema_version: 1
provider: sandbox
operator:
  username: marty-mcfly
  email: marty@dmf.test
  display: "Marty McFly"
# label is cosmetic — empty auto-derives BASE_DOMAIN from node_ip via sslip.io
sandbox:
  # label: demo                # optional; omit for auto-derive
  node_ip: 203.0.113.10
  ansible_user: lima
  iface: lima0
  ssh_private_key_path: /tmp/fake-sandbox-key
  # addressing: sslip.io       # default; set to "hosts" for air-gapped .dmf.test
  # base_domain: custom.io     # explicit override
```

## Hetzner example

```yaml
schema_version: 1
provider: hetzner
architecture: arm64
label: lab cluster
posture: test
operator:
  username: marty-mcfly
  email: marty@dmf.test
  display: "Marty McFly"
base_domain: lab.example.com
dns:
  cloudflare_api_token: "<token>"
  cloudflare_zone_name: example.com
ssh:
  mode: generate
network:
  ssh_allow_ipv4: "203.0.113.10/32"
  ssh_allow_ipv6: ""
hetzner:
  context: lab-cluster
  cloud_token: "<token>"
object_storage:
  b2_key_id: "<key-id>"
  b2_app_key: "<app-key>"
  b2_region: us-west-001
networking:
  tailscale_authkey: ""
  headscale_host: ""
openbao:
  breakglass_dir: /abs/path/openbao-breakglass
  usb_base: /abs/path/usb
```

## Notes

- The file is inputs-only; the wizard generates secrets and `env_id`.
- Non-interactive mode does not run `validate-env.sh`.
- `ssh.mode: generate` keeps the per-env SSH keypair wizard-internal; `byo`
  tells the wizard to copy the supplied key paths into the env directory.
- In non-interactive mode `hetzner.context` and `hetzner.cloud_token` are taken verbatim from the file and are not validated against the hcloud CLI; interactive mode validates via `~/.config/hcloud/cli.toml`, so an invalid or expired token will only surface at `tofu apply`.
