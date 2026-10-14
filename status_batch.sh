#!/usr/bin/env bash
# At-a-glance running/pass/fail status of a batch run, PER DB (default: the most recent run).
#
# Usage:
#   ./status_batch.sh                 # newest run under batch-runs/
#   ./status_batch.sh 20260921-111300 # a specific run timestamp
#   BATCH_RUN_TS=… ./status_batch.sh  # or via env (the CI spot — same var the build sets)
#   ./status_batch.sh --oneline       # single machine-readable line (for a CI status step)
#
# This is a read-only snapshot you can run at ANY time — mid-flight or after. It reports every DB
# in the run's manifest as one of: ✅ PASS · ❌ FAIL · 🟢 RUNNING(<phase>) · ⏳ QUEUED · ⚠️ DID-NOT-START.
# QUEUED = in the manifest but not yet admitted (no job dir yet). Once the run writes summary.txt it
# is FINISHED and we show that final table verbatim.
set -uo pipefail
cd "$(dirname "$0")"

ONELINE=0
args=()
for a in "$@"; do case "$a" in --oneline|-1) ONELINE=1 ;; *) args+=("$a") ;; esac; done
set -- "${args[@]:-}"

RUN_TS="${1:-${BATCH_RUN_TS:-}}"
if [[ -z "$RUN_TS" ]]; then
  latest="$(ls -dt batch-runs/*/ 2>/dev/null | head -1)"
  [[ -z "$latest" ]] && { echo "No runs found under batch-runs/"; exit 0; }
  RUN_TS="$(basename "$latest")"
fi
RUN_DIR="batch-runs/$RUN_TS"
[[ -d "$RUN_DIR" ]] || { echo "No such run: $RUN_DIR"; exit 1; }

# ---- roster: every modl this run targets (so QUEUED DBs are visible before they start) ----------
# Prefer the manifest snapshot batch_upgrade.sh writes into the run dir; fall back to the live
# BATCH_MANIFEST, then the newest manifest on disk. Manifest field 1 = engine, field 4 = modl.
roster_src=""
for cand in "$RUN_DIR/manifest.txt" "${BATCH_MANIFEST:-}" auto.gen jobs.manifest; do
  [[ -n "$cand" && -r "$cand" ]] && { roster_src="$cand"; break; }
done
declare -A R_ENGINE=(); ROSTER=()
if [[ -n "$roster_src" ]]; then
  while IFS='|' read -r f_engine _f2 _f3 f_modl _rest; do
    m="${f_modl//[[:space:]]/}"; e="${f_engine//[[:space:]]/}"
    [[ -z "$m" || "$e" == \#* ]] && continue
    R_ENGINE[$m]="$e"; ROSTER+=("$m")
  done < <(grep -vE '^\s*#|^\s*$' "$roster_src")
fi

started="$(date -d "${RUN_TS:0:4}-${RUN_TS:4:2}-${RUN_TS:6:2} ${RUN_TS:9:2}:${RUN_TS:11:2}:${RUN_TS:13:2}" +%s 2>/dev/null || echo "")"
FINISHED=0; [[ -f "$RUN_DIR/summary.txt" ]] && FINISHED=1

# ---- per-DB state from the run dir --------------------------------------------------------------
# PASS/FAIL from the archived upgrade.log; a job dir with neither yet = RUNNING; a roster DB with no
# job dir = QUEUED. After finish, summary.txt is authoritative (it also carries DID-NOT-START).
declare -A STATE=() PHASE=()
strip_ansi='s/\x1b\][0-9]+;[^\x07]*\x07//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b//g'
classify_job() {
  local jd="$1"
  if grep -q "result success" "$jd/upgrade.log" 2>/dev/null; then echo PASS; return; fi
  if grep -q "result failure" "$jd/upgrade.log" 2>/dev/null; then echo FAIL; return; fi
  echo RUNNING
}
# seed roster as QUEUED
for m in "${ROSTER[@]}"; do STATE[$m]="QUEUED"; done
shopt -s nullglob
for jobdir in "$RUN_DIR"/*/; do
  modl="$(basename "$jobdir")"
  [[ -f "$jobdir/console.log" || -f "$jobdir/upgrade.log" ]] || continue
  [[ -n "${R_ENGINE[$modl]:-}" ]] || ROSTER+=("$modl")   # ran but not in roster snapshot — still show it
  STATE[$modl]="$(classify_job "$jobdir")"
  if [[ "${STATE[$modl]}" == "RUNNING" && -f "$jobdir/console.log" ]]; then
    PHASE[$modl]="$(grep -avE '^[[:space:]]*(at |Caused by|\.\.\. )|^[[:space:]]*$' "$jobdir/console.log" 2>/dev/null \
                     | sed -E "$strip_ansi" | tail -1 | tr -d '\r' | cut -c1-58)"
  fi
done
# After finish, overlay the authoritative summary.txt result (adds DID-NOT-START, resolves stragglers).
if [[ "$FINISHED" == 1 ]]; then
  while read -r modl engine result _rest; do
    case "$result" in PASS|FAIL|UNKNOWN|DID-NOT-START)
      STATE[$modl]="$result"
      [[ -n "${R_ENGINE[$modl]:-}" ]] || { ROSTER+=("$modl"); R_ENGINE[$modl]="$engine"; } ;;
    esac
  done < <(grep -E '[[:space:]](PASS|FAIL|UNKNOWN|DID-NOT-START)[[:space:]]' "$RUN_DIR/summary.txt")
fi

# de-dup roster, tally
mapfile -t ROSTER < <(printf '%s\n' "${ROSTER[@]}" | awk 'NF && !seen[$0]++')
n_pass=0 n_fail=0 n_run=0 n_queue=0 n_nostart=0
for m in "${ROSTER[@]}"; do case "${STATE[$m]:-QUEUED}" in
  PASS) n_pass=$((n_pass+1));; FAIL|UNKNOWN) n_fail=$((n_fail+1));; RUNNING) n_run=$((n_run+1));;
  DID-NOT-START) n_nostart=$((n_nostart+1));; *) n_queue=$((n_queue+1));; esac; done

state_word() {
  if [[ "$FINISHED" == 1 ]]; then echo "finished"; return; fi
  if pgrep -f '[b]atch_upgrade.sh' >/dev/null 2>&1; then echo "running"; else echo "stopped-no-summary"; fi
}
STATE_WORD="$(state_word)"

# ---- --oneline: one grep-able line for a CI status step -----------------------------------------
if [[ "$ONELINE" == 1 ]]; then
  echo "run=$RUN_TS state=$STATE_WORD total=${#ROSTER[@]} running=$n_run passed=$n_pass failed=$n_fail queued=$n_queue did-not-start=$n_nostart toolkit=$(cut -d' ' -f1 "$RUN_DIR/toolkit.txt" 2>/dev/null || echo unknown)"
  exit 0
fi

echo "──────────────────────────────────────────────"
echo " batch run : $RUN_TS"
[[ -s "$RUN_DIR/version.txt" ]] && echo " bundle    : $(cat "$RUN_DIR/version.txt")"
[[ -r "$RUN_DIR/toolkit.txt" ]] && echo " toolkit   : $(cat "$RUN_DIR/toolkit.txt")"
if [[ "$FINISHED" == 1 ]]; then
  if [[ -n "$started" ]]; then
    end="$(stat -c %Y "$RUN_DIR/summary.txt" 2>/dev/null || echo "")"
    [[ -n "$end" ]] && echo " duration  : $(( (end - started) / 60 )) min (completed $(date -d "@$end" '+%H:%M'))"
  fi
  echo " state     : ✅ finished"
elif [[ "$STATE_WORD" == "running" ]]; then
  [[ -n "$started" ]] && echo " elapsed   : $(( ( $(date +%s) - started ) / 60 )) min"
  echo " state     : 🟢 RUNNING"
else
  [[ -n "$started" ]] && echo " elapsed   : $(( ( $(date +%s) - started ) / 60 )) min"
  echo " state     : ⚪ stopped — no summary.txt (interrupted or crashed before finishing)"
fi
echo "──────────────────────────────────────────────"

# per-DB table (roster order)
for m in "${ROSTER[@]}"; do
  eng="${R_ENGINE[$m]:-?}"
  case "${STATE[$m]:-QUEUED}" in
    PASS)          printf "   %-16s %-9s ✅ PASS\n"          "$m" "$eng" ;;
    FAIL|UNKNOWN)  printf "   %-16s %-9s ❌ %s\n"            "$m" "$eng" "${STATE[$m]}" ;;
    DID-NOT-START) printf "   %-16s %-9s ⚠️  DID-NOT-START\n" "$m" "$eng" ;;
    RUNNING)       printf "   %-16s %-9s 🟢 %s\n"            "$m" "$eng" "${PHASE[$m]:-running…}" ;;
    *)             printf "   %-16s %-9s ⏳ QUEUED\n"         "$m" "$eng" ;;
  esac
done
[[ ${#ROSTER[@]} -eq 0 ]] && echo "   (no roster/jobs yet — still in shared ES8 setup)"

echo "──────────────────────────────────────────────"
printf " tally: %d running / %d passed / %d failed / %d queued / %d did-not-start   (%d total)\n" \
  "$n_run" "$n_pass" "$n_fail" "$n_queue" "$n_nostart" "${#ROSTER[@]}"
echo " full log: batch-runs/run-${RUN_TS}.log"
