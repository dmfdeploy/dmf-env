#!/usr/bin/env bash
# recreate-sandbox-vm.sh — (re)create the WP1S sandbox Lima VM substrate.
#
# PLATFORM: macOS + Lima ONLY — a maintainer convenience, NOT the paved
# onboarding path. It hard-requires limactl/Lima (vmType vz, socket_vmnet on
# en0) and produces a node whose SSH user / interface are `lima` / `lima0`.
# The substrate-agnostic path is to bring any SSH-reachable Debian 12/13 ARM64
# node (works from any operator OS) and answer the dmf-init wizard's Target-node
# fields for that node — Node IP, Ansible user (root, or the image default such
# as debian), Interface (eth0/ens3/…). See dmfdeploy/dmfdeploy#81.
#
# VM-FIRST, env-agnostic. This script rebuilds ONLY the Lima Debian-12 VM
# substrate and emits its bridged LAN IP. It does NOT assume any particular
# env id. Two modes:
#
#   1. Fresh-wizard: rebuild the VM, print the bridged IP, and tell you to run
#      init-wizard.sh answering "Sandbox node host/IP" with that IP. The wizard
#      lands a fresh env under ~/.dmfdeploy/envs/<env>/ (post-2026-05-28
#      consolidation). This is the cold-bootstrap path that proves the local-CA
#      / cert-manager flow.
#
# Faithful to the original recipe (see ~/.lima/dmf-sandbox/lima.yaml):
#   Debian 12 (bookworm) · vmType vz · 4 CPU / 10 GiB / 60 GiB ·
#   network lima:bridged (socket_vmnet on en0, defined in
#   ~/.lima/_config/networks.yaml). The guest gets a DHCP LAN IP on lima0.
#
# Usage:
#   bin/recreate-sandbox-vm.sh [-y|--yes]              # fresh-wizard mode
#   ENV_NAME=<env-id> bin/recreate-sandbox-vm.sh -y    # legacy reuse mode
#
# Override any default via env vars, e.g.  CPUS=6 MEMORY=12 bin/recreate-sandbox-vm.sh
#
# stdout: the new bridged IPv4 (only). All human log goes to stderr, so
#   NEW_IP="$(bin/recreate-sandbox-vm.sh -y)"  captures just the IP.

set -euo pipefail

VM_NAME="${VM_NAME:-dmf-sandbox}"
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-10}"                 # GiB
DISK="${DISK:-60}"                     # GiB
VM_TYPE="${VM_TYPE:-vz}"
NETWORK="${NETWORK:-lima:bridged}"
TEMPLATE="${TEMPLATE:-template://debian-12}"
GUEST_BRIDGE_IF="${GUEST_BRIDGE_IF:-lima0}"   # bridged NIC name inside the guest
ENV_NAME="${ENV_NAME:-}"                       # empty = fresh-wizard mode (no committed env)
IP_WAIT_TRIES="${IP_WAIT_TRIES:-30}"          # × 3s ≈ 90s for the DHCP lease

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR%/bin}"

# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"

# Legacy-reuse paths — only meaningful when ENV_NAME names a committed env.
HOSTS_INI=""
SECURE_DIR="${HOME}/.secure/${ENV_NAME}"
NET_CFG="${HOME}/.lima/_config/networks.yaml"

# If ENV_NAME is set (legacy-reuse mode), resolve the env paths
if [ -n "$ENV_NAME" ]; then
  cd "$REPO_DIR"
  dmf_source_operator_config
  if dmf_resolve_env_paths "$ENV_NAME" 2>/dev/null; then
    HOSTS_INI="${DMF_ENV_INVENTORY_DIR}/hosts.ini"
  fi
fi

if [ -t 2 ]; then
  c_bold=$'\033[1m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_rst=$'\033[0m'
else
  c_bold=''; c_red=''; c_grn=''; c_ylw=''; c_rst=''
fi
say()  { printf '%s\n' "$*" >&2; }
ok()   { printf '%s✓%s %s\n' "$c_grn" "$c_rst" "$*" >&2; }
warn() { printf '%s!%s %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()  { printf '%s✗ %s%s\n' "$c_red" "$*" "$c_rst" >&2; exit 1; }

ASSUME_YES=0
case "${1:-}" in
  -y|--yes) ASSUME_YES=1 ;;
  "") ;;
  *) die "Unknown argument: $1 (use -y/--yes)" ;;
esac

guest_ip() { limactl shell "$VM_NAME" -- ip -4 -o addr show "$GUEST_BRIDGE_IF" 2>/dev/null \
               | awk '{print $4}' | cut -d/ -f1 | head -1; }

# ── Preflight ────────────────────────────────────────────────────────────────
command -v limactl >/dev/null 2>&1 || die "limactl not found (brew install lima)."

if [ "$NETWORK" = "lima:bridged" ]; then
  [ -f "$NET_CFG" ] || die "Lima networks.yaml not found: $NET_CFG (bridged not configured)."
  grep -q "bridged:" "$NET_CFG" || die "No 'bridged' network defined in $NET_CFG."
  sv="$(grep -E 'socketVMNet' "$NET_CFG" | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  if [ -n "${sv:-}" ] && [ -x "$sv" ]; then
    ok "socket_vmnet present: $sv"
  else
    warn "socket_vmnet not found/executable (${sv:-unset}); bridged DHCP may fail."
  fi
fi

# ── Confirm + delete existing ────────────────────────────────────────────────
if limactl list -q 2>/dev/null | grep -qx "$VM_NAME"; then
  cur_ip="$(guest_ip || true)"
  warn "Lima VM '${VM_NAME}' exists${cur_ip:+ (bridged IP ${cur_ip})} and will be DESTROYED."
  if [ "$ASSUME_YES" -ne 1 ]; then
    printf 'Delete and recreate %s? [y/N] ' "$VM_NAME" >&2
    read -r ans
    case "$ans" in y|Y|yes|YES) ;; *) die "Aborted — nothing changed." ;; esac
  fi
  say "Stopping + deleting ${VM_NAME}…"
  limactl stop -f "$VM_NAME" >/dev/null 2>&1 || true
  limactl delete -f "$VM_NAME" >/dev/null 2>&1 || die "limactl delete failed."
  ok "Deleted ${VM_NAME}."
else
  say "No existing '${VM_NAME}'; creating fresh."
fi

# ── Create ───────────────────────────────────────────────────────────────────
say "Creating ${VM_NAME}: ${TEMPLATE} · ${VM_TYPE} · ${CPUS} CPU / ${MEMORY} GiB / ${DISK} GiB · net=${NETWORK}"
limactl start \
  --name="$VM_NAME" \
  --tty=false \
  --vm-type="$VM_TYPE" \
  --cpus="$CPUS" \
  --memory="$MEMORY" \
  --disk="$DISK" \
  --network="$NETWORK" \
  "$TEMPLATE" || die "limactl start failed."
ok "VM '${VM_NAME}' started."

# ── Wait for the bridged NIC to get a DHCP lease ─────────────────────────────
say "Waiting for ${GUEST_BRIDGE_IF} to get a LAN IP…"
NEW_IP=""
for _ in $(seq 1 "$IP_WAIT_TRIES"); do
  NEW_IP="$(guest_ip || true)"
  [ -n "$NEW_IP" ] && break
  sleep 3
done
[ -n "$NEW_IP" ] || die "${GUEST_BRIDGE_IF} got no IPv4 in time. Check socket_vmnet / the bridged network."
ok "${VM_NAME} bridged IP: ${c_bold}${NEW_IP}${c_rst}"

# ── Next steps (mode-dependent) ──────────────────────────────────────────────
if [ -n "$ENV_NAME" ] && [ -f "$HOSTS_INI" ]; then
  # Legacy reuse: reconcile the committed inventory IP, no wizard.
  INV_IP="$(grep -oE 'k3s_node_ip=[0-9.]+' "$HOSTS_INI" | head -1 | cut -d= -f2 || true)"
  say ""
  if [ -n "$INV_IP" ] && [ "$INV_IP" != "$NEW_IP" ]; then
    warn "Inventory hosts.ini has ${INV_IP} but the new VM is ${NEW_IP} — update it before bootstrap:"
    say  "    sed -i '' 's/${INV_IP}/${NEW_IP}/g' \"${HOSTS_INI}\""
  elif [ -n "$INV_IP" ]; then
    ok "Inventory IP (${INV_IP}) still matches — no hosts.ini change needed."
  else
    warn "Could not read k3s_node_ip from ${HOSTS_INI}; set ansible_host/k3s_node_ip to ${NEW_IP}."
  fi
  cat >&2 <<NEXT

${c_bold}Next — re-run the sandbox bootstrap (reuses ${ENV_NAME}; no wizard needed):${c_rst}
  rm -rf "${SECURE_DIR}"          # drop the old cluster's OpenBao keys; fresh init regenerates
  cd "${REPO_DIR}"
  bin/run-playbook.sh ${ENV_NAME} ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-provision-pre-seed.yml
  bin/bootstrap-secrets.sh seed-bao ${ENV_NAME}
  bin/run-playbook.sh ${ENV_NAME} ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-provision-post-seed.yml
  bin/run-playbook.sh ${ENV_NAME} ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-configure.yml
  bin/run-playbook.sh ${ENV_NAME} ../dmf-infra/k3s-lab-bootstrap/bootstrap-sandbox-verify.yml
NEXT
else
  # Fresh-wizard (VM-first→wizard-IP): the VM exists; the env does not yet.
  cat >&2 <<NEXT

${c_bold}Next — run the init wizard for a FRESH env, then bootstrap:${c_rst}
  cd "${REPO_DIR}"
  bin/init-wizard.sh         # Provider=sandbox; answer "Sandbox node host/IP" with:
                             #   ${c_bold}${NEW_IP}${c_rst}
                             # SSH user = your Lima guest user; iface = ${GUEST_BRIDGE_IF}
  # then, with the wizard-printed <env_id>, run the 5-stage bootstrap it lists
  # (pre-seed → seed-bao → post-seed → configure → verify).
NEXT
fi

# Machine-readable: the bridged IP on stdout (only) for capture by callers.
printf '%s\n' "$NEW_IP"
