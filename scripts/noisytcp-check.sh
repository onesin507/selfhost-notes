#!/usr/bin/env bash
# noisytcp-check.sh — 检查本机有没有修 NoisyTCP（CVE-2026-99288，Linux 内核 TCP 远程打崩），没修的话临时缓解开了没有
#
# 用途：
#   NoisyTCP 是 Linux 内核 TCP 收包路径里的竞态漏洞，2015 年引入，2026-11-03 上游修复，
#   2026-11-15 公开。机器只要有对外监听的 TCP 端口（sshd、nginx、apache 默认配置就算），
#   网卡有 2 个以上收包队列或开了 RPS，就可能被远程打到内核崩溃（整台机器重启，容器也救不了）。
#   脚本只读，查四件事：
#     1. 正在跑的内核修没修（Debian 看包版本；Ubuntu / RHEL 系看内核包 changelog 里有没有这个 CVE）；
#     2. 装了修复版但还没重启进去的情况；
#     3. 临时缓解：net.ipv4.tcp_syncookies 是不是 0、对外网卡是不是只剩 1 个收包队列且没开 RPS；
#     4. 有没有监听在非回环地址上的 TCP 端口。
#   不改 sysctl，不动网卡，不装软件，不重启。
#
# 用法：
#   noisytcp-check.sh [选项]
#   选项：
#     -i 网卡     要检查收包队列的网卡，可以写多次；默认取默认路由（IPv4 和 IPv6）走的网卡
#     -D 代号     把系统当成这个 Debian 代号（bookworm / trixie），测试用
#     -V 版本     把正在跑的内核当成这个 Debian 包版本（比如 6.1.192-1），测试用
#     -P 版本     把已经装好的内核包当成这个 Debian 包版本（测“装了没重启”），测试用
#     -q          只在有问题（WARN / CRIT）时输出，适合 cron
#     -h          显示帮助
#
# 退出码：0 正常；1 有 WARN；2 有 CRIT；64 用法错误
#
# 依赖：bash 4+、grep、sed、awk、iproute2（ip、ss）。dpkg 或 rpm 二选一（看内核包），zgrep 可选。
#       不需要 root；容器里跑只能看到容器自己的网络命名空间。
#
# 判断依据（2026-11-17 查的，之后发行版会更新，以下面两个页面为准）：
#   Debian：bookworm 修复版 6.1.192-1（但这一版有 ext4 死机问题，要装 6.1.192-2），
#           trixie 修复版 6.12.117-1，sid 7.3.4-1
#           https://security-tracker.debian.org/tracker/CVE-2026-99288
#   Ubuntu：当天所有版本都还是 Needs evaluation，没有修复包
#           https://ubuntu.com/security/CVE-2026-99288
#   上游修复提交 4e2b3ef19e0e；原始公告 https://www.openwall.com/lists/oss-security/2026/11/15/2
#
# 示例：
#   ./noisytcp-check.sh
#   ./noisytcp-check.sh -i eth0 -i ens3
#   ./noisytcp-check.sh -D bookworm -V 6.1.192-1      # 假装是 Debian 12 跑着 6.1.192-1，看判断
#
# 许可证：MIT

set -uo pipefail

CVE="CVE-2026-99288"
IFACES=()
FAKE_CODENAME=""
FAKE_VERSION=""
FAKE_PKG_VERSION=""
QUIET=0
WORST=0
OUTPUT=()
HINTS=()

usage() {
  sed -n '2,/^# 许可证/p' "$0" | sed 's/^# \{0,1\}//'
}

while getopts ":i:D:V:P:qh" opt; do
  case "$opt" in
    i) IFACES+=("$OPTARG") ;;
    D) FAKE_CODENAME="$OPTARG" ;;
    V) FAKE_VERSION="$OPTARG" ;;
    P) FAKE_PKG_VERSION="$OPTARG" ;;
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

# level: 0 OK, 1 INFO, 2 WARN, 3 CRIT
report() {
  local level="$1"; shift
  local tag
  case "$level" in
    0) tag="OK  " ;;
    1) tag="INFO" ;;
    2) tag="WARN"; [ "$WORST" -lt 1 ] && WORST=1 ;;
    3) tag="CRIT"; WORST=2 ;;
  esac
  OUTPUT+=("$tag  $*")
}

have() { command -v "$1" >/dev/null 2>&1; }

# dpkg --compare-versions 的简单替身：没有 dpkg 时用 sort -V 近似
ver_ge() {
  if have dpkg; then
    dpkg --compare-versions "$1" ge "$2"
  else
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
  fi
}

# ---------- 1. 系统和内核 ----------
OS_ID=""; OS_CODENAME=""; OS_PRETTY=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"; OS_CODENAME="${VERSION_CODENAME:-}"; OS_PRETTY="${PRETTY_NAME:-}"
fi
if [ -n "$FAKE_CODENAME" ]; then
  OS_ID="debian"; OS_CODENAME="$FAKE_CODENAME"; OS_PRETTY="（假装）Debian $FAKE_CODENAME"
fi
KREL="$(uname -r)"
KVER="$(uname -v)"

# 正在跑的内核的 Debian 包版本：uname -v 里写着 "Debian 6.1.192-1 (...)"
RUN_DEB_VER=""
if [ -n "$FAKE_VERSION" ]; then
  RUN_DEB_VER="$FAKE_VERSION"
else
  RUN_DEB_VER="$(printf '%s\n' "$KVER" | sed -n 's/.*Debian \([0-9][^ ]*\).*/\1/p')"
fi

# 内核包名和装着的版本（Debian / Ubuntu）
KPKG=""; KPKG_VER=""
if [ -z "$FAKE_VERSION" ] && have dpkg-query && [ -e "/boot/vmlinuz-$KREL" ]; then
  KPKG="$(dpkg -S "/boot/vmlinuz-$KREL" 2>/dev/null | head -n1 | cut -d: -f1)"
  [ -n "$KPKG" ] && KPKG_VER="$(dpkg-query -W -f='${Version}' "$KPKG" 2>/dev/null)"
fi
if [ -n "$FAKE_PKG_VERSION" ]; then
  KPKG="linux-image-$KREL"; KPKG_VER="$FAKE_PKG_VERSION"
fi

# 在内核包 changelog 里找 CVE 号：找到=已修
changelog_has_cve() {
  local f
  if [ -n "$KPKG" ]; then
    for f in /usr/share/doc/"$KPKG"/changelog.Debian.gz /usr/share/doc/linux-modules-"$KREL"/changelog.Debian.gz; do
      [ -r "$f" ] || continue
      if have zgrep && zgrep -q "$CVE" "$f" 2>/dev/null; then return 0; fi
    done
  fi
  if have rpm && rpm -q "kernel-$KREL" >/dev/null 2>&1; then
    rpm -q --changelog "kernel-$KREL" 2>/dev/null | grep -q "$CVE" && return 0
  fi
  if have rpm && rpm -q "kernel-core-$KREL" >/dev/null 2>&1; then
    rpm -q --changelog "kernel-core-$KREL" 2>/dev/null | grep -q "$CVE" && return 0
  fi
  return 1
}

# FIX: fixed / bad_fixed / needs_reboot / vuln / unknown
FIX="unknown"; FIX_MSG=""
case "$OS_ID:$OS_CODENAME" in
  debian:bookworm)
    if [ -z "$RUN_DEB_VER" ]; then
      FIX="unknown"; FIX_MSG="Debian 12，但 uname -v 里读不到 Debian 包版本（自己编的内核？）"
    elif ver_ge "$RUN_DEB_VER" "6.1.192-2"; then
      FIX="fixed"; FIX_MSG="Debian 12 正在跑 $RUN_DEB_VER，已修（修复版 6.1.192-1 起，6.1.192-2 起没有 ext4 死机问题）"
    elif ver_ge "$RUN_DEB_VER" "6.1.192-1"; then
      FIX="bad_fixed"; FIX_MSG="Debian 12 正在跑 $RUN_DEB_VER：NoisyTCP 已修，但这一版重启后会 ext4 死机，尽快换 6.1.192-2"
    else
      FIX="vuln"; FIX_MSG="Debian 12 正在跑 $RUN_DEB_VER，没修（要 6.1.192-2 或更新）"
    fi
    ;;
  debian:trixie)
    if [ -z "$RUN_DEB_VER" ]; then
      FIX="unknown"; FIX_MSG="Debian 13，但 uname -v 里读不到 Debian 包版本（自己编的内核？）"
    elif ver_ge "$RUN_DEB_VER" "6.12.117-1"; then
      FIX="fixed"; FIX_MSG="Debian 13 正在跑 $RUN_DEB_VER，已修（修复版 6.12.117-1）"
    else
      FIX="vuln"; FIX_MSG="Debian 13 正在跑 $RUN_DEB_VER，没修（要 6.12.117-1 或更新）"
    fi
    ;;
  *)
    if changelog_has_cve; then
      FIX="fixed"; FIX_MSG="内核包 changelog 里有 $CVE，已修（$KREL）"
    elif [ "$OS_ID" = "ubuntu" ] && [ -z "$KPKG" ]; then
      FIX="unknown"; FIX_MSG="Ubuntu，但内核 $KREL 不是装出来的官方内核包（云平台自带或自己编的），去提供内核的一方查 $CVE"
    elif [ "$OS_ID" = "ubuntu" ]; then
      FIX="vuln"; FIX_MSG="Ubuntu 内核 $KREL 的 changelog 里没有 $CVE，按没修处理（2026-11-17 Ubuntu 还没出修复包）"
    else
      FIX="unknown"; FIX_MSG="认不出这个系统的修复状态（$OS_PRETTY，内核 $KREL），去发行版安全页面查 $CVE"
    fi
    ;;
esac

# Debian：装着的包版本比正在跑的新 → 修复版装了还没重启
if [ "$OS_ID" = "debian" ] && [ -n "$KPKG_VER" ] && [ -n "$RUN_DEB_VER" ] \
   && [ "$KPKG_VER" != "$RUN_DEB_VER" ] && ver_ge "$KPKG_VER" "$RUN_DEB_VER"; then
  if { [ "$OS_CODENAME" = "bookworm" ] && ver_ge "$KPKG_VER" "6.1.192-2"; } \
     || { [ "$OS_CODENAME" = "trixie" ] && ver_ge "$KPKG_VER" "6.12.117-1"; }; then
    if [ "$FIX" != "fixed" ]; then
      FIX="needs_reboot"; FIX_MSG="$FIX_MSG；已装 $KPKG $KPKG_VER，重启后才生效"
    fi
  fi
fi

# ---------- 2. 临时缓解和暴露面 ----------
SYNCOOKIES="?"
[ -r /proc/sys/net/ipv4/tcp_syncookies ] && SYNCOOKIES="$(cat /proc/sys/net/ipv4/tcp_syncookies)"

if [ ${#IFACES[@]} -eq 0 ] && have ip; then
  mapfile -t IFACES < <( { ip -4 route show default 2>/dev/null; ip -6 route show default 2>/dev/null; } \
    | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}' | sort -u)
fi

RACE_POSSIBLE=0
IFACE_LINES=()
for dev in "${IFACES[@]}"; do
  d="/sys/class/net/$dev/queues"
  if [ ! -d "$d" ]; then
    IFACE_LINES+=("$dev：找不到 $d")
    RACE_POSSIBLE=1
    continue
  fi
  rxq=0; rps=0
  for q in "$d"/rx-*; do
    [ -d "$q" ] || continue
    rxq=$((rxq + 1))
    if [ -r "$q/rps_cpus" ] && tr -d ',\n' < "$q/rps_cpus" | grep -q '[1-9a-fA-F]'; then
      rps=1
    fi
  done
  if [ "$rxq" -ge 2 ] || [ "$rps" -eq 1 ]; then RACE_POSSIBLE=1; fi
  IFACE_LINES+=("$dev：收包队列 $rxq 个，RPS $( [ "$rps" -eq 1 ] && echo 开 || echo 关 )")
done
if [ ${#IFACES[@]} -eq 0 ]; then
  IFACE_LINES+=("没找到默认路由的网卡（用 -i 指定）")
  RACE_POSSIBLE=1
fi

PUBLIC_LISTEN=()
if have ss; then
  mapfile -t PUBLIC_LISTEN < <(ss -Hltn 2>/dev/null | awk '{print $4}' \
    | grep -vE '^(127\.[0-9.]+|\[::1\]|\[::ffff:127\.[0-9.]+\])(%[^:]+)?:[0-9]+$' | sort -u)
fi

MITIGATED=0
MIT_MSG=""
if [ "$SYNCOOKIES" = "0" ]; then
  MITIGATED=1; MIT_MSG="tcp_syncookies=0（缓解一已生效，只管当前网络命名空间）"
elif [ "$RACE_POSSIBLE" -eq 0 ]; then
  MITIGATED=1; MIT_MSG="对外网卡都只有 1 个收包队列、RPS 关（缓解二已生效）"
else
  MIT_MSG="tcp_syncookies=$SYNCOOKIES，且有网卡是多队列或开了 RPS，两种缓解都没生效"
fi

# ---------- 3. 汇总 ----------
case "$FIX" in
  fixed)
    report 0 "$FIX_MSG" ;;
  bad_fixed)
    report 2 "$FIX_MSG"
    HINTS+=("Debian 12：等 apt-cache policy linux-image-$KREL 的候选版本变成 6.1.192-2 就装，确认 dpkg-query 显示 6.1.192-2 后再重启；死机得太频繁就先退回 6.1.0-54 并关 SYN cookies") ;;
  needs_reboot)
    report 2 "$FIX_MSG"
    HINTS+=("挑个时间重启进新内核；Debian 12 重启前先确认装的是 6.1.192-2 而不是 6.1.192-1") ;;
  vuln|unknown)
    if [ "$FIX" = "vuln" ] && [ "$MITIGATED" -eq 0 ] && [ ${#PUBLIC_LISTEN[@]} -gt 0 ]; then
      report 3 "$FIX_MSG"
    elif [ "$FIX" = "vuln" ] || [ "$MITIGATED" -eq 0 ]; then
      report 2 "$FIX_MSG"
    else
      report 1 "$FIX_MSG"
    fi
    if [ "$FIX" = "vuln" ] && [ "$OS_ID:$OS_CODENAME" = "debian:bookworm" ]; then
      HINTS+=("Debian 12：6.1.192-1 会死机，等 apt-cache policy linux-image-$KREL 的候选版本变成 6.1.192-2 再升级并重启，在那之前先用下面的缓解")
    elif [ "$FIX" = "vuln" ] && [ "$OS_ID" = "debian" ]; then
      HINTS+=("sudo apt update && sudo apt full-upgrade 装修复版内核，再重启")
    elif [ "$FIX" = "vuln" ]; then
      HINTS+=("盯着发行版安全页面，修复包一出就升级内核并重启")
    fi
    if [ "$MITIGATED" -eq 0 ]; then
      HINTS+=("没修好之前先关 SYN cookies：sudo sysctl -w net.ipv4.tcp_syncookies=0（每个独立网络命名空间的容器都要单独设；会降低抗 SYN flood 的能力）")
    fi ;;
esac

if [ "$MITIGATED" -eq 1 ]; then
  report 1 "缓解：$MIT_MSG"
elif [ "$FIX" = "fixed" ]; then
  report 1 "缓解：$MIT_MSG（内核已修，不需要缓解）"
else
  report 1 "缓解：$MIT_MSG"
fi
for l in "${IFACE_LINES[@]}"; do report 1 "网卡 $l"; done
if [ ${#PUBLIC_LISTEN[@]} -gt 0 ]; then
  report 1 "对外监听的 TCP 端口 ${#PUBLIC_LISTEN[@]} 个：$(printf '%s ' "${PUBLIC_LISTEN[@]}" | cut -c1-300)"
else
  report 1 "没有监听在非回环地址上的 TCP 端口"
fi
if have docker || have podman || [ -n "$(ip netns list 2>/dev/null)" ]; then
  report 1 "本机有容器或额外网络命名空间：tcp_syncookies 按命名空间算，上面只看了当前这个"
fi

if [ "$QUIET" -eq 1 ] && [ "$WORST" -eq 0 ]; then
  exit 0
fi

echo "NoisyTCP ($CVE) 检查：${OS_PRETTY:-未知系统}，内核 $KREL"
printf '%s\n' "${OUTPUT[@]}"
if [ ${#HINTS[@]} -gt 0 ]; then
  echo
  echo "建议："
  printf '  - %s\n' "${HINTS[@]}"
fi
exit "$WORST"
