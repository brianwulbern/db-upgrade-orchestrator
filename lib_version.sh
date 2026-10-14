#!/usr/bin/env bash
# lib_version.sh: the toolkit version string, sourced by batch_upgrade.sh.
#
# toolkit_id prints the toolkit version (VERSION file) plus the commit it runs from,
# e.g. "v3.9.2 (4d6f5ae)", so every run records which logic produced its results.
# "+local-changes" flags uncommitted edits to tracked files.
toolkit_id() {
  local v sha dirty="" _tk_dir
  _tk_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  v="$(tr -d '[:space:]' < "$_tk_dir/VERSION" 2>/dev/null)"
  sha="$(git -C "$_tk_dir" rev-parse --short HEAD 2>/dev/null)"
  [[ -n "$sha" && -n "$(git -C "$_tk_dir" status --porcelain --untracked-files=no 2>/dev/null)" ]] && dirty="+local-changes"
  printf 'v%s%s' "${v:-unknown}" "${sha:+ ($sha$dirty)}"
}
