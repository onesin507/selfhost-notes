#!/usr/bin/env bash
# pg19-upgrade-precheck.sh — 升级到 PostgreSQL 19 之前的只读体检
#
# 用途：对照 PostgreSQL 19 发布说明里的“不兼容变更”，检查当前（18 及以下）集群
#       有没有会让 pg_upgrade 直接拒绝、升级后起不来、或升级后要重建索引的东西。
#       只跑 SELECT / SHOW，不改任何数据和配置。
# 用法：
#   sudo -u postgres ./pg19-upgrade-precheck.sh          # 本机，用 postgres 身份连默认实例
#   ./pg19-upgrade-precheck.sh --sudo                    # 同上，脚本自己 sudo -u postgres
#   PGHOST=db PGUSER=admin ./pg19-upgrade-precheck.sh    # 连别的实例（用 libpq 环境变量，需超级用户）
#   ./pg19-upgrade-precheck.sh --docker pg               # Docker 容器里的 PostgreSQL
#   ./pg19-upgrade-precheck.sh -q                        # 只在有 WARN / BLOCK 时输出，适合 cron
# 退出码：0 = 没问题，1 = 有 WARN，2 = 有 BLOCK（不处理就升不上去）
# 依赖：bash、psql（本机或容器里）、coreutils（du / df）
# 依据：https://www.postgresql.org/docs/19/release-19.html#RELEASE-19-MIGRATION
# 许可：MIT
set -uo pipefail

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

MODE=local
CONTAINER=""
QUIET=0
DB_USER="${PGUSER:-postgres}"
while [ $# -gt 0 ]; do
  case "$1" in
    --sudo) MODE=sudo ;;
    --docker) MODE=docker; CONTAINER="${2:-}"; shift ;;
    -U) DB_USER="${2:-}"; shift ;;
    -q|--quiet) QUIET=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1（看 --help）" >&2; exit 64 ;;
  esac
  shift
done
if [ "$MODE" = docker ] && [ -z "$CONTAINER" ]; then
  echo "--docker 后面要写容器名" >&2; exit 64
fi

# psql 包装：$1 = 数据库名，$2 = SQL；输出不带表头，字段用 | 分隔
q() {
  local db="$1" sql="$2"
  case "$MODE" in
    local)  psql -X -A -t -q -v ON_ERROR_STOP=1 -d "$db" -c "$sql" ;;
    sudo)   sudo -u postgres psql -X -A -t -q -v ON_ERROR_STOP=1 -d "$db" -c "$sql" ;;
    docker) docker exec -i "$CONTAINER" psql -U "$DB_USER" -X -A -t -q -v ON_ERROR_STOP=1 -d "$db" -c "$sql" ;;
  esac
}

OUT=""
WORST=0
add() { # $1 级别 $2 文本
  OUT+="[$1] $2"$'\n'
  case "$1" in
    BLOCK) WORST=2 ;;
    WARN)  [ "$WORST" -lt 1 ] && WORST=1 ;;
  esac
}
finish() {
  if [ "$QUIET" -eq 0 ] || [ "$WORST" -gt 0 ]; then printf '%s' "$OUT"; fi
  exit "$WORST"
}

VER=$(q postgres "SHOW server_version_num" 2>&1) || { echo "[BLOCK] 连不上数据库：$VER" >&2; exit 2; }
VERS=$(q postgres "SHOW server_version")
if [ "$VER" -ge 190000 ]; then
  add OK "已经是 PostgreSQL $VERS，不用再查"; finish
fi
add INFO "当前版本 PostgreSQL $VERS"
SU=$(q postgres "SELECT rolsuper FROM pg_roles WHERE rolname = current_user")
[ "$SU" = t ] || add WARN "当前用户不是超级用户，密码和 pg_hba 那几项查不了"

mapfile -t DBS < <(q postgres "SELECT datname FROM pg_database WHERE datallowconn ORDER BY 1")

# 1. 名字里带回车 / 换行：pg_upgrade 直接拒绝
BAD=$(q postgres "SELECT kind||' '||replace(replace(n, E'\\r', E'\\\\r'), E'\\n', E'\\\\n') FROM (
  SELECT '数据库' kind, datname::text n FROM pg_database UNION ALL
  SELECT '角色', rolname::text FROM pg_roles UNION ALL
  SELECT '表空间', spcname::text FROM pg_tablespace) s WHERE n ~ E'[\\r\\n]'")
if [ -n "$BAD" ]; then
  while IFS= read -r l; do add BLOCK "名字里有回车/换行，pg_upgrade 会拒绝：$l（先改名）"; done <<<"$BAD"
else add OK "数据库、角色、表空间名字里没有回车/换行"; fi

# 2. MULE_INTERNAL 编码：19 删掉了，只能换编码后 dump/restore
MULE=$(q postgres "SELECT datname FROM pg_database WHERE pg_encoding_to_char(encoding) = 'MULE_INTERNAL'")
if [ -n "$MULE" ]; then
  while IFS= read -r l; do add BLOCK "数据库 $l 用的是 MULE_INTERNAL 编码，19 不再支持，要换编码 dump/restore"; done <<<"$MULE"
else add OK "没有 MULE_INTERNAL 编码的库"; fi

# 3/6/7. 逐库检查索引和扩展
GIST=0; RX=0
for db in "${DBS[@]}"; do
  # btree_gist 的 inet/cidr 索引：pg_upgrade 拒绝
  r=$(q "$db" "SELECT DISTINCT n.nspname||'.'||c.relname FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_opclass o ON o.oid = ANY (i.indclass::oid[])
    WHERE o.opcname IN ('gist_inet_ops', 'gist_cidr_ops')" 2>/dev/null)
  if [ -n "$r" ]; then
    GIST=1
    while IFS= read -r l; do add BLOCK "库 $db 的索引 $l 用了 btree_gist 的 inet/cidr 操作符类，pg_upgrade 会拒绝：先删掉，升级后用默认 GiST 重建"; done <<<"$r"
  fi

  # 升级后建议重建的索引：全文检索 / pg_trgm（非 libc 区域提供者的库）、fuzzystrmatch（所有库）
  prov=c
  if [ "$VER" -ge 150000 ]; then
    prov=$(q postgres "SELECT datlocprovider FROM pg_database WHERE datname = '${db//\'/\'\'}'")
  fi
  r=$(q "$db" "SELECT n.nspname||'.'||c.relname||'|'||
      CASE WHEN pg_get_indexdef(i.indexrelid) ~* '(soundex|metaphone|difference)[(]' THEN 'fuzzy' ELSE 'fts' END
    FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND pg_get_indexdef(i.indexrelid) ~* '(trgm_ops|tsvector|soundex[(]|metaphone[(]|difference[(])'" 2>/dev/null)
  if [ -n "$r" ]; then
    while IFS='|' read -r idx kind; do
      if [ "$kind" = fuzzy ]; then
        RX=1; add WARN "库 $db 的索引 $idx 用了 fuzzystrmatch 函数，pg_upgrade 后建议 REINDEX"
      elif [ "$prov" != c ]; then
        RX=1; add WARN "库 $db（区域提供者不是 libc）的索引 $idx 用了全文检索或 pg_trgm，pg_upgrade 后建议 REINDEX，存下来的 tsvector 也建议重算"
      fi
    done <<<"$r"
  fi

  # 扩展清单：第三方扩展要先确认有 19 版的包
  ext=$(q "$db" "SELECT string_agg(extname||' '||extversion, ', ' ORDER BY extname) FROM pg_extension WHERE extname <> 'plpgsql'" 2>/dev/null)
  [ -n "$ext" ] && add INFO "库 $db 装的扩展：$ext（非 contrib 的要先确认有 PostgreSQL 19 版的包）"
done
[ "$GIST" -eq 0 ] && add OK "没有 btree_gist 的 inet/cidr 索引"
[ "$RX" -eq 0 ] && add OK "没有升级后必须重建的全文检索 / pg_trgm / fuzzystrmatch 索引"

# 4/5. 认证：RADIUS 被删、MD5 登录会告警
if [ "$SU" = t ]; then
  hba=$(q postgres "SELECT line_number||'|'||auth_method FROM pg_hba_file_rules WHERE auth_method IN ('radius', 'md5') ORDER BY line_number" 2>/dev/null)
  hr=0; hm=0
  while IFS='|' read -r ln m; do
    [ -z "$ln" ] && continue
    if [ "$m" = radius ]; then hr=1; add WARN "pg_hba.conf 第 $ln 行用 radius 认证，19 已经删掉 RADIUS，升级前要换掉，否则这条规则用不了"
    else hm=1; add WARN "pg_hba.conf 第 $ln 行用 md5 认证，19 登录成功后会发告警；建议改 scram-sha-256"; fi
  done <<<"$hba"
  [ "$hr" -eq 0 ] && [ "$hm" -eq 0 ] && add OK "pg_hba.conf 里没有 radius / md5 规则"
  md5=$(q postgres "SELECT string_agg(rolname, ', ' ORDER BY rolname) FROM pg_authid WHERE rolpassword LIKE 'md5%'")
  if [ -n "$md5" ]; then add WARN "这些角色的密码还是 MD5 存的：$md5（设 password_encryption = scram-sha-256 后重设一次密码）"
  else add OK "没有用 MD5 存密码的角色"; fi
fi

# 8. 配置项变化
scs=$(q postgres "SHOW standard_conforming_strings")
if [ "$scs" = off ]; then add WARN "standard_conforming_strings = off：19 强制为 on，这种设置下用旧 pg_dump 导出的文件导不进 19，要用 19 的 pg_dump 导"
else add OK "standard_conforming_strings = on"; fi
while IFS='|' read -r name setting source; do
  [ -z "$name" ] && continue
  case "$name" in
    io_workers) [ "$source" != default ] && add WARN "配置里设了 io_workers = $setting，19 删掉了这个参数（换成 io_min_workers 等四个），升级前从配置里拿掉" ;;
    max_locks_per_transaction) [ "$source" != default ] && add INFO "max_locks_per_transaction = $setting 是手动设的：19 的计算方式变了，要翻倍才等于原来的容量（默认值也从 64 改成 128）" ;;
    jit) [ "$setting" = on ] && [ "$source" = default ] && add INFO "现在 JIT 是默认开着的，19 默认关；跑大量分析查询的话升级后手动打开" ;;
  esac
done < <(q postgres "SELECT name||'|'||setting||'|'||source FROM pg_settings WHERE name IN ('io_workers', 'max_locks_per_transaction', 'jit')")

# 9. 磁盘：pg_upgrade 默认复制模式要再占一份数据目录大小
if [ "$MODE" != docker ] && [ "$SU" = t ]; then
  dir=$(q postgres "SHOW data_directory")
  if [ -n "$dir" ]; then
    if [ "$MODE" = sudo ]; then size=$(sudo du -sk "$dir" 2>/dev/null | cut -f1); else size=$(du -sk "$dir" 2>/dev/null | cut -f1); fi
    avail=$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$size" ] && [ -n "$avail" ]; then
      if [ "$avail" -lt "$size" ]; then add WARN "数据目录约 $((size/1024)) MB，所在分区只剩 $((avail/1024)) MB：pg_upgrade 默认复制模式空间不够，要么腾空间，要么用 --link / --clone"
      else add OK "数据目录约 $((size/1024)) MB，分区剩 $((avail/1024)) MB，够 pg_upgrade 复制一份"; fi
    else add INFO "读不到数据目录大小（$dir），磁盘空间自己看一下"; fi
  fi
fi

finish
