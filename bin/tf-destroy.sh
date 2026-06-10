#!/usr/bin/env bash
# tf-destroy.sh — safe ordered teardown of the Hetzner cluster.
#
# Why this exists
# ---------------
# `tofu destroy` alone fails on this stack for three reasons:
#
#   1. Hetzner's CCM provisions the dmf-traefik LB *outside* Tofu's
#      control and attaches it to the k3s-private network. The subnet
#      cannot be deleted while any LB is attached → tofu hangs in
#      "Still destroying..." until the API context deadline blows.
#
#   2. k3s/flannel adds pod-CIDR routes to the network. The subnet
#      cannot be deleted while routes exist.
#
#   3. The cluster module reads the LB via a `data` source. If the LB
#      has already been deleted by hand when Tofu runs, refresh fails
#      with "no Load Balancer found" before destroy can begin.
#
# Safe order (this script)
# ------------------------
#   1. Detach LB from private network — keeps the LB alive for the
#      Tofu data source while removing the dependency that blocks
#      subnet destruction.
#   2. Remove all routes from the network (flannel pod-CIDR routes).
#   3. `tofu destroy -auto-approve` — succeeds (no in-network deps).
#   4. Delete the LB — no longer needed; CCM re-creates it on next
#      cluster bring-up when the Service of type=LoadBalancer comes up.
#
# Usage (ENV_NAME is required — no default; current id is in the umbrella STATUS.md):
#   bin/tf-destroy.sh <env-id>
#
# Env-var overrides:
#   NETWORK_NAME (default k3s-private)
#   LB_NAME      (default dmf-traefik)
#
# Edge case: LB already deleted manually
#   If you (or another script) deleted the LB before running this, the
#   Tofu data source can't refresh. The script warns; if `tofu destroy`
#   then errors, recover with:
#     cd terraform/<env>
#     for r in $(tofu state list); do tofu state rm "$r"; done
#   which empties Tofu state, accepting the manual cleanup as
#   authoritative.
#
# What this script does NOT touch
#   - Cloudflare wildcard A records (reconciled by 321-tailscale.yml on
#     next bring-up).
#   - Headscale node entries (reconciled by 322-headscale-cleanup.yml in
#     lifecycle-finalise).
#   - LAN Forgejo content / operator Keychain / break-glass JSON.

set -euo pipefail

ENV_NAME="${1:-}"
if [ -z "$ENV_NAME" ]; then
  echo "ERROR: ENV_NAME (your cloud env id) is required as the first arg." >&2
  echo "  e.g. bin/tf-destroy.sh <env-id>   (current id is in the umbrella STATUS.md)" >&2
  echo "  DESTRUCTIVE (tofu destroy) — never defaults to a baked env." >&2
  exit 1
fi

NETWORK_NAME="${NETWORK_NAME:-}"
LB_NAME="${LB_NAME:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

cd "$REPO_DIR"

# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"

dmf_source_operator_config
dmf_resolve_env_paths "$ENV_NAME" || {
  echo "ERROR: Unable to resolve environment $ENV_NAME" >&2
  echo "Available environments:" >&2
  dmf_list_known_envs "$REPO_DIR" | sed 's/^/  /' >&2
  exit 1
}

inventory_var() {
  local key="$1"
  local f="${DMF_ENV_INVENTORY_DIR}/group_vars/all/main.yml"
  [ -f "$f" ] || return 1
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      sub("^[[:space:]]*" key ":[[:space:]]*", "", $0)
      gsub(/^"/, "", $0)
      gsub(/"$/, "", $0)
      gsub(/^'\''/, "", $0)
      gsub(/'\''$/, "", $0)
      print
      exit
    }
  ' "$f"
}

# Determine provider
DMF_PROVIDER="$(inventory_var dmf_provider || true)"
if [ -z "$DMF_PROVIDER" ]; then
  case "$ENV_NAME" in
    *)               DMF_PROVIDER="hetzner" ;;
  esac
fi

# Runtime guard: only hetzner has a Terraform/cloud destroy path.
case "$DMF_PROVIDER" in
  hetzner) ;;  # OK — the only supported provider for tf-destroy
  sandbox)
    echo "ERROR: sandbox has no Terraform/OpenTofu destroy path" >&2
    exit 1
    ;;
  *)
    echo "ERROR: unsupported provider for tf-destroy: $DMF_PROVIDER" >&2
    exit 1
    ;;
esac

HCLOUD_CONTEXT="$(inventory_var hcloud_context || true)"
if [ -z "$NETWORK_NAME" ]; then
    NETWORK_NAME="$(inventory_var hcloud_ccm_network || true)"
fi
if [ -z "$NETWORK_NAME" ]; then
    NETWORK_NAME="k3s-private"
fi
if [ -z "$LB_NAME" ]; then
    LB_NAME="$(inventory_var hcloud_load_balancer_name || true)"
fi
if [ -z "$LB_NAME" ]; then
    LB_NAME="dmf-traefik"
fi

if [ -n "$HCLOUD_CONTEXT" ]; then
    HCLOUD=(hcloud --context "$HCLOUD_CONTEXT")
    echo "==> hcloud context: $HCLOUD_CONTEXT"
else
    HCLOUD=(hcloud)
    echo "==> hcloud context: active CLI context"
fi

# === 1. Detach LB from the private network (keep LB alive for data source) ===
if LB_JSON="$("${HCLOUD[@]}" load-balancer describe "$LB_NAME" -o json 2>/dev/null)"; then
    # Resolve network name to ID for accurate comparison
    NET_ID="$("${HCLOUD[@]}" network describe "$NETWORK_NAME" -o json 2>/dev/null | jq -r '.id // empty')"

    if [ -n "$NET_ID" ]; then
        ATTACHED_IP="$(jq -r --arg netid "$NET_ID" \
            '(.private_net // [])[] | select(.network == ($netid | tonumber)) | .ip' <<<"$LB_JSON")"
    else
        ATTACHED_IP=""
    fi

    if [ -n "$ATTACHED_IP" ]; then
        echo "==> detach LB '$LB_NAME' from network '$NETWORK_NAME' (was at $ATTACHED_IP)"
        "${HCLOUD[@]}" load-balancer detach-from-network "$LB_NAME" --network "$NETWORK_NAME"
    else
        if [ -z "$NET_ID" ]; then
            echo "==> network '$NETWORK_NAME' not found; skipping LB detach"
        else
            echo "==> LB '$LB_NAME' present but not attached to '$NETWORK_NAME'; skipping detach"
        fi
    fi
    LB_PRESENT=1
else
    echo "==> LB '$LB_NAME' not found (likely already deleted)"
    echo "    WARN: the Tofu data source for the LB will fail to refresh."
    echo "    If 'tofu destroy' errors, see the edge-case note in this script."
    LB_PRESENT=0
fi

# === 2. Remove all routes from the network ===
if NET_ID="$("${HCLOUD[@]}" network describe "$NETWORK_NAME" -o json 2>/dev/null | jq -r '.id // empty')"; then
    if [ -n "$NET_ID" ]; then
        ROUTES_TSV="$("${HCLOUD[@]}" network describe "$NETWORK_NAME" -o json \
            | jq -r '(.routes // [])[] | "\(.destination)\t\(.gateway)"')"
        if [ -n "$ROUTES_TSV" ]; then
            ROUTE_COUNT="$(printf '%s\n' "$ROUTES_TSV" | wc -l | tr -d ' ')"
            echo "==> remove $ROUTE_COUNT route(s) from network '$NETWORK_NAME'"
            while IFS=$'\t' read -r dest gw; do
                [ -z "$dest" ] && continue
                printf '    rm %-18s -> %s\n' "$dest" "$gw"
                "${HCLOUD[@]}" network remove-route "$NET_ID" --destination "$dest" --gateway "$gw"
            done <<<"$ROUTES_TSV"
        else
            echo "==> network '$NETWORK_NAME' has no routes; skipping"
        fi
    fi
else
    echo "==> network '$NETWORK_NAME' not found; skipping route cleanup"
fi

# === 3. tofu destroy via the existing wrapper ===
echo
echo "==> tofu destroy ($ENV_NAME) — invoking bin/tf-apply.sh"
bin/tf-apply.sh "$ENV_NAME" destroy -auto-approve

# === 4. Delete the LB (kept alive only for step 3) ===
if [ "$LB_PRESENT" -eq 1 ] && "${HCLOUD[@]}" load-balancer describe "$LB_NAME" >/dev/null 2>&1; then
    echo
    echo "==> delete LB '$LB_NAME' (post-tofu — CCM will recreate on next bring-up)"
    "${HCLOUD[@]}" load-balancer delete "$LB_NAME"
fi

echo
echo "==> teardown complete."
if [ -n "$HCLOUD_CONTEXT" ]; then
    echo "    Verify: hcloud --context $HCLOUD_CONTEXT server list / network list / load-balancer list"
else
    echo "    Verify: hcloud server list / hcloud network list / hcloud load-balancer list"
fi
