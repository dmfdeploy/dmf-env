#!/usr/bin/env bash
# cluster-bootstrap-operator-approle.sh
#
# One-shot setup of the env-specific operator AppRole + matching policy in
# OpenBao. The openbao role auto-creates ESO + born-inventory AppRoles, the
# ops-admin userpass user, and baseline policies — but NOT the narrow-scope
# operator AppRole that bin/run-playbook.sh consumes via openbao_secrets.yml.
# This script fills that gap.
#
# Idempotent: re-running rewrites the policy + AppRole config (no destructive
# difference) and mints a fresh secret_id (the only side effect; the previous
# one is invalidated, which is exactly what you want on a re-bootstrap).
#
# Runs on the k3s control node, exec'ing into openbao-0.
#
# Usage (typically via the bootstrap-operator-approle.sh wrapper, but works
# standalone):
#
#   ssh -t k3s-admin@<control-node> \
#     ./cluster-bootstrap-operator-approle.sh dmf-infra k3s-hetzner
#
# Args:
#   1. APPROLE name (also used as the policy name)
#   2. SECRET_PATH_SCOPE — first path segment under secret/data/, e.g.
#      "k3s-hetzner" → policy grants read/create/update on
#      secret/data/k3s-hetzner/*. Defaults to "k3s-hetzner".
#
# Output (stdout, two lines, machine-parseable):
#   ROLE_ID=<uuid>
#   SECRET_ID=<uuid>
#
# Progress + role_id (also-non-secret) → stderr.

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $(basename "$0") <approle-name> [secret-path-scope=k3s-hetzner]" >&2
    exit 1
fi

APPROLE="$1"
SCOPE="${2:-k3s-hetzner}"
OPS_USER="${OPS_ADMIN_USER:-ops-admin}"
NS="${OPENBAO_NAMESPACE:-openbao}"
POD="${OPENBAO_POD:-openbao-0}"

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

# The openbao role's password generator uses ascii_letters+digits, so this
# inlining is safe. Reject anything else to avoid heredoc/single-quote
# injection surprises.
if ! printf '%s' "$OPS_PASS" | LC_ALL=C grep -q '^[[:alnum:]]\+$'; then
    echo "error: password contains characters outside the expected alnum charset" >&2
    exit 3
fi

OUT="$(sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n "$NS" exec -i "$POD" -- sh <<EOF
set -e

TOKEN=\$(bao login -no-store -format=json -method=userpass \
  username='${OPS_USER}' password='${OPS_PASS}' 2>/dev/null \
  | sed -n 's/.*"client_token"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
[ -n "\$TOKEN" ] || { echo "userpass login failed" >&2; exit 4; }
export BAO_TOKEN=\$TOKEN

# 1. Policy — narrow scope on secret/data/<scope>/*
POL=/tmp/${APPROLE}.hcl
cat > "\$POL" <<HCL
path "secret/data/${SCOPE}/*" {
  capabilities = ["read", "create", "update"]
}
HCL
bao policy write '${APPROLE}' "\$POL" >&2
rm -f "\$POL"

# 2. AppRole bound to that policy
bao write auth/approle/role/'${APPROLE}' \
  token_policies='${APPROLE}' \
  token_ttl=1h token_max_ttl=24h \
  secret_id_ttl=8760h secret_id_num_uses=0 \
  bind_secret_id=true >&2

# 3. role_id (stable across re-runs unless the AppRole is deleted)
ROLE_ID=\$(bao read -field=role_id auth/approle/role/'${APPROLE}'/role-id)
[ -n "\$ROLE_ID" ] || { echo "role_id read failed" >&2; exit 5; }

# 4. fresh secret_id (caller stores in Keychain)
SECRET_ID=\$(bao write -force -field=secret_id auth/approle/role/'${APPROLE}'/secret-id)
[ -n "\$SECRET_ID" ] || { echo "secret_id mint failed" >&2; exit 6; }

echo "ROLE_ID=\$ROLE_ID"
echo "SECRET_ID=\$SECRET_ID"
EOF
)"

unset OPS_PASS

ROLE_ID="$(printf '%s\n' "$OUT" | sed -n 's/^ROLE_ID=//p')"
SECRET_ID="$(printf '%s\n' "$OUT" | sed -n 's/^SECRET_ID=//p')"
unset OUT

if [ -z "$ROLE_ID" ] || [ -z "$SECRET_ID" ]; then
    echo "error: did not capture role_id+secret_id from pod output" >&2
    exit 7
fi

# role_id → stderr (non-secret, informational)
echo "role_id: $ROLE_ID" >&2

# Both → stdout (machine-parseable; SECRET_ID is sensitive — only on stdout
# so a single pipeline can split them, never echoed to scrollback)
echo "ROLE_ID=$ROLE_ID"
echo "SECRET_ID=$SECRET_ID"

unset ROLE_ID SECRET_ID
