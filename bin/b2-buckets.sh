#!/usr/bin/env bash
# b2-buckets.sh — create and configure Backblaze B2 buckets for a DMF env.
#
# Workaround for AWS Terraform provider incompatibility with B2's
# S3-Compatible API (NoSuchCorsConfiguration casing mismatch, PutBucketTagging
# 501, side-paths that overwrite bucket attrs). Configures buckets directly
# via B2's native API. Idempotent — safe to re-run after partial failures.
#
# Per env, ensures these three buckets exist and are configured:
#   dmf-audit-<env>              Object Lock enabled, COMPLIANCE retention
#                                 via per-upload --object-lock-retain-until-date.
#                                 SSE-B2 AES256. Permissive CORS (workaround).
#                                 No lifecycle rules — Object Lock owns retention.
#   dmf-openbao-snapshots-<env>  SSE-B2 AES256. Permissive CORS.
#                                 Lifecycle: hidden versions deleted after 90d.
#   dmf-app-backups-<env>        SSE-B2 AES256. Permissive CORS.
#                                 Lifecycle: hidden versions deleted after 365d.
#
# Bucket names + endpoint + region come from the env manifest (resolved via
# ~/.dmfdeploy/envs/<env>/). Credentials come from the tfvars file at
# ~/.dmfdeploy/envs/<env>/object-storage.tfvars (operator-managed,
# never committed).
#
# Usage:
#   dmf-env/bin/b2-buckets.sh ensure <env>      # create + configure all buckets
#   dmf-env/bin/b2-buckets.sh show <env>        # show current B2-side state
#
# Prerequisites:
#   - tfvars file exists at ~/.dmfdeploy/envs/<env>/object-storage.tfvars
#     (operator can use the same B2 credentials across envs — keys are
#      account-scoped, not env-scoped)
#   - env manifest has spec.object_storage block with bucket names + endpoint + region

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/_resolve_env_paths.sh
. "$SCRIPT_DIR/lib/_resolve_env_paths.sh"

usage() {
    cat <<'USAGE'
Usage:
  b2-buckets.sh ensure <env>      Create + configure all DMF buckets for the env.
                                  Idempotent; safe to re-run.
  b2-buckets.sh show <env>        Show current B2-side state of the env's buckets.
  b2-buckets.sh verify <env>      Read each bucket and assert it matches the
                                  expected contracts (Object Lock on audit,
                                  SSE-B2 AES256 on all three, CORS rule present,
                                  lifecycle rules where expected). Read-only.
                                  Exits non-zero on any deviation.
  b2-buckets.sh preflight <env>   Account-level capability test: create a
                                  throwaway lock-enabled bucket, verify the
                                  flag was honored, delete it. Run once per
                                  Backblaze account to catch silent-drop
                                  cases (account-level Object Lock disabled).
                                  Uses the env's tfvars only for credentials;
                                  the env's own buckets are not touched.

ENV is your env id / manifest name (the current id is in the umbrella STATUS.md).
USAGE
}

run_python() {
    local subcmd="$1"
    local env="$2"

    # Resolve env paths to get manifest location
    cd "$REPO_DIR"
    dmf_source_operator_config
    dmf_resolve_env_paths "$env" || {
      echo "ERROR: Unable to resolve environment $env" >&2
      exit 1
    }

    local manifest="${DMF_ENV_MANIFEST_FILE}"
    local tfvars="${DMF_ENV_TFVARS_DIR}/object-storage.tfvars"

    if [ ! -r "${tfvars}" ]; then
        echo "ERROR: tfvars not readable at ${tfvars}" >&2
        echo "       Populate from the operator's B2 application key (see Phase 2 handoff §4)." >&2
        exit 1
    fi

    # preflight is account-scoped; doesn't read the manifest. show / ensure /
    # verify all need the per-env manifest to know which buckets to act on.
    if [ "$subcmd" != "preflight" ]; then
        if [ ! -r "${manifest}" ]; then
            echo "ERROR: manifest not readable at ${manifest}" >&2
            exit 1
        fi
        SUBCMD="${subcmd}" MANIFEST="${manifest}" TFVARS="${tfvars}" \
            python3 "${SCRIPT_DIR}/lib/b2-buckets.py"
    else
        SUBCMD="${subcmd}" TFVARS="${tfvars}" \
            python3 "${SCRIPT_DIR}/lib/b2-buckets.py"
    fi
}

case "${1:-}" in
    ensure|show|verify|preflight)
        if [ $# -lt 2 ]; then echo "ERROR: env required" >&2; usage >&2; exit 1; fi
        run_python "$1" "$2"
        ;;
    ""|-h|--help)
        usage
        ;;
    *)
        echo "Unknown subcommand: $1" >&2
        usage >&2
        exit 1
        ;;
esac
