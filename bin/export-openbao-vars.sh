#!/usr/bin/env bash
# export-openbao-vars.sh — generate a temp vars file for ansible-playbook.
#
# Current behaviour (bootstrap phase):
#   1. Read provider tokens from local config (hcloud CLI config, keychain)
#   2. Generate ephemeral random values for self-seeded secrets
#
# Future (after OpenBao is deployed and pivoted to):
#   The wrapper will be extended to fetch from the new OpenBao instance.
#   Until then, every run produces bootstrap vars.

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: bin/export-openbao-vars.sh <env-name> <output-json>" >&2
  exit 1
fi

ENV_NAME="$1"
OUTPUT_JSON="$2"

# ──────────────────────────────────────────────────────────────
# Read provider tokens from local config
# ──────────────────────────────────────────────────────────────

# Hetzner Cloud API token from hcloud CLI config
hcloud_token=""
hcloud_config="$HOME/.config/hcloud/cli.toml"
if [ -f "$hcloud_config" ]; then
  hcloud_token="$(python3 -c '
import pathlib, re, sys
config = pathlib.Path(sys.argv[1]).read_text()
active_match = re.search(r"active_context\s*=\s*\"([^\"]+)\"", config)
if not active_match:
    sys.exit(0)
active = active_match.group(1)
ctx_pattern = rf"\[\[contexts\]\]\s+name\s*=\s*\"{re.escape(active)}\".*?token\s*=\s*\"([^\"]+)\""
token_match = re.search(ctx_pattern, config, re.DOTALL)
if token_match:
    print(token_match.group(1))
' "$hcloud_config" 2>/dev/null)" || hcloud_token=""
fi

# Cloudflare DNS API token from local file
cf_dns_token=""
cf_dns_file="$HOME/.config/cf/dns.txt"
if [ -f "$cf_dns_file" ]; then
  cf_dns_token="$(cat "$cf_dns_file" | tr -d '[:space:]')" || cf_dns_token=""
fi

# Headscale reusable pre-auth key for the 3 k3s nodes. Generate with:
#   ssh root@<headscale-host> "docker exec headscale headscale \
#     preauthkeys create --user <id> --reusable --expiration 720h -o json" \
#     | jq -r .key > ~/.config/ts/authkey.txt
ts_authkey=""
ts_authkey_file="$HOME/.config/ts/authkey.txt"
if [ -f "$ts_authkey_file" ]; then
  ts_authkey="$(cat "$ts_authkey_file" | tr -d '[:space:]')" || ts_authkey=""
fi

# ntfy topic URL for Alertmanager primary receiver
# Example content: https://ntfy.dmf.example.com/<your-topic>
ntfy_url=""
ntfy_file="$HOME/.config/ntfy/alertmanager-url.txt"
if [ -f "$ntfy_file" ]; then
  ntfy_url="$(cat "$ntfy_file" | tr -d '[:space:]')" || ntfy_url=""
fi

# healthchecks.io ping URL for the Watchdog dead-man's switch
# Example content: https://hc-ping.com/<uuid>
watchdog_url=""
watchdog_file="$HOME/.config/healthchecks/watchdog-url.txt"
if [ -f "$watchdog_file" ]; then
  watchdog_url="$(cat "$watchdog_file" | tr -d '[:space:]')" || watchdog_url=""
fi

# ──────────────────────────────────────────────────────────────
# Generate ephemeral random values for self-seeded secrets
# ──────────────────────────────────────────────────────────────
k3s_token="$(openssl rand -base64 32 | tr -d '+/=' | head -c 40)"
zot_admin_password="$(openssl rand -base64 24 | tr -d '+/=' | head -c 32)"
awx_admin_password="$(openssl rand -base64 24 | tr -d '+/=' | head -c 32)"

# ──────────────────────────────────────────────────────────────
# Build the vars JSON
# ──────────────────────────────────────────────────────────────
python3 -c '
import json
import pathlib
import sys

vars = {}

hcloud_token = sys.argv[2]
cf_dns_token = sys.argv[3]
k3s_token = sys.argv[4]
zot_admin_password = sys.argv[5]
awx_admin_password = sys.argv[6]
ts_authkey = sys.argv[7]
ntfy_url = sys.argv[8]
watchdog_url = sys.argv[9]

if hcloud_token:
    vars["vault_hcloud_token"] = hcloud_token
if cf_dns_token:
    vars["vault_cloudflare_dns_token"] = cf_dns_token
if ts_authkey:
    vars["vault_tailscale_authkey"] = ts_authkey
if ntfy_url:
    vars["vault_alertmanager_ntfy_url"] = ntfy_url
if watchdog_url:
    vars["vault_alertmanager_watchdog_url"] = watchdog_url

vars["vault_k3s_token"] = k3s_token
vars["vault_zot_admin_password"] = zot_admin_password
vars["vault_awx_admin_password"] = awx_admin_password

pathlib.Path(sys.argv[1]).write_text(json.dumps(vars, indent=2, sort_keys=True))
' "$OUTPUT_JSON" "$hcloud_token" "$cf_dns_token" "$k3s_token" "$zot_admin_password" \
  "$awx_admin_password" "$ts_authkey" "$ntfy_url" "$watchdog_url"
