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
    grep -Fq "$expected" "$file_path" || fail "expected '$expected' in $file_path"
}

assert_output_contains() {
    local output_file="$1"
    local expected="$2"
    grep -Fq "$expected" "$output_file" || fail "expected output '$expected' in $output_file"
}

assert_wine_arg_present() {
    local log_file="$1"
    local expected_arg="$2"
    if ! grep -Fq "arg=${expected_arg}" "$log_file"; then
        echo "--- ${log_file} ---" >&2
        cat "$log_file" >&2 || true
        fail "expected wine arg '${expected_arg}' in $log_file"
    fi
}

assert_wine_log_contains() {
    local log_file="$1"
    local expected="$2"
    grep -Fq "$expected" "$log_file" || fail "expected '$expected' in $log_file"
}

make_temp_dir() {
    local tmp_base="${TMPDIR:-/tmp}"
    mktemp -d "${tmp_base%/}/srvsurvey-test-XXXXXX"
}

cleanup() {
    if [[ -n "${TEST_TMP_ROOT}" && -d "${TEST_TMP_ROOT}" ]]; then
        rm -rf "${TEST_TMP_ROOT}"
    fi
}
trap cleanup EXIT

write_wine_stub() {
    local file_path="$1"
    cat > "${file_path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'argv0=%s\n' "$0"
    printf 'env_LD_PRELOAD=%s\n' "${LD_PRELOAD-__unset__}"
    printf 'env_LD_LIBRARY_PATH=%s\n' "${LD_LIBRARY_PATH-__unset__}"
    printf 'env_WINEPREFIX=%s\n' "${WINEPREFIX-__unset__}"
    for arg in "$@"; do
        printf 'arg=%s\n' "$arg"
    done
} >> "${SRV_TEST_WINE_LOG}"
exit 0
EOF
    chmod +x "${file_path}"
}

prepare_env() {
    local test_name="$1"
    local test_tmp_root
    test_tmp_root="$(make_temp_dir)"

    local launcher_dir="${test_tmp_root}/${test_name}/launcher"
    local srv_dir="${launcher_dir}/SrvSurvey"
    local bin_dir="${test_tmp_root}/${test_name}/bin"
    local steamapps_dir="${test_tmp_root}/${test_name}/Steam/steamapps"
    local compat_dir="${steamapps_dir}/compatdata/359320"
    local prefix_dir="${compat_dir}/pfx"

    mkdir -p "${launcher_dir}" "${srv_dir}" "${bin_dir}" "${prefix_dir}"
    cp "${REPO_ROOT}/srvsurvey.sh" "${launcher_dir}/srvsurvey.sh"
    printf 'fake exe\n' > "${srv_dir}/SrvSurvey.exe"

    echo "${test_tmp_root}|${launcher_dir}|${srv_dir}|${bin_dir}|${steamapps_dir}|${compat_dir}"
}

run_srvsurvey() {
    local launcher_dir="$1"
    local bin_dir="$2"
    local output_file="$3"
    local wine_log="$4"
    local explicit_dir="${5:-}"
    shift 5 || true

    if [[ -n "${explicit_dir}" ]]; then
        env PATH="${bin_dir}:${PATH}" \
            SRV_TEST_WINE_LOG="${wine_log}" \
            "$@" \
            bash "${launcher_dir}/srvsurvey.sh" "${explicit_dir}" > "${output_file}" 2>&1
    else
        env PATH="${bin_dir}:${PATH}" \
            SRV_TEST_WINE_LOG="${wine_log}" \
            "$@" \
            bash "${launcher_dir}/srvsurvey.sh" > "${output_file}" 2>&1
    fi
}

test_prefers_wineloader_and_default_dir() {
    local setup
    setup="$(prepare_env wineloader-default)"
    local launcher_dir srv_dir bin_dir steamapps_dir compat_dir
    IFS='|' read -r TEST_TMP_ROOT launcher_dir srv_dir bin_dir steamapps_dir compat_dir <<< "${setup}"

    local wine_log="${TEST_TMP_ROOT}/wine.log"
    local output_file="${TEST_TMP_ROOT}/stdout.log"
    local wineloader="${TEST_TMP_ROOT}/custom-wine64"
    write_wine_stub "${wineloader}"

    run_srvsurvey "${launcher_dir}" "${bin_dir}" "${output_file}" "${wine_log}" "" \
        WINELOADER="${wineloader}" \
        SRVSURVEY_DELAY=0

    assert_file_exists "${wine_log}"
    assert_wine_arg_present "${wine_log}" "${srv_dir}/SrvSurvey.exe"
    assert_wine_arg_present "${wine_log}" "-linux"
    assert_output_contains "${output_file}" "Using Wine binary: ${wineloader}"
    pass "prefers WINELOADER with default SrvSurvey dir"
}

test_uses_steam_compat_proton_wine() {
    local setup
    setup="$(prepare_env proton-fallback)"
    local launcher_dir srv_dir bin_dir steamapps_dir compat_dir
    IFS='|' read -r TEST_TMP_ROOT launcher_dir srv_dir bin_dir steamapps_dir compat_dir <<< "${setup}"

    local wine_log="${TEST_TMP_ROOT}/wine.log"
    local output_file="${TEST_TMP_ROOT}/stdout.log"
    local proton_wine="${steamapps_dir}/common/Proton Experimental Custom/files/bin/wine64"
    mkdir -p "$(dirname "${proton_wine}")"
    write_wine_stub "${proton_wine}"

    run_srvsurvey "${launcher_dir}" "${bin_dir}" "${output_file}" "${wine_log}" "" \
        SRVSURVEY_DELAY=0 \
        STEAM_COMPAT_DATA_PATH="${compat_dir}"

    assert_wine_arg_present "${wine_log}" "${srv_dir}/SrvSurvey.exe"
    assert_wine_arg_present "${wine_log}" "-linux"
    assert_wine_log_contains "${wine_log}" "env_WINEPREFIX=${compat_dir}/pfx"
    assert_output_contains "${output_file}" "Using Wine binary: ${proton_wine}"
    pass "uses Proton wine derived from STEAM_COMPAT_DATA_PATH"
}

test_falls_back_to_system_wine64_and_honors_delay() {
    local setup
    setup="$(prepare_env system-wine)"
    local launcher_dir srv_dir bin_dir steamapps_dir compat_dir
    IFS='|' read -r TEST_TMP_ROOT launcher_dir srv_dir bin_dir steamapps_dir compat_dir <<< "${setup}"

    local wine_log="${TEST_TMP_ROOT}/wine.log"
    local output_file="${TEST_TMP_ROOT}/stdout.log"
    local sleep_log="${TEST_TMP_ROOT}/sleep.log"

    write_wine_stub "${bin_dir}/wine64"
    cat > "${bin_dir}/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${SRV_TEST_SLEEP_LOG}"
exit 0
EOF
    chmod +x "${bin_dir}/sleep"

    run_srvsurvey "${launcher_dir}" "${bin_dir}" "${output_file}" "${wine_log}" "" \
        SRV_TEST_SLEEP_LOG="${sleep_log}" \
        SRVSURVEY_DELAY=7

    assert_file_contains "${sleep_log}" "7"
    assert_wine_arg_present "${wine_log}" "${srv_dir}/SrvSurvey.exe"
    assert_wine_arg_present "${wine_log}" "-linux"
    assert_output_contains "${output_file}" "Using Wine binary: wine64"
    pass "falls back to system wine64 and honors delay"
}

test_sanitizes_steam_runtime_environment() {
    local setup
    setup="$(prepare_env sanitize-env)"
    local launcher_dir srv_dir bin_dir steamapps_dir compat_dir
    IFS='|' read -r TEST_TMP_ROOT launcher_dir srv_dir bin_dir steamapps_dir compat_dir <<< "${setup}"

    local wine_log="${TEST_TMP_ROOT}/wine.log"
    local output_file="${TEST_TMP_ROOT}/stdout.log"
    local log_file="${TEST_TMP_ROOT}/home/.local/state/ed-srv-survey-helper/srvsurvey.log"

    mkdir -p "${TEST_TMP_ROOT}/home"
    write_wine_stub "${bin_dir}/wine64"

    run_srvsurvey "${launcher_dir}" "${bin_dir}" "${output_file}" "${wine_log}" "" \
        HOME="${TEST_TMP_ROOT}/home" \
        SRVSURVEY_DELAY=0 \
        LD_PRELOAD="/usr/lib/extest/libextest.so" \
        LD_LIBRARY_PATH="/steam/runtime/lib" \
        MEL_LD_LIBRARY_PATH="/host/runtime/lib"

    assert_file_exists "${log_file}"
    assert_output_contains "${output_file}" "Clearing LD_PRELOAD for helper launch"
    assert_output_contains "${output_file}" "Restoring host LD_LIBRARY_PATH from MEL_LD_LIBRARY_PATH"
    assert_wine_log_contains "${wine_log}" 'env_LD_PRELOAD=__unset__'
    assert_wine_log_contains "${wine_log}" 'env_LD_LIBRARY_PATH=/host/runtime/lib'
    pass "sanitizes Steam runtime environment before launching Wine"
}

test_uses_tmp_log_when_home_missing() {
    local setup
    setup="$(prepare_env tmp-log)"
    local launcher_dir srv_dir bin_dir steamapps_dir compat_dir
    IFS='|' read -r TEST_TMP_ROOT launcher_dir srv_dir bin_dir steamapps_dir compat_dir <<< "${setup}"

    local wine_log="${TEST_TMP_ROOT}/wine.log"
    local output_file="${TEST_TMP_ROOT}/stdout.log"
    local tmp_base="${TEST_TMP_ROOT}/tmp"
    local fallback_log="${tmp_base}/ed-srv-survey-helper/srvsurvey.log"

    mkdir -p "${tmp_base}"
    write_wine_stub "${bin_dir}/wine64"

    env -u HOME -u XDG_STATE_HOME \
        TMPDIR="${tmp_base}" \
        PATH="${bin_dir}:${PATH}" \
        SRV_TEST_WINE_LOG="${wine_log}" \
        SRVSURVEY_DELAY=0 \
        bash "${launcher_dir}/srvsurvey.sh" > "${output_file}" 2>&1

    assert_file_exists "${fallback_log}"
    assert_file_contains "${fallback_log}" "Logging to ${fallback_log}"
    pass "writes helper log to TMPDIR when HOME is unavailable"
}

test_errors_when_srvsurvey_dir_missing() {
    local setup
    setup="$(prepare_env missing-dir)"
    local launcher_dir srv_dir bin_dir steamapps_dir compat_dir
    IFS='|' read -r TEST_TMP_ROOT launcher_dir srv_dir bin_dir steamapps_dir compat_dir <<< "${setup}"

    rm -rf "${srv_dir}"
    local output_file="${TEST_TMP_ROOT}/stderr.log"

    if env PATH="${bin_dir}:${PATH}" bash "${launcher_dir}/srvsurvey.sh" > "${output_file}" 2>&1; then
        fail "expected srvsurvey.sh to fail when SrvSurvey directory is missing"
    fi

    assert_output_contains "${output_file}" "ERROR: SrvSurvey directory not found"
    pass "fails clearly when SrvSurvey directory is missing"
}

test_errors_when_no_wine_binary_found() {
    local setup
    setup="$(prepare_env missing-wine)"
    local launcher_dir srv_dir bin_dir steamapps_dir compat_dir
    IFS='|' read -r TEST_TMP_ROOT launcher_dir srv_dir bin_dir steamapps_dir compat_dir <<< "${setup}"

    local output_file="${TEST_TMP_ROOT}/stderr.log"

    if env PATH="${bin_dir}:${PATH}" \
        SRVSURVEY_DELAY=0 \
        WINELOADER="" \
        bash "${launcher_dir}/srvsurvey.sh" > "${output_file}" 2>&1; then
        fail "expected srvsurvey.sh to fail when no Wine binary is available"
    fi

    assert_output_contains "${output_file}" "ERROR: Could not locate a Wine or Proton binary"
    pass "fails clearly when no Wine binary is available"
}

main() {
    test_prefers_wineloader_and_default_dir
    TESTS_RUN=$((TESTS_RUN + 1))
    test_uses_steam_compat_proton_wine
    TESTS_RUN=$((TESTS_RUN + 1))
    test_falls_back_to_system_wine64_and_honors_delay
    TESTS_RUN=$((TESTS_RUN + 1))
    test_sanitizes_steam_runtime_environment
    TESTS_RUN=$((TESTS_RUN + 1))
    test_uses_tmp_log_when_home_missing
    TESTS_RUN=$((TESTS_RUN + 1))
    test_errors_when_srvsurvey_dir_missing
    TESTS_RUN=$((TESTS_RUN + 1))
    test_errors_when_no_wine_binary_found
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "1..${TESTS_RUN}"
}

main "$@"
