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
# If no argument is given, the script looks for a "SrvSurvey" subdirectory
# alongside this script.
#
# Environment variables:
#   SRVSURVEY_DELAY   Seconds to sleep before launching SrvSurvey (default: 15)
#                     Increase this if Elite fails to start when SrvSurvey
#                     launches too early.

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Locate the SrvSurvey installation directory
# ---------------------------------------------------------------------------
# Resolve the directory this script lives in (handles symlinks).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ge 1 ]]; then
    SRVSURVEY_DIR="$1"
else
    # Default: a "SrvSurvey" folder next to this script
    SRVSURVEY_DIR="${SCRIPT_DIR}/SrvSurvey"
fi

SRVSURVEY_EXE="${SRVSURVEY_DIR}/SrvSurvey.exe"

if [[ ! -d "${SRVSURVEY_DIR}" ]]; then
    echo "[srvsurvey.sh] ERROR: SrvSurvey directory not found: ${SRVSURVEY_DIR}" >&2
    echo "[srvsurvey.sh] Pass the path as the first argument, or place SrvSurvey" >&2
    echo "[srvsurvey.sh] in a 'SrvSurvey' folder next to this script." >&2
    exit 1
fi

if [[ ! -f "${SRVSURVEY_EXE}" ]]; then
    echo "[srvsurvey.sh] ERROR: SrvSurvey.exe not found in: ${SRVSURVEY_DIR}" >&2
    echo "[srvsurvey.sh] Download the latest SrvSurvey .zip release from:" >&2
    echo "[srvsurvey.sh]   https://github.com/njthomson/SrvSurvey/releases" >&2
    echo "[srvsurvey.sh] and extract it to: ${SRVSURVEY_DIR}" >&2
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
    echo "[srvsurvey.sh] Waiting ${DELAY}s for Elite Dangerous to start …"
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

WINE="$(find_wine)"

if [[ -z "${WINE}" ]]; then
    echo "[srvsurvey.sh] ERROR: Could not locate a Wine or Proton binary." >&2
    echo "[srvsurvey.sh] Ensure that WINELOADER is set by ED Mini Launcher, or" >&2
    echo "[srvsurvey.sh] that system Wine is installed (wine / wine64)." >&2
    exit 1
fi

echo "[srvsurvey.sh] Using Wine binary: ${WINE}"
echo "[srvsurvey.sh] Launching SrvSurvey from: ${SRVSURVEY_EXE}"

# ---------------------------------------------------------------------------
# 4. Launch SrvSurvey
# ---------------------------------------------------------------------------
# The -linux flag is an explicit fallback for Linux detection inside
# SrvSurvey.  The app also auto-detects Linux via the WINELOADER environment
# variable (which is already set when running under Proton), but passing the
# flag makes the intent clear and guards against edge cases.
exec "${WINE}" "${SRVSURVEY_EXE}" -linux
