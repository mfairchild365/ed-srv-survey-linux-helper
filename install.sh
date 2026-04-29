#!/usr/bin/env bash
# install.sh — Install or update SrvSurvey + ED Mini Launcher for Elite Dangerous on Linux
#
# Automates the manual steps described in README.md:
#   1. Check for required tools (curl, unzip).
#   2. Detect your Steam installation and Elite Dangerous Proton prefix.
#   3. Download the latest SrvSurvey release and extract it.
#   4. Download the latest ED Mini Launcher Linux binary.
#   5. Place srvsurvey.sh next to SrvSurvey.exe.
#   6. Create / update ~/.config/min-ed-launcher/settings.json with the
#      processes entry for srvsurvey.sh.
#   7. Print the one remaining manual step: setting the Steam launch option.
#
# Pass --update to check GitHub for newer releases and download them.
# Without --update, already-installed components are left as-is.
#
# Usage:
#   ./install.sh [--update] [--install-dir DIR]
#
# Options:
#   --update            Check GitHub for newer releases and update if available.
#   --install-dir DIR   Where to install SrvSurvey and ED Mini Launcher.
#                       Defaults to ~/.local/share/ed-srv-survey-helper

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}[install]${NC} $*"; }
warn()    { echo -e "${YELLOW}[install]${NC} $*" >&2; }
error()   { echo -e "${RED}[install]${NC} ERROR: $*"; }
heading() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }
step()    { echo -e "  ${CYAN}▶${NC} $*"; }
ok()      { echo -e "  ${GREEN}✔${NC} $*"; }
note()    { echo -e "  ${YELLOW}!${NC} $*"; }
die()     { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
ELITE_APP_ID=359320
SRVSURVEY_REPO="njthomson/SrvSurvey"
MINEDLAUNCHER_REPO="rfvgyhn/min-ed-launcher"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INSTALL_DIR="${HOME}/.local/share/ed-srv-survey-helper"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
INSTALL_DIR="${DEFAULT_INSTALL_DIR}"
DO_UPDATE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)
            DO_UPDATE=true
            shift
            ;;
        --install-dir)
            INSTALL_DIR="${2:?--install-dir requires a path}"
            shift 2
            ;;
        --install-dir=*)
            INSTALL_DIR="${1#--install-dir=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--update] [--install-dir DIR]"
            echo ""
            echo "Install SrvSurvey and ED Mini Launcher."
            echo "Pass --update to check GitHub for newer releases and download them."
            echo ""
            echo "Options:"
            echo "  --update            Check GitHub for newer releases and update if available."
            echo "  --install-dir DIR   Where to install (default: ${DEFAULT_INSTALL_DIR})"
            exit 0
            ;;
        *)
            die "Unknown argument: $1  (try --help)"
            ;;
    esac
done

SRVSURVEY_INSTALL_DIR="${INSTALL_DIR}/SrvSurvey"
MINEDLAUNCHER_INSTALL_DIR="${INSTALL_DIR}/min-ed-launcher"

# ---------------------------------------------------------------------------
# 1. Check dependencies
# ---------------------------------------------------------------------------
heading "Checking dependencies"

MISSING=()
for cmd in curl unzip python3; do
    if command -v "${cmd}" &>/dev/null; then
        ok "${cmd}"
    else
        MISSING+=("${cmd}")
        note "${cmd}  ← missing"
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    die "Missing required tools: ${MISSING[*]}
Install them with your package manager, e.g.:
    apt install curl unzip python3
    dnf install curl unzip python3
    pacman -S curl unzip python3"
fi

# ---------------------------------------------------------------------------
# 2. Detect Steam installation and Elite Dangerous
# ---------------------------------------------------------------------------
heading "Detecting Steam installation"

find_steam_root() {
    local candidates=(
        "${HOME}/.local/share/Steam"
        "${HOME}/.steam/steam"
        "${HOME}/.steam/root"
        "/usr/share/steam"
    )
    for dir in "${candidates[@]}"; do
        if [[ -d "${dir}/steamapps" ]]; then
            echo "${dir}"
            return 0
        fi
    done
    return 1
}

STEAM_ROOT=""
if STEAM_ROOT="$(find_steam_root)"; then
    ok "Steam root: ${STEAM_ROOT}"
else
    warn "Steam installation not found in standard locations."
    warn "Proton prefix detection will be skipped."
fi

# Locate the steamapps directory that contains Elite Dangerous.
# Elite may be in a secondary library folder listed in libraryfolders.vdf.
find_elite_steamapps() {
    local steam_root="$1"
    # Default library
    if [[ -d "${steam_root}/steamapps/common/Elite Dangerous" ]]; then
        echo "${steam_root}/steamapps"
        return 0
    fi
    # Additional library folders
    local vdf="${steam_root}/steamapps/libraryfolders.vdf"
    if [[ -f "${vdf}" ]]; then
        while IFS= read -r line; do
            if [[ "${line}" =~ \"path\"[[:space:]]+\"([^\"]+)\" ]]; then
                local lib="${BASH_REMATCH[1]}"
                if [[ -d "${lib}/steamapps/common/Elite Dangerous" ]]; then
                    echo "${lib}/steamapps"
                    return 0
                fi
            fi
        done < "${vdf}"
    fi
    return 1
}

ELITE_STEAMAPPS=""
ELITE_PREFIX=""
if [[ -n "${STEAM_ROOT}" ]]; then
    if ELITE_STEAMAPPS="$(find_elite_steamapps "${STEAM_ROOT}")"; then
        ok "Elite Dangerous steamapps: ${ELITE_STEAMAPPS}"
        ELITE_PREFIX="${ELITE_STEAMAPPS}/compatdata/${ELITE_APP_ID}/pfx"
        if [[ -d "${ELITE_PREFIX}" ]]; then
            ok "Proton prefix found: ${ELITE_PREFIX}"
        else
            note "Proton prefix not found at: ${ELITE_PREFIX}"
            note "Launch Elite Dangerous at least once via Steam to create it."
        fi
    else
        note "Elite Dangerous not found in any Steam library."
        note "Install Elite Dangerous via Steam (and run it once) before playing."
    fi
fi

# ---------------------------------------------------------------------------
# GitHub release helpers
# ---------------------------------------------------------------------------
# If GITHUB_TOKEN is set in the environment, pass it as a Bearer token to
# raise the GitHub API rate limit from 60 to 5000 requests per hour.
github_curl() {
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$@"
    else
        curl -fsSL "$@"
    fi
}

portable_sed_inplace() {
    local expression="$1"
    local file_path="$2"

    if sed --version >/dev/null 2>&1; then
        sed -i "$expression" "$file_path"
    else
        sed -i '' "$expression" "$file_path"
    fi
}

# Print the browser_download_url of the first release asset whose filename
# matches PATTERN (case-insensitive) from the latest release of REPO.
get_latest_release_url() {
    local repo="$1"
    local pattern="$2"
    github_curl "https://api.github.com/repos/${repo}/releases/latest" \
        | grep '"browser_download_url"' \
        | grep -i "${pattern}" \
        | head -1 \
        | sed 's/.*"browser_download_url": "\([^"]*\)".*/\1/' \
        || true
}

# Print the tag_name of the latest release of REPO.
get_latest_release_tag() {
    local repo="$1"
    github_curl "https://api.github.com/repos/${repo}/releases/latest" \
        | grep '"tag_name"' \
        | head -1 \
        | sed 's/.*"tag_name": "\([^"]*\)".*/\1/'
}

# ---------------------------------------------------------------------------
# 3. Install / update SrvSurvey
# ---------------------------------------------------------------------------
heading "SrvSurvey"

SRVSURVEY_VERSION_FILE="${SRVSURVEY_INSTALL_DIR}/.installed-version"
INSTALLED_SRVSURVEY_TAG=""
if [[ -f "${SRVSURVEY_VERSION_FILE}" ]]; then
    INSTALLED_SRVSURVEY_TAG="$(<"${SRVSURVEY_VERSION_FILE}")"
fi

if [[ -n "${INSTALLED_SRVSURVEY_TAG}" \
      && -f "${SRVSURVEY_INSTALL_DIR}/SrvSurvey.exe" \
      && "${DO_UPDATE}" == "false" ]]; then
    ok "SrvSurvey ${INSTALLED_SRVSURVEY_TAG} is already installed. Pass --update to check for a newer version."
    SRVSURVEY_TAG="${INSTALLED_SRVSURVEY_TAG}"
else

step "Fetching latest release information from GitHub…"
SRVSURVEY_TAG="$(get_latest_release_tag "${SRVSURVEY_REPO}")"

if [[ -z "${SRVSURVEY_TAG}" ]]; then
    die "Could not retrieve the latest SrvSurvey release tag.
Check your internet connection or visit https://github.com/${SRVSURVEY_REPO}/releases"
fi

ok "Latest SrvSurvey release: ${SRVSURVEY_TAG}"

# Check whether the installed version is already current.
if [[ "${INSTALLED_SRVSURVEY_TAG}" == "${SRVSURVEY_TAG}" \
      && -f "${SRVSURVEY_INSTALL_DIR}/SrvSurvey.exe" ]]; then
    ok "SrvSurvey ${SRVSURVEY_TAG} is already up to date. Skipping download."
else
    SRVSURVEY_URL="$(get_latest_release_url "${SRVSURVEY_REPO}" "SrvSurvey.*\.zip")"
    if [[ -z "${SRVSURVEY_URL}" ]]; then
        die "Could not find SrvSurvey.zip in the latest release (${SRVSURVEY_TAG}).
Check https://github.com/${SRVSURVEY_REPO}/releases manually."
    fi

    if [[ -n "${INSTALLED_SRVSURVEY_TAG}" ]]; then
        step "Updating SrvSurvey from ${INSTALLED_SRVSURVEY_TAG} → ${SRVSURVEY_TAG}…"
    else
        step "Installing SrvSurvey ${SRVSURVEY_TAG}…"
    fi

    TMPZIP="$(mktemp /tmp/SrvSurvey-XXXXXX.zip)"
    trap 'rm -f "${TMPZIP}"' EXIT

    step "Downloading SrvSurvey.zip…"
    curl -fsSL --progress-bar -o "${TMPZIP}" "${SRVSURVEY_URL}"

    step "Extracting to ${SRVSURVEY_INSTALL_DIR}…"
    mkdir -p "${SRVSURVEY_INSTALL_DIR}"
    unzip -q -o "${TMPZIP}" -d "${SRVSURVEY_INSTALL_DIR}"

    echo "${SRVSURVEY_TAG}" > "${SRVSURVEY_VERSION_FILE}"
    rm -f "${TMPZIP}"
    trap - EXIT

    ok "SrvSurvey ${SRVSURVEY_TAG} installed to ${SRVSURVEY_INSTALL_DIR}"
fi

fi  # end DO_UPDATE / already-installed check

if [[ ! -f "${SRVSURVEY_INSTALL_DIR}/SrvSurvey.exe" ]]; then
    die "SrvSurvey.exe not found after extraction in ${SRVSURVEY_INSTALL_DIR}.
The zip layout may have changed — check https://github.com/${SRVSURVEY_REPO}/releases"
fi

# ---------------------------------------------------------------------------
# 4. Install / update ED Mini Launcher
# ---------------------------------------------------------------------------
heading "ED Mini Launcher"

# Detect host architecture for selecting the correct release asset.
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)  MEL_ARCH="x64"  ;;
    aarch64) MEL_ARCH="arm64" ;;
    *)       warn "Unknown architecture '${ARCH}'; will try 'x64'."; MEL_ARCH="x64" ;;
esac

MEL_BIN="${MINEDLAUNCHER_INSTALL_DIR}/min-ed-launcher"
MEL_VERSION_FILE="${MINEDLAUNCHER_INSTALL_DIR}/.installed-version"
INSTALLED_MEL_TAG=""
if [[ -f "${MEL_VERSION_FILE}" ]]; then
    INSTALLED_MEL_TAG="$(<"${MEL_VERSION_FILE}")"
fi

if [[ -n "${INSTALLED_MEL_TAG}" \
      && -x "${MEL_BIN}" \
      && "${DO_UPDATE}" == "false" ]]; then
    ok "ED Mini Launcher ${INSTALLED_MEL_TAG} is already installed. Pass --update to check for a newer version."
    MEL_TAG="${INSTALLED_MEL_TAG}"
else

step "Fetching latest release information from GitHub…"

MEL_TAG="$(get_latest_release_tag "${MINEDLAUNCHER_REPO}")"
if [[ -z "${MEL_TAG}" ]]; then
    die "Could not retrieve the latest ED Mini Launcher release tag.
Check your internet connection or visit https://github.com/${MINEDLAUNCHER_REPO}/releases"
fi

ok "Latest ED Mini Launcher release: ${MEL_TAG}"

if [[ "${INSTALLED_MEL_TAG}" == "${MEL_TAG}" && -x "${MEL_BIN}" ]]; then
    ok "ED Mini Launcher ${MEL_TAG} is already up to date. Skipping download."
else
    # Try arch-specific asset first (e.g. linux-x64), then plain "linux".
    MEL_URL="$(get_latest_release_url "${MINEDLAUNCHER_REPO}" "linux-${MEL_ARCH}")"
    if [[ -z "${MEL_URL}" ]]; then
        MEL_URL="$(get_latest_release_url "${MINEDLAUNCHER_REPO}" "linux")"
    fi
    if [[ -z "${MEL_URL}" ]]; then
        die "Could not find a Linux release asset for ED Mini Launcher (${MEL_TAG}).
Check https://github.com/${MINEDLAUNCHER_REPO}/releases manually."
    fi

    if [[ -n "${INSTALLED_MEL_TAG}" ]]; then
        step "Updating ED Mini Launcher from ${INSTALLED_MEL_TAG} → ${MEL_TAG}…"
    else
        step "Installing ED Mini Launcher ${MEL_TAG}…"
    fi

    mkdir -p "${MINEDLAUNCHER_INSTALL_DIR}"
    TMPASSET="$(mktemp /tmp/min-ed-launcher-XXXXXX)"
    trap 'rm -f "${TMPASSET}"' EXIT

    step "Downloading…"
    curl -fsSL --progress-bar -o "${TMPASSET}" "${MEL_URL}"

    # Determine asset format and install the binary.
    # move_binary_to_dest: after extraction, locate the binary if not at MEL_BIN yet.
    move_binary_to_dest() {
        if [[ ! -f "${MEL_BIN}" ]]; then
            local found
            found="$(find "${MINEDLAUNCHER_INSTALL_DIR}" -type f \
                        \( -name "min-ed-launcher" -o -name "min-ed-launcher_*" -o -name "min-ed-launcher-*" -o -name "MinEdLauncher" \) \
                        ! -name "*.version" ! -name "*.tar.gz" ! -name "*.tgz" ! -name "*.zip" \
                        | head -1)"
            if [[ -n "${found}" && "${found}" != "${MEL_BIN}" ]]; then
                mv "${found}" "${MEL_BIN}"
            fi
        fi
    }

    if [[ "${MEL_URL}" == *.tar.gz || "${MEL_URL}" == *.tgz ]]; then
        step "Extracting tar archive…"
        tar -xzf "${TMPASSET}" -C "${MINEDLAUNCHER_INSTALL_DIR}"
        # The binary may be nested inside a subdirectory.
        move_binary_to_dest
    elif [[ "${MEL_URL}" == *.zip ]]; then
        step "Extracting zip archive…"
        unzip -q -o "${TMPASSET}" -d "${MINEDLAUNCHER_INSTALL_DIR}"
        move_binary_to_dest
    else
        # Raw binary (no archive)
        step "Installing binary…"
        cp "${TMPASSET}" "${MEL_BIN}"
    fi

    if [[ ! -f "${MEL_BIN}" ]]; then
        die "Downloaded ED Mini Launcher asset did not contain an installable binary.
Asset URL: ${MEL_URL}
Check https://github.com/${MINEDLAUNCHER_REPO}/releases manually."
    fi

    chmod +x "${MEL_BIN}"
    echo "${MEL_TAG}" > "${MEL_VERSION_FILE}"
    rm -f "${TMPASSET}"
    trap - EXIT

    ok "ED Mini Launcher ${MEL_TAG} installed to ${MEL_BIN}"
fi

fi  # end DO_UPDATE / already-installed check

if [[ ! -x "${MEL_BIN}" ]]; then
    die "ED Mini Launcher binary not found / not executable at ${MEL_BIN}."
fi

# ---------------------------------------------------------------------------
# 5. Place srvsurvey.sh next to SrvSurvey.exe
# ---------------------------------------------------------------------------
heading "srvsurvey.sh launcher script"

SRVSURVEY_SH_DEST="${SRVSURVEY_INSTALL_DIR}/srvsurvey.sh"

if [[ -f "${SRVSURVEY_SH_DEST}" && "${DO_UPDATE}" == "false" ]]; then
    ok "srvsurvey.sh is already installed. Pass --update to refresh it."
else
    # Prefer the copy shipped alongside this install.sh (same repo).
    # Fall back to downloading from GitHub if install.sh was run standalone.
    if [[ -f "${SCRIPT_DIR}/srvsurvey.sh" ]]; then
        step "Copying srvsurvey.sh from ${SCRIPT_DIR}…"
        # Guard: skip cp if source and destination are the same file
        # (e.g. install.sh was placed inside SRVSURVEY_INSTALL_DIR).
        if [[ ! "${SCRIPT_DIR}/srvsurvey.sh" -ef "${SRVSURVEY_SH_DEST}" ]]; then
            cp "${SCRIPT_DIR}/srvsurvey.sh" "${SRVSURVEY_SH_DEST}"
        fi
    else
        step "srvsurvey.sh not found alongside install.sh — downloading from GitHub…"
        curl -fsSL \
            "https://raw.githubusercontent.com/mfairchild365/ed-srv-survey-linux-helper/main/srvsurvey.sh" \
            -o "${SRVSURVEY_SH_DEST}"
    fi

    chmod +x "${SRVSURVEY_SH_DEST}"
    ok "srvsurvey.sh installed at ${SRVSURVEY_SH_DEST}"
fi

# ---------------------------------------------------------------------------
# 6. Configure ED Mini Launcher settings.json
# ---------------------------------------------------------------------------
heading "ED Mini Launcher configuration (settings.json)"

MEL_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/min-ed-launcher"
MEL_CONFIG="${MEL_CONFIG_DIR}/settings.json"
MEL_LEGACY_CONFIG="${MEL_CONFIG_DIR}/settings.toml"
mkdir -p "${MEL_CONFIG_DIR}"

configure_mel_settings() {
    local python_status

    if [[ -f "${MEL_LEGACY_CONFIG}" ]]; then
        note "Legacy ${MEL_LEGACY_CONFIG} detected. min-ed-launcher uses settings.json; leaving the TOML file untouched."
    fi

    step "Ensuring ${MEL_CONFIG} launches srvsurvey.sh as an additional process…"
    python_status="$({ python3 - "${MEL_CONFIG}" "${SRVSURVEY_SH_DEST}" <<'PY'
import json
import os
import sys

config_path, script_path = sys.argv[1:3]
created = not os.path.exists(config_path)

if created:
    data = {}
else:
    try:
        with open(config_path, 'r', encoding='utf-8') as handle:
            data = json.load(handle)
    except json.JSONDecodeError as exc:
        print(f"invalid-json:{exc}")
        sys.exit(2)

if not isinstance(data, dict):
    print("invalid-root")
    sys.exit(3)

processes = data.get('processes')
if processes is None:
    processes = []
elif not isinstance(processes, list):
    print("invalid-processes")
    sys.exit(4)

updated = False
found = False
for process in processes:
    if isinstance(process, dict) and str(process.get('fileName', '')).endswith('srvsurvey.sh'):
        found = True
        if process.get('fileName') != script_path:
            process['fileName'] = script_path
            updated = True
        if process.get('keepOpen') is not True:
            process['keepOpen'] = True
            updated = True

if not found:
    processes.append({'fileName': script_path, 'keepOpen': True})
    updated = True

data['processes'] = processes

with open(config_path, 'w', encoding='utf-8') as handle:
    json.dump(data, handle, indent=2)
    handle.write('\n')

if created:
    print('created')
elif updated:
    print('updated')
else:
    print('unchanged')
PY
        } 2>&1)"

    case "${python_status}" in
        created)
            ok "Created ${MEL_CONFIG}"
            ;;
        updated)
            ok "Updated srvsurvey.sh process entry in ${MEL_CONFIG}"
            ;;
        unchanged)
            ok "settings.json already contains the srvsurvey.sh process entry. No changes needed."
            ;;
        invalid-json:*)
            die "${MEL_CONFIG} is not valid JSON (${python_status#invalid-json:}). Fix or remove it, then run install.sh again."
            ;;
        invalid-root)
            die "${MEL_CONFIG} must contain a JSON object at the top level. Fix or remove it, then run install.sh again."
            ;;
        invalid-processes)
            die "${MEL_CONFIG} has a non-array 'processes' value. Fix or remove it, then run install.sh again."
            ;;
        *)
            die "Failed to update ${MEL_CONFIG}: ${python_status}"
            ;;
    esac
}

detect_terminal_prefix() {
    if command -v ptyxis &>/dev/null; then
        echo 'LD_LIBRARY_PATH="" ptyxis -- env MEL_LD_LIBRARY_PATH="$LD_LIBRARY_PATH" LD_LIBRARY_PATH="$LD_LIBRARY_PATH"'
    elif command -v konsole &>/dev/null; then
        echo 'LD_LIBRARY_PATH="" konsole -e env MEL_LD_LIBRARY_PATH="$LD_LIBRARY_PATH" LD_LIBRARY_PATH="$LD_LIBRARY_PATH"'
    elif command -v gnome-terminal &>/dev/null; then
        echo 'gnome-terminal --'
    elif command -v alacritty &>/dev/null; then
        echo 'alacritty -e'
    elif command -v xterm &>/dev/null; then
        echo 'xterm -e'
    else
        echo ''
    fi
}

build_steam_launch_option() {
    local terminal_prefix
    terminal_prefix="$(detect_terminal_prefix)"

    if [[ -n "${terminal_prefix}" ]]; then
        echo "${terminal_prefix} \"${MEL_BIN}\" %command% /autorun /autoquit"
    else
        echo "\"${MEL_BIN}\" %command% /autorun /autoquit"
    fi
}

configure_mel_settings
STEAM_LAUNCH_OPTION="$(build_steam_launch_option)"

# ---------------------------------------------------------------------------
# 7. Summary and remaining manual step
# ---------------------------------------------------------------------------
heading "Installation complete"

ok "SrvSurvey ${SRVSURVEY_TAG}        → ${SRVSURVEY_INSTALL_DIR}"
ok "ED Mini Launcher ${MEL_TAG}  → ${MEL_BIN}"
ok "srvsurvey.sh                      → ${SRVSURVEY_SH_DEST}"
ok "settings.json                     → ${MEL_CONFIG}"
if [[ -n "${ELITE_STEAMAPPS}" ]]; then
    ok "Elite Dangerous                  → ${ELITE_STEAMAPPS}/common/Elite Dangerous"
fi

echo ""
echo -e "${BOLD}${YELLOW}One manual step remaining — set the Steam launch option:${NC}"
echo ""
echo "  In Steam, right-click Elite Dangerous → Properties → General."
echo "  Set 'Launch Options' to:"
echo ""
echo -e "    ${CYAN}${STEAM_LAUNCH_OPTION}${NC}"
echo ""
echo "  Then launch Elite Dangerous through Steam as normal."
echo "  ED Mini Launcher will start SrvSurvey automatically alongside the game."
echo ""

if [[ "${STEAM_LAUNCH_OPTION}" == "\"${MEL_BIN}\" %command% /autorun /autoquit" ]]; then
    echo -e "${YELLOW}  Note:${NC} No supported terminal emulator was detected."
    echo "  If Steam still fails to launch the game silently, install or select a terminal"
    echo "  such as Ptyxis, Konsole, Gnome Terminal, Alacritty, or Xterm and rerun install.sh."
    echo ""
fi

if [[ -n "${ELITE_STEAMAPPS}" \
      && ! -d "${ELITE_STEAMAPPS}/compatdata/${ELITE_APP_ID}/pfx" ]]; then
    echo -e "${YELLOW}  Note:${NC} The Elite Dangerous Proton prefix was not found."
    echo "  Before setting the launch option, launch Elite once with Proton enabled:"
    echo "  Steam → Elite Dangerous → Properties → Compatibility → Proton Experimental."
    echo ""
fi

# Keep the terminal open when launched from a file browser so the user can
# read the Steam launch option instructions above before the window closes.
# Skip this in CI or other automated runs.
if [[ "${CI:-}" != "1" && "${INSTALL_SH_NO_WAIT:-}" != "1" && -e /dev/tty && -t 1 ]]; then
    read -rp "Press Enter to close..." _ < /dev/tty || true
elif [[ -t 1 ]]; then
    echo "(Close this window when you are done reading.)"
fi
