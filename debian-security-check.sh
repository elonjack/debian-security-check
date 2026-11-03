#!/usr/bin/env bash
# Debian 12/13 security health check and conservative updater.
# Interactive smart mode checks first, installs available updates only after a clean preflight,
# and reboots after a successful update or when a newly installed kernel needs activation.

set -u
set -o pipefail

SCRIPT_VERSION="1.5.0"
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
AUTO_UPDATE_CONFIG="/etc/apt/apt.conf.d/99debian-security-check"
AUTO_UPDATE_MARKER="Managed by debian-security-check"
AUTO_UPDATE_HELPER="/usr/local/sbin/debian-security-check-auto-update"
AUTO_UPDATE_SERVICE="/etc/systemd/system/debian-security-check-auto-update.service"
AUTO_UPDATE_TIMER="/etc/systemd/system/debian-security-check-auto-update.timer"
KERNEL_CLEANUP_MARKER="Managed by debian-security-check kernel cleanup"
KERNEL_CLEANUP_HELPER="/usr/local/sbin/debian-security-check-kernel-cleanup"
KERNEL_CLEANUP_SERVICE="/etc/systemd/system/debian-security-check-kernel-cleanup.service"
KERNEL_CLEANUP_TIMER="/etc/systemd/system/debian-security-check-kernel-cleanup.timer"
KERNEL_CLEANUP_MIN_AGE_DAYS=30

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
  --self-test    维护者自检：验证安全源解析、自动重启和自动更新配置
  -V, --version 显示脚本版本
  -h, --help    显示帮助

退出码：0=未发现需处理项，1=有警告/待更新/待重启，2=严重问题或检查失败。

交互菜单的选项 1 执行一次性智能检查与修复；选项 2 管理长期自动安全更新；选项 3 管理旧内核安全清理。
一次性智能模式复查确认需要重启时才自动重启。自动化参数模式不会自动重启。
EOF
}

if (($# == 0)) && [[ -t 0 ]]; then
  INTERACTIVE_MENU=1
  printf '\n%s%sDebian 安全检查与修复 v%s%s\n' "$C_BOLD" "$C_YELLOW" "$SCRIPT_VERSION" "$C_RESET"
  printf '%s%s选择 1：本次检查修复；选择 2：设置以后自动安装安全更新；选择 3：旧内核安全清理。%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
  printf '%s%s自动重启会断开当前 SSH；检查或升级失败时不会自动重启。%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"

  while true; do
    printf '\n%s%s%s\n' "$C_YELLOW" '  1) 智能检查并修复（有更新才安装，需要时自动重启）' "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  2) 自动安全更新设置（长期生效，默认不会自动开启）' "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  3) 旧内核安全清理（默认关闭，始终保留当前和一个备用）' "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  0) 退出' "$C_RESET"
    printf '\n%s请选择 [1/2/3/0]：%s' "$C_YELLOW" "$C_RESET"

    if ! read -r MENU_CHOICE; then
      printf '\n未读取到选择，已退出。\n' >&2
      exit 2
    fi

    case "$MENU_CHOICE" in
      1)
        MODE="smart"
        break
        ;;
      2)
        MODE="auto-settings"
        break
        ;;
      3)
        MODE="kernel-cleanup-settings"
        break
        ;;
      0)
        printf '已退出，没有修改系统。\n'
        exit 0
        ;;
      *)
        printf '输入无效，请输入 1、2、3 或 0。\n' >&2
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

is_official_debian_kernel_source() {
  case "$1" in
    linux|linux-[0-9]*|linux-signed-amd64|linux-signed-arm64|linux-signed-i386) return 0 ;;
    *) return 1 ;;
  esac
}

kernel_dependency_candidates() {
  local dependency_text="$1"
  grep -oE 'linux-image-[0-9][[:alnum:].+~_-]*(:[[:alnum:]_-]+)?' <<<"$dependency_text" |
    sed -E 's/:[[:alnum:]_-]+$//' |
    awk '!seen[$0]++'
}

installed_kernel_target_for_meta() {
  local meta_package="$1"
  local dependencies candidate query status source source_version binary_version
  local best_package="" best_version="" best_source="" best_source_version=""

  dependencies="$(dpkg-query -W -f='${Depends}, ${Pre-Depends}' "$meta_package" 2>/dev/null || true)"
  [[ -n "$dependencies" ]] || return 1

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    query="$(dpkg-query -W -f='${db:Status-Abbrev}|${source:Package}|${source:Version}|${Version}' "$candidate" 2>/dev/null || true)"
    IFS='|' read -r status source source_version binary_version <<<"$query"
    [[ "$status" == ii* && -n "$binary_version" ]] || continue
    [[ -n "$source" ]] || source="$candidate"
    [[ -n "$source_version" ]] || source_version="$binary_version"
    if [[ -z "$best_package" ]] || dpkg --compare-versions "$binary_version" gt "$best_version"; then
      best_package="$candidate"
      best_version="$binary_version"
      best_source="$source"
      best_source_version="$source_version"
    fi
  done < <(kernel_dependency_candidates "$dependencies")

  [[ -n "$best_package" ]] || return 1
  printf '%s|%s|%s|%s\n' "$best_package" "$best_version" "$best_source" "$best_source_version"
}

installed_kernel_meta_records() {
  local query status package meta_version target
  query="$(dpkg-query -W -f='${db:Status-Abbrev}|${binary:Package}|${Version}\n' 'linux-image-*' 2>/dev/null || true)"
  while IFS='|' read -r status package meta_version; do
    [[ "$status" == ii* ]] || continue
    package="${package%%:*}"
    [[ "$package" == linux-image-* && "$package" != linux-image-[0-9]* ]] || continue
    target="$(installed_kernel_target_for_meta "$package" 2>/dev/null || true)"
    [[ -n "$target" ]] || continue
    printf '%s|%s|%s\n' "$package" "$meta_version" "$target"
  done <<<"$query"
}

matching_kernel_meta_record() {
  local running_release="$1"
  local record meta_package meta_version target_package target_version target_source target_source_version flavor
  local best_record="" best_length=-1

  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    IFS='|' read -r meta_package meta_version target_package target_version target_source target_source_version <<<"$record"
    flavor="${meta_package#linux-image-}"
    if [[ "$running_release" == *-"$flavor" && ${#flavor} -gt $best_length ]]; then
      best_record="$meta_package|$meta_version|$target_package|$target_version|$target_source|$target_source_version"
      best_length=${#flavor}
    fi
  done

  [[ -n "$best_record" ]] || return 1
  printf '%s\n' "$best_record"
}

kernel_target_requires_reboot() {
  local running_package="$1" running_version="$2" target_package="$3" target_version="$4"
  [[ "$target_package" != "$running_package" ]] || return 1
  dpkg --compare-versions "$target_version" ge "$running_version"
}

pending_newer_kernel_target() {
  local running_release="${1:-$(uname -r)}"
  local running_package="linux-image-$running_release"
  local running_query running_status running_source running_version
  local records matching target_package target_version target_source

  running_query="$(dpkg-query -W -f='${db:Status-Abbrev}|${source:Package}|${source:Version}|${Version}' "$running_package" 2>/dev/null || true)"
  IFS='|' read -r running_status running_source _ running_version <<<"$running_query"
  [[ "$running_status" == ii* && -n "$running_version" ]] || return 1
  is_official_debian_kernel_source "$running_source" || return 1

  records="$(installed_kernel_meta_records || true)"
  [[ -n "$records" ]] || return 1
  matching="$(matching_kernel_meta_record "$running_release" <<<"$records" || true)"
  [[ -n "$matching" ]] || return 1
  IFS='|' read -r _ _ target_package target_version target_source _ <<<"$matching"
  is_official_debian_kernel_source "$target_source" || return 1
  kernel_target_requires_reboot "$running_package" "$running_version" "$target_package" "$target_version" || return 1
  printf '%s\n' "$matching"
}

classify_kernel_cleanup_records() {
  local current_package="$1" now_epoch="$2" minimum_age_days="$3"
  local package version modified role age_days i current_index=-1 fallback_index=-1
  local -a packages=() versions=() modified_times=()

  while IFS='|' read -r package version modified; do
    [[ -n "$package" && -n "$version" ]] || continue
    packages+=("$package")
    versions+=("$version")
    modified_times+=("$modified")
  done

  for i in "${!packages[@]}"; do
    if [[ "${packages[$i]}" == "$current_package" ]]; then
      current_index=$i
      break
    fi
  done
  ((current_index >= 0)) || return 2

  for i in "${!packages[@]}"; do
    ((i == current_index)) && continue
    if ((fallback_index < 0)) || dpkg --compare-versions "${versions[$i]}" gt "${versions[$fallback_index]}"; then
      fallback_index=$i
    fi
  done

  for i in "${!packages[@]}"; do
    package="${packages[$i]}"
    version="${versions[$i]}"
    modified="${modified_times[$i]}"
    age_days=-1
    if [[ "$modified" =~ ^[0-9]+$ ]] && ((modified > 0 && modified <= now_epoch)); then
      age_days=$(((now_epoch - modified) / 86400))
    fi

    if ((i == current_index)); then
      role="current"
    elif ((i == fallback_index)); then
      role="fallback"
    elif ((${#packages[@]} < 3)); then
      role="protected"
    elif ((age_days < 0)); then
      role="unknown-age"
    elif ((age_days >= minimum_age_days)); then
      role="candidate"
    else
      role="young"
    fi
    printf '%s|%s|%s|%s|%s\n' "$role" "$package" "$version" "$modified" "$age_days"
  done
}

kernel_cleanup_build_plan() {
  local command_name os_id os_version audit_output held_packages
  local needrestart_status
  local running_release running_package running_query running_status running_source running_version
  local meta_records matching_meta_record matching_meta meta_version target_package target_version target_source
  local kernel_query status package version source modified release series_match series_meta
  local series_records="" classification role age_days now_epoch count=0

  KERNEL_CLEANUP_CANDIDATES=()
  KERNEL_CLEANUP_DETAILS=()
  KERNEL_CLEANUP_REASON=""
  KERNEL_CLEANUP_META=""
  KERNEL_CLEANUP_TARGET=""

  for command_name in apt-get apt-mark awk date dpkg dpkg-query grep sed uname; do
    if ! have "$command_name"; then
      KERNEL_CLEANUP_REASON="缺少必要命令：$command_name"
      return 2
    fi
  done
  if [[ ! -r /etc/os-release ]]; then
    KERNEL_CLEANUP_REASON="找不到 /etc/os-release。"
    return 2
  fi
  os_id="$(awk -F= '$1 == "ID" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release)"
  os_version="$(awk -F= '$1 == "VERSION_ID" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release)"
  if [[ "$os_id" != "debian" || ("$os_version" != "12" && "$os_version" != "13") ]]; then
    KERNEL_CLEANUP_REASON="旧内核清理只支持 Debian 12/13。"
    return 2
  fi
  if { have systemd-detect-virt && systemd-detect-virt --quiet --container; } || [[ -e /.dockerenv || -e /run/.containerenv ]]; then
    KERNEL_CLEANUP_REASON="容器内核由宿主机控制，禁止在容器内自动清理。"
    return 2
  fi
  if [[ -e /run/reboot-required ]]; then
    KERNEL_CLEANUP_REASON="系统当前明确要求重启；请先重启并确认新内核正常，再清理旧内核。"
    return 2
  fi
  if have needrestart; then
    run_root needrestart -p -k >/dev/null 2>&1
    needrestart_status=$?
    if ((needrestart_status == 2)); then
      KERNEL_CLEANUP_REASON="needrestart 确认运行中内核已过期；请先重启，再清理旧内核。"
      return 2
    elif ((needrestart_status != 0)); then
      KERNEL_CLEANUP_REASON="needrestart 内核状态检查失败，禁止清理。"
      return 2
    fi
  fi

  audit_output="$(dpkg --audit 2>&1 || true)"
  if [[ -n "$audit_output" ]]; then
    KERNEL_CLEANUP_REASON="dpkg 报告未完成或异常的软件包状态，禁止清理。"
    return 2
  fi
  if ! run_root apt-get -o DPkg::Lock::Timeout=0 check >/dev/null 2>&1; then
    KERNEL_CLEANUP_REASON="APT 依赖检查失败或软件包管理器正忙，禁止清理。"
    return 2
  fi
  held_packages="$(apt-mark showhold 2>/dev/null || true)"
  if [[ -n "$held_packages" ]]; then
    KERNEL_CLEANUP_REASON="存在被 hold 的软件包，禁止自动清理内核。"
    return 2
  fi

  running_release="$(uname -r)"
  running_package="linux-image-$running_release"
  running_query="$(dpkg-query -W -f='${db:Status-Abbrev}|${source:Package}|${source:Version}|${Version}' "$running_package" 2>/dev/null || true)"
  IFS='|' read -r running_status running_source _ running_version <<<"$running_query"
  if [[ "$running_status" != ii* || -z "$running_version" ]] || ! is_official_debian_kernel_source "$running_source"; then
    KERNEL_CLEANUP_REASON="当前运行内核不是可确认的 Debian 官方已安装内核，禁止清理。"
    return 2
  fi

  meta_records="$(installed_kernel_meta_records || true)"
  matching_meta_record="$(matching_kernel_meta_record "$running_release" <<<"$meta_records" || true)"
  if [[ -z "$matching_meta_record" ]]; then
    KERNEL_CLEANUP_REASON="没有找到与当前运行内核同系列的 Debian 内核元包，禁止清理。"
    return 2
  fi
  IFS='|' read -r matching_meta meta_version target_package target_version target_source _ <<<"$matching_meta_record"
  if ! is_official_debian_kernel_source "$target_source"; then
    KERNEL_CLEANUP_REASON="内核元包目标不是可确认的 Debian 官方内核，禁止清理。"
    return 2
  fi
  if [[ "$target_package" != "$running_package" ]]; then
    KERNEL_CLEANUP_REASON="新内核已经安装但尚未运行；必须先重启进入 $target_package，禁止清理。"
    return 2
  fi
  KERNEL_CLEANUP_META="$matching_meta $meta_version"
  KERNEL_CLEANUP_TARGET="$target_package $target_version"

  kernel_query="$(dpkg-query -W -f='${db:Status-Abbrev}|${binary:Package}|${Version}|${source:Package}|${db-fsys:Last-Modified}\n' 'linux-image-[0-9]*' 2>/dev/null || true)"
  while IFS='|' read -r status package version source modified; do
    [[ "$status" == ii* ]] || continue
    package="${package%%:*}"
    [[ "$package" == linux-image-[0-9]* ]] || continue
    release="${package#linux-image-}"
    series_match="$(matching_kernel_meta_record "$release" <<<"$meta_records" || true)"
    [[ -n "$series_match" ]] || continue
    IFS='|' read -r series_meta _ <<<"$series_match"
    [[ "$series_meta" == "$matching_meta" ]] || continue
    if ! is_official_debian_kernel_source "$source"; then
      KERNEL_CLEANUP_REASON="同系列内核 $package 来自无法确认的源包 $source，禁止清理。"
      return 2
    fi
    series_records+="${series_records:+$'\n'}$package|$version|$modified"
    count=$((count + 1))
  done <<<"$kernel_query"

  if ((count == 0)); then
    KERNEL_CLEANUP_REASON="没有找到当前系列的已安装内核，禁止清理。"
    return 2
  fi
  now_epoch="$(date +%s)"
  classification="$(classify_kernel_cleanup_records "$running_package" "$now_epoch" "$KERNEL_CLEANUP_MIN_AGE_DAYS" <<<"$series_records")" || {
    KERNEL_CLEANUP_REASON="无法在已安装内核列表中确认当前运行内核，禁止清理。"
    return 2
  }

  while IFS='|' read -r role package version modified age_days; do
    [[ -n "$role" ]] || continue
    KERNEL_CLEANUP_DETAILS+=("$role|$package|$version|$modified|$age_days")
    if [[ "$role" == "candidate" ]]; then
      KERNEL_CLEANUP_CANDIDATES+=("$package")
    fi
  done <<<"$classification"

  if ((count < 3)); then
    KERNEL_CLEANUP_REASON="当前系列只有 $count 个内核；至少三个才会清理。"
    return 3
  fi
  if ((${#KERNEL_CLEANUP_CANDIDATES[@]} == 0)); then
    KERNEL_CLEANUP_REASON="没有安装满 $KERNEL_CLEANUP_MIN_AGE_DAYS 天且位于第三位或更旧的内核。"
    return 3
  fi
  return 0
}

kernel_cleanup_print_plan() {
  local detail role package version age_days age_text
  printf '[信息] 当前内核元包：%s\n' "${KERNEL_CLEANUP_META:-未知}"
  printf '[信息] 元包最新目标：%s\n' "${KERNEL_CLEANUP_TARGET:-未知}"
  for detail in "${KERNEL_CLEANUP_DETAILS[@]}"; do
    IFS='|' read -r role package version _ age_days <<<"$detail"
    if ((age_days >= 0)); then age_text="约 ${age_days} 天"; else age_text="安装时间未知"; fi
    case "$role" in
      current) printf '[保留] %s %s（当前运行且为最新内核，%s）\n' "$package" "$version" "$age_text" ;;
      fallback) printf '[保留] %s %s（最近的备用内核，%s）\n' "$package" "$version" "$age_text" ;;
      candidate) printf '[候选] %s %s（第三个或更旧，%s）\n' "$package" "$version" "$age_text" ;;
      young) printf '[保留] %s %s（尚未满 %s 天，%s）\n' "$package" "$version" "$KERNEL_CLEANUP_MIN_AGE_DAYS" "$age_text" ;;
      unknown-age) printf '[保留] %s %s（无法确认安装时间）\n' "$package" "$version" ;;
      *) printf '[保留] %s %s（受保护，%s）\n' "$package" "$version" "$age_text" ;;
    esac
  done
  if [[ -n "$KERNEL_CLEANUP_REASON" ]]; then
    printf '[信息] %s\n' "$KERNEL_CLEANUP_REASON"
  fi
}

kernel_cleanup_simulation_matches_candidates() {
  local simulation="$1" package removal
  shift
  local -a removals=()
  local -A expected=() seen=()

  (($# > 0)) || return 1
  for package in "$@"; do
    [[ "$package" =~ ^linux-image-[0-9][[:alnum:].+~_-]*$ ]] || return 1
    expected["$package"]=1
  done
  if grep -qE '^Inst[[:space:]]' <<<"$simulation"; then
    return 1
  fi
  mapfile -t removals < <(sed -nE 's/^(Remv|Purg)[[:space:]]+([^[:space:]]+).*/\2/p' <<<"$simulation" | sed -E 's/:[[:alnum:]_-]+$//' | awk '!seen[$0]++')
  ((${#removals[@]} > 0)) || return 1
  for removal in "${removals[@]}"; do
    [[ -n "${expected[$removal]:-}" ]] || return 1
    seen["$removal"]=1
  done
  for package in "$@"; do
    [[ -n "${seen[$package]:-}" ]] || return 1
  done
}

kernel_cleanup_validate_simulation() {
  local simulation
  (($# > 0)) || return 1
  if ! simulation="$(run_root apt-get -s -o DPkg::Lock::Timeout=0 purge "$@" 2>&1)"; then
    printf '%s\n' "$simulation" >&2
    return 1
  fi
  if ! kernel_cleanup_simulation_matches_candidates "$simulation" "$@"; then
    printf '%s\n' "$simulation" >&2
    return 1
  fi
}

kernel_cleanup_purge_candidates() {
  local package plan_status
  local -a requested_candidates=("${KERNEL_CLEANUP_CANDIDATES[@]}")
  ((${#KERNEL_CLEANUP_CANDIDATES[@]} > 0)) || return 1
  kernel_cleanup_build_plan
  plan_status=$?
  if ((plan_status != 0)) || [[ "${requested_candidates[*]}" != "${KERNEL_CLEANUP_CANDIDATES[*]}" ]]; then
    printf '[错误] 确认后系统内核或软件包状态发生变化；为安全起见已取消，没有删除任何软件包。\n' >&2
    return 1
  fi
  if ! kernel_cleanup_validate_simulation "${KERNEL_CLEANUP_CANDIDATES[@]}"; then
    printf '[错误] APT 模拟删除没有通过严格校验；没有删除任何软件包。\n' >&2
    return 1
  fi
  printf '[通过] APT 模拟仅删除已列出的旧内核，没有牵连其他软件包。\n'
  if ! run_root env DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=0 purge "${KERNEL_CLEANUP_CANDIDATES[@]}"; then
    printf '[错误] 旧内核清理失败；请检查上面的 APT/dpkg 输出。\n' >&2
    return 1
  fi
  for package in "${KERNEL_CLEANUP_CANDIDATES[@]}"; do
    if installed "$package"; then
      printf '[错误] %s 仍处于已安装状态。\n' "$package" >&2
      return 1
    fi
  done
  printf '[通过] 已清理 %d 个旧内核；没有运行 autoremove，也没有删除其他软件包。\n' "${#KERNEL_CLEANUP_CANDIDATES[@]}"
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

is_valid_reboot_time() {
  [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

is_managed_auto_update_config() {
  local first_line=""
  [[ -f "$AUTO_UPDATE_CONFIG" && -r "$AUTO_UPDATE_CONFIG" ]] || return 1
  IFS= read -r first_line <"$AUTO_UPDATE_CONFIG" || true
  [[ "$first_line" == "// $AUTO_UPDATE_MARKER. Do not edit this file by hand." ]]
}

is_managed_auto_update_runtime_file() {
  local path="$1" first_line="" second_line=""
  [[ -f "$path" && -r "$path" ]] || return 1
  {
    IFS= read -r first_line || true
    IFS= read -r second_line || true
  } <"$path"
  if [[ "$path" == "$AUTO_UPDATE_HELPER" ]]; then
    [[ "$first_line" == '#!/usr/bin/env bash' && "$second_line" == "# $AUTO_UPDATE_MARKER. Do not edit this file by hand." ]]
  else
    [[ "$first_line" == "# $AUTO_UPDATE_MARKER. Do not edit this file by hand." ]]
  fi
}

check_auto_update_paths_safe() {
  local path
  if [[ -e "$AUTO_UPDATE_CONFIG" ]] && ! is_managed_auto_update_config; then
    printf '错误：%s 已存在但不是本脚本创建的文件，拒绝覆盖。\n' "$AUTO_UPDATE_CONFIG" >&2
    return 1
  fi
  for path in "$AUTO_UPDATE_HELPER" "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"; do
    if [[ -e "$path" ]] && ! is_managed_auto_update_runtime_file "$path"; then
      printf '错误：%s 已存在但不是本脚本创建的文件，拒绝覆盖。\n' "$path" >&2
      return 1
    fi
  done
}

ensure_auto_update_not_running() {
  local active_state="inactive"
  if have systemctl && [[ -d /run/systemd/system ]]; then
    active_state="$(systemctl show -p ActiveState --value debian-security-check-auto-update.service 2>/dev/null || true)"
    case "$active_state" in
      active|activating|reloading|deactivating)
        printf '错误：自动安全更新当前正在执行或切换状态。为避免中断软件包操作，请等待完成后再修改设置。\n' >&2
        return 1
        ;;
    esac
  fi
}

render_auto_update_config() {
  local config_mode="$1"
  local reboot_time="${2:-04:30}"

  cat <<EOF
// $AUTO_UPDATE_MARKER. Do not edit this file by hand.
// Mode: $config_mode
EOF

  if [[ "$config_mode" == "disabled" ]]; then
    cat <<'EOF'
APT::Periodic::Unattended-Upgrade "0";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    return 0
  fi

  cat <<EOF
// The dedicated systemd timer runs unattended-upgrade and checks its exit code.
// Disable APT's direct invocation so a failed run can never trigger its reboot path.
APT::Periodic::Unattended-Upgrade "0";

// Clear Debian defaults before allowing only the official security archive.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=\${distro_codename},label=Debian-Security";
        "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
};

// Never remove packages or upgrade during shutdown.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Allow-downgrade "false";
Unattended-Upgrade::SyslogEnable "true";

// Reboot is handled only by the guarded helper after a fully successful run.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Debian-Security-Check::Schedule-Time "$reboot_time";
EOF
}

render_auto_update_helper() {
  local config_mode="$1"
  local kernel_helper_functions
  kernel_helper_functions="$(declare -f is_official_debian_kernel_source kernel_dependency_candidates installed_kernel_target_for_meta installed_kernel_meta_records matching_kernel_meta_record kernel_target_requires_reboot pending_newer_kernel_target)"
  cat <<EOF
#!/usr/bin/env bash
# $AUTO_UPDATE_MARKER. Do not edit this file by hand.
set -u
set -o pipefail

MODE="$config_mode"
RUN_MARKER=""

cleanup() {
  if [[ -n "\$RUN_MARKER" ]]; then
    rm -f -- "\$RUN_MARKER"
  fi
}
trap cleanup EXIT

log() { printf '[debian-security-check] %s\\n' "\$*"; }

$kernel_helper_functions

if [[ ! -r /etc/os-release ]]; then
  log "无法识别系统，已停止自动更新。"
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
if [[ "\${ID:-}" != "debian" || ("\${VERSION_ID:-}" != "12" && "\${VERSION_ID:-}" != "13") ]]; then
  log "只支持 Debian 12/13；当前系统已停止自动更新。"
  exit 1
fi

for command_name in apt-config apt-get awk dpkg dpkg-query grep mktemp rm sed sync systemctl uname users; do
  if ! command -v "\$command_name" >/dev/null 2>&1; then
    log "缺少必要命令：\$command_name"
    exit 1
  fi
done

APT_DUMP="\$(apt-config dump 2>/dev/null)" || { log "无法读取 APT 有效配置。"; exit 1; }
ORIGIN_LINES="\$(grep -E '^Unattended-Upgrade::Origins-Pattern::' <<<"\$APT_DUMP" || true)"
ORIGIN_COUNT="\$(grep -c . <<<"\$ORIGIN_LINES" || true)"
if [[ "\$ORIGIN_COUNT" != "2" ]] ||
   grep -qE '^Unattended-Upgrade::Allowed-Origins::' <<<"\$APT_DUMP" ||
   ! grep -Fxq 'Unattended-Upgrade::Origins-Pattern:: "origin=Debian,codename=\${distro_codename},label=Debian-Security";' <<<"\$ORIGIN_LINES" ||
   ! grep -Fxq 'Unattended-Upgrade::Origins-Pattern:: "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";' <<<"\$ORIGIN_LINES" ||
   ! grep -Fxq 'APT::Periodic::Unattended-Upgrade "0";' <<<"\$APT_DUMP" ||
   ! grep -Fxq 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"\$APT_DUMP"; then
  log "APT 安全来源或重启保护配置已改变，已停止自动更新。"
  exit 1
fi

umask 077
RUN_MARKER="\$(mktemp /run/debian-security-check-auto-update.XXXXXX)" || exit 1
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
KERNEL_TARGET_BEFORE="\$(pending_newer_kernel_target 2>/dev/null || true)"

log "开始刷新全部 APT 软件源索引。"
if ! apt-get update -o APT::Update::Error-Mode=any; then
  log "apt-get update 失败；没有安装更新，也不会自动重启。"
  exit 1
fi

log "开始安装 Debian 官方安全来源允许的更新。"
if ! unattended-upgrade; then
  log "安全更新没有完整成功；不会自动重启。"
  exit 1
fi
log "安全更新执行成功。"
KERNEL_TARGET_AFTER="\$(pending_newer_kernel_target 2>/dev/null || true)"

if [[ "\$MODE" != "enabled-reboot" ]]; then
  exit 0
fi
NEW_REBOOT_MARKER=0
NEW_KERNEL_TARGET=0
if [[ -f /run/reboot-required && /run/reboot-required -nt "\$RUN_MARKER" ]]; then
  NEW_REBOOT_MARKER=1
fi
if [[ -n "\$KERNEL_TARGET_AFTER" && "\$KERNEL_TARGET_AFTER" != "\$KERNEL_TARGET_BEFORE" ]]; then
  NEW_KERNEL_TARGET=1
fi
if ((NEW_REBOOT_MARKER == 0 && NEW_KERNEL_TARGET == 0)); then
  log "本次更新没有新产生重启要求，也没有安装尚未启用的新内核，不重启。"
  exit 0
fi
LOGGED_IN_USERS="\$(users 2>/dev/null || true)"
if [[ -n "\$LOGGED_IN_USERS" ]]; then
  log "检测到登录用户，已跳过自动重启：\$LOGGED_IN_USERS"
  exit 0
fi

if ((NEW_KERNEL_TARGET)); then
  log "本次安全更新安装了尚未启用的新内核。"
fi
log "本次安全更新成功并确认需要重启，现在重启。"
sync
systemctl reboot
EOF
}

render_auto_update_service() {
  local config_mode="$1"
  cat <<EOF
# $AUTO_UPDATE_MARKER. Do not edit this file by hand.
[Unit]
Description=Debian Security Check guarded automatic security update
Documentation=https://github.com/elonjack/debian-security-check
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$AUTO_UPDATE_HELPER
TimeoutStartSec=2h
UMask=0022

# Selected mode: $config_mode
EOF
}

render_auto_update_timer() {
  local reboot_time="$1"
  cat <<EOF
# $AUTO_UPDATE_MARKER. Do not edit this file by hand.
[Unit]
Description=Run guarded Debian security updates every day

[Timer]
OnCalendar=*-*-* $reboot_time:00
AccuracySec=1min
RandomizedDelaySec=5m
Unit=debian-security-check-auto-update.service

[Install]
WantedBy=timers.target
EOF
}

remove_auto_update_runtime_files_safely() {
  local path
  for path in "$AUTO_UPDATE_HELPER" "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"; do
    if [[ -e "$path" ]] && ! is_managed_auto_update_runtime_file "$path"; then
      printf '错误：拒绝删除不是本脚本创建的 %s。\n' "$path" >&2
      return 1
    fi
  done
  if have systemctl && [[ -d /run/systemd/system ]]; then
    run_root systemctl disable --now debian-security-check-auto-update.timer >/dev/null 2>&1 || true
  fi
  for path in "$AUTO_UPDATE_HELPER" "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"; do
    if [[ -e "$path" ]]; then
      run_root rm -f -- "$path" || return 1
    fi
  done
  if have systemctl && [[ -d /run/systemd/system ]]; then
    run_root systemctl daemon-reload || return 1
  fi
}

write_auto_update_runtime_files() {
  local config_mode="$1" reboot_time="$2"
  local helper_tmp service_tmp timer_tmp

  check_auto_update_paths_safe || return 1
  new_temp_file || return 1
  helper_tmp="$NEW_TEMP_FILE"
  render_auto_update_helper "$config_mode" >"$helper_tmp" || return 1
  new_temp_file || return 1
  service_tmp="$NEW_TEMP_FILE"
  render_auto_update_service "$config_mode" >"$service_tmp" || return 1
  new_temp_file || return 1
  timer_tmp="$NEW_TEMP_FILE"
  render_auto_update_timer "$reboot_time" >"$timer_tmp" || return 1

  if ! run_root install -o root -g root -m 0755 "$helper_tmp" "$AUTO_UPDATE_HELPER" ||
     ! run_root install -o root -g root -m 0644 "$service_tmp" "$AUTO_UPDATE_SERVICE" ||
     ! run_root install -o root -g root -m 0644 "$timer_tmp" "$AUTO_UPDATE_TIMER"; then
    printf '错误：安装受控自动更新文件失败，正在清理未完成配置。\n' >&2
    remove_auto_update_runtime_files_safely || true
    return 1
  fi

  if ! run_root systemd-analyze verify "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"; then
    printf '错误：systemd 单元校验失败，已关闭并移除定时任务。\n' >&2
    remove_auto_update_runtime_files_safely || true
    return 1
  fi
  if ! run_root systemctl daemon-reload; then
    remove_auto_update_runtime_files_safely || true
    return 1
  fi
  if ! run_root systemctl enable --now debian-security-check-auto-update.timer; then
    printf '错误：无法启用安全更新定时器，已关闭并移除定时任务。\n' >&2
    remove_auto_update_runtime_files_safely || true
    return 1
  fi
}

validate_effective_auto_update_config() {
  local expected_mode="$1"
  local expected_time="${2:-04:30}"
  local dump origin_lines origin_count

  dump="$(apt-config dump 2>/dev/null)" || return 1

  if [[ "$expected_mode" == "disabled" ]]; then
    grep -Fxq 'APT::Periodic::Unattended-Upgrade "0";' <<<"$dump" &&
      grep -Fxq 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"$dump"
    return
  fi

  grep -Fxq 'APT::Periodic::Unattended-Upgrade "0";' <<<"$dump" || return 1

  if grep -qE '^Unattended-Upgrade::Allowed-Origins::' <<<"$dump"; then
    return 1
  fi

  origin_lines="$(grep -E '^Unattended-Upgrade::Origins-Pattern::' <<<"$dump" || true)"
  origin_count="$(grep -c . <<<"$origin_lines" || true)"
  [[ "$origin_count" == "2" ]] || return 1
  grep -Fxq "Unattended-Upgrade::Origins-Pattern:: \"origin=Debian,codename=\${distro_codename},label=Debian-Security\";" <<<"$origin_lines" || return 1
  grep -Fxq "Unattended-Upgrade::Origins-Pattern:: \"origin=Debian,codename=\${distro_codename}-security,label=Debian-Security\";" <<<"$origin_lines" || return 1

  grep -Fxq "Debian-Security-Check::Schedule-Time \"$expected_time\";" <<<"$dump" || return 1
  grep -Fxq 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"$dump" || return 1
  grep -Fxq 'Unattended-Upgrade::Automatic-Reboot-WithUsers "false";' <<<"$dump"
}

write_auto_update_config() {
  local config_mode="$1"
  local reboot_time="${2:-04:30}"
  local new_config backup_config="" had_existing=0

  case "$config_mode" in
    enabled-no-reboot|enabled-reboot|disabled) ;;
    *) printf '错误：未知的自动更新配置模式：%s\n' "$config_mode" >&2; return 1 ;;
  esac
  if [[ "$config_mode" != "disabled" ]] && ! is_valid_reboot_time "$reboot_time"; then
    printf '错误：定时任务时间格式无效：%s\n' "$reboot_time" >&2
    return 1
  fi

  new_temp_file || { printf '错误：无法创建临时配置文件。\n' >&2; return 1; }
  new_config="$NEW_TEMP_FILE"
  render_auto_update_config "$config_mode" "$reboot_time" >"$new_config" || return 1

  if run_root test -e "$AUTO_UPDATE_CONFIG"; then
    if ! is_managed_auto_update_config; then
      printf '错误：%s 已存在但不是本脚本创建的文件，为防止覆盖已停止。\n' "$AUTO_UPDATE_CONFIG" >&2
      return 1
    fi
    new_temp_file || { printf '错误：无法备份原自动更新配置。\n' >&2; return 1; }
    backup_config="$NEW_TEMP_FILE"
    run_root cp -- "$AUTO_UPDATE_CONFIG" "$backup_config" || return 1
    had_existing=1
  fi

  if ! run_root install -o root -g root -m 0644 "$new_config" "$AUTO_UPDATE_CONFIG"; then
    printf '错误：无法安装自动更新配置。\n' >&2
    return 1
  fi

  if validate_effective_auto_update_config "$config_mode" "$reboot_time"; then
    return 0
  fi

  printf '错误：APT 有效配置校验失败，正在恢复修改前的配置。\n' >&2
  if ((had_existing)); then
    run_root install -o root -g root -m 0644 "$backup_config" "$AUTO_UPDATE_CONFIG" || true
  else
    run_root rm -f -- "$AUTO_UPDATE_CONFIG" || true
  fi
  return 1
}

validate_auto_update_host() {
  local wants_reboot="$1"
  local ID="" VERSION_ID="" VERSION_CODENAME="" source_text

  if [[ ! -r /etc/os-release ]]; then
    printf '错误：找不到 /etc/os-release。\n' >&2
    return 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "$ID" != "debian" || ("$VERSION_ID" != "12" && "$VERSION_ID" != "13") ]]; then
    printf '错误：长期自动更新设置只支持 Debian 12/13；当前为 %s %s。\n' "$ID" "$VERSION_ID" >&2
    return 1
  fi
  [[ "$VERSION_ID" == "13" ]] && VERSION_CODENAME="trixie" || VERSION_CODENAME="bookworm"

  source_text="$(collect_active_sources /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)"
  if ! grep -Eq "(^|[[:space:]])${VERSION_CODENAME}-security([[:space:]]|$)" <<<"$source_text"; then
    printf '错误：未发现真正启用的 %s-security，不能开启自动安全更新。\n' "$VERSION_CODENAME" >&2
    return 1
  fi
  if grep -Eqi '(^|[[:space:]])(testing|unstable|sid|forky)([[:space:]]|$)' <<<"$source_text"; then
    printf '错误：发现 testing/unstable/sid/forky 软件源，已阻止自动更新。\n' >&2
    return 1
  fi

  if [[ "$wants_reboot" == "1" ]] &&
     ({ have systemd-detect-virt && systemd-detect-virt --quiet --container; } || [[ -e /.dockerenv || -e /run/.containerenv ]]); then
    printf '错误：容器不能由本脚本设置自动重启；请在宿主机处理内核和重启。\n' >&2
    return 1
  fi
  if ! have systemctl || ! have systemd-analyze || [[ ! -d /run/systemd/system ]]; then
    printf '错误：未检测到可用的 systemd；无法创建可验证的长期定时任务。\n' >&2
    return 1
  fi
  return 0
}

show_auto_update_status() {
  local dump schedule_time timer_state="不可用"
  section "自动安全更新状态"

  if installed unattended-upgrades; then
    ok "已安装 unattended-upgrades。"
  else
    warn "尚未安装 unattended-upgrades。"
  fi

  if is_managed_auto_update_config; then
    ok "本脚本正在管理：$AUTO_UPDATE_CONFIG"
  elif [[ -e "$AUTO_UPDATE_CONFIG" ]]; then
    warn "$AUTO_UPDATE_CONFIG 存在，但不是本脚本创建的配置。"
  else
    info "本脚本尚未创建长期自动更新配置。"
  fi

  dump="$(apt-config dump 2>/dev/null || true)"
  if grep -Fxq 'Unattended-Upgrade::Automatic-Reboot "true";' <<<"$dump"; then
    warn "发现 unattended-upgrades 自带自动重启仍为开启状态；这不是本脚本的安全模式。"
  else
    ok "unattended-upgrades 自带自动重启已关闭。"
  fi

  schedule_time="$(sed -nE 's/^Debian-Security-Check::Schedule-Time "([0-9]{2}:[0-9]{2})";$/\1/p' <<<"$dump" | tail -n 1)"

  if have systemctl && [[ -d /run/systemd/system ]]; then
    timer_state="$(systemctl is-enabled debian-security-check-auto-update.timer 2>/dev/null || true)"
    if [[ "$timer_state" == "enabled" || "$timer_state" == "static" ]]; then
      ok "本脚本定时器已启用；每天 ${schedule_time:-配置时间} 执行安全更新。"
      if systemctl is-failed --quiet debian-security-check-auto-update.service 2>/dev/null; then
        warn "上一次自动安全更新执行失败；请查看：journalctl -u debian-security-check-auto-update.service"
      fi
      if is_managed_auto_update_runtime_file "$AUTO_UPDATE_HELPER" && grep -Fxq 'MODE="enabled-reboot"' "$AUTO_UPDATE_HELPER"; then
        warn "本次安全更新完整成功并新产生重启要求或安装新内核时，将在无人登录的情况下重启。"
      elif ! is_managed_auto_update_runtime_file "$AUTO_UPDATE_HELPER"; then
        warn "定时器已启用，但执行文件不是本脚本管理的文件；请立即检查。"
      else
        ok "自动更新完成后不会自动重启。"
      fi
    else
      info "本脚本定时器状态：${timer_state:-unknown}；目前不会执行长期自动更新。"
    fi
  else
    info "未检测到正在运行的 systemd，无法读取 APT 定时器状态。"
  fi
  info "更新日志：/var/log/unattended-upgrades/"
  info "定时任务日志：journalctl -u debian-security-check-auto-update.service"
}

enable_auto_updates() {
  local enable_reboot="$1"
  local reboot_time="04:30" config_mode="enabled-no-reboot"

  info "定时器使用服务器本机时区：$(date '+%Z (UTC%:z)')。"
  printf '%s请输入每天执行安全更新的本机时间 [04:30]：%s' "$C_YELLOW" "$C_RESET"
  read -r reboot_time || return 1
  reboot_time="${reboot_time:-04:30}"
  if ! is_valid_reboot_time "$reboot_time"; then
    printf '错误：时间必须是 00:00 到 23:59 的 HH:MM 格式。\n' >&2
    return 1
  fi
  if [[ "$enable_reboot" == "1" ]]; then
    config_mode="enabled-reboot"
  fi

  validate_auto_update_host "$enable_reboot" || return 1
  ensure_auto_update_not_running || return 1
  check_auto_update_paths_safe || return 1
  if ((EUID != 0)) && ! have sudo; then
    printf '错误：此操作需要 root 权限，且系统没有 sudo。\n' >&2
    return 1
  fi

  info "刷新 APT 索引；任一软件源失败都会停止配置。"
  if ! run_root apt-get update -o APT::Update::Error-Mode=any; then
    printf '错误：apt-get update 失败，没有修改自动更新配置。\n' >&2
    return 1
  fi
  info "安装 Debian 官方 unattended-upgrades（不会删除软件包）。"
  if ! run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends unattended-upgrades; then
    printf '错误：unattended-upgrades 安装失败，没有启用本脚本配置。\n' >&2
    return 1
  fi
  if ! write_auto_update_config "$config_mode" "$reboot_time"; then
    return 1
  fi

  if ! write_auto_update_runtime_files "$config_mode" "$reboot_time"; then
    write_auto_update_config "disabled" || true
    warn "定时任务配置失败，已将无人值守安装和自动重启保持为关闭状态。"
    return 1
  fi

  if [[ "$enable_reboot" == "1" ]]; then
    ok "已开启：每天 $reboot_time 自动安装 Debian 官方安全更新。"
    info "只有本次更新完整成功并新产生重启要求或安装新内核，而且无人登录时，才会立即重启。"
  else
    ok "已开启：每天 $reboot_time 自动安装 Debian 官方安全更新，不自动重启。"
  fi
  info "不会自动跨版本升级 Debian，不会自动更新第三方软件或容器镜像，不会自动删除软件包。"
  info "建议仍定期运行主菜单选项 1，检查普通更新、hold 包、内核状态和执行失败记录。"
}

disable_auto_updates() {
  ensure_auto_update_not_running || return 1
  check_auto_update_paths_safe || return 1
  if have systemctl && [[ -d /run/systemd/system ]]; then
    run_root systemctl disable --now debian-security-check-auto-update.timer >/dev/null 2>&1 || true
  fi
  if ! write_auto_update_config "disabled"; then
    return 1
  fi
  ok "已关闭无人值守安装和自动重启。"
  info "unattended-upgrades 软件包和日志仍保留，没有卸载或删除软件包。"
}

remove_managed_auto_update_config() {
  ensure_auto_update_not_running || return 1
  if [[ ! -e "$AUTO_UPDATE_CONFIG" && ! -e "$AUTO_UPDATE_HELPER" && ! -e "$AUTO_UPDATE_SERVICE" && ! -e "$AUTO_UPDATE_TIMER" ]]; then
    info "本脚本没有可移除的自动更新配置。"
    return 0
  fi
  if [[ -e "$AUTO_UPDATE_CONFIG" ]] && ! is_managed_auto_update_config; then
    printf '错误：拒绝删除不是本脚本创建的 %s。\n' "$AUTO_UPDATE_CONFIG" >&2
    return 1
  fi
  if ! remove_auto_update_runtime_files_safely; then
    return 1
  fi
  if [[ -e "$AUTO_UPDATE_CONFIG" ]]; then
    run_root rm -f -- "$AUTO_UPDATE_CONFIG" || return 1
  fi
  ok "已移除本脚本配置，恢复由系统其他 APT 配置决定。"
  info "没有卸载 unattended-upgrades，也没有删除任何更新或日志。"
}

pause_for_menu() {
  printf '\n%s按回车键返回自动安全更新菜单……%s' "$C_YELLOW" "$C_RESET"
  read -r _MENU_PAUSE || true
}

auto_update_settings_menu() {
  local choice script_path
  script_path="$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")"

  while true; do
    printf '\n%s%s自动安全更新设置（长期生效）%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  1) 开启自动安装 Debian 安全更新（不自动重启）' "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  2) 定时安装安全更新（成功后确需重启才自动重启）' "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  3) 查看当前状态' "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  4) 关闭无人值守安装和自动重启' "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  5) 移除本脚本配置（恢复系统原有设置）' "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  0) 返回主菜单' "$C_RESET"
    printf '\n%s请选择 [1/2/3/4/5/0]：%s' "$C_YELLOW" "$C_RESET"
    if ! read -r choice; then
      printf '\n未读取到选择，已退出。\n' >&2
      return 2
    fi
    case "$choice" in
      1) enable_auto_updates 0 || true; pause_for_menu ;;
      2) enable_auto_updates 1 || true; pause_for_menu ;;
      3) show_auto_update_status; pause_for_menu ;;
      4) disable_auto_updates || true; pause_for_menu ;;
      5) remove_managed_auto_update_config || true; pause_for_menu ;;
      0)
        if [[ -r /dev/tty && -f "$script_path" ]]; then
          exec bash "$script_path" </dev/tty
        fi
        return 0
        ;;
      *) printf '输入无效，请输入 1、2、3、4、5 或 0。\n' >&2 ;;
    esac
  done
}

is_managed_kernel_cleanup_file() {
  local path="$1" first_line="" second_line=""
  [[ -f "$path" && -r "$path" ]] || return 1
  {
    IFS= read -r first_line || true
    IFS= read -r second_line || true
  } <"$path"
  if [[ "$path" == "$KERNEL_CLEANUP_HELPER" ]]; then
    [[ "$first_line" == '#!/usr/bin/env bash' && "$second_line" == "# $KERNEL_CLEANUP_MARKER. Do not edit this file by hand." ]]
  else
    [[ "$first_line" == "# $KERNEL_CLEANUP_MARKER. Do not edit this file by hand." ]]
  fi
}

check_kernel_cleanup_paths_safe() {
  local path
  for path in "$KERNEL_CLEANUP_HELPER" "$KERNEL_CLEANUP_SERVICE" "$KERNEL_CLEANUP_TIMER"; do
    if [[ -e "$path" ]] && ! is_managed_kernel_cleanup_file "$path"; then
      printf '错误：%s 已存在但不是本脚本创建的文件，拒绝覆盖或删除。\n' "$path" >&2
      return 1
    fi
  done
}

render_kernel_cleanup_helper() {
  local helper_functions
  helper_functions="$(declare -f have run_root installed is_official_debian_kernel_source kernel_dependency_candidates installed_kernel_target_for_meta installed_kernel_meta_records matching_kernel_meta_record classify_kernel_cleanup_records kernel_cleanup_build_plan kernel_cleanup_print_plan kernel_cleanup_simulation_matches_candidates kernel_cleanup_validate_simulation kernel_cleanup_purge_candidates)"
  cat <<EOF
#!/usr/bin/env bash
# $KERNEL_CLEANUP_MARKER. Do not edit this file by hand.
set -u
set -o pipefail

KERNEL_CLEANUP_MIN_AGE_DAYS=$KERNEL_CLEANUP_MIN_AGE_DAYS

$helper_functions

if ((EUID != 0)); then
  printf '[错误] 旧内核自动清理必须以 root 运行。\n' >&2
  exit 1
fi
if ! command -v flock >/dev/null 2>&1; then
  printf '[错误] 缺少 flock，旧内核自动清理已停止。\n' >&2
  exit 1
fi
exec 9>/run/debian-security-check-kernel-cleanup.lock
if ! flock -n 9; then
  printf '[信息] 另一个旧内核清理任务正在运行，本次跳过。\n'
  exit 0
fi

kernel_cleanup_build_plan
PLAN_STATUS=\$?
kernel_cleanup_print_plan
case "\$PLAN_STATUS" in
  0) kernel_cleanup_purge_candidates ;;
  3) printf '[通过] 本周没有符合全部安全条件的旧内核，未删除任何软件包。\n'; exit 0 ;;
  *) printf '[错误] 安全前置检查未通过，未删除任何软件包。\n' >&2; exit 1 ;;
esac
EOF
}

render_kernel_cleanup_service() {
  cat <<EOF
# $KERNEL_CLEANUP_MARKER. Do not edit this file by hand.
[Unit]
Description=Safely purge old Debian kernels managed by debian-security-check
Documentation=https://github.com/elonjack/debian-security-check
After=apt-daily.service apt-daily-upgrade.service debian-security-check-auto-update.service

[Service]
Type=oneshot
ExecStart=$KERNEL_CLEANUP_HELPER
TimeoutStartSec=1h
UMask=0022
EOF
}

render_kernel_cleanup_timer() {
  cat <<EOF
# $KERNEL_CLEANUP_MARKER. Do not edit this file by hand.
[Unit]
Description=Check for safely removable old Debian kernels every week

[Timer]
OnCalendar=Sun *-*-* 04:15:00
AccuracySec=1min
RandomizedDelaySec=30m
Unit=debian-security-check-kernel-cleanup.service

[Install]
WantedBy=timers.target
EOF
}

enable_weekly_kernel_cleanup() {
  local helper_tmp service_tmp timer_tmp os_id os_version path preflight_status
  if [[ ! -r /etc/os-release ]]; then
    printf '错误：找不到 /etc/os-release。\n' >&2
    return 1
  fi
  os_id="$(awk -F= '$1 == "ID" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release)"
  os_version="$(awk -F= '$1 == "VERSION_ID" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release)"
  if [[ "$os_id" != "debian" || ("$os_version" != "12" && "$os_version" != "13") ]]; then
    printf '错误：每周旧内核清理只支持 Debian 12/13。\n' >&2
    return 1
  fi
  if { have systemd-detect-virt && systemd-detect-virt --quiet --container; } || [[ -e /.dockerenv || -e /run/.containerenv ]]; then
    printf '错误：容器内核由宿主机控制，不能开启容器内旧内核清理。\n' >&2
    return 1
  fi
  if ! have systemctl || ! have systemd-analyze || ! have flock || [[ ! -d /run/systemd/system ]]; then
    printf '错误：缺少可用的 systemd、systemd-analyze 或 flock，无法创建安全定时任务。\n' >&2
    return 1
  fi
  if ((EUID != 0)) && ! have sudo; then
    printf '错误：开启定时任务需要 root 权限，且系统没有 sudo。\n' >&2
    return 1
  fi
  kernel_cleanup_build_plan
  preflight_status=$?
  if ((preflight_status == 2)); then
    printf '错误：开启前的安全检查未通过：%s\n' "$KERNEL_CLEANUP_REASON" >&2
    return 1
  fi
  check_kernel_cleanup_paths_safe || return 1

  new_temp_file || return 1
  helper_tmp="$NEW_TEMP_FILE"
  render_kernel_cleanup_helper >"$helper_tmp" || return 1
  new_temp_file || return 1
  service_tmp="$NEW_TEMP_FILE"
  render_kernel_cleanup_service >"$service_tmp" || return 1
  new_temp_file || return 1
  timer_tmp="$NEW_TEMP_FILE"
  render_kernel_cleanup_timer >"$timer_tmp" || return 1
  bash -n "$helper_tmp" || { printf '错误：旧内核清理执行器语法校验失败。\n' >&2; return 1; }

  if ! run_root install -o root -g root -m 0755 "$helper_tmp" "$KERNEL_CLEANUP_HELPER" ||
     ! run_root install -o root -g root -m 0644 "$service_tmp" "$KERNEL_CLEANUP_SERVICE" ||
     ! run_root install -o root -g root -m 0644 "$timer_tmp" "$KERNEL_CLEANUP_TIMER"; then
    printf '错误：无法安装旧内核清理定时任务文件。\n' >&2
    return 1
  fi
  if ! run_root systemd-analyze verify "$KERNEL_CLEANUP_SERVICE" "$KERNEL_CLEANUP_TIMER" ||
     ! run_root systemctl daemon-reload ||
     ! run_root systemctl enable --now debian-security-check-kernel-cleanup.timer; then
    printf '错误：无法校验或启用旧内核清理定时器；正在关闭定时器。\n' >&2
    run_root systemctl disable --now debian-security-check-kernel-cleanup.timer >/dev/null 2>&1 || true
    return 1
  fi
  for path in "$KERNEL_CLEANUP_HELPER" "$KERNEL_CLEANUP_SERVICE" "$KERNEL_CLEANUP_TIMER"; do
    if ! is_managed_kernel_cleanup_file "$path"; then
      printf '错误：安装后的受管文件校验失败：%s\n' "$path" >&2
      run_root systemctl disable --now debian-security-check-kernel-cleanup.timer >/dev/null 2>&1 || true
      return 1
    fi
  done
  printf '[通过] 已开启每周旧内核安全清理：每周日 04:15 后的30分钟随机窗口检查。\n'
  printf '[信息] 只有三个及以上同系列内核，且第三个或更旧内核安装满 %d 天时才会删除。\n' "$KERNEL_CLEANUP_MIN_AGE_DAYS"
}

disable_weekly_kernel_cleanup() {
  local path
  check_kernel_cleanup_paths_safe || return 1
  if have systemctl && [[ -d /run/systemd/system ]]; then
    run_root systemctl disable --now debian-security-check-kernel-cleanup.timer >/dev/null 2>&1 || true
  fi
  for path in "$KERNEL_CLEANUP_HELPER" "$KERNEL_CLEANUP_SERVICE" "$KERNEL_CLEANUP_TIMER"; do
    if [[ -e "$path" ]]; then
      run_root rm -f -- "$path" || return 1
    fi
  done
  if have systemctl && [[ -d /run/systemd/system ]]; then
    run_root systemctl daemon-reload || return 1
  fi
  printf '[通过] 已关闭并移除本脚本的每周旧内核清理任务。\n'
  printf '[信息] 没有删除任何内核或其他软件包。\n'
}

show_kernel_cleanup_timer_status() {
  local timer_state="未安装"
  if have systemctl && [[ -d /run/systemd/system ]]; then
    timer_state="$(systemctl is-enabled debian-security-check-kernel-cleanup.timer 2>/dev/null || true)"
  fi
  if [[ "$timer_state" == "enabled" ]] &&
     is_managed_kernel_cleanup_file "$KERNEL_CLEANUP_HELPER" &&
     is_managed_kernel_cleanup_file "$KERNEL_CLEANUP_SERVICE" &&
     is_managed_kernel_cleanup_file "$KERNEL_CLEANUP_TIMER"; then
    printf '[通过] 每周自动清理已开启：周日 04:15 后的30分钟随机窗口检查。\n'
    if systemctl is-failed --quiet debian-security-check-kernel-cleanup.service 2>/dev/null; then
      printf '[警告] 上一次自动清理失败；请查看：journalctl -u debian-security-check-kernel-cleanup.service\n'
    fi
  elif [[ -e "$KERNEL_CLEANUP_HELPER" || -e "$KERNEL_CLEANUP_SERVICE" || -e "$KERNEL_CLEANUP_TIMER" ]]; then
    printf '[信息] 每周自动清理未启用；检测到已停用或不完整的任务文件。\n'
  else
    printf '[信息] 每周自动清理未开启。\n'
  fi
}

inspect_kernel_cleanup_candidates() {
  local status
  kernel_cleanup_build_plan
  status=$?
  kernel_cleanup_print_plan
  case "$status" in
    0) printf '[信息] 以上“候选”仅供查看，本次没有删除任何软件包。\n' ;;
    3) printf '[通过] 当前没有符合全部安全条件的旧内核。\n' ;;
    *) printf '[错误] 安全前置检查未通过，本次没有删除任何软件包。\n' >&2 ;;
  esac
  return "$status"
}

run_manual_kernel_cleanup() (
  local status answer cleanup_lock_fd
  if ! have flock; then
    printf '[错误] 缺少 flock，无法安全执行旧内核清理。\n' >&2
    return 1
  fi
  exec {cleanup_lock_fd}>/run/debian-security-check-kernel-cleanup.lock || return 1
  if ! flock -n "$cleanup_lock_fd"; then
    printf '[错误] 另一个旧内核清理任务正在运行，本次没有删除任何软件包。\n' >&2
    return 1
  fi
  kernel_cleanup_build_plan
  status=$?
  kernel_cleanup_print_plan
  case "$status" in
    0) ;;
    3) printf '[通过] 当前没有符合全部安全条件的旧内核，未删除任何软件包。\n'; return 0 ;;
    *) printf '[错误] 安全前置检查未通过，未删除任何软件包。\n' >&2; return 1 ;;
  esac
  printf '%s确认只清理上面的 %d 个“候选”旧内核吗？[y/N]：%s' "$C_YELLOW" "${#KERNEL_CLEANUP_CANDIDATES[@]}" "$C_RESET"
  read -r answer || return 1
  case "$answer" in
    y|Y|yes|YES) ;;
    *) printf '已取消，没有删除任何软件包。\n'; return 0 ;;
  esac
  kernel_cleanup_purge_candidates
)

pause_for_kernel_cleanup_menu() {
  printf '\n%s按回车键返回旧内核清理菜单……%s' "$C_YELLOW" "$C_RESET"
  read -r _KERNEL_MENU_PAUSE || true
}

kernel_cleanup_settings_menu() {
  local choice script_path
  script_path="$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")"
  while true; do
    printf '\n%s%s旧内核安全清理（默认关闭）%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf '%s规则：只处理当前系列；保留当前最新内核和一个备用；第三个及更旧且满 %d 天才清理。%s\n' "$C_YELLOW" "$KERNEL_CLEANUP_MIN_AGE_DAYS" "$C_RESET"
    printf '\n%s%s%s\n' "$C_YELLOW" '  1) 查看可清理的旧内核（只检查，不删除）' "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  2) 立即安全清理一次（仍然遵守30天和保留规则）' "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  3) 开启每周自动检查和清理（周日低峰执行）' "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  4) 关闭每周自动清理' "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  5) 查看每周自动清理状态' "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" '  0) 返回主菜单' "$C_RESET"
    printf '\n%s请选择 [1/2/3/4/5/0]：%s' "$C_YELLOW" "$C_RESET"
    if ! read -r choice; then
      printf '\n未读取到选择，已退出。\n' >&2
      return 2
    fi
    case "$choice" in
      1) inspect_kernel_cleanup_candidates || true; pause_for_kernel_cleanup_menu ;;
      2) run_manual_kernel_cleanup || true; pause_for_kernel_cleanup_menu ;;
      3) enable_weekly_kernel_cleanup || true; pause_for_kernel_cleanup_menu ;;
      4) disable_weekly_kernel_cleanup || true; pause_for_kernel_cleanup_menu ;;
      5) show_kernel_cleanup_timer_status; pause_for_kernel_cleanup_menu ;;
      0)
        if [[ -r /dev/tty && -f "$script_path" ]]; then
          exec bash "$script_path" </dev/tty
        fi
        return 0
        ;;
      *) printf '输入无效，请输入 1、2、3、4、5 或 0。\n' >&2 ;;
    esac
  done
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
  local test_dir output config_output helper_test cleanup_helper_test failed=0
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

  output="$(kernel_dependency_candidates 'linux-image-6.12.115+deb13.1-amd64 (= 6.12.115-2), linux-base (>= 4.12) | linux-image-6.12.113+deb13-amd64:amd64')"
  if [[ "$output" != $'linux-image-6.12.115+deb13.1-amd64\nlinux-image-6.12.113+deb13-amd64' ]]; then
    printf '%s\n' 'SELF-TEST FAIL: 无法正确解析内核元包依赖。' >&2
    failed=1
  fi

  output="$(matching_kernel_meta_record '6.12.113+deb13-cloud-amd64' <<'EOF'
linux-image-amd64|6.12.115-2|linux-image-6.12.115+deb13.1-amd64|6.12.115-2|linux-signed-amd64|6.12.115+1
linux-image-cloud-amd64|6.12.115-2|linux-image-6.12.115+deb13.1-cloud-amd64|6.12.115-2|linux-signed-amd64|6.12.115+1
EOF
)"
  if [[ "$output" != linux-image-cloud-amd64\|* ]]; then
    printf '%s\n' 'SELF-TEST FAIL: 普通内核与 cloud 内核并存时没有选择正确元包。' >&2
    failed=1
  fi
  if ! is_official_debian_kernel_source linux-signed-amd64 ||
     ! is_official_debian_kernel_source linux-6.16 ||
     is_official_debian_kernel_source vendor-kernel; then
    printf '%s\n' 'SELF-TEST FAIL: Debian 官方内核源包识别错误。' >&2
    failed=1
  fi
  if ! kernel_target_requires_reboot linux-image-6.12.113+deb13-amd64 6.12.113-1 linux-image-6.12.115+deb13.1-amd64 6.12.115-2 ||
     kernel_target_requires_reboot linux-image-6.12.115+deb13.1-amd64 6.12.115-2 linux-image-6.12.115+deb13.1-amd64 6.12.115-2 ||
     kernel_target_requires_reboot linux-image-6.12.115+deb13.1-amd64 6.12.115-2 linux-image-6.12.113+deb13-amd64 6.12.113-1; then
    printf '%s\n' 'SELF-TEST FAIL: 新旧内核重启判断错误。' >&2
    failed=1
  fi

  output="$(classify_kernel_cleanup_records linux-image-6.12.115+deb13.1-amd64 10000000 30 <<'EOF'
linux-image-6.12.107+deb13-amd64|6.12.107-1|4816000
linux-image-6.12.113+deb13-amd64|6.12.113-1|6544000
linux-image-6.12.115+deb13.1-amd64|6.12.115-2|9568000
EOF
)"
  if ! grep -Fq 'candidate|linux-image-6.12.107+deb13-amd64|6.12.107-1|4816000|60' <<<"$output" ||
     ! grep -Fq 'fallback|linux-image-6.12.113+deb13-amd64|6.12.113-1|6544000|40' <<<"$output" ||
     ! grep -Fq 'current|linux-image-6.12.115+deb13.1-amd64|6.12.115-2|9568000|5' <<<"$output"; then
    printf '%s\n' 'SELF-TEST FAIL: 三个内核时的保留和候选分类错误。' >&2
    failed=1
  fi
  output="$(classify_kernel_cleanup_records linux-image-6.12.115+deb13.1-amd64 10000000 30 <<'EOF'
linux-image-6.12.113+deb13-amd64|6.12.113-1|4816000
linux-image-6.12.115+deb13.1-amd64|6.12.115-2|9568000
EOF
)"
  if grep -q '^candidate|' <<<"$output"; then
    printf '%s\n' 'SELF-TEST FAIL: 只有两个内核时错误地产生了清理候选。' >&2
    failed=1
  fi
  output="$(classify_kernel_cleanup_records linux-image-6.12.115+deb13.1-amd64 10000000 30 <<'EOF'
linux-image-6.12.107+deb13-amd64|6.12.107-1|8272000
linux-image-6.12.113+deb13-amd64|6.12.113-1|6544000
linux-image-6.12.115+deb13.1-amd64|6.12.115-2|9568000
EOF
)"
  if ! grep -Fq 'young|linux-image-6.12.107+deb13-amd64|6.12.107-1|8272000|20' <<<"$output" || grep -q '^candidate|' <<<"$output"; then
    printf '%s\n' 'SELF-TEST FAIL: 未满30天的第三个内核被错误列为候选。' >&2
    failed=1
  fi
  if ! kernel_cleanup_simulation_matches_candidates $'Remv linux-image-6.12.107+deb13-amd64 [6.12.107-1]\n' linux-image-6.12.107+deb13-amd64 ||
     kernel_cleanup_simulation_matches_candidates $'Remv linux-image-6.12.107+deb13-amd64 [6.12.107-1]\nRemv linux-image-amd64 [6.12.115-2]\n' linux-image-6.12.107+deb13-amd64 ||
     kernel_cleanup_simulation_matches_candidates $'Inst unrelated-package (1.0 Debian:stable [amd64])\nRemv linux-image-6.12.107+deb13-amd64 [6.12.107-1]\n' linux-image-6.12.107+deb13-amd64; then
    printf '%s\n' 'SELF-TEST FAIL: APT 模拟删除白名单校验错误。' >&2
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

  if ! is_valid_reboot_time "00:00" || ! is_valid_reboot_time "23:59" || is_valid_reboot_time "24:00" || is_valid_reboot_time "4:30"; then
    printf '%s\n' 'SELF-TEST FAIL: 自动重启时间校验错误。' >&2
    failed=1
  fi

  config_output="$(render_auto_update_config enabled-reboot 04:30)"
  if ! grep -Fq '#clear Unattended-Upgrade::Allowed-Origins;' <<<"$config_output" ||
     ! grep -Fq "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security" <<<"$config_output" ||
     ! grep -Fxq 'APT::Periodic::Unattended-Upgrade "0";' <<<"$config_output" ||
     ! grep -Fxq 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"$config_output" ||
     ! grep -Fxq 'Unattended-Upgrade::Automatic-Reboot-WithUsers "false";' <<<"$config_output" ||
     ! grep -Fxq 'Unattended-Upgrade::Remove-Unused-Dependencies "false";' <<<"$config_output" ||
     ! grep -Fxq 'Debian-Security-Check::Schedule-Time "04:30";' <<<"$config_output"; then
    printf '%s\n' 'SELF-TEST FAIL: 自动安全更新配置缺少安全限制。' >&2
    failed=1
  fi

  helper_test="$test_dir/auto-update-helper"
  render_auto_update_helper enabled-reboot >"$helper_test"
  if ! bash -n "$helper_test" ||
     [[ "$(head -n 1 "$helper_test")" != '#!/usr/bin/env bash' ]] ||
     ! grep -Fxq 'MODE="enabled-reboot"' "$helper_test" ||
     ! grep -Fq 'if ! unattended-upgrade; then' "$helper_test" ||
     ! grep -Fq 'KERNEL_TARGET_AFTER="$(pending_newer_kernel_target 2>/dev/null || true)"' "$helper_test" ||
     ! grep -Fq 'NEW_KERNEL_TARGET=1' "$helper_test" ||
     ! grep -Fq 'systemctl reboot' "$helper_test"; then
    printf '%s\n' 'SELF-TEST FAIL: 受控自动更新执行器不完整或语法错误。' >&2
    failed=1
  fi

  config_output="$(render_auto_update_timer 04:30)"
  if ! grep -Fxq 'OnCalendar=*-*-* 04:30:00' <<<"$config_output" ||
     ! grep -Fxq 'RandomizedDelaySec=5m' <<<"$config_output"; then
    printf '%s\n' 'SELF-TEST FAIL: systemd 定时器配置错误。' >&2
    failed=1
  fi

  cleanup_helper_test="$test_dir/kernel-cleanup-helper"
  render_kernel_cleanup_helper >"$cleanup_helper_test"
  if ! bash -n "$cleanup_helper_test" ||
     [[ "$(head -n 1 "$cleanup_helper_test")" != '#!/usr/bin/env bash' ]] ||
     ! grep -Fxq 'KERNEL_CLEANUP_MIN_AGE_DAYS=30' "$cleanup_helper_test" ||
     ! grep -Fq 'kernel_cleanup_build_plan' "$cleanup_helper_test" ||
     ! grep -Fq 'kernel_cleanup_purge_candidates' "$cleanup_helper_test" ||
     ! grep -Fq 'flock -n 9' "$cleanup_helper_test"; then
    printf '%s\n' 'SELF-TEST FAIL: 每周旧内核清理执行器不完整或语法错误。' >&2
    failed=1
  fi
  config_output="$(render_kernel_cleanup_timer)"
  if ! grep -Fxq 'OnCalendar=Sun *-*-* 04:15:00' <<<"$config_output" ||
     ! grep -Fxq 'RandomizedDelaySec=30m' <<<"$config_output"; then
    printf '%s\n' 'SELF-TEST FAIL: 每周旧内核清理定时器配置错误。' >&2
    failed=1
  fi

  config_output="$(render_auto_update_config disabled)"
  if ! grep -Fxq 'APT::Periodic::Unattended-Upgrade "0";' <<<"$config_output" ||
     ! grep -Fxq 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"$config_output"; then
    printf '%s\n' 'SELF-TEST FAIL: 关闭自动更新的配置不完整。' >&2
    failed=1
  fi

  rm -f -- "$test_dir/sources.list.d/ignored.list.save" "$test_dir/sources.list.d/disabled.sources" "$test_dir/sources.list.d/active.sources" "$helper_test" "$cleanup_helper_test"
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

if [[ "$MODE" == "auto-settings" ]]; then
  auto_update_settings_menu
  exit $?
fi

if [[ "$MODE" == "kernel-cleanup-settings" ]]; then
  kernel_cleanup_settings_menu
  exit $?
fi

printf '%sDebian 安全检查脚本 v%s%s\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"
printf '时间：%s\n' "$(date '+%F %T %Z')"
printf '主机：%s\n' "$(hostname -f 2>/dev/null || hostname)"

section "系统与支持状态"
for REQUIRED_COMMAND in apt apt-get apt-mark awk dpkg dpkg-query find grep mktemp sed sort uname; do
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

section "运行中内核、最新内核与 CVE-2026-98432"
RUNNING_RELEASE="$(uname -r)"
KERNEL_PACKAGE=""
BINARY_VERSION=""
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
    if is_official_debian_kernel_source "$SOURCE_PACKAGE"; then SOURCE_IS_OFFICIAL=1; fi

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
      warn "该官方内核分支不在 CVE-2026-98432 的内置修复表内；仅跳过这个特定 CVE 结论，不影响通用更新和最新内核判断。"
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
  is_official_debian_kernel_source "$INSTALLED_SOURCE" || continue

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

KERNEL_META_RECORDS="$(installed_kernel_meta_records || true)"
META_KERNELS="$(awk -F'|' 'NF >= 2 {print $1, $2}' <<<"$KERNEL_META_RECORDS" | sort -u)"
if [[ -n "$META_KERNELS" ]]; then
  ok "已安装内核元包，后续内核通常可随 APT 持续更新："
  sed 's/^/  /' <<<"$META_KERNELS"
else
  warn "未发现 linux-image-* 内核元包；未来可能收不到新 ABI 内核。请按机器类型确认应安装 linux-image-amd64、linux-image-cloud-amd64 或 linux-image-arm64 等元包。"
fi

if ((IN_CONTAINER == 0)) && [[ -n "$KERNEL_PACKAGE" && -n "$BINARY_VERSION" && -n "$KERNEL_META_RECORDS" ]]; then
  MATCHING_META_RECORD="$(matching_kernel_meta_record "$RUNNING_RELEASE" <<<"$KERNEL_META_RECORDS" || true)"
  if [[ -n "$MATCHING_META_RECORD" ]]; then
    IFS='|' read -r MATCHING_META META_VERSION TARGET_KERNEL_PACKAGE TARGET_KERNEL_VERSION TARGET_KERNEL_SOURCE _TARGET_KERNEL_SOURCE_VERSION <<<"$MATCHING_META_RECORD"
    info "当前内核系列由 $MATCHING_META $META_VERSION 跟踪；元包目标：$TARGET_KERNEL_PACKAGE $TARGET_KERNEL_VERSION"
    if ! is_official_debian_kernel_source "$TARGET_KERNEL_SOURCE"; then
      blocker "内核元包目标来自非 Debian 官方内核源包 $TARGET_KERNEL_SOURCE，已停止自动判断和重启。"
    elif [[ "$TARGET_KERNEL_PACKAGE" == "$KERNEL_PACKAGE" ]]; then
      ok "当前正在运行内核元包指向的最新内核。"
    elif kernel_target_requires_reboot "$KERNEL_PACKAGE" "$BINARY_VERSION" "$TARGET_KERNEL_PACKAGE" "$TARGET_KERNEL_VERSION"; then
      REBOOT_RECOMMENDED=1
      if ((RUNNING_KERNEL_VULNERABLE)); then
        info "内核元包指向的较新官方内核已经安装，重启后将启用：$TARGET_KERNEL_PACKAGE"
      else
        warn "较新的 Debian 官方内核已经安装，但当前仍在运行 $KERNEL_PACKAGE；需要重启以启用 $TARGET_KERNEL_PACKAGE。"
      fi
    else
      ok "当前运行内核不低于内核元包目标；不会为较旧目标触发重启。"
    fi
  else
    warn "已安装内核元包，但没有找到与当前 $RUNNING_RELEASE 同系列的元包；无法通用判断是否正在运行最新内核。"
  fi
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
  info "未安装 needrestart；仍会依据 /run/reboot-required 和内核元包目标判断是否需要重启。"
fi

section "自动安全更新"
if installed unattended-upgrades; then
  ok "已安装 unattended-upgrades。"
  AUTO_APT_DUMP="$(apt-config dump 2>/dev/null || true)"
  if have systemctl && [[ -d /run/systemd/system ]] &&
     systemctl is-enabled --quiet debian-security-check-auto-update.timer 2>/dev/null; then
    AUTO_SCHEDULE_TIME="$(sed -nE 's/^Debian-Security-Check::Schedule-Time "([0-9]{2}:[0-9]{2})";$/\1/p' <<<"$AUTO_APT_DUMP" | tail -n 1)"
    if is_managed_auto_update_config &&
       is_managed_auto_update_runtime_file "$AUTO_UPDATE_HELPER" &&
       is_managed_auto_update_runtime_file "$AUTO_UPDATE_SERVICE" &&
       is_managed_auto_update_runtime_file "$AUTO_UPDATE_TIMER"; then
      ok "本脚本受控安全更新已启用；每天 ${AUTO_SCHEDULE_TIME:-配置时间} 执行。"
      if systemctl is-failed --quiet debian-security-check-auto-update.service 2>/dev/null; then
        warn "上一次受控安全更新执行失败；请查看：journalctl -u debian-security-check-auto-update.service"
      fi
      if grep -Fxq 'MODE="enabled-reboot"' "$AUTO_UPDATE_HELPER"; then
        info "更新完整成功、本次新产生重启要求或安装新内核且无人登录时，才会自动重启。"
      else
        info "自动安装安全更新后不会自动重启。"
      fi
    else
      warn "本脚本定时器已启用，但配置或执行文件不完整/不属于本脚本。"
    fi
  elif grep -Fxq 'APT::Periodic::Unattended-Upgrade "1";' <<<"$AUTO_APT_DUMP"; then
    ok "检测到系统原有的 APT 每日无人值守安装；其更新来源由系统现有配置决定。"
  else
    warn "unattended-upgrades 已安装，但长期自动安装没有启用。可从主菜单选 2 设置。"
  fi
  if grep -Fxq 'Unattended-Upgrade::Automatic-Reboot "true";' <<<"$AUTO_APT_DUMP"; then
    warn "检测到系统原有的 unattended-upgrades 自动重启开关；本脚本的受控模式不会开启该开关。"
  fi
else
  warn "未安装 unattended-upgrades；可从主菜单选 2 设置长期自动安全更新。"
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
    printf '%s当前没有剩余 APT 更新，也不需要重启；脚本没有删除软件包。%s\n' "$C_GREEN" "$C_RESET"
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
