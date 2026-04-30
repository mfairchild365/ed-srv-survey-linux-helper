#!/usr/bin/env bash
# srvsurvey.sh — Launch SrvSurvey inside Elite Dangerous's Proton/Wine session
#
# This script is intended to be invoked by ED Mini Launcher as a companion app.
# ED Mini Launcher runs inside the same Proton/Wine session as Elite Dangerous,
# so any child process it starts (including SrvSurvey) shares that session.
# Sharing the same Wine session means SrvSurvey can:
#   - Discover Elite's process via Process.GetProcessesByName("EliteDangerous64")
#   - Parent its overlay windows to Elite's HWND (Win32 window handles are valid
#     across all processes within the same Wine server)
#
# Usage:
#   srvsurvey.sh [/path/to/SrvSurvey/directory]
#
# If no argument is given, the script first checks whether `SrvSurvey.exe`
# lives alongside this script. If not, it falls back to a `SrvSurvey`
# subdirectory next to this script.
#
# Environment variables:
#   SRVSURVEY_DELAY   Seconds to sleep before launching SrvSurvey (default: 15)
#                     Increase this if Elite fails to start when SrvSurvey
#                     launches too early.

set -euo pipefail

STATE_BASE="${XDG_STATE_HOME:-}"
if [[ -z "${STATE_BASE}" ]]; then
    if [[ -n "${HOME:-}" ]]; then
        STATE_BASE="${HOME}/.local/state"
    else
        STATE_BASE="${TMPDIR:-/tmp}"
    fi
fi

LOG_DIR="${STATE_BASE%/}/ed-srv-survey-helper"
LOG_FILE="${LOG_DIR}/srvsurvey.log"

ensure_log_dir() {
    mkdir -p "${LOG_DIR}" 2>/dev/null || {
        LOG_DIR="${TMPDIR:-/tmp}"
        LOG_FILE="${LOG_DIR%/}/ed-srv-survey-helper.log"
    }
}

log() {
    local message="[srvsurvey.sh] $*"
    echo "${message}" >&2
    printf '%s\n' "${message}" >> "${LOG_FILE}" 2>/dev/null || true
}

ensure_log_dir

trap 'status=$?; if [[ ${status} -ne 0 ]]; then log "Exiting with status ${status}"; fi' EXIT

sanitize_runtime_env() {
    if [[ -n "${LD_PRELOAD:-}" ]]; then
        log "Clearing LD_PRELOAD for helper launch: ${LD_PRELOAD}"
        unset LD_PRELOAD
    fi

    if [[ -n "${MEL_LD_LIBRARY_PATH:-}" ]]; then
        log "Restoring host LD_LIBRARY_PATH from MEL_LD_LIBRARY_PATH"
        export LD_LIBRARY_PATH="${MEL_LD_LIBRARY_PATH}"
    fi
}

log "Logging to ${LOG_FILE}"
sanitize_runtime_env

# ---------------------------------------------------------------------------
# 1. Locate the SrvSurvey installation directory
# ---------------------------------------------------------------------------
# Resolve the directory this script lives in (handles symlinks).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ge 1 ]]; then
    SRVSURVEY_DIR="$1"
elif [[ -f "${SCRIPT_DIR}/SrvSurvey.exe" ]]; then
    SRVSURVEY_DIR="${SCRIPT_DIR}"
else
    # Fallback: a "SrvSurvey" folder next to this script
    SRVSURVEY_DIR="${SCRIPT_DIR}/SrvSurvey"
fi

SRVSURVEY_EXE="${SRVSURVEY_DIR}/SrvSurvey.exe"

if [[ ! -d "${SRVSURVEY_DIR}" ]]; then
    log "ERROR: SrvSurvey directory not found: ${SRVSURVEY_DIR}"
    log "Pass the path as the first argument, or place SrvSurvey"
    log "in a 'SrvSurvey' folder next to this script."
    exit 1
fi

if [[ ! -f "${SRVSURVEY_EXE}" ]]; then
    log "ERROR: SrvSurvey.exe not found in: ${SRVSURVEY_DIR}"
    log "Download the latest SrvSurvey .zip release from:"
    log "  https://github.com/njthomson/SrvSurvey/releases"
    log "and extract it to: ${SRVSURVEY_DIR}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Sleep before launching SrvSurvey
# ---------------------------------------------------------------------------
# If SrvSurvey starts before Elite Dangerous has fully initialised, Elite may
# fail to launch entirely. The delay gives Elite time to get past its intro
# videos and reach the main menu before SrvSurvey starts competing for Wine
# resources.
#
# Override by setting SRVSURVEY_DELAY in your environment (e.g. in
# ED Mini Launcher's environment settings). Set to 0 to disable.
DELAY="${SRVSURVEY_DELAY:-15}"

if [[ "${DELAY}" -gt 0 ]]; then
    log "Waiting ${DELAY}s for Elite Dangerous to start …"
    sleep "${DELAY}"
fi

# ---------------------------------------------------------------------------
# 3. Locate the Proton/Wine binary
# ---------------------------------------------------------------------------
# ED Mini Launcher sets several environment variables that we can use to find
# the correct Wine binary for the active Proton session:
#
#   WINELOADER              Full path to the wine binary Proton is using
#   STEAM_COMPAT_DATA_PATH  Proton compatibility data directory for the game
#
# We prefer WINELOADER because it is set by Proton itself. Falling back to a
# wine64 built from STEAM_COMPAT_DATA_PATH ensures we stay within the same
# Proton version. System wine is the last resort.

find_wine() {
    # Prefer the exact binary Proton is already using
    if [[ -n "${WINELOADER:-}" && -x "${WINELOADER}" ]]; then
        echo "${WINELOADER}"
        return
    fi

    # Derive wine64 from STEAM_COMPAT_DATA_PATH
    # Typical layout: .../steamapps/compatdata/<appid>/
    # Proton lives at:  .../steamapps/common/Proton - Experimental/files/bin/wine64
    if [[ -n "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
        STEAMAPPS_DIR="$(dirname "$(dirname "${STEAM_COMPAT_DATA_PATH}")")"
        for CANDIDATE in \
            "${STEAMAPPS_DIR}/common/Proton - Experimental/files/bin/wine64" \
            "${STEAMAPPS_DIR}/common/Proton 9.0 (Beta)/files/bin/wine64" \
            "${STEAMAPPS_DIR}/common/Proton 8.0/files/bin/wine64"; do
            if [[ -x "${CANDIDATE}" ]]; then
                echo "${CANDIDATE}"
                return
            fi
        done

        # Generic search: pick the first Proton directory we find
        PROTON_WINE=$(find "${STEAMAPPS_DIR}/common" -maxdepth 4 \
            -path "*/Proton*/files/bin/wine64" -type f 2>/dev/null | head -1)
        if [[ -n "${PROTON_WINE}" && -x "${PROTON_WINE}" ]]; then
            echo "${PROTON_WINE}"
            return
        fi
    fi

    # Fall back to system wine
    if command -v wine64 &>/dev/null; then
        echo "wine64"
        return
    fi
    if command -v wine &>/dev/null; then
        echo "wine"
        return
    fi

    echo ""
}

configure_proton_prefix() {
    if [[ -n "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
        local compat_prefix="${STEAM_COMPAT_DATA_PATH%/}/pfx"
        if [[ -d "${compat_prefix}" ]]; then
            export WINEPREFIX="${compat_prefix}"
            log "Using Proton prefix: ${WINEPREFIX}"
        else
            log "Proton prefix path not found at ${compat_prefix}"
        fi
    fi
}

configure_proton_prefix

WINE="$(find_wine)"

if [[ -z "${WINE}" ]]; then
    log "ERROR: Could not locate a Wine or Proton binary."
    log "Ensure that WINELOADER is set by ED Mini Launcher, or"
    log "that system Wine is installed (wine / wine64)."
    exit 1
fi

log "Using Wine binary: ${WINE}"
log "Launching SrvSurvey from: ${SRVSURVEY_EXE}"
log "Using working directory: ${SRVSURVEY_DIR}"

# ---------------------------------------------------------------------------
# 4. Launch SrvSurvey
# ---------------------------------------------------------------------------
# The -linux flag is an explicit fallback for Linux detection inside
# SrvSurvey.  The app also auto-detects Linux via the WINELOADER environment
# variable (which is already set when running under Proton), but passing the
# flag makes the intent clear and guards against edge cases.
cd "${SRVSURVEY_DIR}"

set +e
"${WINE}" "${SRVSURVEY_EXE}" -linux >> "${LOG_FILE}" 2>&1
launch_status=$?
set -e

if [[ ${launch_status} -ne 0 ]]; then
    log "ERROR: Wine launch exited with status ${launch_status}"
    exit "${launch_status}"
fi

log "Wine launch exited with status 0"
