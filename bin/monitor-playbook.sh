#!/usr/bin/env bash
# monitor-playbook.sh — stream filtered ansible-playbook output from a log file.
#
# Usage:
#   bin/monitor-playbook.sh <log-file>
#
# Filters for PLAY/TASK/fatal/FAILED/PLAY RECAP lines so the operator can
# watch progress without wading through the full log.
#
# Typically invoked with the log path printed by bin/run-playbook.sh.

set -euo pipefail

LOG="${1:?usage: monitor-playbook.sh <log-file>}"
[[ -f "$LOG" ]] || { echo "no such file: $LOG" >&2; exit 1; }

exec tail -F "$LOG" | grep -E --line-buffered \
  "^(TASK |PLAY |fatal:|failed=|FAILED - RETRYING|PLAY RECAP|Blueprint invalid|Entry invalid)"
