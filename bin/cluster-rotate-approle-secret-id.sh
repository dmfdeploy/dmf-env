#!/usr/bin/env bash
# cluster-rotate-approle-secret-id.sh
#
# Runs on the k3s control node. Generates a fresh OpenBao AppRole secret_id
# inside the openbao-0 pod and prints it on stdout (only). role_id and
# progress notes go to stderr.
#
# This script intentionally lives on the cluster, not the operator's
# workstation: it avoids the breakglass JSON file path used by
# bin/get-admin-cred.sh, in case that file is unavailable or you'd rather
# enter the ops_admin password by hand.
#
# Invocation patterns
# -------------------
# Interactive (paste password at hidden prompt):
#   ssh -t k3s-admin@<control-node> ./cluster-rotate-approle-secret-id.sh k3s-infra-lab
#
# Pipe password from stdin (clean stdout for chaining into Keychain):
#   read -rs PASS
#   ssh -q k3s-admin@<control-node> ./cluster-rotate-approle-secret-id.sh k3s-infra-lab <<<"$PASS" \
#     | { IFS= read -r SID; \
#         security delete-generic-password -s openbao-approle-dmf-infra -a secret-id 2>/dev/null; \
#         security add-generic-password    -s openbao-approle-dmf-infra -a secret-id -w "$SID"; }
#   unset PASS
#
# Secrets discipline
# ------------------
# - The password never appears in argv (read -rs from terminal or piped via
#   stdin; passed into the pod through a heredoc, then into bao login via
#   single-quoted argv inside the pod's own shell — never visible to ps on
#   the host).
# - The secret_id is the only thing on stdout. role_id and any errors go
#   to stderr so a `| pipeline | security add-generic-password` chain works.
# - The token bao mints lives only inside the ephemeral pod shell; -no-store
#   keeps it out of the pod's filesystem.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $(basename "$0") <approle-name>" >&2
    exit 1
fi

APPROLE="$1"
OPS_USER="${OPS_ADMIN_USER:-ops_admin}"
NS="${OPENBAO_NAMESPACE:-openbao}"
POD="${OPENBAO_POD:-openbao-0}"

# Read password — prompt if attached to a terminal, else read one line from stdin.
if [ -t 0 ]; then
    printf 'OpenBao %s password: ' "$OPS_USER" >&2
    IFS= read -rs OPS_PASS
    printf '\n' >&2
else
    IFS= read -r OPS_PASS
fi

if [ -z "${OPS_PASS}" ]; then
    echo "error: empty password" >&2
    exit 2
fi

# Sanity: the userpass charset (per the openbao role generator) is
# ascii_letters+digits, so single-quote inlining in the heredoc is safe.
if ! printf '%s' "$OPS_PASS" | LC_ALL=C grep -q '^[[:alnum:]]\+$'; then
    echo "error: password contains characters that aren't in the expected alnum charset; aborting to avoid injection risk" >&2
    exit 3
fi

OUT="$(sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n "$NS" exec -i "$POD" -- sh <<EOF
set -e
TOKEN=\$(bao login -no-store -format=json -method=userpass \
  username='${OPS_USER}' password='${OPS_PASS}' 2>/dev/null \
  | sed -n 's/.*"client_token"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
[ -n "\$TOKEN" ] || { echo "userpass login failed" >&2; exit 4; }
export BAO_TOKEN=\$TOKEN
ROLE_ID=\$(bao read -field=role_id auth/approle/role/${APPROLE}/role-id 2>/dev/null || true)
[ -n "\$ROLE_ID" ] || { echo "AppRole '${APPROLE}' not found" >&2; exit 5; }
echo "ROLE_ID=\$ROLE_ID"
SECRET_ID=\$(bao write -force -field=secret_id auth/approle/role/${APPROLE}/secret-id)
[ -n "\$SECRET_ID" ] || { echo "secret_id generation failed" >&2; exit 6; }
echo "SECRET_ID=\$SECRET_ID"
EOF
)"

unset OPS_PASS

ROLE_ID="$(printf '%s\n' "$OUT" | sed -n 's/^ROLE_ID=//p')"
SECRET_ID="$(printf '%s\n' "$OUT" | sed -n 's/^SECRET_ID=//p')"
unset OUT

if [ -z "$SECRET_ID" ]; then
    echo "error: did not capture secret_id from pod output" >&2
    exit 7
fi

# role_id → stderr (non-secret, informational)
echo "role_id: $ROLE_ID" >&2

# secret_id → stdout (only line on stdout, ready to pipe)
printf '%s\n' "$SECRET_ID"

unset ROLE_ID SECRET_ID
