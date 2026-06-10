#!/usr/bin/env python3
"""
b2-buckets.py — DMF B2 bucket lifecycle (create + configure), invoked by
b2-buckets.sh. Pure-stdlib (urllib + json) so no pip install required on
the operator's machine.

Reads env from os.environ:
    SUBCMD     — "ensure" or "show"
    MANIFEST   — path to env manifest YAML
    TFVARS     — path to object-storage.tfvars

Configures per env (under spec.object_storage.<logical>):
    audit              — object_lock_enabled at create, SSE-B2 AES256, CORS,
                         no lifecycle rules (Object Lock owns retention)
    openbao_snapshots  — SSE-B2 AES256, CORS, lifecycle: hidden versions
                         deleted after 90 days
    app_backups        — SSE-B2 AES256, CORS, lifecycle: hidden versions
                         deleted after 365 days

Object Lock default retention is set per-upload by the audit-log-archival
cron via --object-lock-retain-until-date, not bucket-default.

B2 versioning is implicit (always on); lifecycle rules control how long
hidden versions are retained. Without these rules, daily backups would
accumulate version-storage cost unbounded.
"""
from __future__ import annotations

import base64
import json
import os
import re
import secrets
import sys
import urllib.error
import urllib.request

LOGICAL_BUCKETS = ("audit", "openbao_snapshots", "app_backups")
CORS_RULE = {
    "corsRuleName": "dmfDefault",
    "allowedOrigins": ["https://*"],
    "allowedOperations": ["s3_head", "s3_get"],
    "maxAgeSeconds": 3600,
}
SSE_CONFIG = {"mode": "SSE-B2", "algorithm": "AES256"}
LIFECYCLE_RULES = {
    "audit": [],
    "openbao_snapshots": [
        {
            "fileNamePrefix": "",
            "daysFromHidingToDeleting": 90,
            "daysFromUploadingToHiding": None,
        }
    ],
    "app_backups": [
        {
            "fileNamePrefix": "",
            "daysFromHidingToDeleting": 365,
            "daysFromUploadingToHiding": None,
        }
    ],
}


def fail(msg: str) -> "None":
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def read_text(path: str) -> str:
    try:
        with open(path) as f:
            return f.read()
    except OSError as e:
        fail(f"reading {path}: {e}")


def parse_tfvars(text: str) -> "tuple[str, str]":
    m1 = re.search(r'object_storage_access_key_id\s*=\s*"([^"]+)"', text)
    m2 = re.search(r'object_storage_secret_access_key\s*=\s*"([^"]+)"', text)
    if not m1 or not m2:
        fail("could not parse access_key_id / secret_access_key from tfvars")
    return m1.group(1), m2.group(1)


def parse_object_storage_block(manifest_text: str) -> "dict":
    """
    Pure-stdlib YAML parser for the `spec.object_storage:` block.
    Returns: { logical_name: { bucket, endpoint, region } }
    """
    out: "dict[str, dict[str, str]]" = {}
    in_spec = False
    in_os = False
    in_logical: "str | None" = None
    indent_logical: "int | None" = None

    for raw in manifest_text.splitlines():
        line = raw.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        stripped = line.strip()

        if indent == 0 and stripped == "spec:":
            in_spec = True
            in_os = False
            in_logical = None
            continue

        if not in_spec:
            continue

        # Detect spec.object_storage
        if indent == 2 and stripped == "object_storage:":
            in_os = True
            in_logical = None
            continue

        if not in_os:
            # Anything else under spec — skip
            continue

        if indent == 4 and stripped.endswith(":"):
            logical = stripped[:-1]
            if logical not in LOGICAL_BUCKETS:
                fail(f"unexpected logical bucket name in manifest: {logical}")
            in_logical = logical
            indent_logical = 4
            out.setdefault(logical, {})
            continue

        if in_logical and indent == 6 and ":" in stripped:
            k, _, v = stripped.partition(":")
            v = v.strip()
            out[in_logical][k.strip()] = v
            continue

        # Left the object_storage block
        if indent <= 2 and stripped:
            in_os = False
            in_logical = None

    return out


def req(url, method="GET", headers=None, body=None, basic=None):
    r = urllib.request.Request(url, method=method)
    if basic:
        r.add_header(
            "Authorization",
            "Basic " + base64.b64encode(f"{basic[0]}:{basic[1]}".encode()).decode(),
        )
    if headers:
        for k, v in headers.items():
            r.add_header(k, v)
    if body is not None:
        data = json.dumps(body).encode()
        r.add_header("Content-Type", "application/json")
    else:
        data = None
    try:
        return json.loads(urllib.request.urlopen(r, data=data).read())
    except urllib.error.HTTPError as e:
        err = e.read().decode()
        fail(f"HTTP {e.code} from {url}: {err[:400]}")


def authorize(key: str, secret: str) -> "tuple[str, str, str]":
    auth = req(
        "https://api.backblazeb2.com/b2api/v3/b2_authorize_account",
        basic=(key, secret),
    )
    api_url = auth["apiInfo"]["storageApi"]["apiUrl"]
    s3_url = auth["apiInfo"]["storageApi"].get("s3ApiUrl", "")
    return api_url, auth["authorizationToken"], auth["accountId"], s3_url


def list_buckets(api_url, token, account_id):
    return req(
        f"{api_url}/b2api/v3/b2_list_buckets",
        headers={"Authorization": token},
        method="POST",
        body={"accountId": account_id},
    )["buckets"]


def existing_by_name(buckets):
    return {b["bucketName"]: b for b in buckets}


def _is_file_lock_enabled(bucket: "dict") -> bool:
    """Read fileLockConfiguration.value.isFileLockEnabled defensively.

    B2 returns this nested under .value (capability-wrapped) on some
    SDK versions and flat on others; cmd_show treats both shapes, so
    we do too.
    """
    flc = bucket.get("fileLockConfiguration") or {}
    flc_val = flc.get("value") if isinstance(flc, dict) and "value" in flc else flc
    if not isinstance(flc_val, dict):
        return False
    return bool(flc_val.get("isFileLockEnabled"))


def ensure_bucket(api_url, token, account_id, name, is_audit):
    """Create the bucket if missing; return (bucket, created).

    For existing audit buckets, asserts that Object Lock is enabled.
    B2 only accepts fileLockEnabled at create-time (b2_create_bucket);
    b2_update_bucket cannot toggle it later. If an existing audit
    bucket lacks Object Lock, the only remediation is drain+recreate.
    We refuse to silently 'ensure' such a bucket — the operator would
    pass bootstrap and then audit-log immutability would be a lie.
    """
    existing = existing_by_name(list_buckets(api_url, token, account_id))
    if name in existing:
        bucket = existing[name]
        if is_audit and not _is_file_lock_enabled(bucket):
            fail(
                f"audit bucket {name!r} exists but Object Lock is NOT enabled.\n"
                f"  B2 only accepts fileLockEnabled at bucket-create time; it cannot be\n"
                f"  toggled on an existing bucket. The audit bucket carries the\n"
                f"  COMPLIANCE-retention contract for audit logs, so silently proceeding\n"
                f"  with a non-immutable bucket would break that contract.\n"
                f"  Remediation:\n"
                f"    1. Empty the bucket (B2 console or `b2 bucket delete --force`).\n"
                f"    2. Delete the bucket on B2.\n"
                f"    3. Re-run `bin/b2-buckets.sh ensure <env>` — this script will\n"
                f"       recreate it with fileLockEnabled at create-time."
            )
        return bucket, False

    body = {
        "accountId": account_id,
        "bucketName": name,
        "bucketType": "allPrivate",
    }
    if is_audit:
        body["fileLockEnabled"] = True
    created = req(
        f"{api_url}/b2api/v3/b2_create_bucket",
        headers={"Authorization": token},
        method="POST",
        body=body,
    )
    # Defence in depth: if B2 silently dropped fileLockEnabled on
    # create, surface that immediately rather than at audit-verify time.
    if is_audit and not _is_file_lock_enabled(created):
        fail(
            f"created audit bucket {name!r} but B2 did NOT report Object Lock as\n"
            f"  enabled in the response. This may indicate an account-level setting\n"
            f"  blocking File Lock, or a B2 API change. Check the B2 console; if the\n"
            f"  bucket is not Object-Lock-enabled, delete it and investigate before\n"
            f"  re-running."
        )
    return created, True


def configure_bucket(api_url, token, account_id, bucket, logical):
    """Set CORS + SSE + lifecycle on the bucket in one call. Idempotent.

    All three attrs go in a single b2_update_bucket request to avoid B2's
    side-path-clobber behaviour (an out-of-band CORS pre-set would be wiped
    by a later SSE-only update).
    """
    return req(
        f"{api_url}/b2api/v3/b2_update_bucket",
        headers={"Authorization": token},
        method="POST",
        body={
            "accountId": account_id,
            "bucketId": bucket["bucketId"],
            "corsRules": [CORS_RULE],
            "defaultServerSideEncryption": SSE_CONFIG,
            "lifecycleRules": LIFECYCLE_RULES[logical],
        },
    )


def cmd_show(api_url, token, account_id, target_names):
    buckets = list_buckets(api_url, token, account_id)
    by_name = existing_by_name(buckets)
    for name in target_names:
        if name not in by_name:
            print(f"  {name}: MISSING")
            continue
        b = by_name[name]
        sse_raw = b.get("defaultServerSideEncryption") or {}
        sse_val = sse_raw.get("value") if isinstance(sse_raw, dict) and "value" in sse_raw else sse_raw
        flc = b.get("fileLockConfiguration") or {}
        flc_val = flc.get("value") if isinstance(flc, dict) and "value" in flc else flc
        lc = b.get("lifecycleRules") or []
        lc_summary = (
            ", ".join(
                f"{r.get('fileNamePrefix') or '*'}→hide+{r.get('daysFromHidingToDeleting') or '∞'}d"
                for r in lc
            )
            or "none"
        )
        print(f"  {name}:")
        print(f"    rev:        {b['revision']}")
        print(f"    corsRules:  {len(b.get('corsRules') or [])} rule(s)")
        print(f"    SSE:        mode={sse_val.get('mode')} alg={sse_val.get('algorithm')}")
        print(f"    Object Lock: enabled={flc_val.get('isFileLockEnabled')}")
        print(f"    lifecycle:  {lc_summary}")


def cmd_verify(api_url, token, account_id, env_buckets):
    """Read each bucket from B2 and assert it matches the expected contract.

    Contract per logical bucket:
      audit              — Object Lock enabled, NO lifecycle, SSE-B2 AES256, CORS rule present
      openbao_snapshots  — Object Lock disabled, 90d hidden-version lifecycle, SSE-B2 AES256, CORS rule present
      app_backups        — Object Lock disabled, 365d hidden-version lifecycle, SSE-B2 AES256, CORS rule present

    Exits 0 if every bucket matches; exits 1 with a list of every
    deviation found. Read-only; never modifies state.
    """
    buckets = list_buckets(api_url, token, account_id)
    by_name = existing_by_name(buckets)
    issues = []

    print(f"Verifying {len(env_buckets)} buckets at {api_url}\n", file=sys.stderr)

    for logical, coords in env_buckets.items():
        name = coords["bucket"]
        if name not in by_name:
            issues.append(f"{name}: MISSING — run 'b2-buckets.sh ensure <env>' first")
            print(f"  {name}: MISSING", file=sys.stderr)
            continue

        b = by_name[name]
        is_audit = logical == "audit"

        # Object Lock contract
        actual_lock = _is_file_lock_enabled(b)
        if is_audit and not actual_lock:
            issues.append(
                f"{name}: Object Lock DISABLED but the audit-bucket contract "
                "requires it ENABLED. B2 only accepts fileLockEnabled at "
                "create-time; drain + delete + re-ensure required."
            )
        elif not is_audit and actual_lock:
            issues.append(
                f"{name}: Object Lock ENABLED but contract requires it "
                "DISABLED (non-audit bucket). This would block lifecycle "
                "version-cleanup and is unexpected."
            )

        # SSE contract
        sse_raw = b.get("defaultServerSideEncryption") or {}
        sse_val = sse_raw.get("value") if isinstance(sse_raw, dict) and "value" in sse_raw else sse_raw
        if not isinstance(sse_val, dict) \
                or sse_val.get("mode") != SSE_CONFIG["mode"] \
                or sse_val.get("algorithm") != SSE_CONFIG["algorithm"]:
            issues.append(
                f"{name}: SSE mismatch. Expected "
                f"{SSE_CONFIG['mode']}/{SSE_CONFIG['algorithm']}, got "
                f"{sse_val.get('mode')}/{sse_val.get('algorithm')}"
            )

        # CORS contract — at least one rule present
        cors = b.get("corsRules") or []
        if not cors:
            issues.append(f"{name}: no CORS rules; expected at least 1")

        # Lifecycle contract — compare expected vs actual daysFromHidingToDeleting
        actual_lc = b.get("lifecycleRules") or []
        expected_lc = LIFECYCLE_RULES[logical]
        actual_days = sorted(
            r.get("daysFromHidingToDeleting") for r in actual_lc if r
        )
        expected_days = sorted(
            r.get("daysFromHidingToDeleting") for r in expected_lc
        )
        if actual_days != expected_days:
            issues.append(
                f"{name}: lifecycle mismatch. Expected daysFromHidingToDeleting="
                f"{expected_days}, got {actual_days}"
            )

        flags = []
        flags.append(f"lock={'on' if actual_lock else 'off'}")
        flags.append(f"sse={sse_val.get('mode')}/{sse_val.get('algorithm')}" if isinstance(sse_val, dict) else "sse=?")
        flags.append(f"cors={len(cors)}")
        flags.append(f"lifecycle={len(actual_lc)}")
        print(f"  {name}: {' '.join(flags)}", file=sys.stderr)

    print("", file=sys.stderr)
    if issues:
        print("=== CONTRACT VIOLATIONS ===", file=sys.stderr)
        for i in issues:
            print(f"  ✗ {i}", file=sys.stderr)
        sys.exit(1)
    else:
        print("All buckets match contracts.", file=sys.stderr)


def cmd_preflight(api_url, token, account_id):
    """Account capability test: create a throwaway lock-enabled bucket,
    verify B2 actually honored the flag, delete it.

    Run once per Backblaze account (or after changing account-level
    settings) to confirm Object Lock is reliably enableable via the API.
    Catches the silent-drop case where B2 accepts fileLockEnabled=True
    at create-time but the resulting bucket has Object Lock OFF —
    typically because the account-level Object Lock setting is disabled.

    Exits 0 if Object Lock works reliably; exits 1 with remediation
    guidance otherwise.
    """
    test_name = f"dmf-preflight-{secrets.token_hex(4)}"
    print(
        f"Preflight: creating throwaway bucket {test_name!r} with "
        "fileLockEnabled=True\n",
        file=sys.stderr,
    )

    created = req(
        f"{api_url}/b2api/v3/b2_create_bucket",
        headers={"Authorization": token},
        method="POST",
        body={
            "accountId": account_id,
            "bucketName": test_name,
            "bucketType": "allPrivate",
            "fileLockEnabled": True,
        },
    )
    bucket_id = created["bucketId"]
    print(f"  created: bucketId={bucket_id}", file=sys.stderr)

    lock_in_create = False
    lock_on_list = False
    try:
        lock_in_create = _is_file_lock_enabled(created)
        # Re-read via b2_list_buckets — same path as ensure_bucket() uses.
        listed = list_buckets(api_url, token, account_id)
        fresh = next((b for b in listed if b["bucketName"] == test_name), None)
        if not fresh:
            fail("test bucket vanished between create and list — likely B2 transient")
        lock_on_list = _is_file_lock_enabled(fresh)

        print(f"  create response: isFileLockEnabled={lock_in_create}", file=sys.stderr)
        print(f"  list response:   isFileLockEnabled={lock_on_list}", file=sys.stderr)
    finally:
        # Always clean up — even on assertion failure.
        req(
            f"{api_url}/b2api/v3/b2_delete_bucket",
            headers={"Authorization": token},
            method="POST",
            body={"accountId": account_id, "bucketId": bucket_id},
        )
        print(f"  deleted: {test_name!r}", file=sys.stderr)

    print("", file=sys.stderr)
    if lock_in_create and lock_on_list:
        print(
            "PASS: this account creates Object Lock-enabled buckets reliably "
            "via the b2-buckets.py code path.",
            file=sys.stderr,
        )
    else:
        fail(
            "this account did NOT actually enable Object Lock on the test "
            "bucket. Likely cause: Backblaze account-level Object Lock is "
            "off. Enable it in the B2 console under Account Settings → "
            "Object Lock, then re-run this preflight to confirm before "
            "creating audit buckets."
        )


def cmd_ensure(api_url, token, account_id, env_buckets):
    """env_buckets: { logical: { bucket, endpoint, region } }"""
    print(f"Ensuring {len(env_buckets)} buckets at {api_url}\n")
    for logical, coords in env_buckets.items():
        name = coords["bucket"]
        is_audit = logical == "audit"

        bucket, created = ensure_bucket(api_url, token, account_id, name, is_audit)
        status = "CREATED" if created else "exists"
        print(f"  {name}: {status} (rev={bucket['revision']}, audit={is_audit})")

        res = configure_bucket(api_url, token, account_id, bucket, logical)
        cors_n = len(res.get("corsRules") or [])
        sse_raw = res.get("defaultServerSideEncryption") or {}
        sse_val = sse_raw.get("value") if isinstance(sse_raw, dict) and "value" in sse_raw else sse_raw
        lc_n = len(res.get("lifecycleRules") or [])
        print(
            f"    configured: corsRules={cors_n}, "
            f"SSE={sse_val.get('mode')}/{sse_val.get('algorithm')}, "
            f"lifecycle={lc_n} rule(s), "
            f"rev={res['revision']}"
        )
    print("\ndone.")


def main():
    subcmd = os.environ.get("SUBCMD") or fail("SUBCMD env var required")
    tfvars_path = os.environ.get("TFVARS") or fail("TFVARS env var required")
    tfvars_text = read_text(tfvars_path)
    key, secret = parse_tfvars(tfvars_text)
    api_url, token, account_id, s3_url = authorize(key, secret)

    # preflight is account-scoped; it doesn't need (and shouldn't depend on)
    # any per-env manifest. Authorize + run.
    if subcmd == "preflight":
        cmd_preflight(api_url, token, account_id)
        return

    # show / ensure / verify all need the manifest to know which env's
    # buckets to look at.
    manifest_path = os.environ.get("MANIFEST") or fail("MANIFEST env var required")
    manifest_text = read_text(manifest_path)

    env_buckets = parse_object_storage_block(manifest_text)
    missing = [lb for lb in LOGICAL_BUCKETS if lb not in env_buckets or not env_buckets[lb].get("bucket")]
    if missing:
        fail(
            f"manifest spec.object_storage block missing or empty for: {missing}. "
            "Populate the env manifest (~/.dmfdeploy/envs/<env>/manifest.yaml) before running this."
        )

    # Sanity: warn if the key's region doesn't match the manifest's endpoint
    sample_endpoint = next(iter(env_buckets.values()))["endpoint"]
    if s3_url and not sample_endpoint.startswith(s3_url):
        print(
            f"  WARNING: key's s3ApiUrl={s3_url} but manifest endpoint={sample_endpoint}",
            file=sys.stderr,
        )

    target_names = [c["bucket"] for c in env_buckets.values()]

    if subcmd == "show":
        cmd_show(api_url, token, account_id, target_names)
    elif subcmd == "ensure":
        cmd_ensure(api_url, token, account_id, env_buckets)
    elif subcmd == "verify":
        cmd_verify(api_url, token, account_id, env_buckets)
    else:
        fail(f"unknown subcmd: {subcmd}")


if __name__ == "__main__":
    main()
