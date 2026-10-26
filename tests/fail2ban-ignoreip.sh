#!/usr/bin/env bash
# fail2ban-ignoreip.sh — verify the init-wizard fail2ban_ignoreip helper never
# passes a /0 range (any spelling) into harden_fail2ban_ignoreip, and keeps
# the operator's real SSH source CIDRs.
# Runs the helper's own definition, cut from bin/init-wizard.sh, which cannot
# be sourced (it runs main on load).

set -euo pipefail

echo "=== fail2ban-ignoreip test ==="

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIZARD="${REPO_DIR}/bin/init-wizard.sh"

helper="$(awk '/^fail2ban_ignoreip\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$WIZARD")"
[ -n "$helper" ] || { echo "FAIL: fail2ban_ignoreip not found in ${WIZARD}" >&2; exit 1; }
eval "$helper"

FAILED=0
LOOPBACK="127.0.0.1/8 ::1"

# check <description> <expected output> <args>...
check() {
  local what="$1" want="$2" got
  shift 2
  got="$(fail2ban_ignoreip "$@")"
  if [ "$got" = "$want" ]; then
    echo "  PASS: ${what}"
  else
    echo "  FAIL: ${what}: want [${want}], got [${got}]" >&2
    FAILED=1
  fi
}

echo "Every spelling of a /0 range is dropped..."
check "0.0.0.0/0"            "$LOOPBACK" "0.0.0.0/0" ""
check "::/0"                 "$LOOPBACK" "" "::/0"
check "0:0:0:0:0:0:0:0/0"    "$LOOPBACK" "" "0:0:0:0:0:0:0:0/0"
check "0000::/0"             "$LOOPBACK" "" "0000::/0"
check "::/00"                "$LOOPBACK" "" "::/00"
check "0.0.0.0/000"          "$LOOPBACK" "0.0.0.0/000" ""
check "host address with /0" "$LOOPBACK" "198.51.100.7/0" "2001:db8::1/0"
check "surrounding whitespace" "$LOOPBACK" "  0.0.0.0/0	" "
::/0 "

echo "A prefix that is not a decimal number is dropped..."
check "empty prefix"   "$LOOPBACK" "198.51.100.0/" ""
check "hex prefix"     "$LOOPBACK" "" "::/0x0"
check "signed prefix"  "$LOOPBACK" "0.0.0.0/-0" ""

echo "Real SSH source ranges are kept..."
check "IPv4 /32"       "${LOOPBACK} 203.0.113.10/32" "203.0.113.10/32" ""
check "IPv4 /30 (zero in prefix)" "${LOOPBACK} 198.51.100.0/30" "198.51.100.0/30" ""
check "IPv6 /48"       "${LOOPBACK} 2001:db8:1::/48" "" "2001:db8:1::/48"
check "bare address"   "${LOOPBACK} 198.51.100.7" "198.51.100.7" ""
check "mixed list keeps only the real ranges" \
  "${LOOPBACK} 203.0.113.10/32 2001:db8::/32" \
  "0.0.0.0/0,203.0.113.10/32" "0:0:0:0:0:0:0:0/0,2001:db8::/32"
check "no ranges"      "$LOOPBACK" "" ""

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED" >&2
  exit 1
fi
echo "OK"
