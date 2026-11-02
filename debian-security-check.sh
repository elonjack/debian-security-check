#!/usr/bin/env bash
# Debian 12/13 security health check and conservative updater.
# Interactive smart mode checks first, installs available updates only after a clean preflight,
# and reboots after a successful update or when a newly installed kernel needs activation.

set -u
set -o pipefail

SCRIPT_VERSION="1.3.2"
MODE="check"
INTERACTIVE_MENU=0
REFRESH_APT=1
WARNINGS=0
CRITICALS=0
BLOCKERS=0
PATCH_RECOMMENDED=0
REBOOT_RECOMMENDED=0
RUNNING_KERNEL_VULNERABLE=0
KERNEL_UPDATE_NEEDED=0
UPGRADE_FAILED=0
POST_UPDATE_MODE=0
RETURN_TO_MENU=0
TEMP_FILES=()

if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'
  C_BLUE=$'\033[36m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_RED="" C_YELLOW="" C_GREEN="" C_BLUE="" C_BOLD="" C_RESET=""
fi

usage() {
  cat <<'EOF'
用法：
  sudo bash debian-security-check.sh              # 推荐：打开交互菜单
  sudo bash debian-security-check.sh --check      # 自动化：直接检查
  sudo bash debian-security-check.sh --fix        # 自动化：直接检查并安装更新
  bash debian-security-check.sh --no-refresh      # 离线检查，不刷新 APT 索引

选项：
  --check       直接运行普通检查，不显示菜单
  --fix         执行 apt-get upgrade --with-new-pkgs
  --no-refresh  不执行 apt-get update（结果可能不是最新）
  --self-test    维护者自检：验证安全源解析和自动重启保护条件
  -V, --version 显示脚本版本
  -h, --help    显示帮助

退出码：0=未发现需处理项，1=有警告/待更新/待重启，2=严重问题或检查失败。

交互菜单只有一个智能操作：先完整检查；有更新才模拟并安装；
复查确认需要重启时才自动重启。自动化参数模式不会自动重启。
EOF
}

if (($# == 0)) && [[ -t 0 ]]; then
  INTERACTIVE_MENU=1
  printf '\n%s%sDebian 安全检查与修复 v%s%s\n' "$C_BOLD" "$C_YELLOW" "$SCRIPT_VERSION" "$C_RESET"
  printf '%s%s选择 1 后会先完整检查；有更新才安装，需要时自动重启。%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
  printf '%s%s自动重启会断开当前 SSH；检查或升级失败时不会自动重启。%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"

  while true; do
    printf '\n%s%s%s\n' "$C_YELLOW" '  1) 智能检查并修复（有更新才安装，需要时自动重启）' "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  0) 退出' "$C_RESET"
    printf '\n%s请选择 [1/0]：%s' "$C_YELLOW" "$C_RESET"

    if ! read -r MENU_CHOICE; then
      printf '\n未读取到选择，已退出。\n' >&2
      exit 2
    fi

    case "$MENU_CHOICE" in
      1)
        MODE="smart"
        break
        ;;
      0)
        printf '已退出，没有修改系统。\n'
        exit 0
        ;;
      *)
        printf '输入无效，请输入 1 或 0。\n' >&2
        ;;
    esac
  done
fi

while (($#)); do
  case "$1" in
    --check) MODE="check" ;;
    --fix) MODE="fix" ;;
    --no-refresh) REFRESH_APT=0 ;;
    --self-test) MODE="self-test"; REFRESH_APT=0 ;;
    --internal-post-smart) MODE="post-smart"; REFRESH_APT=0; POST_UPDATE_MODE=1; [[ "${DEBIAN_SECURITY_CHECK_RETURN_TO_MENU:-0}" == "1" ]] && RETURN_TO_MENU=1 ;;
    --internal-post-fix) MODE="post-fix"; REFRESH_APT=0; POST_UPDATE_MODE=1 ;;
    -V|--version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数：%s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ ("$MODE" == "fix" || "$MODE" == "smart") && "$REFRESH_APT" -eq 0 ]]; then
  printf '%s\n' '错误：--fix 不能与 --no-refresh 同时使用；修复前必须取得最新的软件包索引。' >&2
  exit 2
fi

section() { printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_BLUE" "$1" "$C_RESET"; }
ok() { printf '%s[通过]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; WARNINGS=$((WARNINGS + 1)); }
critical() { printf '%s[严重]%s %s\n' "$C_RED" "$C_RESET" "$*"; CRITICALS=$((CRITICALS + 1)); }
blocker() { critical "$@"; BLOCKERS=$((BLOCKERS + 1)); }

have() { command -v "$1" >/dev/null 2>&1; }

run_root() {
  if ((EUID == 0)); then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    return 126
  fi
}

installed() {
  [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null || true)" == ii* ]]
}

cleanup_temp_files() {
  if ((${#TEMP_FILES[@]})); then
    rm -f -- "${TEMP_FILES[@]}"
  fi
}
trap cleanup_temp_files EXIT

new_temp_file() {
  NEW_TEMP_FILE="$(mktemp -t debian-security-check.XXXXXX)" || return 1
  TEMP_FILES+=("$NEW_TEMP_FILE")
}

collect_active_sources() {
  local main_file="$1"
  local source_dir="$2"
  local file

  if [[ -f "$main_file" ]]; then
    awk '/^[[:space:]]*deb[[:space:]]/ && $0 !~ /^[[:space:]]*#/ {print}' "$main_file"
  fi

  [[ -d "$source_dir" ]] || return 0
  while IFS= read -r -d '' file; do
    case "$file" in
      *.list)
        awk '/^[[:space:]]*deb[[:space:]]/ && $0 !~ /^[[:space:]]*#/ {print}' "$file"
        ;;
      *.sources)
        awk '
          BEGIN { RS=""; FS="\n" }
          {
            enabled="yes"; types=""; uris=""; suites=""; components=""; field=""
            for (i=1; i<=NF; i++) {
              line=$i
              if (line ~ /^[[:space:]]*#/) continue
              if (line ~ /^[[:space:]]+/ && field != "") {
                sub(/^[[:space:]]+/, "", line)
                if (field == "Types") types=types " " line
                else if (field == "URIs") uris=uris " " line
                else if (field == "Suites") suites=suites " " line
                else if (field == "Components") components=components " " line
                continue
              }
              field=""
              if (line ~ /^Enabled:[[:space:]]*/) { sub(/^Enabled:[[:space:]]*/, "", line); sub(/[[:space:]]+$/, "", line); enabled=tolower(line) }
              else if (line ~ /^Types:[[:space:]]*/) { sub(/^Types:[[:space:]]*/, "", line); types=line; field="Types" }
              else if (line ~ /^URIs:[[:space:]]*/) { sub(/^URIs:[[:space:]]*/, "", line); uris=line; field="URIs" }
              else if (line ~ /^Suites:[[:space:]]*/) { sub(/^Suites:[[:space:]]*/, "", line); suites=line; field="Suites" }
              else if (line ~ /^Components:[[:space:]]*/) { sub(/^Components:[[:space:]]*/, "", line); components=line; field="Components" }
            }
            if (enabled != "no" && (" " types " ") ~ / deb /) {
              print "deb " uris " " suites " " components
            }
          }
        ' "$file"
        ;;
    esac
  done < <(find "$source_dir" -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print0 | sort -z)
}

query_upgradable_packages() {
  local output error_log
  new_temp_file || { blocker "无法创建 APT 查询临时文件。"; return 1; }
  error_log="$NEW_TEMP_FILE"
  if ! output="$(apt list --upgradable 2>"$error_log")"; then
    blocker "apt list --upgradable 查询失败，不能把失败误判为系统已是最新。"
    tail -n 10 "$error_log"
    return 1
  fi
  mapfile -t UPGRADABLE < <(sed '1{/Listing/d;}' <<<"$output" | sed '/^[[:space:]]*$/d')
}

should_auto_reboot() {
  ((UPGRADE_FAILED == 0 && BLOCKERS == 0 && CRITICALS == 0 && PATCH_RECOMMENDED == 0 && REBOOT_RECOMMENDED == 1))
}

run_self_test() {
  local test_dir output failed=0
  test_dir="$(mktemp -d -t debian-security-check-test.XXXXXX)" || return 1
  mkdir -p "$test_dir/sources.list.d"

  printf '%s\n' 'deb https://example.invalid/debian-security trixie-security main' >"$test_dir/sources.list.d/ignored.list.save"
  cat >"$test_dir/sources.list.d/disabled.sources" <<'EOF'
Types: deb
URIs: https://disabled.invalid/debian-security
Suites: trixie-security
Components: main
Enabled: no
EOF

  output="$(collect_active_sources "$test_dir/sources.list" "$test_dir/sources.list.d")"
  if [[ -n "$output" ]]; then
    printf '%s\n' 'SELF-TEST FAIL: 禁用或备份安全源被误判为启用。' >&2
    failed=1
  fi

  cat >"$test_dir/sources.list.d/active.sources" <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian-security
Suites: trixie-security
Components: main
EOF
  output="$(collect_active_sources "$test_dir/sources.list" "$test_dir/sources.list.d")"
  if ! grep -q 'trixie-security' <<<"$output"; then
    printf '%s\n' 'SELF-TEST FAIL: 有效的 Deb822 安全源未被识别。' >&2
    failed=1
  fi

  UPGRADE_FAILED=0 BLOCKERS=0 CRITICALS=0 PATCH_RECOMMENDED=0 REBOOT_RECOMMENDED=1
  should_auto_reboot || { printf '%s\n' 'SELF-TEST FAIL: 安全重启条件未通过。' >&2; failed=1; }
  UPGRADE_FAILED=1
  if should_auto_reboot; then printf '%s\n' 'SELF-TEST FAIL: 升级失败后仍允许重启。' >&2; failed=1; fi
  UPGRADE_FAILED=0 BLOCKERS=1
  if should_auto_reboot; then printf '%s\n' 'SELF-TEST FAIL: 存在阻断项时仍允许重启。' >&2; failed=1; fi
  BLOCKERS=0 PATCH_RECOMMENDED=1
  if should_auto_reboot; then printf '%s\n' 'SELF-TEST FAIL: 仍有补丁时仍允许重启。' >&2; failed=1; fi
  PATCH_RECOMMENDED=0 CRITICALS=1
  if should_auto_reboot; then printf '%s\n' 'SELF-TEST FAIL: 存在严重问题时仍允许重启。' >&2; failed=1; fi

  rm -f -- "$test_dir/sources.list.d/ignored.list.save" "$test_dir/sources.list.d/disabled.sources" "$test_dir/sources.list.d/active.sources"
  rmdir -- "$test_dir/sources.list.d" "$test_dir"

  if ((failed)); then return 1; fi
  printf '%s\n' 'SELF-TEST OK'
}

if [[ "$MODE" == "self-test" ]]; then
  run_self_test
  exit $?
fi

export LC_ALL=C
export LANG=C

printf '%sDebian 安全检查脚本 v%s%s\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"
printf '时间：%s\n' "$(date '+%F %T %Z')"
printf '主机：%s\n' "$(hostname -f 2>/dev/null || hostname)"

section "系统与支持状态"
for REQUIRED_COMMAND in apt apt-get apt-mark awk dpkg dpkg-query find grep mktemp sed sort; do
  if ! have "$REQUIRED_COMMAND"; then
    blocker "缺少必要命令：$REQUIRED_COMMAND"
  fi
done

if [[ ! -r /etc/os-release ]]; then
  blocker "找不到 /etc/os-release，无法识别系统。"
  exit 2
fi

# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
VERSION="${VERSION_ID:-unknown}"
CODENAME="${VERSION_CODENAME:-}"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

info "系统：${PRETTY_NAME:-$OS_ID $VERSION}；架构：$ARCH"

if [[ "$OS_ID" != "debian" ]]; then
  blocker "该脚本只对 Debian 官方软件包给出漏洞结论；当前 ID=$OS_ID。"
fi

case "$VERSION" in
  13)
    [[ -n "$CODENAME" ]] || CODENAME="trixie"
    case "$ARCH" in
      amd64|arm64|armel|armhf|ppc64el|riscv64|s390x) ok "Debian 13 当前处于官方支持期，架构受支持。" ;;
      i386) blocker "Debian 13 不再把 i386 作为常规系统架构支持；不要在该系统上自动升级。" ;;
      *) blocker "Debian 13 不支持当前系统架构 $ARCH。" ;;
    esac
    ;;
  12)
    [[ -n "$CODENAME" ]] || CODENAME="bookworm"
    case "$ARCH" in
      amd64|i386|arm64|armhf|ppc64el) ok "Debian 12 LTS 架构受支持（支持至 2028-06-30）。" ;;
      *) blocker "Debian 12 LTS 不支持当前架构 $ARCH；应升级至 Debian 13。" ;;
    esac
    ;;
  11)
    [[ -n "$CODENAME" ]] || CODENAME="bullseye"
    blocker "Debian 11 官方 LTS 已于 2026-08-31 结束；应升级至 Debian 12/13 或使用 ELTS。"
    ;;
  *)
    blocker "Debian $VERSION 不在本脚本支持的 Debian 12/13 范围内。"
    ;;
esac

if { have systemd-detect-virt && systemd-detect-virt --quiet --container; } || [[ -e /.dockerenv || -e /run/.containerenv ]]; then
  IN_CONTAINER=1
  warn "检测到容器环境：容器共享宿主机内核，必须在宿主机更新并重启内核。"
else
  IN_CONTAINER=0
fi

section "APT 安全源"
SOURCE_TEXT="$(collect_active_sources /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)"

if [[ -n "$CODENAME" ]] && grep -Eq "(^|[[:space:]])${CODENAME}-security([[:space:]]|$)" <<<"$SOURCE_TEXT"; then
  ok "已配置 ${CODENAME}-security。"
elif grep -Eqi '(^|[[:space:]])(stable|oldstable)-security([[:space:]]|$)' <<<"$SOURCE_TEXT"; then
  blocker "security 源使用了 stable/oldstable 滚动别名；自动更新前必须改成 ${CODENAME}-security，避免意外跨版本。"
else
  blocker "未发现真正启用的 ${CODENAME}-security APT 源；拿不到官方安全更新。"
fi

if grep -Eqi '(^|[[:space:]])(testing|unstable|sid|forky)([[:space:]]|$)' <<<"$SOURCE_TEXT"; then
  blocker "发现 testing/unstable/sid/forky 软件源；为避免跨发行版升级，智能修复已被阻止。"
fi

section "刷新软件包索引"
if ((REFRESH_APT)); then
  if ! new_temp_file; then
    blocker "无法创建 APT 日志临时文件。"
    APT_LOG=""
  else
    APT_LOG="$NEW_TEMP_FILE"
  fi
  info "执行 apt-get update（只更新索引，不安装包）……"
  if [[ -n "$APT_LOG" ]] && run_root apt-get update -o APT::Update::Error-Mode=any >"$APT_LOG" 2>&1; then
    ok "APT 索引刷新成功。"
  else
    blocker "apt-get update 失败；不会安装任何更新。"
    [[ -n "$APT_LOG" ]] && tail -n 20 "$APT_LOG"
  fi
elif ((POST_UPDATE_MODE)); then
  info "更新后复查沿用刚刚成功刷新的 APT 索引。"
else
  warn "已跳过 apt-get update；后续结果可能过期。"
fi

section "待更新与被锁定的软件包"
if ! HELD_OUTPUT="$(apt-mark showhold 2>&1)"; then
  blocker "apt-mark showhold 查询失败，无法可靠判断被锁定的软件包。"
  HELD_PACKAGES=()
else
  mapfile -t HELD_PACKAGES <<<"$HELD_OUTPUT"
  if [[ -z "$HELD_OUTPUT" ]]; then HELD_PACKAGES=(); fi
fi
if ((${#HELD_PACKAGES[@]})); then
  warn "发现被 hold 的包：${HELD_PACKAGES[*]}"
else
  ok "没有被 hold 的软件包。"
fi

UPGRADABLE=()
query_upgradable_packages || true
if ((${#UPGRADABLE[@]})); then
  PATCH_RECOMMENDED=1
  warn "还有 ${#UPGRADABLE[@]} 个软件包可更新。"
  printf '%s\n' "${UPGRADABLE[@]:0:20}" | sed 's/^/  /'
  if ((${#UPGRADABLE[@]} > 20)); then
    info "仅显示前 20 个。"
  fi
else
  ok "当前 APT 索引中没有待更新软件包。"
fi

if have debsecan && [[ -n "$CODENAME" ]]; then
  info "运行 debsecan，检查已有修复可安装的漏洞包……"
  if DEBSECAN_OUTPUT="$(debsecan --suite "$CODENAME" --format packages --only-fixed 2>/dev/null | sort -u)"; then
    if [[ -n "$DEBSECAN_OUTPUT" ]]; then
      PATCH_RECOMMENDED=1
      DEBSECAN_COUNT="$(wc -l <<<"$DEBSECAN_OUTPUT" | tr -d ' ')"
      warn "debsecan 报告 $DEBSECAN_COUNT 个存在可用安全修复的软件包："
      sed -n '1,30p' <<<"$DEBSECAN_OUTPUT" | sed 's/^/  /'
      if ((DEBSECAN_COUNT > 30)); then info "仅显示前 30 个。"; fi
    else
      ok "debsecan 未发现已有修复但尚未更新的软件包。"
    fi
  else
    warn "debsecan 查询失败，未据此给出安全结论；请检查网络后重试。"
  fi
else
  info "未安装 debsecan；可运行：sudo apt-get install debsecan debian-security-support"
fi

section "CVE-2026-98432 与运行中内核"
RUNNING_RELEASE="$(uname -r)"
info "正在运行：$RUNNING_RELEASE"

if ((IN_CONTAINER)); then
  warn "无法在容器内判定宿主机是否修复 CVE-2026-98432。"
else
  KERNEL_PACKAGE="linux-image-$RUNNING_RELEASE"
  KERNEL_QUERY="$(dpkg-query -W -f='${db:Status-Abbrev}|${source:Package}|${source:Version}|${Version}' "$KERNEL_PACKAGE" 2>/dev/null || true)"

  if [[ "$KERNEL_QUERY" != ii* ]]; then
    blocker "运行内核不属于已安装的 Debian 包 $KERNEL_PACKAGE；可能是云厂商/Proxmox/自编译内核，不能安全自动处理。"
  else
    IFS='|' read -r _STATUS SOURCE_PACKAGE SOURCE_VERSION BINARY_VERSION <<<"$KERNEL_QUERY"
    [[ -n "$SOURCE_PACKAGE" ]] || SOURCE_PACKAGE="$KERNEL_PACKAGE"
    [[ -n "$SOURCE_VERSION" ]] || SOURCE_VERSION="$BINARY_VERSION"
    info "运行内核来源：$SOURCE_PACKAGE $SOURCE_VERSION"

    UPSTREAM_VERSION="$(sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' <<<"$SOURCE_VERSION")"
    FIXED_UPSTREAM=""
    FIXED_DEBIAN=""
    VERSION_IS_FIXED=0
    SOURCE_IS_OFFICIAL=0

    case "$SOURCE_PACKAGE" in
      linux|linux-6.12|linux-signed-amd64|linux-signed-arm64|linux-signed-i386) SOURCE_IS_OFFICIAL=1 ;;
    esac

    case "$VERSION:$UPSTREAM_VERSION" in
      13:6.12.*)
        FIXED_UPSTREAM="6.12.113"; FIXED_DEBIAN="6.12.113-1"
        ;;
      12:6.1.*)
        FIXED_UPSTREAM="6.1.190"; FIXED_DEBIAN="6.1.190-1"
        ;;
      12:6.12.*)
        FIXED_UPSTREAM="6.12.113"; FIXED_DEBIAN="6.12.113-1~deb12u1"
        ;;
    esac

    if ((SOURCE_IS_OFFICIAL == 0)); then
      blocker "运行内核来源 $SOURCE_PACKAGE 不在 Debian 官方内核源包白名单内，不能自动判定 CVE 状态。"
    elif [[ -z "$FIXED_UPSTREAM" ]]; then
      blocker "该内核分支不在 Debian 12/13 官方修复表内，不能自动判定 CVE 状态。"
    else
      if [[ "$SOURCE_PACKAGE" == "linux" || "$SOURCE_PACKAGE" == "linux-6.12" ]]; then
        if dpkg --compare-versions "$SOURCE_VERSION" ge "$FIXED_DEBIAN"; then
          VERSION_IS_FIXED=1
        fi
      elif dpkg --compare-versions "$UPSTREAM_VERSION" ge "$FIXED_UPSTREAM"; then
        # linux-signed-* 使用与对应 linux 源包相同的上游版本，但 Debian 修订后缀不同。
        VERSION_IS_FIXED=1
      fi

      if ((VERSION_IS_FIXED)); then
        ok "运行中内核已达到 CVE-2026-98432 修复线（Debian 修复版本：$FIXED_DEBIAN）。"
      else
        RUNNING_KERNEL_VULNERABLE=1
        KERNEL_UPDATE_NEEDED=1
        info "运行中内核低于修复线 $FIXED_DEBIAN，正在确认修复内核是否已经安装。"
      fi
    fi
  fi
fi

info "已安装的 Debian 内核："
INSTALLED_KERNELS="$(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${Version}\n' 'linux-image-[0-9]*' 2>/dev/null | awk '$1 ~ /^ii/ {print $2, $3}' | sort -V || true)"
if [[ -n "$INSTALLED_KERNELS" ]]; then
  sed 's/^/  /' <<<"$INSTALLED_KERNELS"
else
  printf '  （未找到 Debian linux-image 内核包）\n'
fi

INSTALLED_FIXED_KERNEL=0
while IFS='|' read -r STATUS_ABBR PACKAGE_NAME INSTALLED_SOURCE _INSTALLED_SOURCE_VERSION; do
  [[ "$STATUS_ABBR" == ii* ]] || continue
  case "$INSTALLED_SOURCE" in
    linux|linux-6.12|linux-signed-amd64|linux-signed-arm64|linux-signed-i386) ;;
    *) continue ;;
  esac

  PACKAGE_NAME="${PACKAGE_NAME%%:*}"
  INSTALLED_UPSTREAM="$(sed -nE 's/^linux-image-([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' <<<"$PACKAGE_NAME")"
  [[ -n "$INSTALLED_UPSTREAM" ]] || continue

  case "$VERSION:$INSTALLED_UPSTREAM" in
    13:6.12.*)
      if dpkg --compare-versions "$INSTALLED_UPSTREAM" ge "6.12.113"; then INSTALLED_FIXED_KERNEL=1; fi
      ;;
    12:6.1.*)
      if dpkg --compare-versions "$INSTALLED_UPSTREAM" ge "6.1.190"; then INSTALLED_FIXED_KERNEL=1; fi
      ;;
    12:6.12.*)
      if dpkg --compare-versions "$INSTALLED_UPSTREAM" ge "6.12.113"; then INSTALLED_FIXED_KERNEL=1; fi
      ;;
  esac
done < <(dpkg-query -W -f='${db:Status-Abbrev}|${binary:Package}|${source:Package}|${source:Version}\n' 'linux-image-[0-9]*' 2>/dev/null || true)

if ((RUNNING_KERNEL_VULNERABLE && INSTALLED_FIXED_KERNEL)); then
  KERNEL_UPDATE_NEEDED=0
  REBOOT_RECOMMENDED=1
  warn "修复内核已经安装，但当前仍在运行有风险的旧内核；现在需要重启，不需要再次安装内核更新。"
elif ((KERNEL_UPDATE_NEEDED)); then
  critical "运行中内核仍低于 CVE-2026-98432 修复线，且尚未找到已安装的修复内核。"
  PATCH_RECOMMENDED=1
fi

META_KERNELS="$(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${Version}\n' 'linux-image-*' 2>/dev/null | awk '$1 ~ /^ii/ && $2 ~ /^linux-image-(amd64|cloud-amd64|rt-amd64|arm64|cloud-arm64|armmp|powerpc64le|riscv64|s390x)(:[^ ]+)?$/ {print $2, $3}' | sort -u || true)"
if [[ -n "$META_KERNELS" ]]; then
  ok "已安装内核元包，后续内核通常可随 APT 持续更新："
  sed 's/^/  /' <<<"$META_KERNELS"
else
  warn "未发现 linux-image-* 内核元包；未来可能收不到新 ABI 内核。请按机器类型确认应安装 linux-image-amd64、linux-image-cloud-amd64 或 linux-image-arm64 等元包。"
fi

if [[ -e /run/reboot-required ]]; then
  REBOOT_RECOMMENDED=1
  warn "系统明确要求重启：/run/reboot-required 已存在。"
  if [[ -r /run/reboot-required.pkgs ]]; then
    sed 's/^/  触发包：/' /run/reboot-required.pkgs
  fi
elif have needrestart; then
  run_root needrestart -p -k >/dev/null 2>&1
  NEEDRESTART_STATUS=$?
  case "$NEEDRESTART_STATUS" in
    0) ok "needrestart 未报告过期的运行中内核。" ;;
    2)
      REBOOT_RECOMMENDED=1
      warn "needrestart 确认当前运行内核已过期，需要重启。"
      ;;
    *) warn "needrestart 内核检查失败（退出码：$NEEDRESTART_STATUS），未据此触发自动重启。" ;;
  esac
else
  info "未安装 needrestart；仅能依据 /run/reboot-required 判断是否需要重启。"
fi

section "自动安全更新"
if installed unattended-upgrades; then
  ok "已安装 unattended-upgrades。"
  if have systemctl && systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null; then
    ok "apt-daily-upgrade.timer 已启用。"
  elif apt-config dump 2>/dev/null | grep -qE '^APT::Periodic::Unattended-Upgrade "1";'; then
    ok "APT 周期性无人值守升级已启用。"
  else
    warn "unattended-upgrades 已安装，但未确认自动升级定时器/配置已启用。"
  fi
else
  warn "未安装 unattended-upgrades；建议安装并启用自动安全更新。"
fi

SCRIPT_PATH="$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")"

if [[ "$MODE" == "fix" || "$MODE" == "smart" ]]; then
  section "安全决策与安装更新"
  if ((EUID != 0)) && ! have sudo; then
    blocker "安装更新需要 root 权限，且系统没有 sudo。请用 root 运行。"
  elif ((BLOCKERS > 0)); then
    info "检查发现 $BLOCKERS 个阻断项，已停止安装更新。"
  elif ((${#UPGRADABLE[@]} == 0)); then
    ok "没有可更新软件包，已跳过安装。"
  else
    if ! new_temp_file; then
      blocker "无法创建升级模拟日志，已停止安装。"
      UPGRADE_FAILED=1
    else
      APT_SIM_LOG="$NEW_TEMP_FILE"
      info "先模拟 apt-get upgrade --with-new-pkgs，确认升级方案可执行且不删除软件包……"
      if ! run_root apt-get -s upgrade --with-new-pkgs >"$APT_SIM_LOG" 2>&1; then
        blocker "APT 升级模拟失败，已停止安装且不会自动重启。"
        tail -n 20 "$APT_SIM_LOG"
        UPGRADE_FAILED=1
      elif grep -qE '^Remv[[:space:]]' "$APT_SIM_LOG"; then
        blocker "升级模拟包含删除软件包操作，已停止安装且不会自动重启。"
        grep -E '^Remv[[:space:]]' "$APT_SIM_LOG" | head -n 20
        UPGRADE_FAILED=1
      else
        ok "升级模拟通过，没有计划删除现有软件包。"
        info "开始安装所有已配置 APT 源提供的可用更新；更新过程可能重启相关服务。"
        if run_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y upgrade --with-new-pkgs; then
          ok "APT 更新安装成功；现在重新执行完整检查，再决定是否重启。"
          cleanup_temp_files
          TEMP_FILES=()
          trap - EXIT
          if [[ "$MODE" == "smart" ]]; then
            DEBIAN_SECURITY_CHECK_RETURN_TO_MENU="$INTERACTIVE_MENU" exec bash "$SCRIPT_PATH" --internal-post-smart
          else
            exec bash "$SCRIPT_PATH" --internal-post-fix
          fi
          blocker "无法启动更新后复查，禁止自动重启。"
          UPGRADE_FAILED=1
        else
          blocker "升级失败；即使系统提示需要重启，本次也禁止自动重启。请先处理上面的 APT/dpkg 错误。"
          UPGRADE_FAILED=1
        fi
      fi
    fi
  fi
fi

section "结论"
if ((CRITICALS > 0)); then
  printf '%s发现 %d 个严重问题、%d 个警告。%s\n' "$C_RED" "$CRITICALS" "$WARNINGS" "$C_RESET"
elif ((WARNINGS > 0)); then
  printf '%s没有发现已确认的严重问题，但有 %d 个警告/待处理项。%s\n' "$C_YELLOW" "$WARNINGS" "$C_RESET"
else
  printf '%s检查完成，未发现当前可安装更新或本脚本能够确认的严重问题。%s\n' "$C_GREEN" "$C_RESET"
fi

section "下一步"
if ((EUID == 0)); then
  BASH_COMMAND_PREFIX="bash"
  REBOOT_COMMAND="reboot"
else
  BASH_COMMAND_PREFIX="sudo bash"
  REBOOT_COMMAND="sudo reboot"
fi

if [[ "$MODE" == "smart" || "$MODE" == "post-smart" ]]; then
  if ((UPGRADE_FAILED)); then
    printf '%s升级失败，本次明确禁止自动重启。%s 请先处理上面的 APT/dpkg 错误。\n' "$C_RED" "$C_RESET"
  elif ((BLOCKERS > 0)); then
    printf '%s发现 %d 个安全阻断项；没有执行自动重启。%s 请先处理上面的“严重”项目。\n' "$C_RED" "$BLOCKERS" "$C_RESET"
  elif ((PATCH_RECOMMENDED)); then
    printf '%s仍有可安装更新、被 hold 的补丁或尚未安装的修复内核；不会自动重启。%s 请先处理上面的提示。\n' "$C_RED" "$C_RESET"
  elif ((CRITICALS > 0)); then
    printf '%s仍有脚本无法自动解决的严重问题；不会自动重启。%s\n' "$C_RED" "$C_RESET"
  elif should_auto_reboot; then
    printf '%s完整复查通过，并确认需要重启才能启用补丁。%s\n' "$C_YELLOW" "$C_RESET"
    printf '%s10 秒后将自动重启，当前 SSH 会断开；按 Ctrl+C 可取消本次重启。%s\n' "$C_YELLOW" "$C_RESET"
    sleep 10
    sync
    if have systemctl && run_root systemctl reboot; then
      exit 0
    elif run_root reboot; then
      exit 0
    else
      critical "自动重启失败。请确认有 root 权限后手动运行：$REBOOT_COMMAND"
    fi
  else
    printf '%s当前没有剩余 APT 更新，也不需要重启；没有安装或删除额外软件包。%s\n' "$C_GREEN" "$C_RESET"
    if ((INTERACTIVE_MENU || RETURN_TO_MENU)) && [[ -r /dev/tty ]] && [[ -f "$SCRIPT_PATH" ]]; then
      info "3 秒后自动返回菜单。"
      sleep 3
      cleanup_temp_files
      TEMP_FILES=()
      trap - EXIT
      exec bash "$SCRIPT_PATH" </dev/tty
    fi
  fi
elif [[ "$MODE" == "check" ]]; then
  if ((BLOCKERS > 0)); then
    printf '%s发现安全阻断项。%s 请先处理上面的严重问题，不要运行 --fix。\n' "$C_RED" "$C_RESET"
  elif ((PATCH_RECOMMENDED)); then
    printf '%s发现可尝试通过 Debian 更新修复的问题。%s 下一步运行：\n' "$C_YELLOW" "$C_RESET"
    printf '  %s %q --fix\n' "$BASH_COMMAND_PREFIX" "$SCRIPT_PATH"
    printf '修复结束后按照提示决定是否重启；之后再运行一次普通检查。\n'
  elif ((REBOOT_RECOMMENDED)); then
    printf '%s更新可能已经安装，目前只需要先重启：%s\n' "$C_YELLOW" "$C_RESET"
    printf '  %s\n' "$REBOOT_COMMAND"
    printf '服务器恢复后，再运行一次普通检查。此时无需先运行 --fix。\n'
  elif ((CRITICALS > 0)); then
    printf '%s存在无法由本脚本自动判断或修复的问题。%s 请按上面的严重提示人工处理，不要把运行 --fix 当成已经修好。\n' "$C_RED" "$C_RESET"
  else
    printf '%s当前没有可通过本脚本安装的更新，无需运行 --fix。%s 这不代表所有第三方软件或尚无补丁的漏洞都已消失。\n' "$C_GREEN" "$C_RESET"
  fi
else
  if ((UPGRADE_FAILED)); then
    printf '%s升级失败，不要重启；请先处理上面的 APT/dpkg 错误。%s\n' "$C_RED" "$C_RESET"
  elif ((BLOCKERS > 0)); then
    printf '%s仍有安全阻断项，请先人工处理。%s\n' "$C_RED" "$C_RESET"
  elif ((PATCH_RECOMMENDED)); then
    printf '%s修复后仍有可更新项目或运行内核仍有风险。%s 请查看上面的 hold、依赖或内核提示。\n' "$C_RED" "$C_RESET"
  elif ((CRITICALS > 0)); then
    printf '%s仍有脚本无法自动解决的严重问题。%s 请按照上面的提示人工处理。\n' "$C_RED" "$C_RESET"
  elif ((REBOOT_RECOMMENDED)); then
    printf '%s补丁已经安装或内核已经更新，下一步需要重启：%s\n' "$C_YELLOW" "$C_RESET"
    printf '  %s\n' "$REBOOT_COMMAND"
    printf '服务器恢复后，再运行：\n'
    printf '  %s %q\n' "$BASH_COMMAND_PREFIX" "$SCRIPT_PATH"
  else
    printf '%s修复完成，当前无需再次运行 --fix。%s\n' "$C_GREEN" "$C_RESET"
  fi
fi

if ((CRITICALS > 0)); then
  exit 2
elif ((WARNINGS > 0)); then
  exit 1
else
  exit 0
fi
