#!/usr/bin/env bash
#
# lib_diagnostics.sh — sourceable helper library for the database-upgrade
# batch runner scripts (parallel_upgrades*.sh / upgrade_databases.sh).
#
# Self-contained: no dependencies beyond coreutils/grep/awk/bash builtins.
#
# Usage:
#   source /path/to/db_upgrades/lib_diagnostics.sh
#   extract_upgrade_result "<name>-bundle/logs/upgrade.log"
#   classify_failure "<name>-bundle/logs/upgrade.log" "<name>-bundle/logs/upgrade_report_diagnostics.txt"
#   echo_diagnostic_errors "<name>-bundle/logs/upgrade_report_diagnostics.txt"
#
# Functions:
#   extract_upgrade_result <upgrade_log_path>
#   classify_failure <log_or_report_path> [more_paths...]
#   echo_diagnostic_errors <upgrade_report_diagnostics_path>

# extract_upgrade_result <upgrade_log_path>
#
# Echoes PASS, FAIL, or UNKNOWN based on the "Major upgrade finished with
# result ..." line in the given upgrade log. Missing/unreadable file -> UNKNOWN.
# Always returns 0.
extract_upgrade_result() {
    local log_path="${1:-}"

    if [[ -z "$log_path" || ! -r "$log_path" ]]; then
        echo "UNKNOWN"
        return 0
    fi

    if grep -qF 'Major upgrade finished with result success' -- "$log_path" 2>/dev/null; then
        echo "PASS"
        return 0
    fi

    if grep -qF 'Major upgrade finished with result failure' -- "$log_path" 2>/dev/null; then
        echo "FAIL"
        return 0
    fi

    echo "UNKNOWN"
    return 0
}

# classify_failure <log_or_report_path> [more_paths...]
#
# Greps the given file(s) for known failure signatures and echoes a
# best-guess tag + short hint, one line per matched signature (a run can
# match several), tab-separated as: <TAG>\t<hint>\t<matched phrase>
#
# Always appends a trailing NOTE line. If no signature matches, an
# UNCLASSIFIED line is emitted before the NOTE line. Always returns 0.
classify_failure() {
    local -a files=("$@")
    local -a readable_files=()
    local f

    for f in "${files[@]}"; do
        [[ -n "$f" && -r "$f" ]] && readable_files+=("$f")
    done

    local -a tags=(
        "INFRA/RAM"
        "INFRA/RAM"
        "INFRA/container"
        "INFRA/shm"
        "INFRA/pool"
        "INFRA/JDK"
        "DATA/dump"
        "DATA/erc-null"
        "OPERATOR/rerun"
        "DIRTY-CONTAINER"
        "DATA/collation"
    )
    local -a hints=(
        "host OOM-killed a container; retry serially on a freed box"
        "process OOM-killed (exit 137); reduce concurrency"
        "a DB container was stopped; start it and retry"
        "Postgres /dev/shm too small; container needs --shm-size or mmap"
        "Hikari pool starved; free RAM or raise jdbc maxPoolSize"
        "bundle needs JDK 21 (--add-opens); wrong Java in use"
        "dump missing/misnamed or import aborted before upgrade"
        "SQL Server NULL-ERC dup breaks a UNIQUE index (transient table)"
        "ran upgrade on an already-upgraded DB; re-import fresh first"
        "stale tables from a prior aborted run; re-import into a clean container"
        "unsupported BIN2/CS collation (advisory or blocking)"
    )
    local -a patterns=(
        'Connection refused'
        'exit code 137|Exited \(137\)|OOMKilled'
        'is not running'
        'could not resize shared memory segment'
        'Connection is not available, request timed out'
        'Unrecognized option: --add-opens'
        'Dump file|Backup file'
        'duplicate key was found'
        'already exists'
        'Stale tables were detected'
        'Mixed character set|_BIN2|_CS_'
    )

    local matched_any=0
    local i matched_phrase

    if [[ ${#readable_files[@]} -gt 0 ]]; then
        for i in "${!tags[@]}"; do
            matched_phrase=$(grep -hoiE -- "${patterns[$i]}" "${readable_files[@]}" 2>/dev/null | head -n1)
            if [[ -n "$matched_phrase" ]]; then
                printf '%s\t%s\t%s\n' "${tags[$i]}" "${hints[$i]}" "$matched_phrase"
                matched_any=1
            fi
        done
    fi

    if [[ "$matched_any" -eq 0 ]]; then
        printf 'UNCLASSIFIED\tno known signature matched; inspect logs by hand\t\n'
    fi

    printf 'NOTE\tbest-guess from known signatures — verify manually\t\n'
    return 0
}

# echo_diagnostic_errors <upgrade_report_diagnostics_path>
#
# Prints the "Errors" section blurbs from an upgrade_report_diagnostics.txt:
# each "Class name: ..." line followed by its "N occurrences of the
# following event: ..." line. Prints "(no diagnostics report found)" if the
# file is missing/unreadable. Tolerates the Errors section being absent.
echo_diagnostic_errors() {
    local report_path="${1:-}"

    if [[ -z "$report_path" || ! -r "$report_path" ]]; then
        echo "(no diagnostics report found)"
        return 0
    fi

    awk '
        /^Errors[[:space:]]*$/ { in_errors=1; next }
        in_errors && /^Class name:/ {
            print
            if ((getline line) > 0 && line ~ /occurrences of the following event:/) {
                print line
            }
            next
        }
    ' "$report_path"

    return 0
}

# ---------------------------------------------------------------------------
# Self-test (only runs when this file is executed directly, not sourced)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -u

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/lib_diagnostics_selftest.XXXXXX")
    trap 'rm -rf "$tmpdir"' EXIT

    success_log="$tmpdir/success.log"
    fail_log="$tmpdir/fail.log"
    diag_report="$tmpdir/upgrade_report_diagnostics.txt"

    cat > "$success_log" <<'EOF'
2026-08-26 10:00:00 INFO  Starting upgrade
2026-08-26 10:05:00 INFO  Running upgrade process com.example.app.platform.tools.db.upgrade.client.Main
2026-08-26 10:10:00 INFO  Major upgrade finished with result success
EOF

    cat > "$fail_log" <<'EOF'
2026-08-26 11:00:00 INFO  Starting upgrade
2026-08-26 11:02:15 WARN  HikariPool-1 - Connection is not available, request timed out after 30000ms.
2026-08-26 11:02:20 ERROR mysql_db is not running
2026-08-26 11:02:25 ERROR Major upgrade finished with result failure
EOF

    cat > "$diag_report" <<'EOF'
Summary

Something summary here.

Errors

Class name: com.example.app.platform.kernel.exception.SystemException
3 occurrences of the following event: Failed to upgrade table X

Class name: com.example.app.exportimport.kernel.exception.SomeException
1 occurrences of the following event: Something else
EOF

    echo "=== extract_upgrade_result (success log) ==="
    extract_upgrade_result "$success_log"

    echo "=== extract_upgrade_result (failure log) ==="
    extract_upgrade_result "$fail_log"

    echo "=== extract_upgrade_result (missing file) ==="
    extract_upgrade_result "$tmpdir/does_not_exist.log"

    echo "=== classify_failure (failure log) ==="
    classify_failure "$fail_log"

    echo "=== classify_failure (success log, expect UNCLASSIFIED) ==="
    classify_failure "$success_log"

    echo "=== echo_diagnostic_errors (diag report) ==="
    echo_diagnostic_errors "$diag_report"

    echo "=== echo_diagnostic_errors (missing file) ==="
    echo_diagnostic_errors "$tmpdir/no_such_report.txt"

    echo "=== self-test complete ==="
fi
