#!/usr/bin/env bash
# Download, verify, install, and launch Debian Security Check.

set -euo pipefail

REPOSITORY="elonjack/debian-security-check"
RELEASE_TAG="v1.4.1"
BASE_URL="${DEBIAN_SECURITY_CHECK_BASE_URL:-https://github.com/${REPOSITORY}/releases/download/${RELEASE_TAG}}"
INSTALL_DIR="${DEBIAN_SECURITY_CHECK_DIR:-${HOME}/debian-security-check}"
PAYLOAD="debian-security-check.sh"
CHECKSUMS="SHA256SUMS"

die() {
  printf '安装失败：%s\n' "$*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || die "缺少 curl，请先安装：apt-get update && apt-get install -y curl"
command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum（coreutils）。"
command -v install >/dev/null 2>&1 || die "缺少 install（coreutils）。"

TMP_DIR="$(mktemp -d)"
trap 'rm -f -- "$TMP_DIR/$PAYLOAD" "$TMP_DIR/$CHECKSUMS"; rmdir -- "$TMP_DIR" 2>/dev/null || true' EXIT

printf '正在从 GitHub Release 下载正式版本……\n'
curl --proto '=https' --tlsv1.2 -fL --retry 3 -o "$TMP_DIR/$PAYLOAD" "$BASE_URL/$PAYLOAD"
curl --proto '=https' --tlsv1.2 -fL --retry 3 -o "$TMP_DIR/$CHECKSUMS" "$BASE_URL/$CHECKSUMS"

printf '正在校验 SHA-256……\n'
EXPECTED_LINE="$(grep -E "^[[:xdigit:]]{64}  ${PAYLOAD}$" "$TMP_DIR/$CHECKSUMS" || true)"
[[ -n "$EXPECTED_LINE" ]] || die "校验文件中没有找到 $PAYLOAD。"
printf '%s\n' "$EXPECTED_LINE" | (cd "$TMP_DIR" && sha256sum -c -) || die "SHA-256 校验失败，已停止执行。"

mkdir -p "$INSTALL_DIR"
install -m 0755 "$TMP_DIR/$PAYLOAD" "$INSTALL_DIR/$PAYLOAD"
install -m 0644 "$TMP_DIR/$CHECKSUMS" "$INSTALL_DIR/$CHECKSUMS"

# exec does not trigger an EXIT trap, so remove temporary files before launching.
rm -f -- "$TMP_DIR/$PAYLOAD" "$TMP_DIR/$CHECKSUMS"
rmdir -- "$TMP_DIR"
trap - EXIT

printf '已安装到：%s\n' "$INSTALL_DIR/$PAYLOAD"

if [[ "${DEBIAN_SECURITY_CHECK_INSTALL_ONLY:-0}" == "1" ]]; then
  exit 0
fi

if [[ -r /dev/tty ]]; then
  exec bash "$INSTALL_DIR/$PAYLOAD" </dev/tty
fi

printf '当前没有交互式终端，将执行普通检查模式。\n'
exec bash "$INSTALL_DIR/$PAYLOAD" --check
