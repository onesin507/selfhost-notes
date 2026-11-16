#!/usr/bin/env bash
# kernel-fallback-check.sh — 升级内核、重启之前，检查这台机器有没有退路
#
# 用途：
#   内核更新偶尔会出问题（比如 2026-11 Debian 12 的 6.1.0-55，重启后几分钟到几小时内整机卡死）。
#   出事时能不能救回来，取决于重启前的几件事：
#     1. 现在跑的是哪个内核，下次重启会进哪个（默认是装着的最新那个）；
#     2. 除了下次要进的那个，还有没有别的完整内核（vmlinuz + initrd 都在）可以退回去；
#     3. 有没有已知有问题的内核版本（用 -b 指定）正在跑，或者下次重启就会进；
#     4. GRUB 默认启动项、启动菜单是否隐藏、unattended-upgrades 会不会自动重启。
#   脚本只读：不改 GRUB，不装卸软件包，不重启。
#
# 用法：
#   kernel-fallback-check.sh [选项]
#   选项：
#     -b 模式     已知有问题的内核版本，按子串匹配；可以写多次。匹配的对象是
#                 「uname -r 那种写法 + 内核包的版本号」，比如 6.1.0-55-cloud-arm64 6.1.192-1。
#                 Debian 的修复版常常沿用同一个 uname -r（6.1.192-2 还是 6.1.0-55），
#                 这时要写包版本（-b 6.1.192-1），别写 6.1.0-55，不然修好的也会被当成坏的
#     -m 个数     至少要有几个可以退回去的旧内核，默认 1
#     -R 目录     检查挂在别处的系统（比如救援模式下挂到 /mnt 的根分区），默认 /；
#                 用了 -R 时不看当前运行的内核（除非同时给 -r）
#     -r 版本     把这个当成「正在跑的内核」，默认取 uname -r
#     -q          只在有问题（WARN / CRIT）时输出，适合 cron
#     -h          显示帮助
#
# 退出码：0 正常；1 有 WARN；2 有 CRIT；64 用法错误
#
# 依赖：bash 4+、GNU coreutils（sort -V）、grep、sed。apt-mark 可选（看内核包有没有被 hold）。
#       适用于 /boot 下放 vmlinuz-版本 和 initrd.img-版本（或 initramfs-版本.img）的发行版：
#       Debian、Ubuntu、RHEL 系都是这样。用 systemd-boot / UKI 的机器结果只作参考。
#
# 示例：
#   ./kernel-fallback-check.sh
#   ./kernel-fallback-check.sh -b 6.1.192-1         # Debian 12 在 2026-11-14 推的那一版
#   sudo ./kernel-fallback-check.sh -R /mnt -b 6.1.192-1
#
# 思路来源：Debian bug #1154101 里大家的救法（GRUB 选回 6.1.0-54）
#   https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1154101
#
# 许可证：MIT

set -uo pipefail

ROOT="/"
RUNNING=""
RUNNING_BUILD=""
RUNNING_SET=0
MIN_FALLBACK=1
QUIET=0
BAD=()
WORST=0
OUTPUT=()
HINTS=()

usage() {
  sed -n '2,/^# 许可证/p' "$0" | sed 's/^# \{0,1\}//'
}

while getopts ":b:m:R:r:qh" opt; do
  case "$opt" in
    b) BAD+=("$OPTARG") ;;
    m) MIN_FALLBACK="$OPTARG" ;;
    R) ROOT="$OPTARG" ;;
    r) RUNNING="$OPTARG"; RUNNING_SET=1 ;;
    q) QUIET=1 ;;
    h) usage; exit 0 ;;
    :) echo "选项 -$OPTARG 需要参数" >&2; exit 64 ;;
    *) echo "未知选项：-$OPTARG（-h 看帮助）" >&2; exit 64 ;;
  esac
done
shift $((OPTIND - 1))
if [ $# -gt 0 ]; then
  echo "多余的参数：$*（-h 看帮助）" >&2
  exit 64
fi
if ! [[ "$MIN_FALLBACK" =~ ^[0-9]+$ ]]; then
  echo "-m 要写非负整数" >&2
  exit 64
fi
if [ ! -d "$ROOT" ]; then
  echo "目录不存在：$ROOT" >&2
  exit 64
fi
ROOT="${ROOT%/}"   # "/" 变成 ""，后面统一写 "$ROOT/boot"

if [ "$RUNNING_SET" -eq 0 ] && [ -z "$ROOT" ]; then
  RUNNING="$(uname -r)"
  RUNNING_BUILD="$(uname -v)"   # Debian 在这里写包版本，如 "#1 SMP ... Debian 6.1.192-1 (2026-11-14)"
fi

# 记一行结果：状态 项目 说明
add() {
  local state="$1" item="$2" detail="$3" lvl=0
  case "$state" in
    WARN) lvl=1 ;;
    CRIT) lvl=2 ;;
  esac
  [ "$lvl" -gt "$WORST" ] && WORST=$lvl
  OUTPUT+=("$(printf '%-5s %-10s %s' "$state" "$item" "$detail")")
}

is_bad() {
  local v="$1" p
  for p in "${BAD[@]+"${BAD[@]}"}"; do
    [ -n "$p" ] && [[ "$v" == *"$p"* ]] && return 0
  done
  return 1
}

# 内核包的版本号（Debian/Ubuntu 才有；查不到就是空）
pkgver() {
  command -v dpkg-query >/dev/null 2>&1 || return 0
  [ -d "$ROOT/var/lib/dpkg" ] || return 0
  dpkg-query --admindir="$ROOT/var/lib/dpkg" -W -f='${Version}\n' \
    "linux-image-$1" "linux-image-$1-unsigned" 2>/dev/null | grep -m1 . || true
}

# 显示用：6.1.0-55-cloud-arm64（包 6.1.192-1）
label() {
  local pv; pv="$(pkgver "$1")"
  printf '%s%s' "$1" "${pv:+（包 $pv）}"
}

# 某个已安装内核是不是坏的：uname -r 写法和包版本一起匹配
kernel_bad() {
  is_bad "$1 $(pkgver "$1") ${2:-}"
}

has_initrd() {
  local v="$1"
  [ -s "$ROOT/boot/initrd.img-$v" ] || [ -s "$ROOT/boot/initramfs-$v.img" ]
}

# ---- 1. 装了哪些内核 ----
mapfile -t KERNELS < <(
  for f in "$ROOT"/boot/vmlinuz-*; do
    [ -e "$f" ] || continue
    v="${f##*/vmlinuz-}"
    case "$v" in *.old|*rescue*) continue ;; esac
    printf '%s\n' "$v"
  done | sort -V
)

if [ "${#KERNELS[@]}" -eq 0 ]; then
  add WARN "内核列表" "$ROOT/boot 下没有 vmlinuz-*（容器、UKI 或 /boot 没挂上？），判断不了"
  if [ -n "$RUNNING" ] && kernel_bad "$RUNNING" "$RUNNING_BUILD"; then
    add CRIT "正在运行" "$RUNNING 匹配已知有问题的版本"
  fi
else
  BOOTABLE=()
  for v in "${KERNELS[@]}"; do
    if has_initrd "$v"; then
      BOOTABLE+=("$v")
    else
      add WARN "缺 initrd" "$v 没有 initrd，这个内核多半起不来，别指望它当退路"
    fi
  done
  NEWEST="${KERNELS[${#KERNELS[@]}-1]}"
  add INFO "已安装" "${KERNELS[*]}"

  # ---- 2. 正在跑的和下次重启要进的 ----
  if [ -n "$RUNNING" ]; then
    if kernel_bad "$RUNNING" "$RUNNING_BUILD"; then
      add CRIT "正在运行" "$(label "$RUNNING") 匹配已知有问题的版本，尽快重启进别的内核"
    else
      add OK "正在运行" "$(label "$RUNNING")"
    fi
    found=0
    for v in "${KERNELS[@]}"; do [ "$v" = "$RUNNING" ] && found=1; done
    if [ "$found" -eq 0 ]; then
      add WARN "正在运行" "$RUNNING 的文件已经不在 $ROOT/boot 里了（被 autoremove 删掉？），它不能再当退路"
    fi
  fi

  if kernel_bad "$NEWEST"; then
    add CRIT "下次重启" "默认会进 $(label "$NEWEST")，它匹配已知有问题的版本"
    HINTS+=("等修复版装上再重启；非重启不可，就用 grub-reboot 只让下一次启动进旧内核（见 README）")
  elif [ -n "$RUNNING" ] && [ "$NEWEST" != "$RUNNING" ]; then
    add INFO "下次重启" "默认会进 $(label "$NEWEST")（比正在跑的新）"
  else
    add OK "下次重启" "默认会进 $(label "$NEWEST")"
  fi

  # ---- 3. 有没有退路 ----
  FALLBACK=()
  for v in "${BOOTABLE[@]+"${BOOTABLE[@]}"}"; do
    [ "$v" = "$NEWEST" ] && continue
    kernel_bad "$v" && continue
    FALLBACK+=("$v")
  done
  if [ "${#FALLBACK[@]}" -lt "$MIN_FALLBACK" ]; then
    add WARN "退路" "可以退回去的旧内核只有 ${#FALLBACK[@]} 个（要求至少 $MIN_FALLBACK 个）：新内核出事时没有旧内核可选"
    HINTS+=("重启进新内核、确认没问题之前，别跑 apt autoremove 把旧内核删掉")
  else
    add OK "退路" "${FALLBACK[*]}"
  fi

  for v in "${KERNELS[@]}"; do
    [ "$v" = "$NEWEST" ] && continue
    [ -n "$RUNNING" ] && [ "$v" = "$RUNNING" ] && continue
    kernel_bad "$v" && add WARN "有问题的" "$(label "$v") 还装着，不是默认启动项，别手动选它"
  done
fi

# ---- 4. 重启待办 ----
if [ -e "$ROOT/var/run/reboot-required" ] || [ -e "$ROOT/run/reboot-required" ]; then
  pkgs=""
  for f in "$ROOT/var/run/reboot-required.pkgs" "$ROOT/run/reboot-required.pkgs"; do
    [ -r "$f" ] && pkgs="$(sort -u "$f" | tr '\n' ' ')" && pkgs="${pkgs% }" && break
  done
  add INFO "待重启" "系统标记了需要重启${pkgs:+（$pkgs）}"
fi

# ---- 5. GRUB ----
GRUB_CFG="$ROOT/etc/default/grub"
if [ -r "$GRUB_CFG" ]; then
  gdef="$(grep -E '^[[:space:]]*GRUB_DEFAULT=' "$GRUB_CFG" | tail -n1 | cut -d= -f2- | tr -d '"'\''')"
  gto="$(grep -E '^[[:space:]]*GRUB_TIMEOUT=' "$GRUB_CFG" | tail -n1 | cut -d= -f2- | tr -d '"'\''')"
  gstyle="$(grep -E '^[[:space:]]*GRUB_TIMEOUT_STYLE=' "$GRUB_CFG" | tail -n1 | cut -d= -f2- | tr -d '"'\''')"
  case "${gdef:-0}" in
    0) add OK "GRUB 默认" "GRUB_DEFAULT=0（第一项，也就是最新内核）" ;;
    saved)
      saved=""
      [ -r "$ROOT/boot/grub/grubenv" ] && saved="$(sed -n 's/^saved_entry=//p' "$ROOT/boot/grub/grubenv")"
      add INFO "GRUB 默认" "GRUB_DEFAULT=saved，当前记住的是：${saved:-（空，等于第一项）}；上面「下次重启」按最新内核估计，以这里为准" ;;
    *) add INFO "GRUB 默认" "GRUB_DEFAULT=$gdef，不是第一项；上面「下次重启」按最新内核估计，以这里为准" ;;
  esac
  if [ "${gto:-5}" = "0" ] || [ "$gstyle" = "hidden" ]; then
    add INFO "启动菜单" "菜单不显示（GRUB_TIMEOUT=${gto:-?}${gstyle:+, STYLE=$gstyle}），出事时要靠串口/VNC 控制台按 Esc 才能选旧内核"
  fi
else
  add INFO "GRUB" "没有 $GRUB_CFG（不是 GRUB 引导，或文件不可读）"
fi

# ---- 6. unattended-upgrades 会不会自动重启 ----
AUTO_REBOOT=""
if [ -d "$ROOT/etc/apt/apt.conf.d" ]; then
  AUTO_REBOOT="$(grep -hsE '^[[:space:]]*Unattended-Upgrade::Automatic-Reboot[[:space:]]+"?(true|1|yes)"?' "$ROOT"/etc/apt/apt.conf.d/* | tail -n1)"
fi
if [ -n "$AUTO_REBOOT" ]; then
  rtime="$(grep -hsE '^[[:space:]]*Unattended-Upgrade::Automatic-Reboot-Time' "$ROOT"/etc/apt/apt.conf.d/* | tail -n1 | sed -E 's/.*"([^"]*)".*/\1/')"
  add INFO "自动重启" "unattended-upgrades 装完内核会自己重启${rtime:+（时间 $rtime）}，坏内核会在没人看着时生效"
fi

# ---- 7. 内核包有没有被 hold ----
if [ -z "$ROOT" ] && command -v apt-mark >/dev/null 2>&1; then
  held="$(apt-mark showhold 2>/dev/null | grep -E '^linux-(image|generic|virtual|oracle|aws|azure|gcp|kvm|cloud)' | tr '\n' ' ')"
  [ -n "$held" ] && add INFO "hold" "这些内核包被 hold 了，不会自动升级：$held"
fi

# ---- 输出 ----
if [ "$QUIET" -eq 1 ] && [ "$WORST" -eq 0 ]; then
  exit 0
fi
printf '%-5s %-10s %s\n' "STATE" "ITEM" "DETAIL"
printf '%s\n' "${OUTPUT[@]}"
if [ "${#HINTS[@]}" -gt 0 ]; then
  echo
  echo "建议："
  printf '  - %s\n' "${HINTS[@]}"
fi
exit "$WORST"
