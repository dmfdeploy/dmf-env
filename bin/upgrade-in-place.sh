#!/usr/bin/env bash
# upgrade-in-place.sh — idempotent upgrade of an existing DMF env to current main.
#
# Canonical upgrade sequence (6 stages):
#   Stage 1 — unseal           — verify every OpenBao pod is unsealed, then run
#                                the rolling-restart guard (102-openbao-ha-guard.yml)
#   Stage 2 — seed-bao         — backfill platform+app secrets into OpenBao
#   Stage 3 — pre-seed         — prepare cluster state for apps
#   Stage 4 — post-seed        — deploy apps (dependent on seed-bao secrets)
#   Stage 5 — configure        — final customization
#   Stage 6 — convergence gates — verify all apps running, cluster converged
#
# This wrapper is IDEMPOTENT: safe to re-run on an already-upgraded env.
# A second run should complete with "converged to current main; clean no-op"
# if nothing changed. It targets an EXISTING env with OpenBao already initialized
# and unsealed.
#
# CAVEAT: k3s version is NOT upgraded. The playbooks/300-k3s.yml role installs
# only when k3s is absent; re-running pre-seed on an existing env leaves k3s at
# its current version. There is NO in-place minor-version jump. The k3s_version
# bump applies to FRESH builds only. Consequence: an upgraded existing env runs
# the new CCM/platform on its OLD k3s (acceptable in experiment phase; a true
# k3s migration requires a separate sequential plan).
#
# The playbooks of stages 3-5 can restart an OpenBao pod, and a restarted pod is
# sealed. Stage 1 therefore refuses while any pod is sealed. On a Raft cluster the
# guard also refuses while any pod is not a healthy voter, and it needs an ops-admin
# token in OPENBAO_GUARD_TOKEN. On a single replica the guard passes when that pod
# is unsealed. No flag skips the guard. Unseal each pod with
# bin/unseal-openbao.sh (OPENBAO_POD=<pod>) before you run the upgrade again.
#
# Usage:
#   bin/upgrade-in-place.sh <ENV_NAME>
#   bin/upgrade-in-place.sh <ENV_NAME> --yes (skip confirm prompt)
#   bin/upgrade-in-place.sh <ENV_NAME> --skip-unseal-check (skip the stage 1 seal check; the guard still runs)
#   bin/upgrade-in-place.sh <ENV_NAME> --dry-run (plan without mutating seed-bao)
#
# Exit codes:
#   0   upgraded successfully, converged
#   1   bad arg / config
#   2   OpenBao unreachable, a pod sealed, or the restart guard refused
#   3   seed-bao failed
#   4   playbook stage failed
#   5   convergence gate failed
#   6   bootstrap-verify gate failed

set -euo pipefail

# Resolve script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Source the environment resolver
# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"
dmf_source_operator_config

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

err() { printf 'error: %s\n' "$*" >&2; }
info() { printf '  %s\n' "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────

if [ $# -lt 1 ] || [ -z "${1:-}" ] || ! dmf_env_exists "$1"; then
  if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
    echo "ERROR: <ENV_NAME> is required as the first positional arg." >&2
  else
    echo "ERROR: env '${1}' not found" >&2
  fi
  echo "Available envs:" >&2
  while IFS= read -r env; do
    [ -n "$env" ] && echo "  $env" >&2
  done < <(dmf_list_known_envs)
  echo "(current live env id is in the umbrella's STATUS.digest.local.md, which bin/generate-status.sh writes)" >&2
  exit 1
fi

ENV_NAME="$1"
shift

dmf_resolve_env_paths "$ENV_NAME"

# Parse flags
SKIP_UNSEAL_CHECK=0
SKIP_CONFIRM=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --skip-unseal-check) SKIP_UNSEAL_CHECK=1 ;;
    --yes | -y) SKIP_CONFIRM=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      sed -n '/^# upgrade-in-place/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      err "unknown arg: $arg (try --help)"
      exit 1
      ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Upgrade sequence
# ─────────────────────────────────────────────────────────────────────────────

section "Upgrade: $ENV_NAME"
info "Current state will be validated and upgraded to current main"
info "This wrapper is idempotent — safe to re-run"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: OpenBao unsealed precheck
# ─────────────────────────────────────────────────────────────────────────────

if [ "$SKIP_UNSEAL_CHECK" -ne 1 ]; then
  section "Stage 1: OpenBao unsealed precheck"

  status_rc=0
  status_output=$("$SCRIPT_DIR/unseal-openbao.sh" "$ENV_NAME" --status-all 2>&1) || status_rc=$?

  if [ "$status_rc" -eq 0 ]; then
    printf '%s\n' "$status_output" | grep -E ': (un)?sealed$' || true
    info "every OpenBao pod is unsealed — proceeding"
  elif [ "$status_rc" -eq 6 ]; then
    printf '%s\n' "$status_output" | grep -E ': (un)?sealed$' >&2 || true
    err "at least one OpenBao pod is sealed — unseal each sealed pod first:"
    err "  OPENBAO_POD=<pod> bin/unseal-openbao.sh $ENV_NAME"
    err "  (or re-run vertical-security/100-openbao.yml)"
    err "then re-run this upgrade."
    exit 2
  else
    info "WARN: OpenBao status unclear (may be flaky); continuing anyway"
    info "If the upgrade fails with OpenBao errors, run:"
    info "  bin/unseal-openbao.sh $ENV_NAME"
    info "and retry."
  fi
else
  section "Stage 1: OpenBao unsealed precheck (SKIPPED)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1b: restart guard. No flag skips it.
# ─────────────────────────────────────────────────────────────────────────────

# Guard before any step that can restart an OpenBao pod. It is read-only, so it
# runs without --check even in a dry run: ansible skips command tasks under
# --check, and a skipped guard would pass without looking. --skip-unseal-check
# skips only the seal precheck of stage 1. It never skips this guard, because the
# guard also reads the Raft state, which the seal precheck does not.
section "Stage 1b: OpenBao restart guard"
if ! "$SCRIPT_DIR/run-playbook.sh" "$ENV_NAME" "../dmf-infra/k3s-lab-bootstrap/playbooks/vertical-security/102-openbao-ha-guard.yml"; then
  err "the restart guard refused — no OpenBao pod was restarted and nothing changed"
  err "fix what it reports (sealed pod, a pod that is not a healthy voter, no OPENBAO_GUARD_TOKEN on a cluster)"
  exit 2
fi

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: seed-bao (secret backfill)
# ─────────────────────────────────────────────────────────────────────────────

section "Stage 2: seed-bao (secret backfill)"
cat <<EOF
This stage will backfill platform and app secrets from the bootstrap bundle
into OpenBao. It is idempotent — re-running is safe.

Proceed with upgrade?
EOF
echo ""

if [ "$SKIP_CONFIRM" -eq 0 ]; then
  if ! [ -t 0 ]; then
    err "stdin is not a TTY — pass --yes to skip the confirm prompt"
    exit 1
  fi
  read -r -p "Proceed? [y/N] " ans
  case "$ans" in
    y | Y | yes | YES) ;;
    *) info "aborted"; exit 0 ;;
  esac
fi

if [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] skipping seed-bao (mutating step)"
else
  info "Running seed-bao (de-masked)..."
  if ! "$SCRIPT_DIR/bootstrap-secrets.sh" seed-bao "$ENV_NAME"; then
    err "seed-bao failed — secrets NOT seeded; aborting upgrade"
    err "Set DMF_BUNDLE_SET_DEBUG=1 for per-step detail"
    exit 3
  fi
  info "seed-bao complete — secrets backfilled"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Stages 3–5: Run the upgrade stages (pre-seed, post-seed, configure)
# ─────────────────────────────────────────────────────────────────────────────

STAGES=(
  "bootstrap-provision-pre-seed.yml"
  "bootstrap-provision-post-seed.yml"
  "bootstrap-configure.yml"
)

STAGE_NUM=3
for stage in "${STAGES[@]}"; do
  section "Stage $STAGE_NUM: $stage"
  EXTRA_ARGS=""
  if [ "$DRY_RUN" -eq 1 ]; then
    EXTRA_ARGS="--check --diff"
    info "[dry-run] running with --check --diff"
  fi
  if ! "$SCRIPT_DIR/run-playbook.sh" "$ENV_NAME" "../dmf-infra/k3s-lab-bootstrap/$stage" $EXTRA_ARGS; then
    err "$stage failed — aborting"
    exit 4
  fi
  ((STAGE_NUM++)) || true
done

# ─────────────────────────────────────────────────────────────────────────────
# Stage 6: Convergence gates
# ─────────────────────────────────────────────────────────────────────────────

section "Stage 6: Convergence gates"

info "Running verify-bootstrap-convergence.yml..."
EXTRA_ARGS=""
if [ "$DRY_RUN" -eq 1 ]; then
  EXTRA_ARGS="--check --diff"
  info "[dry-run] running with --check --diff"
fi
if ! "$SCRIPT_DIR/run-playbook.sh" "$ENV_NAME" "../dmf-infra/k3s-lab-bootstrap/playbooks/verify-bootstrap-convergence.yml" $EXTRA_ARGS; then
  err "convergence gate failed"
  exit 5
fi

info "Running bootstrap-verify.yml..."
EXTRA_ARGS=""
if [ "$DRY_RUN" -eq 1 ]; then
  EXTRA_ARGS="--check --diff"
  info "[dry-run] running with --check --diff"
fi
if ! "$SCRIPT_DIR/run-playbook.sh" "$ENV_NAME" "../dmf-infra/k3s-lab-bootstrap/bootstrap-verify.yml" $EXTRA_ARGS; then
  err "bootstrap verification failed"
  exit 6
fi

# ─────────────────────────────────────────────────────────────────────────────
# Success
# ─────────────────────────────────────────────────────────────────────────────

if [ "$DRY_RUN" -eq 1 ]; then
  section "Dry-run complete"
  info "dry-run complete — no changes made"
else
  section "Upgrade complete"
  info "Converged to current main"
  info "A second run should be a clean no-op (all idempotent gates already met)"
fi

exit 0
