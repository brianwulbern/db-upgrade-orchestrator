#!/usr/bin/env bash
# lib_platform.sh: the few things that differ between Linux and macOS, for the batch toolkit.
# Source it; it only defines functions. Works with GNU or BSD tools on either OS.

plat_is_mac() { [[ "$(uname -s)" == "Darwin" ]]; }

plat_require_bash4() {
  if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: $(basename "$0") needs bash 4 or newer; this is bash ${BASH_VERSION}." >&2
    plat_is_mac && echo "  On macOS: brew install bash, then run it again (the scripts use the first bash on PATH)." >&2
    exit 2
  fi
}

plat_total_mem_mb() {
  if plat_is_mac; then
    echo $(( $(sysctl -n hw.memsize) / 1048576 ))
  else
    awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || echo 0
  fi
}

plat_avail_mem_mb() {
  if plat_is_mac; then
    vm_stat | awk -v ps="$(sysctl -n hw.pagesize)" '
      /^Pages (free|inactive|speculative|purgeable):/ { gsub(/\./, "", $NF); pages += $NF }
      END { print int(pages * ps / 1048576) }'
  else
    awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || echo 0
  fi
}

plat_docker_mem_mb() {
  local bytes
  bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null)"
  echo $(( ${bytes:-0} / 1048576 ))
}

plat_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

plat_epoch() {
  date -d "$1" +%s 2>/dev/null || date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null
}

plat_fmt_epoch() {
  date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2" 2>/dev/null
}

plat_sed_inplace() {
  local expr="$1" file="$2"
  sed -i.platbak -e "$expr" "$file" && rm -f "$file.platbak"
}

plat_timeout() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    "$@"
  fi
}
