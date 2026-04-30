#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_ROOT=""
TESTS_RUN=0

fail() {
    echo "not ok - $*" >&2
    exit 1
}

pass() {
    echo "ok - $*"
}

assert_file_exists() {
    local file_path="$1"
    [[ -e "$file_path" ]] || fail "expected file to exist: $file_path"
}

assert_file_contains() {
    local file_path="$1"
    local expected="$2"
    grep -Fq -- "$expected" "$file_path" || fail "expected '$expected' in $file_path"
}

assert_file_not_contains() {
    local file_path="$1"
    local unexpected="$2"
    if grep -Fq -- "$unexpected" "$file_path"; then
        fail "did not expect '$unexpected' in $file_path"
    fi
}

assert_output_contains() {
    local output_file="$1"
    local expected="$2"
    grep -Fq -- "$expected" "$output_file" || fail "expected '$expected' in $output_file"
}

assert_file_not_exists() {
    local file_path="$1"
    [[ ! -e "$file_path" ]] || fail "did not expect file to exist: $file_path"
}

make_temp_dir() {
    local tmp_base="${TMPDIR:-/tmp}"
    mktemp -d "${tmp_base%/}/install-test-XXXXXX"
}

cleanup() {
    if [[ -n "${TEST_TMP_ROOT}" && -d "${TEST_TMP_ROOT}" ]]; then
        rm -rf "${TEST_TMP_ROOT}"
    fi
}
trap cleanup EXIT

write_mock_commands() {
    local bin_dir="$1"

    cat > "${bin_dir}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)
            output="$2"
            shift 2
            ;;
        -H|--header)
            shift 2
            ;;
        -f|-s|-S|-L|--progress-bar|-fsSL)
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done

if [[ -n "${output}" ]]; then
    case "${url}" in
        *SrvSurvey*.zip)
            printf 'fake-srvsurvey-archive\n' > "${output}"
            ;;
        *.tar.gz|*.tgz)
            printf 'fake-tar-archive\n' > "${output}"
            ;;
        *linux-x64*|*linux-arm64*|*min-ed-launcher*)
            cat > "${output}" <<'BIN'
#!/usr/bin/env bash
exit 0
BIN
            ;;
        *raw.githubusercontent.com*srvsurvey.sh)
            cp "${REPO_ROOT}/srvsurvey.sh" "${output}"
            ;;
        *)
            printf 'downloaded\n' > "${output}"
            ;;
    esac
    exit 0
fi

case "${url}" in
    *repos/njthomson/SrvSurvey/releases/latest*)
        cat <<'JSON'
{
  "tag_name": "v1.2.3",
  "browser_download_url": "https://example.test/SrvSurvey-v1.2.3.zip"
}
JSON
        ;;
    *repos/rfvgyhn/min-ed-launcher/releases/latest*)
        cat <<'JSON'
{
  "tag_name": "v4.5.6",
    "browser_download_url": "https://example.test/min-ed-launcher_v4.5.6_linux-x64.tar.gz"
}
JSON
        ;;
    *)
        echo "unexpected curl url: ${url}" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "${bin_dir}/curl"

    cat > "${bin_dir}/unzip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

destination=""
archive=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)
            destination="$2"
            shift 2
            ;;
        -q|-o)
            shift
            ;;
        *)
            archive="$1"
            shift
            ;;
    esac
done

mkdir -p "${destination}"
if [[ "${archive}" == *SrvSurvey* ]]; then
    printf 'fake exe\n' > "${destination}/SrvSurvey.exe"
else
    cat > "${destination}/min-ed-launcher" <<'BIN'
#!/usr/bin/env bash
exit 0
BIN
    chmod +x "${destination}/min-ed-launcher"
fi
EOF
    chmod +x "${bin_dir}/unzip"

    cat > "${bin_dir}/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-m" ]]; then
    printf '%s\n' "${MOCK_UNAME_M:-x86_64}"
else
    /usr/bin/uname "$@"
fi
EOF
    chmod +x "${bin_dir}/uname"

    cat > "${bin_dir}/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

destination=""
archive=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -C)
            destination="$2"
            shift 2
            ;;
        -xzf)
            archive="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

mkdir -p "${destination}/release-dir"
cat > "${destination}/release-dir/MinEdLauncher" <<'BIN'
#!/usr/bin/env bash
exit 0
BIN
chmod +x "${destination}/release-dir/MinEdLauncher"
EOF
    chmod +x "${bin_dir}/tar"

    cat > "${bin_dir}/sed" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
    if [[ "${MOCK_SED_STYLE:-gnu}" == "bsd" ]]; then
        exit 1
    fi
    echo "sed (GNU sed) mock"
    exit 0
fi

if [[ "${1:-}" == "-i" ]]; then
    shift
    if [[ "${1:-}" == "" ]]; then
        shift
    fi

    expr="$1"
    file_path="$2"
    IFS='|' read -r _ _ replacement _ <<< "${expr}"

    tmp_file="${file_path}.tmp"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^[[:space:]]*path[[:space:]]*=.*srvsurvey\.sh.*$ ]]; then
            printf '%s\n' "${replacement}" >> "${tmp_file}"
        else
            printf '%s\n' "${line}" >> "${tmp_file}"
        fi
    done < "${file_path}"
    mv "${tmp_file}" "${file_path}"
    exit 0
fi

expr="$1"
if [[ "${expr}" == *'"tag_name"'* ]]; then
    while IFS= read -r line; do
        if [[ "${line}" =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
        fi
    done
    exit 0
fi

if [[ "${expr}" == *'"browser_download_url"'* ]]; then
    while IFS= read -r line; do
        if [[ "${line}" =~ \"browser_download_url\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
        fi
    done
    exit 0
fi

cat
EOF
    chmod +x "${bin_dir}/sed"

    cat > "${bin_dir}/protontricks" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${HOME}/protontricks.log"

if [[ "${MOCK_PROTONTRICKS_FAIL:-0}" == "1" ]]; then
    exit 1
fi

prefix_dir="${HOME}/.local/share/Steam/steamapps/compatdata/359320/pfx/drive_c/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App/9.0.0"
mkdir -p "${prefix_dir}"
exit 0
EOF
    chmod +x "${bin_dir}/protontricks"
}

prepare_env() {
    local test_name="$1"
    local test_tmp_root
    test_tmp_root="$(make_temp_dir)"

    local home_dir="${test_tmp_root}/${test_name}/home"
    local install_dir="${test_tmp_root}/${test_name}/install"
    local bin_dir="${test_tmp_root}/${test_name}/bin"

    mkdir -p "${home_dir}/.local/share/Steam/steamapps/common/Elite Dangerous"
    mkdir -p "${home_dir}/.local/share/Steam/steamapps/compatdata/359320/pfx"
    mkdir -p "${home_dir}/.config"
    mkdir -p "${bin_dir}"

    write_mock_commands "${bin_dir}"

    echo "${test_tmp_root}|${home_dir}|${install_dir}|${bin_dir}"
}

run_install() {
    local home_dir="$1"
    local install_dir="$2"
    local bin_dir="$3"
    local sed_style="${4:-gnu}"
    local output_file="$5"

    (
        export REPO_ROOT
        export HOME="${home_dir}"
        export XDG_CONFIG_HOME="${home_dir}/.config"
        export PATH="${bin_dir}:${PATH}"
        export CI=1
        export INSTALL_SH_NO_WAIT=1
        export MOCK_SED_STYLE="${sed_style}"
        bash "${REPO_ROOT}/install.sh" --install-dir "${install_dir}"
    ) > "${output_file}" 2>&1
}

test_fresh_install_creates_files() {
    local setup
    setup="$(prepare_env fresh)"
    local home_dir install_dir bin_dir
    IFS='|' read -r TEST_TMP_ROOT home_dir install_dir bin_dir <<< "${setup}"

    run_install "${home_dir}" "${install_dir}" "${bin_dir}" gnu "${TEST_TMP_ROOT}/fresh.log"

    assert_file_exists "${install_dir}/SrvSurvey/SrvSurvey.exe"
    assert_file_exists "${install_dir}/SrvSurvey/srvsurvey.sh"
    assert_file_exists "${install_dir}/min-ed-launcher/min-ed-launcher"
        assert_file_exists "${home_dir}/.config/min-ed-launcher/settings.json"
        assert_file_contains "${home_dir}/.config/min-ed-launcher/settings.json" '"processes": ['
            assert_file_contains "${home_dir}/.config/min-ed-launcher/settings.json" '"keepOpen": true'
        assert_file_contains "${home_dir}/.config/min-ed-launcher/settings.json" "\"fileName\": \"${install_dir}/SrvSurvey/srvsurvey.sh\""
    assert_file_contains "${install_dir}/SrvSurvey/.installed-version" "v1.2.3"
    assert_file_contains "${install_dir}/min-ed-launcher/.installed-version" "v4.5.6"
    assert_file_contains "${home_dir}/protontricks.log" '-q 359320 dotnetdesktop9'
        assert_output_contains "${TEST_TMP_ROOT}/fresh.log" "%command% /autorun /autoquit"
    pass "fresh install creates expected files"
}

test_skips_dotnet_install_when_runtime_exists() {
    local setup
    setup="$(prepare_env dotnet-present)"
    local home_dir install_dir bin_dir
    IFS='|' read -r TEST_TMP_ROOT home_dir install_dir bin_dir <<< "${setup}"

    mkdir -p "${home_dir}/.local/share/Steam/steamapps/compatdata/359320/pfx/drive_c/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App/9.0.12"

    run_install "${home_dir}" "${install_dir}" "${bin_dir}" gnu "${TEST_TMP_ROOT}/dotnet-present.log"

    assert_output_contains "${TEST_TMP_ROOT}/dotnet-present.log" '.NET Desktop Runtime 9 is already present'
    assert_file_not_exists "${home_dir}/protontricks.log"
    pass "skips dotnetdesktop9 install when runtime already exists"
}

test_existing_process_path_updates_in_json() {
    local setup
        setup="$(prepare_env update-json)"
    local home_dir install_dir bin_dir
    IFS='|' read -r TEST_TMP_ROOT home_dir install_dir bin_dir <<< "${setup}"

    mkdir -p "${home_dir}/.config/min-ed-launcher"
        cat > "${home_dir}/.config/min-ed-launcher/settings.json" <<'EOF'
{
    "language": "en",
    "processes": [
        {
            "fileName": "/old/location/srvsurvey.sh"
        }
    ]
}
EOF

        run_install "${home_dir}" "${install_dir}" "${bin_dir}" gnu "${TEST_TMP_ROOT}/update-json.log"

        assert_file_contains "${home_dir}/.config/min-ed-launcher/settings.json" '"language": "en"'
        assert_file_contains "${home_dir}/.config/min-ed-launcher/settings.json" "\"fileName\": \"${install_dir}/SrvSurvey/srvsurvey.sh\""
            assert_file_contains "${home_dir}/.config/min-ed-launcher/settings.json" '"keepOpen": true'
        assert_file_not_contains "${home_dir}/.config/min-ed-launcher/settings.json" '"fileName": "/old/location/srvsurvey.sh"'
        pass "existing srvsurvey process path updates in settings.json"
}

test_process_entry_appends_to_existing_processes() {
    local setup
    setup="$(prepare_env append-json)"
    local home_dir install_dir bin_dir
    IFS='|' read -r TEST_TMP_ROOT home_dir install_dir bin_dir <<< "${setup}"

    mkdir -p "${home_dir}/.config/min-ed-launcher"
    cat > "${home_dir}/.config/min-ed-launcher/settings.json" <<'EOF'
{
  "gameStartDelay": 2,
  "processes": [
    {
      "fileName": "/usr/bin/existing-helper",
      "arguments": "--demo"
    }
  ]
}
EOF

    run_install "${home_dir}" "${install_dir}" "${bin_dir}" gnu "${TEST_TMP_ROOT}/append.log"

    assert_file_contains "${home_dir}/.config/min-ed-launcher/settings.json" '"gameStartDelay": 2'
    assert_file_contains "${home_dir}/.config/min-ed-launcher/settings.json" '"fileName": "/usr/bin/existing-helper"'
    assert_file_contains "${home_dir}/.config/min-ed-launcher/settings.json" "\"fileName\": \"${install_dir}/SrvSurvey/srvsurvey.sh\""
    assert_file_contains "${home_dir}/.config/min-ed-launcher/settings.json" '"keepOpen": true'
    pass "srvsurvey process entry appends to existing settings.json"
}

test_stale_srvsurvey_script_is_replaced() {
    local setup
    setup="$(prepare_env refresh-script)"
    local home_dir install_dir bin_dir
    IFS='|' read -r TEST_TMP_ROOT home_dir install_dir bin_dir <<< "${setup}"

    mkdir -p "${install_dir}/SrvSurvey"
    printf 'fake exe\n' > "${install_dir}/SrvSurvey/SrvSurvey.exe"
    cat > "${install_dir}/SrvSurvey/srvsurvey.sh" <<'EOF'
#!/usr/bin/env bash
echo old-helper
EOF
    chmod +x "${install_dir}/SrvSurvey/srvsurvey.sh"

    run_install "${home_dir}" "${install_dir}" "${bin_dir}" gnu "${TEST_TMP_ROOT}/refresh-script.log"

    assert_file_contains "${install_dir}/SrvSurvey/srvsurvey.sh" 'Logging to ${LOG_FILE}'
    assert_file_not_contains "${install_dir}/SrvSurvey/srvsurvey.sh" 'echo old-helper'
    pass "stale srvsurvey.sh is refreshed on normal install"
}

main() {
    test_fresh_install_creates_files
    TESTS_RUN=$((TESTS_RUN + 1))
    test_existing_process_path_updates_in_json
    TESTS_RUN=$((TESTS_RUN + 1))
    test_process_entry_appends_to_existing_processes
    TESTS_RUN=$((TESTS_RUN + 1))
    test_stale_srvsurvey_script_is_replaced
    TESTS_RUN=$((TESTS_RUN + 1))
    test_skips_dotnet_install_when_runtime_exists
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "1..${TESTS_RUN}"
}

main "$@"
