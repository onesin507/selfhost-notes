#!/usr/bin/env bash
# cert-expiry-check.sh — 检查 TLS 证书还剩几天过期（线上站点和本地证书文件都行）
#
# 用途：
#   给一串域名（可带端口）或本地证书文件，列出每张证书的到期日和剩余天数，
#   快到期的标 WARN，更近的或已过期、连不上的标 CRIT。适合放进 cron / systemd timer
#   每天跑一次，用退出码判断要不要告警。只读，不改任何东西。
#
# 用法：
#   cert-expiry-check.sh [选项] 目标...
#   目标可以是：
#     example.com            默认连 443 端口
#     example.com:8443       指定端口
#     /path/to/fullchain.pem 本地证书文件（PEM 格式，只看第一张，即叶子证书）
#   选项：
#     -f 文件   从文件读目标，一行一个，# 开头和空行会跳过
#     -w 天数   剩余天数 <= 这个值记为 WARN（默认 21）
#     -c 天数   剩余天数 <= 这个值记为 CRIT（默认 7）
#     -t 秒数   每个站点的连接超时（默认 10）
#     -q        只输出 WARN / CRIT 的行（适合 cron，没事就不出声）
#     -h        显示帮助
#
# 退出码：0 全部正常；1 有 WARN；2 有 CRIT（含已过期、连不上、读不出证书）；64 用法错误
#
# 依赖：bash 4+、openssl、GNU date（Linux 自带；macOS 需装 coreutils 并把 gdate 放进 PATH 叫 date）、timeout（coreutils）
#
# 示例：
#   ./cert-expiry-check.sh example.com mail.example.com:993
#   ./cert-expiry-check.sh -w 30 -c 10 /etc/letsencrypt/live/*/fullchain.pem
#   ./cert-expiry-check.sh -q -f ~/sites.txt || echo "有证书要处理"
#
# 许可证：MIT

set -uo pipefail

WARN_DAYS=21
CRIT_DAYS=7
TIMEOUT=10
QUIET=0
TARGETS=()

usage() {
  sed -n '2,/^# 许可证/{s/^# \{0,1\}//;p}' "$0"
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

while getopts ":f:w:c:t:qh" opt; do
  case "$opt" in
    f)
      if [[ ! -r "$OPTARG" ]]; then
        echo "读不到目标文件：$OPTARG" >&2; exit 64
      fi
      while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -n "$line" ]] && TARGETS+=("$line")
      done < "$OPTARG"
      ;;
    w) WARN_DAYS="$OPTARG" ;;
    c) CRIT_DAYS="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    q) QUIET=1 ;;
    h) usage; exit 0 ;;
    :) echo "选项 -$OPTARG 需要一个值" >&2; exit 64 ;;
    *) echo "不认识的选项：-$OPTARG（-h 看帮助）" >&2; exit 64 ;;
  esac
done
shift $((OPTIND - 1))
TARGETS+=("$@")

for v in "$WARN_DAYS" "$CRIT_DAYS" "$TIMEOUT"; do
  if ! is_uint "$v"; then
    echo "-w / -c / -t 只能是非负整数：$v" >&2; exit 64
  fi
done
if (( CRIT_DAYS > WARN_DAYS )); then
  echo "-c（$CRIT_DAYS）不能大于 -w（$WARN_DAYS）" >&2; exit 64
fi
if (( ${#TARGETS[@]} == 0 )); then
  echo "没有要检查的目标（-h 看帮助）" >&2; exit 64
fi
for bin in openssl date timeout; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "缺少依赖：$bin" >&2; exit 64
  fi
done

# 取证书 PEM：本地文件直接读，否则连过去拿叶子证书
fetch_cert() {
  local target="$1" host port
  if [[ -f "$target" ]]; then
    openssl x509 -in "$target" 2>/dev/null
    return
  fi
  if [[ "$target" == *:* ]]; then
    host="${target%:*}"
    port="${target##*:}"
  else
    host="$target"
    port=443
  fi
  timeout "$TIMEOUT" openssl s_client -connect "${host}:${port}" -servername "$host" \
    </dev/null 2>/dev/null | openssl x509 2>/dev/null
}

now=$(date +%s)
worst=0

if (( QUIET == 0 )); then
  printf '%-5s %6s  %-10s  %s\n' "STATE" "DAYS" "EXPIRES" "TARGET"
fi

for t in "${TARGETS[@]}"; do
  pem=$(fetch_cert "$t")
  if [[ -z "$pem" ]]; then
    printf '%-5s %6s  %-10s  %s\n' "CRIT" "-" "-" "$t（连不上或读不出证书）"
    worst=2
    continue
  fi

  enddate=$(printf '%s\n' "$pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if ! end_ts=$(date -d "$enddate" +%s 2>/dev/null); then
    printf '%-5s %6s  %-10s  %s\n' "CRIT" "-" "-" "$t（到期日解析失败：$enddate）"
    worst=2
    continue
  fi

  # 向下取整：还剩 6.9 天按 6 天算，宁早不晚
  days=$(( (end_ts - now) / 86400 ))
  (( end_ts < now )) && days=$(( (end_ts - now - 86399) / 86400 ))
  day_str=$(date -d "@$end_ts" +%F)

  if (( end_ts <= now )); then
    status=CRIT; note="（已过期）"
  elif (( days <= CRIT_DAYS )); then
    status=CRIT; note=""
  elif (( days <= WARN_DAYS )); then
    status=WARN; note=""
  else
    status=OK; note=""
  fi

  case "$status" in
    CRIT) worst=2 ;;
    WARN) (( worst < 1 )) && worst=1 ;;
  esac

  if (( QUIET == 0 )) || [[ "$status" != OK ]]; then
    printf '%-5s %6s  %-10s  %s\n' "$status" "$days" "$day_str" "$t$note"
  fi
done

exit "$worst"
