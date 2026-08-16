#!/usr/bin/env bash
# 安全安装器：下载固定 Release 资产并用内置 SHA-256 校验后安装。
set -Eeuo pipefail

readonly VERSION='2.0.0'
readonly REPOSITORY='elonjack/vps-tcp-safe-tuner'
readonly EXPECTED_SHA256='0e352d9a52c036c8bf370ce605dd96b4ff5b0c3deab8f3261a162dcb6523c7bd'
readonly DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/download/v$VERSION/vps-tcp-tune.sh"
readonly INSTALL_PATH='/usr/local/bin/vps-tcp-tune'

yellow() { if [[ -t 1 ]]; then printf '\033[1;33m%s\033[0m' "$*"; else printf '%s' "$*"; fi; }
say() { yellow "[安装] $*"; printf '\n'; }
fail() { yellow "[错误] $*" >&2; printf '\n' >&2; exit 1; }

[[ $(uname -s) == Linux ]] || fail '仅支持 Linux。'
command -v curl >/dev/null 2>&1 || fail '需要 curl。'
command -v sha256sum >/dev/null 2>&1 || fail '需要 sha256sum。'

temporary_file=$(mktemp)
trap 'rm -f "$temporary_file"' EXIT
say "下载并校验 v$VERSION。"
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 "$DOWNLOAD_URL" -o "$temporary_file"
actual_sha256=$(sha256sum "$temporary_file" | awk '{print tolower($1)}')
[[ $actual_sha256 == "$EXPECTED_SHA256" ]] || fail 'SHA-256 校验失败，未安装任何文件。'

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  install -D -m 755 "$temporary_file" "$INSTALL_PATH"
else
  command -v sudo >/dev/null 2>&1 || fail '需要 root 或 sudo。'
  sudo install -D -m 755 "$temporary_file" "$INSTALL_PATH"
fi
say "安装完成：$INSTALL_PATH"
say '运行：sudo vps-tcp-tune audit'
