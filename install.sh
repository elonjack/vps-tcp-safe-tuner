#!/usr/bin/env bash
# 安全安装器：下载固定 Release 资产或读取显式本地文件，并用内置 SHA-256 校验后安装。
set -Eeuo pipefail

readonly VERSION='6.0.0'
readonly REPOSITORY='elonjack/vps-tcp-safe-tuner'
readonly EXPECTED_SHA256='0a1a3a50e45233aebc012d35da55c44a5a0e44971176327d105ee874d12060cf'
readonly DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/download/v$VERSION/vps-tcp-tune.sh"
readonly INSTALL_PATH='/usr/local/bin/vps-tcp-tune'

yellow() { if [[ -t 1 ]]; then printf '\033[1;33m%s\033[0m' "$*"; else printf '%s' "$*"; fi; }
say() { yellow "[安装] $*"; printf '\n'; }
fail() { yellow "[错误] $*" >&2; printf '\n' >&2; exit 1; }

[[ $(uname -s) == Linux ]] || fail '仅支持 Linux。'
command -v sha256sum >/dev/null 2>&1 || fail '需要 sha256sum。'

temporary_file=$(mktemp)
trap 'rm -f "$temporary_file"' EXIT
if [[ ${1:-} == --local ]]; then
  [[ $# -eq 2 && -f ${2:-} && ! -L ${2:-} ]] || fail '用法：install.sh --local ./vps-tcp-tune.sh'
  say "读取并校验本地 v$VERSION 脚本：$2"
  cp -- "$2" "$temporary_file"
elif [[ $# -eq 0 ]]; then
  command -v curl >/dev/null 2>&1 || fail '远程安装需要 curl；也可使用 --local 指定已下载脚本。'
  say "下载并校验固定 Release v$VERSION。"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 "$DOWNLOAD_URL" -o "$temporary_file"
else
  fail '用法：install.sh [--local ./vps-tcp-tune.sh]'
fi
actual_sha256=$(sha256sum "$temporary_file" | awk '{print tolower($1)}')
[[ $actual_sha256 == "$EXPECTED_SHA256" ]] || fail 'SHA-256 校验失败，未安装任何文件。'
head -n 3 "$temporary_file" | grep -Fq 'vps-tcp-safe-tuner' || fail '文件标识不正确，未安装。'
grep -Fqx "readonly VERSION='$VERSION'" "$temporary_file" || fail '脚本版本与安装器不一致，未安装。'

if [[ -e $INSTALL_PATH || -L $INSTALL_PATH ]]; then
  [[ -f $INSTALL_PATH && ! -L $INSTALL_PATH ]] || fail "拒绝覆盖非普通文件：$INSTALL_PATH"
  head -n 3 "$INSTALL_PATH" | grep -Fq 'vps-tcp-safe-tuner' || fail "拒绝覆盖不归本项目管理的文件：$INSTALL_PATH"
fi

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  install -D -m 755 "$temporary_file" "$INSTALL_PATH"
else
  command -v sudo >/dev/null 2>&1 || fail '需要 root 或 sudo。'
  sudo install -D -m 755 "$temporary_file" "$INSTALL_PATH"
fi
say "安装完成：$INSTALL_PATH"
if [[ -t 0 && -t 1 ]]; then
  say '正在启动中文调优菜单。'
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then "$INSTALL_PATH"; else sudo "$INSTALL_PATH"; fi
  exit 0
fi
say '非交互安装完成；运行：sudo vps-tcp-tune'
