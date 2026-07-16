#!/usr/bin/env bash
# 离线验证：单独下载 install.sh 时能否拉取并识别完整项目。

set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${ROOT_DIR}/.bootstrap-test.XXXXXX")

cleanup() {
    case "$TEST_TMP" in
        "${ROOT_DIR}"/.bootstrap-test.*) rm -rf -- "$TEST_TMP" ;;
    esac
}
trap cleanup EXIT

mkdir -p "${TEST_TMP}/archive/Ping-WireGuard-main"
cp -R "$ROOT_DIR/install.sh" "$ROOT_DIR/ping-wg.sh" "$ROOT_DIR/scripts" "$ROOT_DIR/templates" \
    "${TEST_TMP}/archive/Ping-WireGuard-main/"
tar -czf "${TEST_TMP}/project.tar.gz" -C "${TEST_TMP}/archive" Ping-WireGuard-main
cp "$ROOT_DIR/install.sh" "${TEST_TMP}/standalone-install.sh"

output=$(PING_WG_BOOTSTRAP_ONLY=1 \
    PING_WG_ARCHIVE_URL="${TEST_TMP}/project.tar.gz" \
    bash "${TEST_TMP}/standalone-install.sh")

[[ $output == *BOOTSTRAP_OK* ]] || {
    printf 'FAIL: install.sh 自举测试失败\n%s\n' "$output" >&2
    exit 1
}

printf 'PASS: install.sh 单文件自举测试通过\n'
