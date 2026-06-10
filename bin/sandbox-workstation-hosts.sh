#!/usr/bin/env bash
# sandbox-workstation-hosts.sh — map the sandbox app hostnames to the node IP
# in THIS workstation's /etc/hosts.
#
# The sandbox lane uses local-CA TLS with names under <base-domain> (no public
# DNS, no Tailscale). The node resolves these in-cluster + in its own /etc/hosts
# (playbook 321-local-ca-trust), but the WORKSTATION does not — so workstation-
# side steps fail: 630-zot-seed-platform's skopeo push to registry.<base-domain>
# (status -1), and browsing https://console.<base-domain> etc.
#
# This writes a marker-delimited block to /etc/hosts (requires sudo), reading the
# node IP + base domain from the env inventory so it stays correct across VM
# rebuilds. Idempotent: re-running replaces the block.
#
# Usage (ENV_NAME is required — current env id is in the umbrella STATUS.md):
#   ENV_NAME=<env-id> bin/sandbox-workstation-hosts.sh
#   ENV_NAME=<env-id> bin/sandbox-workstation-hosts.sh --remove   # delete the block

set -euo pipefail

ENV_NAME="${ENV_NAME:-}"
# Sandbox subdomains (must match the inventory *_host vars + 321-local-ca-trust).
SUBDOMAINS=(auth forgejo grafana console netbox awx registry)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR%/bin}"

# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"

HOSTS_FILE="/etc/hosts"
MARK_BEGIN="# >>> DMF sandbox ${ENV_NAME} >>>"
MARK_END="# <<< DMF sandbox ${ENV_NAME} <<<"

if [ -t 2 ]; then c_b=$'\033[1m'; c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_0=$'\033[0m'
else c_b=''; c_r=''; c_g=''; c_y=''; c_0=''; fi
ok()  { printf '%s✓%s %s\n' "$c_g" "$c_0" "$*" >&2; }
warn(){ printf '%s!%s %s\n' "$c_y" "$c_0" "$*" >&2; }
die() { printf '%s✗ %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }

REMOVE=0
case "${1:-}" in
  --remove) REMOVE=1 ;;
  "") ;;
  *) die "Unknown argument: $1 (use --remove)" ;;
esac

[ -n "$ENV_NAME" ] || die "ENV_NAME is required, e.g.  ENV_NAME=<env-id> $(basename "$0")  (current env id is in the umbrella STATUS.md). Never defaults to a baked env."

# Resolve env paths (sandbox uses new-layout under ~/.dmfdeploy/envs/<env>/)
cd "$REPO_DIR"
dmf_source_operator_config
dmf_resolve_env_paths "$ENV_NAME" || die "Unable to resolve environment $ENV_NAME"

HOSTS_INI="${DMF_ENV_INVENTORY_DIR}/hosts.ini"
GROUP_VARS="${DMF_ENV_INVENTORY_DIR}/group_vars/all/main.yml"

strip_block() {  # print HOSTS_FILE with any existing managed block removed
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0==b {skip=1; next} $0==e {skip=0; next} !skip' "$HOSTS_FILE"
}

apply() {  # $1 = full new /etc/hosts content (on stdin)
  local tmp; tmp="$(mktemp)"; cat > "$tmp"
  if cmp -s "$tmp" "$HOSTS_FILE"; then rm -f "$tmp"; return 1; fi   # no change
  warn "Updating ${HOSTS_FILE} (sudo)…"
  sudo cp "$HOSTS_FILE" "${HOSTS_FILE}.dmf.bak" 2>/dev/null || true
  sudo cp "$tmp" "$HOSTS_FILE"
  rm -f "$tmp"
  return 0
}

[ -f "$HOSTS_INI" ] || die "Inventory not found: $HOSTS_INI (wrong ENV_NAME?)"

if [ "$REMOVE" -eq 1 ]; then
  if grep -qF "$MARK_BEGIN" "$HOSTS_FILE"; then
    strip_block | apply && ok "Removed DMF sandbox block from ${HOSTS_FILE}." || ok "Nothing to remove."
  else ok "No DMF sandbox block present."; fi
  exit 0
fi

NODE_IP="$(grep -oE 'k3s_node_ip=[0-9.]+' "$HOSTS_INI" | head -1 | cut -d= -f2 || true)"
[ -n "$NODE_IP" ] || die "Could not read k3s_node_ip from $HOSTS_INI."

BASE_DOMAIN=""
[ -f "$GROUP_VARS" ] && BASE_DOMAIN="$(grep -E '^dmf_sandbox_base_domain:' "$GROUP_VARS" | head -1 | sed -E 's/^[^:]+:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/' || true)"
[ -n "$BASE_DOMAIN" ] || die "Could not read dmf_sandbox_base_domain from $GROUP_VARS."

# Build the block: apex + each subdomain -> node IP.
block="$MARK_BEGIN"$'\n'"# Managed by sandbox-workstation-hosts.sh — do not edit by hand."$'\n'
block+="${NODE_IP} ${BASE_DOMAIN}"$'\n'
for s in "${SUBDOMAINS[@]}"; do block+="${NODE_IP} ${s}.${BASE_DOMAIN}"$'\n'; done
block+="$MARK_END"

warn "Mapping ${BASE_DOMAIN} (+ ${#SUBDOMAINS[@]} app hosts) -> ${NODE_IP} in ${HOSTS_FILE}"
if { strip_block; printf '%s\n' "$block"; } | apply; then
  ok "Updated. Verify:  ping -c1 registry.${BASE_DOMAIN}"
else
  ok "Already up to date (${NODE_IP}); no change."
fi

printf '%s\n' "" \
  "${c_b}Hosts now mapped:${c_0}" \
  "  ${BASE_DOMAIN}" >&2
for s in "${SUBDOMAINS[@]}"; do printf '  %s.%s\n' "$s" "$BASE_DOMAIN" >&2; done
printf '%s\n' "" \
  "Note: browsers will still warn on the local-CA cert (expected). The 630 Zot" \
  "seed pushes with --dest-tls-verify=false, so it needs only this resolution." >&2
