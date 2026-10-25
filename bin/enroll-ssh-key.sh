#!/usr/bin/env bash
# enroll-ssh-key.sh — enroll the env's SSH key on a bring-your-own sandbox node
# and gate on key-only login before the first playbook run.
#
# A node you bring yourself (VPS, bare metal) does not carry the env key yet, so
# the first key-only SSH check fails with Permission denied. This script logs in
# once with the node user's one-time password, appends the key's public half to
# authorized_keys, then checks key-only login the way Ansible will use it.
#
# The password is typed at ssh's own prompt on /dev/tty. It never reaches argv,
# a file, the environment or a variable of this script, and nothing caches it.
#
# fail2ban: enrollment is one connection with NumberOfPasswordPrompts=1, so a
# mistyped password costs one failed attempt, not three, and a node that already
# accepts the key is never asked for a password. The controller itself is
# exempted by harden_fail2ban_ignoreip (dmf-infra roles/base/harden).
#
# Usage:
#   bin/enroll-ssh-key.sh <ENV_NAME>
#
# Acts on the first host under [k3s] in the env's hosts.ini (single-node
# sandbox envs). Exit 0 = key login works; 1 = failed, cause on stderr.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"
dmf_source_operator_config

err()  { printf 'error: %s\n' "$*" >&2; }
info() { printf '  %s\n' "$*"; }
die()  { err "$*"; exit 1; }

if [ $# -ne 1 ]; then
    echo "Usage: bin/enroll-ssh-key.sh <ENV_NAME>" >&2
    echo "" >&2
    echo "Available environments:" >&2
    dmf_list_known_envs | sed 's/^/  /' >&2
    exit 1
fi
ENV_NAME="$1"
dmf_resolve_env_paths "$ENV_NAME" || die "'${ENV_NAME}' is not a known env (no ${DMF_ENV_ROOT})"

for cmd in ssh ssh-keygen; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: ${cmd}"
done

HOSTS_INI="${DMF_ENV_INVENTORY_DIR}/hosts.ini"
GROUP_VARS_DIR="${DMF_ENV_INVENTORY_DIR}/group_vars/all"

NODE_USER=""
NODE_HOST=""
if [ -r "$HOSTS_INI" ]; then
    read -r NODE_USER NODE_HOST < <(awk '
        /^\[k3s\]/ { in_k3s=1; next }
        /^\[/      { in_k3s=0 }
        in_k3s && NF>0 && $1 !~ /^#/ {
            user=""; host=""
            for (i=2; i<=NF; i++) {
                if ($i ~ /^ansible_host=/) { host=substr($i, 14) }
                if ($i ~ /^ansible_user=/) { user=substr($i, 14) }
            }
            if (user != "" && host != "") { print user, host; exit }
        }
    ' "$HOSTS_INI") || true
fi
[ -n "$NODE_USER" ] && [ -n "$NODE_HOST" ] \
    || die "no [k3s] host with ansible_host and ansible_user in ${HOSTS_INI}"

KEY="$(grep -hE '^ansible_ssh_private_key_file:' "$GROUP_VARS_DIR"/*.yml 2>/dev/null | head -1 | \
    sed -E "s/^ansible_ssh_private_key_file:[[:space:]]*//; s/[[:space:]]*#.*\$//; s/^[\"']//; s/[\"']\$//" || true)"
case "$KEY" in
    "~/"*) KEY="${HOME}/${KEY#\~/}" ;;
esac
[ -n "$KEY" ] || die "ansible_ssh_private_key_file is not set under ${GROUP_VARS_DIR}"
[ -r "$KEY" ] || die "SSH private key not readable at ${KEY}"

PUBKEY="$(ssh-keygen -y -f "$KEY")" || die "cannot derive the public key from ${KEY}"

TARGET="${NODE_USER}@${NODE_HOST}"
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
          -o ConnectTimeout=10 -o LogLevel=ERROR)

# ssh_failure_cause <ssh stderr> — name the likely cause in operator terms.
ssh_failure_cause() {
    case "$1" in
        *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*)
            echo "the host key of ${NODE_HOST} differs from the one in known_hosts (rebuilt node?); run ssh-keygen -R ${NODE_HOST} and retry" ;;
        *"Permission denied"*)
            echo "${NODE_HOST} rejected our credentials: wrong password for ${NODE_USER}, or the env key is not in that user's authorized_keys" ;;
        *"Connection refused"*)
            echo "${NODE_HOST} refused port 22: sshd is not running, or fail2ban on the node banned this host (the harden role exempts it via harden_fail2ban_ignoreip)" ;;
        *"timed out"*|*"No route to host"*|*"Network is unreachable"*)
            echo "${NODE_HOST} did not answer on port 22: check ansible_host in the inventory, the node's power and the network path" ;;
        *"Could not resolve hostname"*)
            echo "cannot resolve ${NODE_HOST}: check ansible_host in the inventory" ;;
        *)
            echo "ssh to ${TARGET} failed" ;;
    esac
}

fail_ssh() {
    local what="$1" raw="$2"
    err "${what}: $(ssh_failure_cause "$raw")"
    [ -z "$raw" ] || printf '  ssh said: %s\n' "$raw" >&2
    exit 1
}

# Appends the key (read from stdin) to authorized_keys unless it is already
# there. Adds the missing final newline an existing file may lack.
ENROLL_CMD='umask 077; mkdir -p ~/.ssh; f=~/.ssh/authorized_keys; touch "$f";
[ -z "$(tail -c1 "$f")" ] || echo >> "$f"; read -r key;
grep -qxF "$key" "$f" || printf "%s\n" "$key" >> "$f"'

info "Enrolling the env key on ${TARGET}."
info "If the node does not accept the key yet, ssh asks once for ${NODE_USER}'s password."
if ! raw="$(printf '%s\n' "$PUBKEY" | ssh "${SSH_OPTS[@]}" \
        -o PreferredAuthentications=publickey,password -o NumberOfPasswordPrompts=1 \
        "$TARGET" "$ENROLL_CMD" 2>&1)"; then
    fail_ssh "enrollment failed" "$raw"
fi

if ! raw="$(ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o PasswordAuthentication=no \
        "$TARGET" true 2>&1)"; then
    fail_ssh "connectivity gate failed: key login to ${TARGET} does not work after enrollment" "$raw"
fi
info "Key login to ${TARGET} works."
