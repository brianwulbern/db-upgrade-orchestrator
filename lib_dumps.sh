#!/usr/bin/env bash
# lib_dumps.sh: helpers for compressed, password-protected database dumps.
#
# Shared dumps often arrive as 7z archives with encrypted headers, each with its OWN password.
# Rather than prompting (which would hang a headless batch), the password is looked up from the
# environment by matching the dump's filename:
#
#   DUMPS_<NAME>_7Z_PASSWORD   where <NAME> is a token from the filename, matched ignoring case and
#                              punctuation; the longest match wins. e.g. customer-c.bak.7z picks
#                              DUMPS_CUSTOMER_C_7Z_PASSWORD over a broader DUMPS_CUSTOMER_7Z_PASSWORD.
#   DUMPS_7Z_PASSWORD          fallback for any archive with no per-dump variable.
#
# With no password, 7z fails fast (stdin is /dev/null) instead of hanging on a prompt.

# sevenz_pw_var <file>: print the NAME of the variable that holds this archive's password ("" if none).
sevenz_pw_var() {
    local file v key best="" bestkey=""
    file="$(basename "$1" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
    for v in $(compgen -v DUMPS_); do
        [[ "$v" =~ ^DUMPS_(.+)_7Z_PASSWORD$ ]] || continue
        key="$(printf '%s' "${BASH_REMATCH[1]}" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
        [[ -n "$key" && "$file" == *"$key"* && ${#key} -gt ${#bestkey} ]] && { best="$v"; bestkey="$key"; }
    done
    [[ -z "$best" && -n "${DUMPS_7Z_PASSWORD:-}" ]] && best="DUMPS_7Z_PASSWORD"
    printf '%s' "$best"
}

# sevenz_pw <file>: print the password itself (never log this).
sevenz_pw() {
    local v; v="$(sevenz_pw_var "$1")"
    [[ -n "$v" ]] && printf '%s' "${!v}"
}

# sevenz_cat <file>: stream the single file inside a .7z to stdout, so a dump imports (or a backup is
# written straight into a container) without an extracted copy on disk. Distros name the tool
# differently: 7zz (7zip package), 7z / 7za (p7zip).
sevenz_cat() {
    local bin pw=() p
    p="$(sevenz_pw "$1")"
    [[ -n "$p" ]] && pw=(-p"$p")
    for bin in 7zz 7z 7za; do
        command -v "$bin" >/dev/null 2>&1 && { "$bin" e -so -bd "${pw[@]}" "$1" </dev/null; return; }
    done
    echo "'$1' is a .7z but no 7-Zip tool found (install 7zip or p7zip-full)." >&2
    return 127
}
