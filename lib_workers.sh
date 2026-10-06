#!/usr/bin/env bash
# lib_workers.sh: MOCK worker library for the public demo.
#
# In the real internal tool, this is a large library that, per database engine, starts a throwaway
# Docker container, imports a customer database dump, and runs the vendor's db_upgrade_client against
# it. That engine layer is tied to real customer data and internal infrastructure, so it is NOT part
# of this public showcase. This stub implements the SAME interface the scheduler calls, but simulates
# the work: no Docker, no network, no real data. It lets the scheduler, the RAM budgeting, the
# concurrency control, and the auto-retry cycle run end to end so the design can be demonstrated.
#
# Interface the scheduler (batch_upgrade.sh) expects:
#   ensure_es8
#   import_mysql_dump <dump> <target> <alter>
#   import_pg_dump    <dump> <target> <alter> <bool>
#   import_sqlserver_bak <dump> <target> <logical>
#   import_oracle_dmp <dump> <modl> <remap> <surgery>
#   upgrade_app <folder_id> <schema> <sub_choice> <db_type>
# An import returns non-zero to signal IMPORT FAILED. upgrade_app writes an upgrade.log the scheduler
# reads to classify PASS/FAIL, at <folder_id>-bundle/app/tools/db-upgrade-client/logs/upgrade.log.

# Per-run marker dir so "fail once then pass" resets each run (keyed on the run timestamp).
_mock_state_dir() { local d="${TMPDIR:-/tmp}/db-upgrade-showcase-${BATCH_RUN_TS:-adhoc}"; mkdir -p "$d"; printf '%s' "$d"; }

ensure_es8() {
  echo "[mock] search/index service is ready (simulated)"
  return 0
}

# Real password lookup for compressed dumps (see lib_dumps.sh); only the decompression is simulated.
source "$(dirname "${BASH_SOURCE[0]}")/lib_dumps.sh"

_mock_import() {   # <engine> <name> [dump]
  local engine="$1" name="$2" dump="${3:-}"
  if [[ "$dump" == *.7z ]]; then
    local pv; pv="$(sevenz_pw_var "$dump")"
    if [[ -n "$pv" ]]; then
      echo "  [mock import] $engine: '$dump' is a 7z archive; password from \$$pv (decompression simulated)"
    else
      echo "  [mock import] $engine: '$dump' is a 7z archive but no password variable is set; a real import would fail fast here"
    fi
  fi
  echo "  [mock import] $engine: importing '$name' (simulated)"
  sleep 1
  return 0
}
import_mysql_dump()     { _mock_import mysql "${2:-$1}" "$1"; }
import_pg_dump()        { _mock_import postgres "${2:-$1}" "$1"; }
import_sqlserver_bak()  { _mock_import sqlserver "${2:-$1}" "$1"; }
import_oracle_dmp()     { _mock_import oracle "${2:-$1}" "$1"; }

# upgrade_app <folder_id> <schema> <sub_choice> <db_type>
# Writes the bundle log the scheduler parses. For the id "customer-fail-once" it fails on the first
# attempt and passes on the next, so a run demonstrates the auto-retry flipping a not-green DB to PASS.
upgrade_app() {
  local folder_id="$1" schema="$2" slot="$3" db_type="$4"
  local logdir="${folder_id}-bundle/app/tools/db-upgrade-client/logs"
  mkdir -p "$logdir"
  local log="$logdir/upgrade.log"

  local result="success"
  if [[ "$folder_id" == "customer-fail-once" ]]; then
    local marker; marker="$(_mock_state_dir)/${folder_id}.attempted"
    if [[ ! -e "$marker" ]]; then
      : > "$marker"
      result="failure"
      echo "  [mock upgrade] $folder_id ($db_type): simulating a transient failure on first attempt"
    else
      echo "  [mock upgrade] $folder_id ($db_type): retry attempt, succeeding now"
    fi
  fi

  # simulate work; vary the time a little so the concurrency view looks realistic
  sleep "$(( (RANDOM % 3) + 1 ))"

  {
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO  Starting upgrade (schema=$schema, slot=$slot, engine=$db_type)"
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO  Running upgrade process"
    if [[ "$result" == success ]]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') INFO  Major upgrade finished with result success"
    else
      echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR Major upgrade finished with result failure"
    fi
  } > "$log"
  return 0
}
