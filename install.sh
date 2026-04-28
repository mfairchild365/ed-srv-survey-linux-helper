#!/usr/bin/env bash
# install.sh — Install or update SrvSurvey + ED Mini Launcher for Elite Dangerous on Linux
#
# Automates the manual steps described in README.md:
#   1. Check for required tools (curl, unzip).
#   2. Detect your Steam installation and Elite Dangerous Proton prefix.
#   3. Download the latest SrvSurvey release and extract it.
#   4. Download the latest ED Mini Launcher Linux binary.
#   5. Place srvsurvey.sh next to SrvSurvey.exe.
#   6. Create / update ~/.config/min-ed-launcher/settings.toml with the
#      autorun entry for srvsurvey.sh.
#   7. Print the one remaining manual step: setting the Steam launch option.
#
# Run again at any time to update SrvSurvey and ED Mini Launcher to their
# latest releases.  Already-current versions are skipped automatically.
#
# Usage:
#   ./install.sh [--install-dir DIR]
#
# Options:
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
error()   { echo -e "${RED}[install]${NC} ERROR: $*" >&2; }
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
        -h|--help)
            echo "Usage: $0 [--install-dir DIR]"
            echo ""
            echo "Install or update SrvSurvey and ED Mini Launcher."
            echo "Run again at any time to pull the latest releases."
            echo ""
            echo "Options:"
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
for cmd in curl unzip; do
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
  apt install curl unzip
  dnf install curl unzip
  pacman -S curl unzip"
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

# Print the browser_download_url of the first release asset whose filename
# matches PATTERN (case-insensitive) from the latest release of REPO.
get_latest_release_url() {
    local repo="$1"
    local pattern="$2"
    curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
        | grep '"browser_download_url"' \
        | grep -i "${pattern}" \
        | head -1 \
        | sed 's/.*"browser_download_url": "\([^"]*\)".*/\1/'
}

# Print the tag_name of the latest release of REPO.
get_latest_release_tag() {
    local repo="$1"
    curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
        | grep '"tag_name"' \
        | head -1 \
        | sed 's/.*"tag_name": "\([^"]*\)".*/\1/'
}

# ---------------------------------------------------------------------------
# 3. Install / update SrvSurvey
# ---------------------------------------------------------------------------
heading "SrvSurvey"

step "Fetching latest release information from GitHub…"
SRVSURVEY_TAG="$(get_latest_release_tag "${SRVSURVEY_REPO}")"
SRVSURVEY_URL="$(get_latest_release_url "${SRVSURVEY_REPO}" "SrvSurvey\.zip")"

if [[ -z "${SRVSURVEY_TAG}" ]]; then
    die "Could not retrieve the latest SrvSurvey release tag.
Check your internet connection or visit https://github.com/${SRVSURVEY_REPO}/releases"
fi
if [[ -z "${SRVSURVEY_URL}" ]]; then
    die "Could not find SrvSurvey.zip in the latest release (${SRVSURVEY_TAG}).
Check https://github.com/${SRVSURVEY_REPO}/releases manually."
fi

ok "Latest SrvSurvey release: ${SRVSURVEY_TAG}"

# Check whether the installed version is already current.
SRVSURVEY_VERSION_FILE="${SRVSURVEY_INSTALL_DIR}/.installed-version"
INSTALLED_SRVSURVEY_TAG=""
if [[ -f "${SRVSURVEY_VERSION_FILE}" ]]; then
    INSTALLED_SRVSURVEY_TAG="$(<"${SRVSURVEY_VERSION_FILE}")"
fi

if [[ "${INSTALLED_SRVSURVEY_TAG}" == "${SRVSURVEY_TAG}" \
      && -f "${SRVSURVEY_INSTALL_DIR}/SrvSurvey.exe" ]]; then
    ok "SrvSurvey ${SRVSURVEY_TAG} is already up to date. Skipping download."
else
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

if [[ ! -f "${SRVSURVEY_INSTALL_DIR}/SrvSurvey.exe" ]]; then
    die "SrvSurvey.exe not found after extraction in ${SRVSURVEY_INSTALL_DIR}.
The zip layout may have changed — check https://github.com/${SRVSURVEY_REPO}/releases"
fi

# ---------------------------------------------------------------------------
# 4. Install / update ED Mini Launcher
# ---------------------------------------------------------------------------
heading "ED Mini Launcher"

step "Fetching latest release information from GitHub…"

# Detect host architecture for selecting the correct release asset.
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)  MEL_ARCH="x64"  ;;
    aarch64) MEL_ARCH="arm64" ;;
    *)       warn "Unknown architecture '${ARCH}'; will try 'x64'."; MEL_ARCH="x64" ;;
esac

MEL_TAG="$(get_latest_release_tag "${MINEDLAUNCHER_REPO}")"
if [[ -z "${MEL_TAG}" ]]; then
    die "Could not retrieve the latest ED Mini Launcher release tag.
Check your internet connection or visit https://github.com/${MINEDLAUNCHER_REPO}/releases"
fi

# Try arch-specific asset first (e.g. linux-x64), then plain "linux".
MEL_URL="$(get_latest_release_url "${MINEDLAUNCHER_REPO}" "linux-${MEL_ARCH}")"
if [[ -z "${MEL_URL}" ]]; then
    MEL_URL="$(get_latest_release_url "${MINEDLAUNCHER_REPO}" "linux")"
fi
if [[ -z "${MEL_URL}" ]]; then
    die "Could not find a Linux release asset for ED Mini Launcher (${MEL_TAG}).
Check https://github.com/${MINEDLAUNCHER_REPO}/releases manually."
fi

ok "Latest ED Mini Launcher release: ${MEL_TAG}"

MEL_BIN="${MINEDLAUNCHER_INSTALL_DIR}/min-ed-launcher"
MEL_VERSION_FILE="${MINEDLAUNCHER_INSTALL_DIR}/.installed-version"
INSTALLED_MEL_TAG=""
if [[ -f "${MEL_VERSION_FILE}" ]]; then
    INSTALLED_MEL_TAG="$(<"${MEL_VERSION_FILE}")"
fi

if [[ "${INSTALLED_MEL_TAG}" == "${MEL_TAG}" && -x "${MEL_BIN}" ]]; then
    ok "ED Mini Launcher ${MEL_TAG} is already up to date. Skipping download."
else
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
    if [[ "${MEL_URL}" == *.tar.gz || "${MEL_URL}" == *.tgz ]]; then
        step "Extracting tar archive…"
        tar -xzf "${TMPASSET}" -C "${MINEDLAUNCHER_INSTALL_DIR}"
        # The binary may be nested inside a subdirectory.
        if [[ ! -f "${MEL_BIN}" ]]; then
            FOUND="$(find "${MINEDLAUNCHER_INSTALL_DIR}" -type f \
                        -name "min-ed-launcher" ! -name "*.version" | head -1)"
            if [[ -n "${FOUND}" && "${FOUND}" != "${MEL_BIN}" ]]; then
                mv "${FOUND}" "${MEL_BIN}"
            fi
        fi
    elif [[ "${MEL_URL}" == *.zip ]]; then
        step "Extracting zip archive…"
        unzip -q -o "${TMPASSET}" -d "${MINEDLAUNCHER_INSTALL_DIR}"
        if [[ ! -f "${MEL_BIN}" ]]; then
            FOUND="$(find "${MINEDLAUNCHER_INSTALL_DIR}" -type f \
                        -name "min-ed-launcher" ! -name "*.version" | head -1)"
            if [[ -n "${FOUND}" && "${FOUND}" != "${MEL_BIN}" ]]; then
                mv "${FOUND}" "${MEL_BIN}"
            fi
        fi
    else
        # Raw binary (no archive)
        step "Installing binary…"
        cp "${TMPASSET}" "${MEL_BIN}"
    fi

    chmod +x "${MEL_BIN}"
    echo "${MEL_TAG}" > "${MEL_VERSION_FILE}"
    rm -f "${TMPASSET}"
    trap - EXIT

    ok "ED Mini Launcher ${MEL_TAG} installed to ${MEL_BIN}"
fi

if [[ ! -x "${MEL_BIN}" ]]; then
    die "ED Mini Launcher binary not found / not executable at ${MEL_BIN}."
fi

# ---------------------------------------------------------------------------
# 5. Place srvsurvey.sh next to SrvSurvey.exe
# ---------------------------------------------------------------------------
heading "srvsurvey.sh launcher script"

SRVSURVEY_SH_DEST="${SRVSURVEY_INSTALL_DIR}/srvsurvey.sh"

# Prefer the copy shipped alongside this install.sh (same repo).
# Fall back to downloading from GitHub if install.sh was run standalone.
if [[ -f "${SCRIPT_DIR}/srvsurvey.sh" ]]; then
    step "Copying srvsurvey.sh from ${SCRIPT_DIR}…"
    cp "${SCRIPT_DIR}/srvsurvey.sh" "${SRVSURVEY_SH_DEST}"
else
    step "srvsurvey.sh not found alongside install.sh — downloading from GitHub…"
    curl -fsSL \
        "https://raw.githubusercontent.com/mfairchild365/ed-srv-survey-linux-helper/main/srvsurvey.sh" \
        -o "${SRVSURVEY_SH_DEST}"
fi

chmod +x "${SRVSURVEY_SH_DEST}"
ok "srvsurvey.sh installed at ${SRVSURVEY_SH_DEST}"

# ---------------------------------------------------------------------------
# 6. Configure ED Mini Launcher settings.toml
# ---------------------------------------------------------------------------
heading "ED Mini Launcher configuration (settings.toml)"

MEL_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/min-ed-launcher"
MEL_CONFIG="${MEL_CONFIG_DIR}/settings.toml"
mkdir -p "${MEL_CONFIG_DIR}"

configure_toml() {
    local entry_path_line="  path = \"${SRVSURVEY_SH_DEST}\""

    if [[ ! -f "${MEL_CONFIG}" ]]; then
        # Create a minimal settings.toml with the autorun entry.
        step "Creating ${MEL_CONFIG}…"
        cat > "${MEL_CONFIG}" <<EOF
# ED Mini Launcher configuration
# See: https://github.com/rfvgyhn/min-ed-launcher#configuration

[autorun]

[[autorun.entries]]
  path = "${SRVSURVEY_SH_DEST}"
EOF
        ok "Created ${MEL_CONFIG}"
        return
    fi

    # File already exists — check whether our exact path is already present.
    if grep -qF "${SRVSURVEY_SH_DEST}" "${MEL_CONFIG}"; then
        ok "settings.toml already contains the srvsurvey.sh entry. No changes needed."
        return
    fi

    # A srvsurvey.sh entry from a previous (different-path) install exists —
    # update the path in-place.
    if grep -q "srvsurvey\.sh" "${MEL_CONFIG}"; then
        step "Updating existing srvsurvey.sh path in settings.toml…"
        sed -i "s|.*srvsurvey\.sh.*|${entry_path_line}|" "${MEL_CONFIG}"
        ok "Updated srvsurvey.sh path in ${MEL_CONFIG}"
        return
    fi

    # Append the entry to an existing [autorun] section, or add one.
    step "Adding srvsurvey.sh autorun entry to ${MEL_CONFIG}…"
    if grep -q '^\[autorun\]' "${MEL_CONFIG}"; then
        printf '\n[[autorun.entries]]\n  path = "%s"\n' "${SRVSURVEY_SH_DEST}" \
            >> "${MEL_CONFIG}"
    else
        printf '\n[autorun]\n\n[[autorun.entries]]\n  path = "%s"\n' \
            "${SRVSURVEY_SH_DEST}" >> "${MEL_CONFIG}"
    fi
    ok "Appended srvsurvey.sh autorun entry to ${MEL_CONFIG}"
}

configure_toml

# ---------------------------------------------------------------------------
# 7. Summary and remaining manual step
# ---------------------------------------------------------------------------
heading "Installation complete"

ok "SrvSurvey ${SRVSURVEY_TAG}        → ${SRVSURVEY_INSTALL_DIR}"
ok "ED Mini Launcher ${MEL_TAG}  → ${MEL_BIN}"
ok "srvsurvey.sh                      → ${SRVSURVEY_SH_DEST}"
ok "settings.toml                     → ${MEL_CONFIG}"
if [[ -n "${ELITE_STEAMAPPS}" ]]; then
    ok "Elite Dangerous                  → ${ELITE_STEAMAPPS}/common/Elite Dangerous"
fi

echo ""
echo -e "${BOLD}${YELLOW}One manual step remaining — set the Steam launch option:${NC}"
echo ""
echo "  In Steam, right-click Elite Dangerous → Properties → General."
echo "  Set 'Launch Options' to:"
echo ""
echo -e "    ${CYAN}${MEL_BIN} %command%${NC}"
echo ""
echo "  Then launch Elite Dangerous through Steam as normal."
echo "  ED Mini Launcher will start SrvSurvey automatically alongside the game."
echo ""

if [[ -n "${ELITE_STEAMAPPS}" \
      && ! -d "${ELITE_STEAMAPPS}/compatdata/${ELITE_APP_ID}/pfx" ]]; then
    echo -e "${YELLOW}  Note:${NC} The Elite Dangerous Proton prefix was not found."
    echo "  Before setting the launch option, launch Elite once with Proton enabled:"
    echo "  Steam → Elite Dangerous → Properties → Compatibility → Proton Experimental."
    echo ""
fi
