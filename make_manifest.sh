#!/usr/bin/env bash
# make_manifest.sh [--catalog FILE] [--for-version VER] [--only m1,m2] [--skip x1,x2] [-o OUT]
#
# Generate a run manifest DYNAMICALLY from the catalog (default jobs.manifest), including only the
# entries whose dump file (field 2) is actually present on disk. Writes a visible OUT you can trim.
# Then: ./start_batch.sh <OUT>. Also invoked by `./start_batch.sh auto`.
#
# Catalog entries come in two forms:
#   - active lines:            engine | dump | target | modl | offset | heap | es | flags
#   - LARGE (opt-in) lines:    # LARGE(<size>): <the same 8 fields>
#     These are real customers deliberately kept OUT of the bare default (big dumps: RAM/disk),
#     but pulled IN when a set explicitly names them or for the full group (ALL).
#
# Set selection (what modls to include):
#   --for-version VER : match VER against release_sets.conf globs (first match wins) -> a modl set,
#                       or ALL. This is the CI hook: BUNDLE_VERSION drives the customer set.
#                         line-a.* -> the line-a set; line-b.* -> the line-b set; * -> ALL.
#   --only m1,m2      : explicit modl list (overrides --for-version). Blank = no restriction.
#   (neither)         : bare default = active lines only (LARGE excluded) — legacy behavior.
# In every case, only entries whose dump is present on disk are emitted.
#
# Dump resolution (field 2 of each catalog line): dumps.local override > literal filename > glob.
#   - The catalog's dump field may be a literal filename OR a glob (e.g. `*customer-a*dump*.sql`).
#   - dumps.local (git-ignored, `<modl> = <file-or-glob>` per line) overrides the catalog per modl,
#     so each machine maps its own dump names without editing the shared catalog. See dumps.local.example.
#   - A glob that matches exactly one file is used; matching several is reported AMBIGUOUS and skipped.
#
# Exclusion (applied last, on top of whatever the set selected):
#   --skip x1,x2      : drop entries whose ENGINE (field 1) OR modl (field 4) matches. So
#                       `--skip oracle` drops every Oracle DB without listing the rest, and
#                       `--skip oracle,customer-e` also drops that modl. Useful for perf runs.
set -uo pipefail
cd "$(dirname "$0")"

CATALOG="jobs.manifest" OUT="auto.gen" ONLY="" FORVER="" SKIP="" SETS_CONF="release_sets.conf"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --catalog)     CATALOG="$2"; shift 2 ;;
    --for-version) FORVER="$2"; shift 2 ;;
    --sets)        SETS_CONF="$2"; shift 2 ;;
    -o|--out)      OUT="$2"; shift 2 ;;
    --only)        ONLY="$2"; shift 2 ;;
    --skip)        SKIP="$2"; shift 2 ;;
    -h|--help)     sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: $0 [--catalog FILE] [--for-version VER] [--only m1,m2] [--skip x1,x2] [-o OUT]" >&2; exit 2 ;;
  esac
done
[[ -f "$CATALOG" ]] || { echo "catalog not found: $CATALOG" >&2; exit 1; }

lc() { echo "${1,,}"; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# ── local dump-name overrides (git-ignored) ────────────────────────────────────────────────────
# Each machine's dumps are named differently. dumps.local maps a modl to the actual filename (or a
# glob) on THIS box, without touching the shared catalog. Format, one per line:  <modl> = <file-or-glob>
# e.g.   customer-a = app-dump-postgres-2025-08-18.sql
#        customer-b = *customer-b*dump*.sql
OVERRIDE_CONF="${DUMPS_LOCAL:-dumps.local}"
declare -A OVERRIDE=()
if [[ -f "$OVERRIDE_CONF" ]]; then
  while IFS= read -r oline || [[ -n "$oline" ]]; do
    case "$oline" in ''|\#*) continue ;; esac
    [[ "$oline" == *=* ]] || continue
    ok="$(trim "${oline%%=*}")"; ov="$(trim "${oline#*=}")"
    [[ -n "$ok" && -n "$ov" ]] && OVERRIDE["$(lc "$ok")"]="$ov"
  done < "$OVERRIDE_CONF"
  ((${#OVERRIDE[@]})) && echo "── loaded ${#OVERRIDE[@]} dump override(s) from $OVERRIDE_CONF ──" >&2
fi

# resolve_dump <modl> <catalog-pattern> -> prints the resolved on-disk path; rc 0 ok / 1 none / 2 ambiguous.
# Precedence: dumps.local override (may be a glob) > literal catalog filename > catalog treated as a glob.
resolve_dump() {
  local modl="$1" pat="$2" ov
  ov="${OVERRIDE[$(lc "$modl")]:-}"
  [[ -n "$ov" ]] && pat="$ov"
  [[ -f "$pat" ]] && { printf '%s' "$pat"; return 0; }
  # A dump may be downloaded still compressed: foo.sql.7z / .gz / .zip (the MySQL and Postgres
  # importers stream all three) or foo.bak.7z (the SQL Server restore streams it into the
  # container). Accept the compressed copy as-is.
  local ext exts=()
  case "$pat" in *.sql) exts=(7z gz zip) ;; *.bak) exts=(7z) ;; esac
  for ext in "${exts[@]}"; do
    [[ -f "$pat.$ext" ]] && { printf '%s' "$pat.$ext"; return 0; }
  done
  # Only glob-expand when the pattern actually contains glob metacharacters — otherwise a literal,
  # non-existent filename would pass through nullglob unchanged and look like a single match.
  if [[ "$pat" == *[\*\?\[]* ]]; then
    local -a m; shopt -s nullglob; m=( $pat )
    if (( ${#m[@]} == 0 )); then
      case "$pat" in *.sql) m=( $pat.7z $pat.gz $pat.zip ) ;; *.bak) m=( $pat.7z ) ;; esac
    fi
    shopt -u nullglob
    case ${#m[@]} in
      0) return 1 ;;
      1) printf '%s' "${m[0]}"; return 0 ;;
      *) printf '%s' "${m[*]}"; return 2 ;;
    esac
  fi
  return 1   # literal filename, already checked with -f above and not found
}

# ── resolve the modl set (space-padded lowercase, or the sentinel __ALL__) ─────────────────────
SET=""            # "" => no set restriction from --for-version
SET_SOURCE=""
if [[ -n "$FORVER" ]]; then
  [[ -f "$SETS_CONF" ]] || { echo "sets config not found: $SETS_CONF" >&2; exit 1; }
  while IFS= read -r cline; do
    case "$cline" in ''|\#*) continue ;; esac
    pat="${cline%%=*}"; rhs="${cline#*=}"
    pat="$(echo "$pat" | xargs)"; rhs="$(echo "$rhs" | xargs)"
    [[ -z "$pat" ]] && continue
    # shellcheck disable=SC2053
    if [[ "$FORVER" == $pat ]]; then
      if [[ "$rhs" == "ALL" ]]; then SET="__ALL__"; else SET=" $(lc "$rhs") "; fi
      SET_SOURCE="$pat"
      break
    fi
  done < "$SETS_CONF"
  [[ -z "$SET" ]] && { echo "no release_sets.conf pattern matched version '$FORVER' (add one, or a '* = ALL' catch-all)" >&2; exit 1; }
fi
# --only is an explicit override/intersection on top of any set.
ONLY_SET=""; [[ -n "$ONLY" ]] && ONLY_SET=" $(lc "${ONLY//,/ }") "
# --skip is an exclusion applied last; each token matches an engine (field 1) or a modl (field 4).
SKIP_SET=""; [[ -n "$SKIP" ]] && SKIP_SET=" $(lc "${SKIP//,/ }") "

# A modl is wanted if: it passes --only (when given) AND passes the set (when given).
want() {
  local m; m=" $(lc "$1") "
  [[ -n "$ONLY" && "$ONLY_SET" != *"$m"* ]] && return 1
  if [[ -n "$SET" && "$SET" != "__ALL__" && "$SET" != *"$m"* ]]; then return 1; fi
  return 0
}
# LARGE entries are emitted only when explicitly selected — i.e. a set is in play (--for-version
# or --only). The bare default (no set at all) keeps them out, preserving legacy `auto`.
large_ok() { [[ -n "$SET" || -n "$ONLY" ]]; }

included=() skipped=() excluded_large=() excluded_skip=() ambiguous=()
consider() {  # <manifest-line> <is_large 0|1>
  local line="$1" large="$2"
  [[ "$line" == *'|'* ]] || return
  local -a F; IFS='|' read -ra F <<< "$line"
  local engine modl patt resolved rc
  engine="$(trim "${F[0]}")"; patt="$(trim "${F[1]}")"; modl="$(trim "${F[3]:-}")"
  want "$modl" || return
  # --skip: drop when the engine OR the modl is named (space-padded lowercase membership test).
  if [[ -n "$SKIP" ]]; then
    local e=" $(lc "$engine") " m=" $(lc "$modl") "
    if [[ "$SKIP_SET" == *"$e"* || "$SKIP_SET" == *"$m"* ]]; then excluded_skip+=("$modl ($engine)"); return; fi
  fi
  if [[ "$large" == 1 ]] && ! large_ok; then excluded_large+=("$modl"); return; fi
  # Resolve the dump: dumps.local override > literal catalog filename > catalog glob.
  resolved="$(resolve_dump "$modl" "$patt")"; rc=$?
  if (( rc == 2 )); then ambiguous+=("$modl → '$patt' matches multiple: $resolved"); return; fi
  if (( rc != 0 )); then skipped+=("$modl → $patt"); return; fi
  # Rebuild the line with the resolved path in field 2 (batch trims each field, so spacing is cosmetic).
  F[1]="$resolved"
  local out="" i
  for i in "${!F[@]}"; do [[ -n "$out" ]] && out+=" | "; out+="$(trim "${F[$i]}")"; done
  included+=("$out")
}

while IFS= read -r line; do
  if [[ "$line" =~ ^#[[:space:]]*LARGE\([^\)]*\):[[:space:]]*(.+\|.+)$ ]]; then
    consider "${BASH_REMATCH[1]}" 1
  else
    case "$line" in ''|\#*) continue ;; esac
    consider "$line" 0
  fi
done < "$CATALOG"

sel_desc="full (active default)"
[[ -n "$SET" && "$SET" == "__ALL__" ]] && sel_desc="ALL (via '$SET_SOURCE')"
[[ -n "$SET" && "$SET" != "__ALL__" ]] && sel_desc="set for '$FORVER' (via '$SET_SOURCE')"
[[ -n "$ONLY" ]] && sel_desc="$sel_desc + only=$ONLY"
[[ -n "$SKIP" ]] && sel_desc="$sel_desc + skip=$SKIP"

{
  echo "# auto-generated $(date '+%F %T') by make_manifest.sh from $CATALOG"
  echo "# selection: $sel_desc — only entries whose dump is present on disk. Then: ./start_batch.sh $OUT"
  echo "# engine | dump | target_db | modl | offset | heap | es_mode | flags"
  ((${#included[@]})) && printf '%s\n' "${included[@]}"
} > "$OUT"

echo "── declared $OUT [$sel_desc]: ${#included[@]} job(s) present / ${#skipped[@]} skipped (dump missing) ──"
((${#included[@]})) && printf '  ✓ %s\n' "$(printf '%s\n' "${included[@]}" | cut -d'|' -f4 | xargs)"
((${#skipped[@]}))         && { echo "  skipped (no dump — set a name/glob in ${OVERRIDE_CONF}):"; printf '    - %s\n' "${skipped[@]}"; }
((${#ambiguous[@]}))       && { echo "  AMBIGUOUS (glob matched >1 — narrow it in ${OVERRIDE_CONF}):"; printf '    - %s\n' "${ambiguous[@]}"; }
((${#excluded_large[@]}))  && echo "  (LARGE, not selected: ${excluded_large[*]})"
((${#excluded_skip[@]}))   && echo "  (skipped via --skip $SKIP: ${excluded_skip[*]})"
((${#included[@]})) || { echo "  (nothing to run — no selected dumps found on disk)"; exit 1; }
