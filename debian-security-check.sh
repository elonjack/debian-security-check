#!/usr/bin/env bash
# Debian 12/13 security health check and conservative updater.
# Interactive check mode does not install or remove packages. It only refreshes APT metadata.

set -u
set -o pipefail

SCRIPT_VERSION="1.2.2"
MODE="check"
INTERACTIVE_MENU=0
REFRESH_APT=1
WARNINGS=0
CRITICALS=0
PATCH_RECOMMENDED=0
REBOOT_RECOMMENDED=0
PREFLIGHT_CRITICALS=0

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
  -V, --version 显示脚本版本
  -h, --help    显示帮助

退出码：0=未发现需处理项，1=有警告/待更新/待重启，2=严重问题或检查失败。

推荐流程：打开菜单后先选 1，并按照最后的“下一步”操作；检查通过时不要再选 2。
EOF
}

if (($# == 0)) && [[ -t 0 ]]; then
  INTERACTIVE_MENU=1
  printf '\n%sDebian 安全检查与修复 v%s%s\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"
  printf '%s\n' '建议第一次使用时先选择 1。只有检查结果建议修复时，才选择 2。'

  while true; do
    printf '\n%s\n' '  1) 普通检查（推荐先选，不安装更新）'
    printf '%s\n' '  2) 检查并修复（安装所有已配置 APT 源的可用更新）'
    printf '%s\n'   '  0) 退出'
    printf '\n请选择 [1/2/0]：'

    if ! read -r MENU_CHOICE; then
      printf '\n未读取到选择，已退出。\n' >&2
      exit 2
    fi

    case "$MENU_CHOICE" in
      1)
        MODE="check"
        break
        ;;
      2)
        printf '\n修复模式会先检查，然后安装所有已配置 APT 软件源的可用更新（可能包括第三方源），但不会自动重启。\n'
        printf '确认继续吗？[y/N]：'
        read -r CONFIRM_FIX || CONFIRM_FIX=""
        case "$CONFIRM_FIX" in
          y|Y|yes|YES|Yes)
            MODE="fix"
            break
            ;;
          *)
            printf '已取消修复，返回菜单。\n'
            ;;
        esac
        ;;
      0)
        printf '已退出，没有修改系统。\n'
        exit 0
        ;;
      *)
        printf '输入无效，请输入 1、2 或 0。\n' >&2
        ;;
    esac
  done
fi

while (($#)); do
  case "$1" in
    --check) MODE="check" ;;
    --fix) MODE="fix" ;;
    --no-refresh) REFRESH_APT=0 ;;
    -V|--version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数：%s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$MODE" == "fix" && "$REFRESH_APT" -eq 0 ]]; then
  printf '%s\n' '错误：--fix 不能与 --no-refresh 同时使用；修复前必须取得最新的软件包索引。' >&2
  exit 2
fi

section() { printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_BLUE" "$1" "$C_RESET"; }
ok() { printf '%s[通过]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; WARNINGS=$((WARNINGS + 1)); }
critical() { printf '%s[严重]%s %s\n' "$C_RED" "$C_RESET" "$*"; CRITICALS=$((CRITICALS + 1)); }

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

export LC_ALL=C
export LANG=C

printf '%sDebian 安全检查脚本 v%s%s\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"
printf '时间：%s\n' "$(date '+%F %T %Z')"
printf '主机：%s\n' "$(hostname -f 2>/dev/null || hostname)"

section "系统与支持状态"
if [[ ! -r /etc/os-release ]]; then
  critical "找不到 /etc/os-release，无法识别系统。"
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
  critical "该脚本只对 Debian 官方软件包给出漏洞结论；当前 ID=$OS_ID。"
fi

case "$VERSION" in
  13)
    [[ -n "$CODENAME" ]] || CODENAME="trixie"
    ok "Debian 13 当前处于官方支持期。"
    ;;
  12)
    [[ -n "$CODENAME" ]] || CODENAME="bookworm"
    case "$ARCH" in
      amd64|i386|arm64|armhf|ppc64el) ok "Debian 12 LTS 架构受支持（支持至 2028-06-30）。" ;;
      *) critical "Debian 12 LTS 不支持当前架构 $ARCH；应升级至 Debian 13。" ;;
    esac
    ;;
  11)
    [[ -n "$CODENAME" ]] || CODENAME="bullseye"
    critical "Debian 11 官方 LTS 已于 2026-08-31 结束；应升级至 Debian 12/13 或使用 ELTS。"
    ;;
  *)
    critical "Debian $VERSION 不在本脚本支持的 Debian 12/13 范围内。"
    ;;
esac

if { have systemd-detect-virt && systemd-detect-virt --quiet --container; } || [[ -e /.dockerenv || -e /run/.containerenv ]]; then
  IN_CONTAINER=1
  warn "检测到容器环境：容器共享宿主机内核，必须在宿主机更新并重启内核。"
else
  IN_CONTAINER=0
fi

section "APT 安全源"
SOURCE_PATHS=(/etc/apt/sources.list /etc/apt/sources.list.d)
SOURCE_TEXT="$(grep -RhsE '^[[:space:]]*(deb |Suites:|URIs:|Components:)' "${SOURCE_PATHS[@]}" 2>/dev/null || true)"

if [[ -n "$CODENAME" ]] && grep -Eq "(^|[[:space:]])${CODENAME}-security([[:space:]]|$)" <<<"$SOURCE_TEXT"; then
  ok "已配置 ${CODENAME}-security。"
elif grep -Eqi '(^|[[:space:]])(stable|oldstable)-security([[:space:]]|$)' <<<"$SOURCE_TEXT"; then
  warn "发现 security 源，但使用了滚动别名；建议改成 ${CODENAME}-security，避免版本切换时意外跨版本。"
else
  critical "未发现 ${CODENAME}-security APT 源；拿不到官方安全更新。"
fi

if grep -Eqi '(^|[[:space:]])(testing|unstable|sid|forky)([[:space:]]|$)' <<<"$SOURCE_TEXT"; then
  warn "发现 testing/unstable/sid/forky 软件源；混用发行版会影响安全版本判断。"
fi

section "刷新软件包索引"
if ((REFRESH_APT)); then
  APT_LOG="$(mktemp -t debian-security-check.XXXXXX)"
  trap 'rm -f "${APT_LOG:-}"' EXIT
  info "执行 apt-get update（只更新索引，不安装包）……"
  if run_root apt-get update -o APT::Update::Error-Mode=any >"$APT_LOG" 2>&1; then
    ok "APT 索引刷新成功。"
  else
    critical "apt-get update 失败；下面是最后 20 行输出："
    tail -n 20 "$APT_LOG"
  fi
else
  warn "已跳过 apt-get update；后续结果可能过期。"
fi

PREFLIGHT_CRITICALS=$CRITICALS

if [[ "$MODE" == "fix" ]]; then
  section "修复前检查"
  mapfile -t PRE_HELD_PACKAGES < <(apt-mark showhold 2>/dev/null || true)
  mapfile -t PRE_UPGRADABLE < <(apt list --upgradable 2>/dev/null | sed '1{/Listing/d;}' || true)

  if ((${#PRE_HELD_PACKAGES[@]})); then
    info "修复前发现被 hold 的包：${PRE_HELD_PACKAGES[*]}（脚本不会擅自解除 hold）。"
  else
    ok "修复前没有被 hold 的软件包。"
  fi

  if ((${#PRE_UPGRADABLE[@]})); then
    info "修复前有 ${#PRE_UPGRADABLE[@]} 个软件包可更新。"
  else
    ok "修复前没有普通 APT 更新可安装。"
  fi

  section "安装更新"
  if ((EUID != 0)) && ! have sudo; then
    critical "--fix 需要 root 权限，且系统没有 sudo。请用 root 运行。"
  elif ((PREFLIGHT_CRITICALS > 0)); then
    critical "修复前检查存在严重问题。为避免错误升级，已停止安装；请先处理上面的严重项。"
  else
    info "执行 apt-get -y upgrade --with-new-pkgs；不会主动删除软件，也不会自动重启。"
    if run_root apt-get -y upgrade --with-new-pkgs; then
      ok "可安全升级的软件包已处理。"
    else
      critical "升级失败，请检查上面的 APT/dpkg 错误。"
    fi
  fi
fi

section "待更新与被锁定的软件包"
mapfile -t HELD_PACKAGES < <(apt-mark showhold 2>/dev/null || true)
if ((${#HELD_PACKAGES[@]})); then
  warn "发现被 hold 的包：${HELD_PACKAGES[*]}"
else
  ok "没有被 hold 的软件包。"
fi

mapfile -t UPGRADABLE < <(apt list --upgradable 2>/dev/null | sed '1{/Listing/d;}' || true)
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
    critical "运行内核不属于已安装的 Debian 包 $KERNEL_PACKAGE；可能是云厂商/Proxmox/自编译内核，请向内核提供方确认补丁。"
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
      critical "运行内核来源 $SOURCE_PACKAGE 不在 Debian 官方内核源包白名单内，不能自动判定 CVE 状态。"
    elif [[ -z "$FIXED_UPSTREAM" ]]; then
      critical "该内核分支不在 Debian 12/13 官方修复表内，不能自动判定 CVE 状态。"
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
        PATCH_RECOMMENDED=1
        critical "运行中内核仍低于修复线 $FIXED_DEBIAN；更新内核后必须重启。"
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
  if run_root needrestart -p -k >/dev/null 2>&1; then
    ok "needrestart 未报告过期的运行中内核。"
  else
    REBOOT_RECOMMENDED=1
    warn "needrestart 认为当前运行内核可能已过期，请安排重启。"
  fi
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

section "结论"
if ((CRITICALS > 0)); then
  printf '%s发现 %d 个严重问题、%d 个警告。%s\n' "$C_RED" "$CRITICALS" "$WARNINGS" "$C_RESET"
elif ((WARNINGS > 0)); then
  printf '%s没有发现已确认的严重问题，但有 %d 个警告/待处理项。%s\n' "$C_YELLOW" "$WARNINGS" "$C_RESET"
else
  printf '%s检查完成，未发现当前可安装更新或本脚本能够确认的严重问题。%s\n' "$C_GREEN" "$C_RESET"
fi

section "下一步"
SCRIPT_NAME="${0##*/}"

if ((PREFLIGHT_CRITICALS > 0)); then
  printf '%s先不要运行 --fix。%s 系统版本、软件源或 APT 刷新存在严重问题，请先处理上面的“严重”项目。\n' "$C_RED" "$C_RESET"
elif [[ "$MODE" == "check" ]]; then
  if ((PATCH_RECOMMENDED)); then
    printf '%s发现可尝试通过 Debian 更新修复的问题。%s 下一步运行：\n' "$C_YELLOW" "$C_RESET"
    if ((INTERACTIVE_MENU)); then
      printf '  sudo bash %q\n' "$SCRIPT_NAME"
      printf '然后在菜单中选择 2“检查并修复”。\n'
    else
      printf '  sudo bash %q --fix\n' "$SCRIPT_NAME"
    fi
    printf '修复结束后按照提示决定是否重启；之后再运行一次普通检查。\n'
  elif ((REBOOT_RECOMMENDED)); then
    printf '%s更新可能已经安装，目前只需要先重启：%s\n' "$C_YELLOW" "$C_RESET"
    printf '  sudo reboot\n'
    printf '服务器恢复后，再运行一次普通检查。此时无需先运行 --fix。\n'
  elif ((CRITICALS > 0)); then
    printf '%s存在无法由本脚本自动判断或修复的问题。%s 请按上面的严重提示人工处理，不要把运行 --fix 当成已经修好。\n' "$C_RED" "$C_RESET"
  else
    printf '%s当前没有可通过本脚本安装的更新，无需运行 --fix。%s 这不代表所有第三方软件或尚无补丁的漏洞都已消失。\n' "$C_GREEN" "$C_RESET"
  fi
else
  if ((REBOOT_RECOMMENDED)); then
    printf '%s补丁已经安装或内核已经更新，下一步需要重启：%s\n' "$C_YELLOW" "$C_RESET"
    printf '  sudo reboot\n'
    printf '服务器恢复后，再运行：\n'
    printf '  sudo bash %q\n' "$SCRIPT_NAME"
  elif ((PATCH_RECOMMENDED)); then
    printf '%s修复后仍有可更新项目或运行内核仍有风险。%s 不要反复盲目运行 --fix，请查看上面的 hold、依赖或内核提示。\n' "$C_RED" "$C_RESET"
  elif ((CRITICALS > 0)); then
    printf '%s仍有脚本无法自动解决的严重问题。%s 请按照上面的提示人工处理。\n' "$C_RED" "$C_RESET"
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
