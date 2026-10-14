#!/bin/bash
#
# batch_upgrade.sh — headless, RAM-budgeted batch scheduler for Database Upgrades.
#
# Author: Brian Wulbern
#
# WHAT THIS DOES
#   Reads jobs.manifest, turns each active row into an import-then-upgrade job, and
#   runs as many jobs concurrently as the RAM budget and the concurrency caps allow.
#   Every job imports a fresh DB and then upgrades it in the SAME subprocess (never an
#   upgrade on a pre-existing DB). Elasticsearch runs once as a shared remote ES8.
#
#   This file DOES NOT reimplement any engine logic. It sources the verified workers
#   from parallel_upgrades_es8_with_plugins.sh (source-safe) and lib_diagnostics.sh.
#
# ---------------------------------------------------------------------------------
# RAM MODEL (all values MB, all overridable via env)
# ---------------------------------------------------------------------------------
#   total   = MemTotal from /proc/meminfo (kB -> MB)
#   RESERVE = BATCH_RAM_RESERVE_MB           (default 6000)  headroom for the OS/host
#   BUDGET  = BATCH_RAM_BUDGET_MB            (default total - RESERVE)
#
#   Per-JOB cost      = heap + BATCH_JOB_OVERHEAD_MB (default 1500)   [upgrade JVM + tomcat noise]
#   Per-ENGINE reservation (charged ONCE when an engine is first activated, then held
#   for the rest of the run — the DB container stays up serving every job of that engine):
#       es8       = BATCH_ES8_RESERVE_MB        (default 2500)  reserved at STARTUP, always
#       mysql     = BATCH_MYSQL_RESERVE_MB      (default 3000)
#       postgres  = BATCH_POSTGRES_RESERVE_MB   (default 3000)
#       sqlserver = BATCH_SQLSERVER_RESERVE_MB  (default 3000)
#       oracle    = BATCH_ORACLE_RESERVE_MB     (default 4000)  (Oracle Free is a heavy 12GB box)
#
#   ADMIT a job only if:
#       committed_job_cost + engine_reserved_total + job_cost
#           + (this engine's reservation, if that engine is not yet active) <= BUDGET
#
# ---------------------------------------------------------------------------------
# CONCURRENCY CAPS (overridable via env)
# ---------------------------------------------------------------------------------
#   Global : BATCH_MAX_CONCURRENCY      (default 3)
#   mysql  : BATCH_MYSQL_MAX            (default 2)
#   postgres: BATCH_POSTGRES_MAX        (default 2)
#   sqlserver: BATCH_SQLSERVER_MAX      (default 2)
#   oracle : BATCH_ORACLE_MAX           (default 1, HARD)  — Oracle jobs never overlap ANY
#            other Oracle job: they share the single APPDB user in one 12GB container,
#            and each is imported with FORCE_ORACLE_WIPE=1 (fresh). Cap is clamped to 1
#            regardless of any override.
#
# PORT ISOLATION
#   Each concurrently-running job gets a globally-unique "slot" S from a pool of
#   BATCH_MAX_CONCURRENCY slots. S is passed as sub_choice to upgrade_app
#   (global CHOICE stays 0), so PORT_OFFSET = S*100 is unique among concurrent jobs.
#   Slots are recycled when a job finishes (they only need to be unique among the
#   jobs running at the same time).
#
# ROBUSTNESS
#   set -uo pipefail (NOT -e): failures are handled explicitly so one bad job never
#   aborts the batch. No date/$RANDOM for anything correctness-bearing — the run
#   timestamp is taken from BATCH_RUN_TS (env or first non-flag arg). INT/TERM stop
#   admitting new jobs, drain the running ones, and print a partial summary.
# ---------------------------------------------------------------------------------

set -uo pipefail

# ------------------------------------------------------------------ arg / env parse
DRY_RUN=0
ARG_TS=""
ARG_MANIFEST=""
for _a in "$@"; do
  case "$_a" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      echo "Usage: BATCH_RUN_TS=<ts> $0 [--dry-run] [<run_ts>] [<manifest>]"
      echo "  <run_ts>   : a YYYYMMDD-HHMMSS id (or set BATCH_RUN_TS)."
      echo "  <manifest> : a *.manifest file (or a readable file); or set BATCH_MANIFEST."
      exit 0 ;;
    -*)
      echo "Unknown option: $_a" >&2; exit 2 ;;
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ARG_TS="$_a" ;;
    *.manifest) ARG_MANIFEST="$_a" ;;
    *) # backward-compat: a readable file is a manifest, else a run_ts
       if [[ -r "$_a" ]]; then ARG_MANIFEST="$_a"; else ARG_TS="$_a"; fi ;;
  esac
done

# The shell cannot call date for a correctness-bearing id; the caller supplies it.
BATCH_RUN_TS="${BATCH_RUN_TS:-$ARG_TS}"
if [[ -z "$BATCH_RUN_TS" ]]; then
  echo "ERROR: no run timestamp. Pass BATCH_RUN_TS=<ts> (env) or a positional <run_ts> arg." >&2
  echo "       e.g.  BATCH_RUN_TS=\$(date +%Y%m%d-%H%M%S) $0" >&2
  exit 2
fi

# Resolve the directory this script lives in (dumps + tomcat archives live alongside it).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${BATCH_MANIFEST:-${ARG_MANIFEST:-$SCRIPT_DIR/jobs.manifest}}"
WORKER_LIB="$SCRIPT_DIR/lib_workers.sh"
DIAG_LIB="$SCRIPT_DIR/lib_diagnostics.sh"
RUN_DIR="$SCRIPT_DIR/batch-runs/$BATCH_RUN_TS"

# Toolkit version plus the commit it ran from, so every run records which logic produced its results.
source "$SCRIPT_DIR/lib_version.sh"
TOOLKIT_ID="$(toolkit_id)"

# ------------------------------------------------------------------ RAM / caps config
_memtotal_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
[[ -z "$_memtotal_kb" ]] && _memtotal_kb=0
TOTAL_RAM_MB=$(( _memtotal_kb / 1024 ))

RESERVE_MB="${BATCH_RAM_RESERVE_MB:-6000}"
JOB_OVERHEAD_MB="${BATCH_JOB_OVERHEAD_MB:-1500}"
BUDGET_MB="${BATCH_RAM_BUDGET_MB:-$(( TOTAL_RAM_MB - RESERVE_MB ))}"

ES8_RES="${BATCH_ES8_RESERVE_MB:-2500}"
declare -A ENGINE_RES=(
  [mysql]="${BATCH_MYSQL_RESERVE_MB:-3000}"
  [postgres]="${BATCH_POSTGRES_RESERVE_MB:-3000}"
  [sqlserver]="${BATCH_SQLSERVER_RESERVE_MB:-3000}"
  [oracle]="${BATCH_ORACLE_RESERVE_MB:-4000}"
)

MAX_CONC="${BATCH_MAX_CONCURRENCY:-3}"
declare -A ENGINE_MAX=(
  [mysql]="${BATCH_MYSQL_MAX:-2}"
  [postgres]="${BATCH_POSTGRES_MAX:-2}"
  [sqlserver]="${BATCH_SQLSERVER_MAX:-2}"
  [oracle]="${BATCH_ORACLE_MAX:-1}"
)
# Oracle cap is HARD 1 no matter what was passed.
ENGINE_MAX[oracle]=1

POLL_SECS="${BATCH_POLL_SECS:-5}"

# BATCH_RETRIES (default 1): after the main pass, re-run each not-PASS DB (UNKNOWN/FAIL/DID-NOT-START)
# serially, up to this many extra passes, until it passes or the passes run out. A retry that passes
# flips the job to PASS in the summary. Set BATCH_RETRIES=0 to disable (single pass, legacy behavior).
RETRIES="${BATCH_RETRIES:-1}"

# BATCH_BUNDLE_VERSION -> the upgrade-bundle version (e.g. 2026.q3.2). Auto-detected from an
# app-bundle-<ver> archive in SCRIPT_DIR when unset. Drives the version-to-DB-set mapping.
detect_bundle_version() {
  local f
  [[ -n "${BATCH_BUNDLE_VERSION:-}" ]] && { printf '%s' "$BATCH_BUNDLE_VERSION"; return; }
  for f in "$SCRIPT_DIR"/*app-bundle-*; do
    [[ -e "$f" ]] || continue
    if [[ "$(basename "$f")" =~ ([0-9]{4}\.q[0-9]+\.[0-9]+) ]]; then
      printf '%s' "${BASH_REMATCH[1]}"; return
    fi
  done
}

# jira_pass_hook <modl> <archived_upgrade_log> ; never fatal to the batch.
# The internal tool reconciles each PASS to an issue tracker here. That integration is internal and
# removed for this public showcase, so this is a no-op that keeps the call site intact.
jira_pass_hook() {
  return 0
}

# ------------------------------------------------------------------ HD hygiene (opt-out)
#   BATCH_HYGIENE=1 (default): on each PASS, drop the just-validated DB from its container to
#   reclaim its import layer (the main source of ~/.local/share/docker ballooning), and prune
#   dangling docker images at end of run. Set BATCH_HYGIENE=0 to keep the upgraded DBs.
HYGIENE_ENABLED="${BATCH_HYGIENE:-1}"

# batch_hygiene_drop_db <engine> <target_db> — reclaim a PASSED DB's data files. Non-fatal.
# Oracle is skipped (APPDB is wiped per run). Throwaway creds match the CLAUDE.md table.
batch_hygiene_drop_db() {
  local engine="$1" target="$2"
  [[ "$HYGIENE_ENABLED" == "1" && -n "$target" ]] || return 0
  case "$engine" in
    mysql)
      docker exec -i mysql_db mysql -uroot ${MYSQL_ROOT_PASSWORD:+-p$MYSQL_ROOT_PASSWORD} \
        -e "DROP DATABASE IF EXISTS \`$target\`;" >/dev/null 2>&1 \
        && echo "  [hygiene] dropped mysql db '$target'" || true ;;
    postgres)
      docker exec -i postgresql_db psql -U root -d postgres \
        -c "DROP DATABASE IF EXISTS \"$target\" WITH (FORCE);" >/dev/null 2>&1 \
        && echo "  [hygiene] dropped postgres db '$target'" || true ;;
    sqlserver)
      # SA password of the throwaway local SQL Server container, whatever it was created with.
      # Supplied via env so no credential lives in the repo (MSSQL_SA_PASSWORD).
      docker exec -i sqlserver_db bash -c \
        "/opt/mssql-tools*/bin/sqlcmd -S localhost -U sa -P '${MSSQL_SA_PASSWORD:-}' -C -Q \"IF DB_ID('$target') IS NOT NULL BEGIN ALTER DATABASE [$target] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$target]; END\"" >/dev/null 2>&1 \
        && echo "  [hygiene] dropped sqlserver db '$target'" || true ;;
    oracle) : ;;  # APPDB is recreated per run (FORCE_ORACLE_WIPE)
  esac
}

# ------------------------------------------------------------------ helpers
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# ------------------------------------------------------------------ resolve_extra_args
# resolve_extra_args <engine> <modl>
#
# SINGLE SOURCE OF TRUTH for per-customer worker extras. Sets these globals for the
# caller (values copied VERBATIM from parallel_upgrades_es8_with_plugins.sh):
#     RES_ALTER    alteration_sql   (mysql/postgres)
#     RES_BOOL     apply_boolean_fixes true|false (postgres 4th arg)
#     RES_LOGICAL  logical_name     (sqlserver 3rd arg; empty => auto-detect)
#     RES_REMAP    remap_arg        (oracle 3rd arg)
#     RES_SURGERY  surgery_sql      (oracle 4th arg)
# Everything not listed resolves to empty extras (RES_BOOL defaults to false).
resolve_extra_args() {
  # Per-database "extras" the workers apply during import: pre-import ALTER/DELETE SQL, a boolean
  # column-fix flag, an explicit backup logical name, an engine schema/tablespace remap, and any
  # post-import surgery SQL. In the real internal tool this is a big case statement keyed on the
  # database id, holding customer-specific fixes (schema remaps, targeted data repairs). That glue
  # is customer data, so it is not part of this public showcase. Here it returns generic defaults,
  # with one illustrative fake example to show the shape. Everything downstream reads these vars.
  local engine="$1" modl="$2"
  RES_ALTER=""
  RES_BOOL="false"
  RES_LOGICAL=""
  RES_REMAP=""
  RES_SURGERY=""

  case "${engine}/${modl,,}" in
    postgres/customer-b)
      # Illustrative example only (fake): a pre-import column fix + boolean normalization.
      RES_ALTER="ALTER TABLE public.sample_table ALTER COLUMN sample_id SET NOT NULL;"
      RES_BOOL="true"
      ;;
    oracle/customer-d)
      # Illustrative example only (fake): an Oracle schema remap for the import.
      RES_REMAP="REMAP_SCHEMA=SOURCE_SCHEMA:APPDB REMAP_TABLESPACE=USERS:USERS"
      ;;
    *)
      : # no extras
      ;;
  esac
  return 0
}

# ------------------------------------------------------------------ manifest parse
# Fills the parallel arrays J_ENGINE / J_DUMP / J_TARGET / J_MODL / J_HEAP.
# Columns: engine | dump | target_db | modl | offset | heap | es_mode | flags
# offset, es_mode and flags are NOTES ONLY (offset -> we assign our own slot; es_mode
# -> always remote; flags -> non-executable, real behavior comes from resolve_extra_args).
declare -a J_ENGINE J_DUMP J_TARGET J_MODL J_HEAP
parse_manifest() {
  local line engine dump target modl offset heap
  [[ -r "$MANIFEST" ]] || { echo "ERROR: manifest not readable: $MANIFEST" >&2; exit 2; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue    # comment / inactive job
    IFS='|' read -r engine dump target modl offset heap _rest <<< "$line"
    engine="$(trim "$engine")"
    dump="$(trim "$dump")"
    target="$(trim "$target")"
    modl="$(trim "$modl")"
    heap="$(trim "$heap")"
    case "$engine" in
      mysql|postgres|sqlserver|oracle) ;;
      *) echo "WARN: skipping row with unknown engine '$engine': $line" >&2; continue ;;
    esac
    [[ "$heap" =~ ^[0-9]+$ ]] || heap=4096
    J_ENGINE+=("$engine")
    J_DUMP+=("$dump")
    J_TARGET+=("$target")
    J_MODL+=("$modl")
    J_HEAP+=("$heap")
  done < "$MANIFEST"
}

job_cost() { echo $(( $1 + JOB_OVERHEAD_MB )); }   # $1 = heap

# bundle_dir_for <engine> <modl> <target_db>  -> the ./<name>-bundle basename
# Matches upgrade_app: BUNDLE_DIR="./${folder_id}-bundle", where folder_id is
# arg1 of upgrade_app. mysql/postgres/oracle pass modl; sqlserver passes target.
bundle_dir_for() {
  local engine="$1" modl="$2" target="$3"
  case "$engine" in
    sqlserver) echo "${target}-bundle" ;;
    *)         echo "${modl}-bundle" ;;
  esac
}

# ==================================================================================
# DRY RUN — plan only; touches no Docker, starts no jobs.
# ==================================================================================
print_budget_header() {
  echo "================================================================"
  echo " Database Upgrade — Batch Plan"
  echo "================================================================"
  echo " run timestamp     : $BATCH_RUN_TS"
  echo " toolkit           : $TOOLKIT_ID"
  echo " manifest          : $MANIFEST"
  echo " total host RAM    : ${TOTAL_RAM_MB} MB"
  echo " reserve (host)    : ${RESERVE_MB} MB"
  echo " BUDGET            : ${BUDGET_MB} MB"
  echo " per-job overhead  : ${JOB_OVERHEAD_MB} MB (added to each job's heap)"
  echo " engine reservations (held for the whole run once activated):"
  echo "     es8=${ES8_RES} (reserved at startup, always)  mysql=${ENGINE_RES[mysql]}  postgres=${ENGINE_RES[postgres]}  sqlserver=${ENGINE_RES[sqlserver]}  oracle=${ENGINE_RES[oracle]}"
  echo " concurrency caps  : global=${MAX_CONC}  mysql=${ENGINE_MAX[mysql]}  postgres=${ENGINE_MAX[postgres]}  sqlserver=${ENGINE_MAX[sqlserver]}  oracle=${ENGINE_MAX[oracle]} (HARD)"
  echo "----------------------------------------------------------------"
}

dry_run() {
  print_budget_header
  local n=${#J_ENGINE[@]}
  echo " active jobs        : $n"
  echo ""
  echo "Per-job plan (cost = heap + overhead):"
  printf "  %-14s %-10s %6s %6s %6s   %s\n" "MODL" "ENGINE" "HEAP" "COST" "SLOT?" "EXTRAS"
  local i extras
  for (( i=0; i<n; i++ )); do
    resolve_extra_args "${J_ENGINE[$i]}" "${J_MODL[$i]}"
    extras=""
    [[ -n "$RES_ALTER" ]]   && extras+="alteration_sql "
    [[ "$RES_BOOL" == "true" ]] && extras+="boolean_fixes=true "
    [[ "${J_ENGINE[$i]}" == sqlserver ]] && { [[ -z "$RES_LOGICAL" ]] && extras+="logical=auto-detect " || extras+="logical=$RES_LOGICAL "; }
    [[ -n "$RES_REMAP" ]]   && extras+="remap=[$RES_REMAP] "
    [[ -n "$RES_SURGERY" ]] && extras+="surgery_sql "
    [[ -z "$extras" ]] && extras="-"
    printf "  %-14s %-10s %6s %6s %6s   %s\n" \
      "${J_MODL[$i]}" "${J_ENGINE[$i]}" "${J_HEAP[$i]}" "$(job_cost "${J_HEAP[$i]}")" "(assigned)" "$extras"
  done
  echo ""
  echo "Admission waves (greedy; a wave = jobs that would run concurrently, then all"
  echo "assumed complete before the next wave. Engine reservations persist across waves):"
  echo ""

  # --- simulate ---
  local -a pending=()
  for (( i=0; i<n; i++ )); do pending+=("$i"); done

  local -A sim_active=()            # engine -> 1 once its reservation is charged
  local sim_engine_reserved=$ES8_RES   # es8 reserved from startup
  local wave=0

  while [[ ${#pending[@]} -gt 0 ]]; do
    wave=$(( wave + 1 ))
    local sim_committed=0
    local sim_total_running=0
    local sim_slot=0
    local -A sim_engine_running=()
    local -a next_pending=()
    local -a wave_lines=()
    local wave_new_engines=""
    local idx eng heap cost extra_engine

    for idx in "${pending[@]}"; do
      eng="${J_ENGINE[$idx]}"
      heap="${J_HEAP[$idx]}"
      cost=$(job_cost "$heap")

      # caps
      local cap="${ENGINE_MAX[$eng]}"
      local eng_run="${sim_engine_running[$eng]:-0}"
      if [[ $sim_total_running -ge $MAX_CONC ]]; then next_pending+=("$idx"); continue; fi
      if [[ $eng_run -ge $cap ]]; then next_pending+=("$idx"); continue; fi
      if [[ $sim_slot -ge $MAX_CONC ]]; then next_pending+=("$idx"); continue; fi

      # budget
      extra_engine=0
      [[ -z "${sim_active[$eng]:-}" ]] && extra_engine="${ENGINE_RES[$eng]}"
      if (( sim_committed + sim_engine_reserved + cost + extra_engine > BUDGET_MB )); then
        next_pending+=("$idx"); continue
      fi

      # admit (in this simulated wave)
      sim_committed=$(( sim_committed + cost ))
      sim_total_running=$(( sim_total_running + 1 ))
      sim_engine_running[$eng]=$(( eng_run + 1 ))
      sim_slot=$(( sim_slot + 1 ))
      if [[ -z "${sim_active[$eng]:-}" ]]; then
        sim_active[$eng]=1
        sim_engine_reserved=$(( sim_engine_reserved + ENGINE_RES[$eng] ))
        wave_new_engines+="$eng(+${ENGINE_RES[$eng]}) "
      fi
      wave_lines+=("$(printf "    slot %-2s  %-14s %-10s cost=%-6s" "$sim_slot" "${J_MODL[$idx]}" "$eng" "$cost")")
    done

    if [[ ${#wave_lines[@]} -eq 0 ]]; then
      echo "  !! Cannot schedule the remaining ${#pending[@]} job(s) under the current"
      echo "     budget/caps (largest remaining exceeds BUDGET even alone). Remaining:"
      for idx in "${pending[@]}"; do
        echo "        - ${J_MODL[$idx]} (${J_ENGINE[$idx]}, cost=$(job_cost "${J_HEAP[$idx]}"))"
      done
      break
    fi

    echo "  --- Wave $wave  (running RAM = committed ${sim_committed} + reserved ${sim_engine_reserved} = $(( sim_committed + sim_engine_reserved )) / ${BUDGET_MB} MB) ---"
    [[ -n "$wave_new_engines" ]] && echo "      engines activated this wave: $wave_new_engines"
    local l
    for l in "${wave_lines[@]}"; do echo "$l"; done
    echo ""

    pending=("${next_pending[@]}")
  done

  echo "================================================================"
  echo "DRY RUN complete — nothing was started. Total active jobs: $n"
  echo "================================================================"
}

# ==================================================================================
# REAL RUN
# ==================================================================================

# run_job — executed inside a backgrounded subshell (one per job). stdin is fed a
# stream of 'y' answers so the workers' residual read prompts (RUN_NOW, "Press Enter",
# the run_oracle nuke prompt) are satisfied non-interactively. All output is redirected
# by the caller to the job's console.log. Returns 90 if the IMPORT worker fails (=>
# DID-NOT-START), otherwise the upgrade step's own return code.
#   args: engine dump target modl heap slot alter bool logical remap surgery
run_job() {
  # The sourced upgrade library was written for the interactive shell (no `set -u`) and
  # references optional vars (e.g. JDK21_HOME) unguarded. Job bodies therefore run with
  # nounset OFF; the scheduler keeps `set -u` for its own accounting. This runs in the
  # backgrounded `{ …; } &` subshell, so the option change is isolated to this job.
  set +u

  local engine="$1" dump="$2" target="$3" modl="$4" heap="$5" slot="$6"
  local alter="$7" bool="$8" logical="$9" remap="${10}" surgery="${11}"

  cd "$SCRIPT_DIR" || { echo "run_job: cannot cd to $SCRIPT_DIR"; return 92; }

  # Shared remote ES for every job; global CHOICE=0 so PORT_OFFSET = slot*100.
  export ES_MODE="remote"
  # Headless: skip the library's residual read prompts. Feeding 'y' on stdin is unreliable
  # because `docker exec -i` steps inside the workers drain the pipe before the prompt.
  export BATCH_NONINTERACTIVE=1
  CHOICE=0

  echo "=== batch job start: modl=$modl engine=$engine target=$target slot=$slot heap=${heap}m ==="

  case "$engine" in
    mysql)
      import_mysql_dump "$dump" "$target" "$alter" || { echo "IMPORT FAILED (mysql/$modl)"; return 90; }
      upgrade_app "$modl" "$target" "$slot" mysql
      ;;
    postgres)
      import_pg_dump "$dump" "$target" "$alter" "$bool" || { echo "IMPORT FAILED (postgres/$modl)"; return 90; }
      upgrade_app "$modl" "$target" "$slot" postgres
      ;;
    sqlserver)
      import_sqlserver_bak "$dump" "$target" "$logical" || { echo "IMPORT FAILED (sqlserver/$modl)"; return 90; }
      upgrade_app "$target" "$target" "$slot" sqlserver
      ;;
    oracle)
      export FORCE_ORACLE_WIPE=1     # fresh import each; oracle-cap=1 makes wipe-between safe
      import_oracle_dmp "$dump" "$modl" "$remap" "$surgery" || { echo "IMPORT FAILED (oracle/$modl)"; return 90; }
      upgrade_app "$modl" "APPDB" "$slot" oracle
      ;;
    *)
      echo "run_job: unknown engine $engine"; return 93 ;;
  esac
}

# state for the scheduler
# NOTE: each MUST be initialized with =() — under bash 5.3 `set -u`, ${#assoc[@]} on an
# associative array declared without an initializer throws "unbound variable" when empty.
declare -A RUN_MODL=() RUN_ENGINE=() RUN_TARGET=() RUN_COST=() RUN_SLOT=() RUN_START=() RUN_LOG=()
declare -a FREE_SLOTS=()
declare -A ACTIVE_ENGINE=()
ENGINE_RESERVED_TOTAL=$ES8_RES     # es8 reserved from startup
COMMITTED_JOBS=0
declare -a SUMMARY_ROWS=()
PASS_N=0; FAIL_N=0; NOSTART_N=0
STOP=0

# Result store, keyed by modl, so a retry pass OVERWRITES a job's result (latest attempt wins)
# rather than appending a duplicate row. write_summary rebuilds SUMMARY_ROWS + tallies from this.
declare -A RESULT_OF=() ENGINE_OF=() NOTE_OF=()
declare -a RESULT_ORDER=()
declare -a pending=()          # scheduler queue (manifest indices); global so retry passes can refill it
record_result() {              # <modl> <engine> <result> <note>
  [[ -z "${RESULT_OF[$1]:-}" ]] && RESULT_ORDER+=("$1")
  RESULT_OF[$1]="$3"; ENGINE_OF[$1]="$2"; NOTE_OF[$1]="$4"
}

on_signal() {
  STOP=1
  echo ""
  echo "[batch] signal received — no new jobs will be admitted; draining running jobs..."
}
trap on_signal INT TERM

# YES_BLOB: enough 'y' lines to answer every residual read prompt in a job.
YES_BLOB="$(printf 'y\n%.0s' $(seq 1 200))"

# post_process_job <pid> <rc>  — archive logs, classify, keep/drop bundle, record row.
post_process_job() {
  local pid="$1" rc="$2"
  local modl="${RUN_MODL[$pid]}" engine="${RUN_ENGINE[$pid]}" target="${RUN_TARGET[$pid]}"
  local start="${RUN_START[$pid]}" console="${RUN_LOG[$pid]}"
  local elapsed=$(( SECONDS - start ))
  local jobdir="$RUN_DIR/$modl"
  mkdir -p "$jobdir"

  local bundle bundle_path tool_dir up_log diag_report gen_report result note kept
  bundle="$(bundle_dir_for "$engine" "$modl" "$target")"
  bundle_path="$SCRIPT_DIR/$bundle"

  # HARDENING (#2): kill any upgrade JVM still bound to this job's bundle. On a mid-upgrade failure
  # (e.g. an OOM-killed DB container) the DBUpgraderLauncher can outlive its client wrapper and spin
  # for hours holding GBs of RAM (a large database, an earlier full run). The job's wrapper pid has already exited by the time
  # we reap, so anything still referencing this bundle is orphaned — safe to kill. Opt-out: BATCH_REAP_JVM=0.
  if [[ "${BATCH_REAP_JVM:-1}" == "1" ]]; then
    pkill -9 -f "$bundle_path/app" 2>/dev/null && echo "  [reap-jvm] killed lingering upgrade JVM for $modl" || true
  fi

  tool_dir="$bundle_path/app/tools/db-upgrade-client"
  up_log="$tool_dir/logs/upgrade.log"
  diag_report="$tool_dir/reports/upgrade_report_diagnostics.txt"
  gen_report="$tool_dir/reports/upgrade_report.info"

  # Result: exit 90 means the import failed and the upgrade never ran.
  if [[ "$rc" == "90" ]]; then
    result="DID-NOT-START"
  else
    result="$(extract_upgrade_result "$up_log")"
  fi

  # Archive artifacts into batch-runs/<ts>/<modl>/
  [[ -r "$up_log" ]]      && cp -f "$up_log"      "$jobdir/upgrade.log" 2>/dev/null
  [[ -r "$diag_report" ]] && cp -f "$diag_report" "$jobdir/upgrade_report_diagnostics.txt" 2>/dev/null
  [[ -r "$gen_report" ]]  && cp -f "$gen_report"  "$jobdir/upgrade_report.info" 2>/dev/null
  # console.log already lives at $console (== $jobdir/console.log); ensure it's there.

  # Diagnostics blurbs -> console.log + shared diagnostics-summary.txt
  {
    echo ""
    echo "=== diagnostics ($modl) ==="
    echo_diagnostic_errors "$diag_report"
  } >> "$console" 2>/dev/null
  {
    echo "=== $modl ($result) ==="
    echo_diagnostic_errors "$diag_report"
    echo ""
  } >> "$RUN_DIR/diagnostics-summary.txt" 2>/dev/null

  # Keep or delete the bundle
  if [[ "$result" == "PASS" && "$rc" == "0" ]]; then
    kept="deleted"
    # JIRA reconcile BEFORE deleting the bundle (uses the archived $jobdir/upgrade.log).
    jira_pass_hook "$modl" "$jobdir/upgrade.log" >> "$console" 2>&1
    [[ -d "$bundle_path" ]] && rm -rf "$bundle_path"
    # reclaim the validated DB's data files (opt-out: BATCH_HYGIENE=0)
    batch_hygiene_drop_db "$engine" "$target" >> "$console" 2>&1
  else
    kept="kept"
    # Downloadable failure artifact: gzip the upgrade log into failed-logs/ so a failed upgrade's log
    # is a small, stable download that survives the kept (but bulky) bundle — CI archives
    # failed-logs/**. PASS logs are NOT kept here: a passing upgrade's log is attached to its JIRA
    # sub-task by reconcile, then dropped with the bundle. Opt-out: BATCH_FAILED_LOGS=0.
    if [[ "${BATCH_FAILED_LOGS:-1}" == "1" && -r "$jobdir/upgrade.log" ]]; then
      mkdir -p "$RUN_DIR/failed-logs"
      gzip -c "$jobdir/upgrade.log" > "$RUN_DIR/failed-logs/${modl}.upgrade.log.gz" 2>/dev/null \
        && echo "  [failed-log] batch-runs/$BATCH_RUN_TS/failed-logs/${modl}.upgrade.log.gz"
    fi
    # best-guess failure classification (advisory)
    {
      echo ""
      echo "=== best-guess failure classification ($modl) — verify manually ==="
      classify_failure "$console" "$up_log"
    } >> "$console" 2>/dev/null
    echo "  [!] $modl -> $result (rc=$rc). Best-guess tags (verify manually):"
    classify_failure "$console" "$up_log" | sed 's/^/        /'
  fi

  note="rc=$rc; ${elapsed}s; bundle-$kept"
  record_result "$modl" "$engine" "$result" "$note"   # overwrites on a retry pass; tallies recomputed in write_summary
  echo "  [reap] $modl ($engine) -> $result  ($note)"

  # release resources (engine reservation is HELD for the run; only job cost + slot freed)
  COMMITTED_JOBS=$(( COMMITTED_JOBS - RUN_COST[$pid] ))
  FREE_SLOTS+=("${RUN_SLOT[$pid]}")
  unset 'RUN_MODL[$pid]' 'RUN_ENGINE[$pid]' 'RUN_TARGET[$pid]' 'RUN_COST[$pid]' \
        'RUN_SLOT[$pid]' 'RUN_START[$pid]' 'RUN_LOG[$pid]'
}

# reap_finished — reap every running job whose process has exited (non-blocking).
# returns 0 if it reaped at least one, 1 if none were done.
reap_finished() {
  local pid reaped=0 rc
  for pid in "${!RUN_MODL[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"; rc=$?
      post_process_job "$pid" "$rc"
      reaped=1
    fi
  done
  [[ $reaped -eq 1 ]]
}

engine_running_count() {
  local want="$1" pid c=0
  for pid in "${!RUN_ENGINE[@]}"; do
    [[ "${RUN_ENGINE[$pid]}" == "$want" ]] && c=$(( c + 1 ))
  done
  echo "$c"
}

can_admit() {
  # can_admit <engine> <cost> ; echoes 0/1 via return code
  local eng="$1" cost="$2"
  local running=${#RUN_MODL[@]}
  [[ $running -ge $MAX_CONC ]] && return 1
  [[ ${#FREE_SLOTS[@]} -eq 0 ]] && return 1
  local cap="${ENGINE_MAX[$eng]}"
  local eng_run; eng_run="$(engine_running_count "$eng")"
  [[ $eng_run -ge $cap ]] && return 1
  local extra_engine=0
  [[ -z "${ACTIVE_ENGINE[$eng]:-}" ]] && extra_engine="${ENGINE_RES[$eng]}"
  (( COMMITTED_JOBS + ENGINE_RESERVED_TOTAL + cost + extra_engine > BUDGET_MB )) && return 1
  return 0
}

admit_job() {
  # admit_job <idx>
  local idx="$1"
  local engine="${J_ENGINE[$idx]}" dump="${J_DUMP[$idx]}" target="${J_TARGET[$idx]}"
  local modl="${J_MODL[$idx]}" heap="${J_HEAP[$idx]}"
  local cost; cost="$(job_cost "$heap")"
  local slot="${FREE_SLOTS[0]}"
  FREE_SLOTS=("${FREE_SLOTS[@]:1}")   # pop

  # charge engine reservation once
  if [[ -z "${ACTIVE_ENGINE[$engine]:-}" ]]; then
    ACTIVE_ENGINE[$engine]=1
    ENGINE_RESERVED_TOTAL=$(( ENGINE_RESERVED_TOTAL + ENGINE_RES[$engine] ))
  fi
  COMMITTED_JOBS=$(( COMMITTED_JOBS + cost ))

  resolve_extra_args "$engine" "$modl"

  local jobdir="$RUN_DIR/$modl"
  mkdir -p "$jobdir"
  local console="$jobdir/console.log"

  # Launch the job in a backgrounded subshell. stdin <<< YES_BLOB answers residual
  # read prompts; all output -> console.log.
  { run_job "$engine" "$dump" "$target" "$modl" "$heap" "$slot" \
      "$RES_ALTER" "$RES_BOOL" "$RES_LOGICAL" "$RES_REMAP" "$RES_SURGERY"; } \
      <<< "$YES_BLOB" > "$console" 2>&1 &
  local pid=$!

  RUN_MODL[$pid]="$modl"
  RUN_ENGINE[$pid]="$engine"
  RUN_TARGET[$pid]="$target"
  RUN_COST[$pid]="$cost"
  RUN_SLOT[$pid]="$slot"
  RUN_START[$pid]="$SECONDS"
  RUN_LOG[$pid]="$console"

  echo "  [admit] $modl ($engine) slot=$slot cost=${cost}  | running=${#RUN_MODL[@]} committed=${COMMITTED_JOBS} reserved=${ENGINE_RESERVED_TOTAL} / ${BUDGET_MB} MB"
}

write_summary() {
  local out="$RUN_DIR/summary.txt"
  local BUNDLE_V; BUNDLE_V="$(cat "$RUN_DIR/version.txt" 2>/dev/null)"
  # Rebuild rows + tallies from the result store (retry-aware: one row per modl, latest result).
  SUMMARY_ROWS=(); PASS_N=0; FAIL_N=0; NOSTART_N=0
  local _m
  for _m in "${RESULT_ORDER[@]}"; do
    SUMMARY_ROWS+=("$_m|${ENGINE_OF[$_m]}|${RESULT_OF[$_m]}|${NOTE_OF[$_m]}")
    case "${RESULT_OF[$_m]}" in
      PASS)          PASS_N=$(( PASS_N + 1 )) ;;
      DID-NOT-START) NOSTART_N=$(( NOSTART_N + 1 )) ;;
      *)             FAIL_N=$(( FAIL_N + 1 )) ;;
    esac
  done
  {
    echo "================================================================"
    echo " Batch Upgrade Summary — run $BATCH_RUN_TS"
    echo " toolkit $TOOLKIT_ID / bundle ${BUNDLE_V:-unknown}"
    echo "================================================================"
    printf "%-16s %-10s %-14s %s\n" "MODL" "ENGINE" "RESULT" "NOTES"
    printf "%-16s %-10s %-14s %s\n" "----" "------" "------" "-----"
    local row modl engine result note
    for row in "${SUMMARY_ROWS[@]}"; do
      IFS='|' read -r modl engine result note <<< "$row"
      printf "%-16s %-10s %-14s %s\n" "$modl" "$engine" "$result" "$note"
    done
    echo "----------------------------------------------------------------"
    echo "Tally: ${PASS_N} passed / ${FAIL_N} failed / ${NOSTART_N} did-not-start"
    echo "  (did-not-start = import worker returned non-zero; upgrade never ran)"
    echo "================================================================"
  } | tee "$out"

  # Bullet-point summary — top-level, human-readable. Written to SUMMARY.md and echoed to
  # the run log. Detailed per-job logs live one level deeper in batch-runs/<ts>/<modl>/.
  local md="$RUN_DIR/SUMMARY.md" row modl engine result note icon
  {
    echo "# Batch Upgrade — $BATCH_RUN_TS"
    echo
    echo "Toolkit \`$TOOLKIT_ID\`, bundle \`${BUNDLE_V:-unknown}\`"
    echo
    echo "**${PASS_N} passed / ${FAIL_N} failed / ${NOSTART_N} did-not-start**"
    echo
    for row in "${SUMMARY_ROWS[@]}"; do
      IFS='|' read -r modl engine result note <<< "$row"
      case "$result" in
        PASS)          icon="✅" ;;
        DID-NOT-START) icon="⚠️" ;;
        *)             icon="❌" ;;
      esac
      echo "- $icon **$modl** ($engine) — $result — ${note} — logs: \`batch-runs/$BATCH_RUN_TS/$modl/\`"
    done
    echo
    echo "Per-job detail (upgrade.log, reports, console.log): \`batch-runs/$BATCH_RUN_TS/<modl>/\`"
    echo "Error blurbs across the run: \`batch-runs/$BATCH_RUN_TS/diagnostics-summary.txt\`"
  } > "$md"

  echo
  echo "──────────────── bullet summary ($md) ────────────────"
  grep '^- ' "$md" || true
  echo "──────────────────────────────────────────────────────"
}

# drain_queue — run the global `pending` queue (manifest indices) to completion: admit every
# currently-eligible job (respecting MAX_CONC, per-engine caps, and BUDGET), reap finished ones,
# repeat until nothing is queued or running. Jobs that can never fit, or are left queued when the
# run is interrupted, are recorded DID-NOT-START. Factored out of real_run so retry passes reuse it.
drain_queue() {
  local i eng cost progressed
  local -a still_pending
  while [[ ${#pending[@]} -gt 0 || ${#RUN_MODL[@]} -gt 0 ]]; do
    progressed=0
    still_pending=()
    if [[ $STOP -eq 0 ]]; then
      for i in "${pending[@]}"; do
        eng="${J_ENGINE[$i]}"
        cost="$(job_cost "${J_HEAP[$i]}")"
        if can_admit "$eng" "$cost"; then
          admit_job "$i"; progressed=1
        else
          still_pending+=("$i")
        fi
      done
      pending=("${still_pending[@]}")
    fi
    if reap_finished; then progressed=1; fi
    if [[ $progressed -eq 0 ]]; then
      if [[ ${#RUN_MODL[@]} -gt 0 ]]; then
        sleep "$POLL_SECS"                     # jobs running but nothing admittable — wait for a reap
      else
        [[ $STOP -ne 0 ]] && break             # interrupted, none running
        for i in "${pending[@]}"; do
          echo "  [skip] ${J_MODL[$i]} (${J_ENGINE[$i]}) — never fits BUDGET/caps; marking did-not-start."
          record_result "${J_MODL[$i]}" "${J_ENGINE[$i]}" "DID-NOT-START" "over-budget/caps; not launched"
        done
        pending=(); break
      fi
    fi
  done
  # interrupted with jobs still queued
  if [[ ${#pending[@]} -gt 0 ]]; then
    for i in "${pending[@]}"; do
      record_result "${J_MODL[$i]}" "${J_ENGINE[$i]}" "DID-NOT-START" "interrupted before launch"
    done
    pending=()
  fi
}

real_run() {
  # Load workers + diagnostics (source-safe; sourcing defines functions only).
  [[ -r "$WORKER_LIB" ]] || { echo "ERROR: worker lib not found: $WORKER_LIB" >&2; exit 2; }
  [[ -r "$DIAG_LIB" ]]   || { echo "ERROR: diagnostics lib not found: $DIAG_LIB" >&2; exit 2; }
  # shellcheck disable=SC1090
  source "$WORKER_LIB"
  # shellcheck disable=SC1090
  source "$DIAG_LIB"

  mkdir -p "$RUN_DIR"
  # Snapshot the resolved manifest into the run dir so a status reporter (status_batch.sh) can
  # show the FULL roster while the run is in flight — including DBs not yet admitted (QUEUED),
  # which otherwise have no job dir and would be invisible until they start.
  [[ -r "$MANIFEST" ]] && cp -f "$MANIFEST" "$RUN_DIR/manifest.txt" 2>/dev/null || true
  # Record the bundle version this run targets, so cross-run tooling (rollup_status.sh)
  # can scope "is every DB green?" to a specific release instead of mixing q3.1 / q3.2.
  detect_bundle_version > "$RUN_DIR/version.txt" 2>/dev/null || true
  echo "$TOOLKIT_ID" > "$RUN_DIR/toolkit.txt"
  # Record the JIRA parent validation Task so `./jira_reconcile.sh` at the end is zero-friction.
  [[ -n "${BATCH_JIRA_TASK:-}" ]] && echo "$BATCH_JIRA_TASK" > "$RUN_DIR/jira_task.txt"
  print_budget_header
  # HARDENING (#3): the modeled BUDGET assumes a clean box. If real available RAM is lower — an
  # external tenant (e.g. an unrelated container) or memory the OS hasn't reclaimed — cap BUDGET to
  # what's actually free so we don't over-admit into a host OOM (the an earlier full run lesson). One-time and
  # deterministic; the existing admit math then respects real memory. Opt-out: BATCH_RAM_REALCAP=0.
  if [[ "${BATCH_RAM_REALCAP:-1}" == "1" ]]; then
    local real_avail_mb; real_avail_mb="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    if (( real_avail_mb > 0 )); then
      local real_budget=$(( real_avail_mb - ES8_RES ))
      if (( real_budget < BUDGET_MB )); then
        echo " ⚠️  real available RAM ${real_avail_mb} MB < modeled BUDGET ${BUDGET_MB} MB — capping BUDGET to ${real_budget} MB (external memory pressure; consider freeing the box)"
        BUDGET_MB=$real_budget
      fi
    fi
  fi
  echo " active jobs        : ${#J_ENGINE[@]}"
  echo " artifacts dir      : $RUN_DIR"
  echo "----------------------------------------------------------------"

  # Slot pool: BATCH_MAX_CONCURRENCY unique slots.
  local s
  for (( s=1; s<=MAX_CONC; s++ )); do FREE_SLOTS+=("$s"); done

  # Shared remote ES8, once.
  echo "[batch] Ensuring shared Elasticsearch 8 (es8_upgrade) is up..."
  export ES_MODE="remote"
  if ! ensure_es8; then
    echo "ERROR: could not bring up shared ES8; aborting before starting jobs." >&2
    exit 1
  fi

  # modl -> manifest index, so a retry pass can re-queue a job by name.
  local i
  local -A IDX_OF=()
  for (( i=0; i<${#J_MODL[@]}; i++ )); do IDX_OF["${J_MODL[$i]}"]="$i"; done

  # ---- initial pass: queue every job (manifest order) and run it ----
  pending=()
  for (( i=0; i<${#J_ENGINE[@]}; i++ )); do pending+=("$i"); done
  drain_queue

  # ---- auto-retry not-green jobs (UNKNOWN / FAIL / DID-NOT-START) ----
  # Most non-PASS results in this toolkit are transient: an import race, ES timing, a container that
  # was memory-starved under load, or an import that silently produced an empty DB. They clear on a
  # clean serial re-run once the box is idle — which it is now. Re-run each not-PASS modl IN PLACE
  # (record_result overwrites its row), up to BATCH_RETRIES times, serialized (MAX_CONC=1, the
  # proven-safer path). A retry that finally passes flips the job to PASS in the summary; one that
  # keeps failing is a real issue to chase. Opt-out with BATCH_RETRIES=0.
  local attempt=1 saved_conc _m
  while (( attempt <= RETRIES )); do
    [[ $STOP -ne 0 ]] && { echo "[batch] interrupted — skipping retry passes."; break; }
    pending=()
    for _m in "${RESULT_ORDER[@]}"; do
      [[ "${RESULT_OF[$_m]}" == "PASS" ]] && continue
      [[ -n "${IDX_OF[$_m]:-}" ]] && pending+=("${IDX_OF[$_m]}")
    done
    (( ${#pending[@]} == 0 )) && { pending=(); break; }
    echo
    echo "──────── retry pass ${attempt}/${RETRIES}: re-running ${#pending[@]} not-green DB(s) serially ────────"
    for _m in "${pending[@]}"; do printf '   ↻ %s (%s)\n' "${J_MODL[$_m]}" "${J_ENGINE[$_m]}"; done
    saved_conc="$MAX_CONC"; MAX_CONC=1
    drain_queue
    MAX_CONC="$saved_conc"
    attempt=$(( attempt + 1 ))
  done

  write_summary

  # Deterministic issue discovery (NO token) — fingerprint FAILs, group across DBs,
  # write DISCOVERED_ISSUES.md + fileable bug-drafts. Non-fatal; opt-out with BATCH_DISCOVER=0.
  if [[ "${BATCH_DISCOVER:-1}" == "1" && -f "$SCRIPT_DIR/discover_issues.py" ]]; then
    echo
    python3 "$SCRIPT_DIR/discover_issues.py" "$RUN_DIR" \
        ${BATCH_BUNDLE_VERSION:+--version "$BATCH_BUNDLE_VERSION"} 2>&1 | sed 's/^/  /' || \
        echo "  [discover] non-fatal error"
  fi

  # End-of-run HD hygiene: prune dangling docker images (safe — keeps tagged in-use images).
  # Opt-out: BATCH_HYGIENE=0. PASS-DB drops already happened per-job in post_process_job.
  if [[ "$HYGIENE_ENABLED" == "1" ]]; then
    local freed; freed="$(docker image prune -f 2>/dev/null | grep -i 'reclaimed' || true)"
    [[ -n "$freed" ]] && echo "  [hygiene] $freed"
  fi

  # HARDENING (#4): end-of-run container spin-down. Every engine container that stays resident holds
  # real RAM even when idle; stopping them between runs is what prevents the NEXT heavy run from
  # OOMing the host (the an earlier full run lesson). Safe here by construction — the admission loop has fully
  # drained, so nothing is in-flight and every container is idle. The next run re-creates/-starts
  # what it needs (run_*_engine, ensure_es8). Opt-out: BATCH_SPINDOWN=0.
  #
  # BATCH_SPINDOWN_RM=1 additionally REMOVES each container (docker rm) after stopping — a pristine
  # slate next run (no reused-container residue, disk reclaimed) at the cost of re-creating and
  # re-initializing each DB engine on the next run. Default is stop-only: stopping already frees the
  # RAM, and keeping the stopped containers makes the next run start faster.
  if [[ "${BATCH_SPINDOWN:-1}" == "1" ]]; then
    local c
    for c in mysql_db postgresql_db sqlserver_db oracle_db es8_upgrade; do
      docker stop "$c" >/dev/null 2>&1 && echo "  [spindown] stopped $c" || true
      if [[ "${BATCH_SPINDOWN_RM:-0}" == "1" ]]; then
        docker rm -f "$c" >/dev/null 2>&1 && echo "  [spindown] removed $c" || true
      fi
    done
  fi
}

# ==================================================================================
# MAIN
# ==================================================================================
parse_manifest

if [[ ${#J_ENGINE[@]} -eq 0 ]]; then
  echo "No active jobs found in $MANIFEST (all lines commented or empty)." >&2
  exit 0
fi

if [[ $DRY_RUN -eq 1 ]]; then
  dry_run
  exit 0
fi

real_run
