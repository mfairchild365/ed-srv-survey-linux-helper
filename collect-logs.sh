#!/usr/bin/env bash

set -euo pipefail

DEFAULT_INSTALL_DIR="${HOME:-}/.local/share/ed-srv-survey-helper"
INSTALL_DIR="${DEFAULT_INSTALL_DIR}"
OUTPUT_FILE=""
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir)
            INSTALL_DIR="${2:?--install-dir requires a path}"
            shift 2
            ;;
        --install-dir=*)
            INSTALL_DIR="${1#--install-dir=}"
            shift
            ;;
        --output)
            OUTPUT_FILE="${2:?--output requires a path}"
            shift 2
            ;;
        --output=*)
            OUTPUT_FILE="${1#--output=}"
            shift
            ;;
        -h|--help)
            SHOW_HELP=true
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ "${SHOW_HELP}" == "true" ]]; then
    cat <<EOF
Usage: $0 [--install-dir DIR] [--output FILE]

Collect troubleshooting information for ed-srv-survey-helper.

Options:
  --install-dir DIR   Installed helper directory (default: ${DEFAULT_INSTALL_DIR})
  --output FILE       Write report to FILE instead of stdout
EOF
    exit 0
fi

XDG_CONFIG_HOME_VALUE="${XDG_CONFIG_HOME:-${HOME:-}/.config}"
XDG_STATE_HOME_VALUE="${XDG_STATE_HOME:-${HOME:-}/.local/state}"
MEL_CONFIG="${XDG_CONFIG_HOME_VALUE}/min-ed-launcher/settings.json"
MEL_LEGACY_CONFIG="${XDG_CONFIG_HOME_VALUE}/min-ed-launcher/settings.toml"
MEL_LOG="${XDG_STATE_HOME_VALUE}/min-ed-launcher/min-ed-launcher.log"
SRV_LOG="${XDG_STATE_HOME_VALUE}/ed-srv-survey-helper/srvsurvey.log"
SRV_TMP_LOG_PATTERN="${TMPDIR:-/tmp}"
SRVSURVEY_DIR="${INSTALL_DIR}/SrvSurvey"
SRVSURVEY_EXE="${SRVSURVEY_DIR}/SrvSurvey.exe"
SRVSURVEY_SH="${SRVSURVEY_DIR}/srvsurvey.sh"
MEL_BIN="${INSTALL_DIR}/min-ed-launcher/min-ed-launcher"

redact() {
    sed -E \
        -e 's/(-auth_password=)[^[:space:]]+/\1<redacted>/g' \
        -e 's/(auth_password["=:[:space:]]+)[^",[:space:]]+/\1<redacted>/g' \
        -e 's/(password["=:[:space:]]+)[^",[:space:]]+/\1<redacted>/Ig' \
        -e 's/(token["=:[:space:]]+)[^",[:space:]]+/\1<redacted>/Ig'
}

print_section() {
    local title="$1"
    printf '\n===== %s =====\n' "$title"
}

print_file_excerpt() {
    local label="$1"
    local file_path="$2"
    local lines="${3:-200}"

    print_section "$label"
    if [[ -f "$file_path" ]]; then
        printf 'Path: %s\n' "$file_path"
        tail -n "$lines" "$file_path" 2>/dev/null | redact
    else
        printf 'Missing: %s\n' "$file_path"
    fi
}

find_tmp_helper_logs() {
    find "${SRV_TMP_LOG_PATTERN}" -path '*/ed-srv-survey-helper/srvsurvey.log' -type f 2>/dev/null | sort
}

emit_report() {
    print_section "Environment"
    printf 'Date: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'OS: %s\n' "$(uname -srvmo 2>/dev/null || uname -a)"
    printf 'Install dir: %s\n' "$INSTALL_DIR"
    printf 'XDG_CONFIG_HOME: %s\n' "$XDG_CONFIG_HOME_VALUE"
    printf 'XDG_STATE_HOME: %s\n' "$XDG_STATE_HOME_VALUE"
    printf 'TMPDIR: %s\n' "${TMPDIR:-/tmp}"
    printf 'PATH: %s\n' "${PATH}"
    printf 'LD_LIBRARY_PATH: %s\n' "${LD_LIBRARY_PATH:-<unset>}"
    printf 'MEL_LD_LIBRARY_PATH: %s\n' "${MEL_LD_LIBRARY_PATH:-<unset>}"
    printf 'LD_PRELOAD: %s\n' "${LD_PRELOAD:-<unset>}"
    printf 'STEAM_COMPAT_DATA_PATH: %s\n' "${STEAM_COMPAT_DATA_PATH:-<unset>}"
    printf 'WINELOADER: %s\n' "${WINELOADER:-<unset>}"
    printf 'WINEPREFIX: %s\n' "${WINEPREFIX:-<unset>}"

    print_section "Installed Files"
    for path in "$MEL_BIN" "$SRVSURVEY_SH" "$SRVSURVEY_EXE"; do
        if [[ -e "$path" ]]; then
            ls -l "$path"
        else
            printf 'Missing: %s\n' "$path"
        fi
    done

    print_file_excerpt "min-ed-launcher settings.json" "$MEL_CONFIG" 250
    print_file_excerpt "Legacy settings.toml" "$MEL_LEGACY_CONFIG" 250
    print_file_excerpt "min-ed-launcher log" "$MEL_LOG" 250
    print_file_excerpt "srvsurvey helper log" "$SRV_LOG" 250

    print_section "Fallback helper logs under TMPDIR"
    local found_any=false
    while IFS= read -r log_path; do
        found_any=true
        printf '\n--- %s ---\n' "$log_path"
        tail -n 100 "$log_path" 2>/dev/null | redact
    done < <(find_tmp_helper_logs)

    if [[ "$found_any" == "false" ]]; then
        printf 'No fallback helper logs found under %s\n' "${SRV_TMP_LOG_PATTERN}"
    fi
}

if [[ -n "$OUTPUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    emit_report > "$OUTPUT_FILE"
    echo "Wrote log bundle to $OUTPUT_FILE"
else
    emit_report
fi
