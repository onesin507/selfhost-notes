# PostgreSQL 19 发布了：升级前先查这几项，有的会让 pg_upgrade 直接拒绝

**一句话结论**：PostgreSQL 19 在 2026-11-19 发布。大版本升级要么 dump/restore，要么用 pg_upgrade 或逻辑复制，不能只换包。这次的不兼容变更里，有三项会让升级当场卡住（名字里带换行、btree_gist 的 inet/cidr 索引、MULE_INTERNAL 编码），还有几项不拦升级但升完会出问题（RADIUS 认证被删、`io_workers` 参数被删、部分索引要重建）。升级前先跑一遍配套脚本 [pg19-upgrade-precheck.sh](../scripts/README.md#pg19-upgrade-precheck.sh)，它只读不改。

- 来源：PostgreSQL 官方发布公告《PostgreSQL 19 Released!》，2026-11-19
  https://www.postgresql.org/about/news/postgresql-19-released-3449/
- 官方 19 版发布说明的「Migration to Version 19」一节
  https://www.postgresql.org/docs/19/release-19.html

## 会让 pg_upgrade 直接拒绝的

| 变更 | 为什么 | 怎么办 |
|---|---|---|
| 数据库、角色、表空间名字里不许再有回车或换行 | 安全原因 | 升级前 `ALTER ... RENAME TO` 改名 |
| `inet` / `cidr` 的默认索引操作符类从 btree_gist 换成内置 GiST | btree_gist 的这两个操作符类有问题，会把该返回的行漏掉 | 升级前删掉这些索引，升级后用默认 GiST 重建 |
| 删掉了 `MULE_INTERNAL` 编码 | 复杂、很少人用 | 只能换一种编码 dump/restore |

## 不拦升级，但升完会出问题的

- **RADIUS 认证删了**：官方说 PostgreSQL 只支持走 UDP 的 RADIUS，本质上不安全。`pg_hba.conf` 里有 `radius` 的规则，升级前换成别的认证方式。
- **MD5 登录会告警**：用 MD5 密码登录成功后会发一条警告，可以用 `md5_password_warnings` 关掉。MD5 在 18 就已经标为弃用。顺手换成 `scram-sha-256` 最省事：先设 `password_encryption = scram-sha-256`，再把每个账号的密码重设一遍，最后把 `pg_hba.conf` 里的 `md5` 改掉。
- **`standard_conforming_strings` 强制为 on**：用 19 以前的 pg_dump、在这个参数为 off 时导出的文件，导不进 19。走 dump/restore 的话，用 19 版的 pg_dump / pg_dumpall 去导。
- **`io_workers` 参数删了**，换成了四个新参数（19 会自动调 I/O 工作进程数）。配置里写了它的，升级前删掉。
- **`max_locks_per_transaction`** 默认值从 64 改成 128，锁的分配方式也变了：手动调过这个值的，要翻倍才等于原来的容量。
- **JIT 默认关掉了**：官方说原来按代价估算自动启用 JIT 不可靠。跑大量分析查询的，升级后手动打开。
- **这几类索引升级后建议重建**（用 pg_upgrade 升的时候）：
  - 全文检索和 pg_trgm 现在按数据库自己的区域提供者分字符类别。只有区域提供者不是 libc（比如 ICU、builtin）的库受影响，尤其是 LC_CTYPE 为 `C` 的。这种库里用到全文检索、pg_trgm 的索引要 REINDEX，存下来的 `tsvector` 也要重算。
  - fuzzystrmatch 的 `soundex()`、`metaphone()`、`difference()` 现在只把 ASCII 字母当字母，`dmetaphone()` 换了大写转换方式。用到这些函数的索引要 REINDEX。

发布说明里还有一些应用层面的变化，脚本查不了，升级前自己对一下：

- `json_array()` 在没有行时返回空数组 `[]`，以前返回 `NULL`。
- `COPY FROM ... WHERE` 里不能再用系统列。
- 系统视图 `pg_stat_subscription_stats` 的 `sync_error_count` 改名为 `sync_table_error_count`；等待事件 `BufferPin` 改名 `BufferCleanup`。监控里写死了这些名字的要改。
- 并行 VACUUM 的各个进程现在共享一份延迟预算，开了基于代价的延迟时可能比以前慢。

## 升级前怎么查

```bash
# 本机用发行版包装的
sudo -u postgres ./pg19-upgrade-precheck.sh
# 或者
./pg19-upgrade-precheck.sh --sudo

# Docker 容器里的
./pg19-upgrade-precheck.sh --docker 容器名
```

结果分三档：**BLOCK** 不处理就升不上去，**WARN** 升级前后要处理，**OK / INFO** 没问题或仅供参考。每个库装了哪些扩展也会列出来：PostGIS、TimescaleDB 这类第三方扩展要先确认有 19 版的包，否则 pg_upgrade 也过不去。

脚本查完没问题，正式升级前还是建议：

1. 先做一份完整备份（`pg_dumpall` 或文件级备份）。
2. Debian / Ubuntu 用的是 PostgreSQL 官方 apt 源的话，装上 19 以后先用 `pg_upgradecluster` 或 `pg_upgrade --check` 试跑一次，它会做正式的官方检查。
3. Docker 里的不要直接把镜像标签从 18 改成 19：新版程序读不了旧版数据目录，得先导出再导入，或用带 pg_upgrade 的工具镜像。

## 还在用 18 的要注意

还没升到 18.7 / 17.12 / 16.16 这一批的，先把 11 月 12 日那次安全更新打上（见 [这篇笔记](../security/2026-11-15-postgresql-nov-2026-cves.md)），大版本升级可以慢慢来。

## 我怎么测的

环境：Ubuntu 26.04，PostgreSQL 18.6（Ubuntu 官方包）。

1. 干净集群跑一遍：全部 OK，只提示了 JIT 默认值会变，退出码 0。
2. 造了一个问题集群：一个 ICU 区域的库，里面建了 btree_gist 的 inet 索引、pg_trgm 索引、全文检索索引、soundex 表达式索引；一个名字带换行的角色；一个 MD5 密码的角色；pg_hba.conf 里加了 md5 和 radius 规则；配置里设了 `io_workers`、`max_locks_per_transaction` 和 `standard_conforming_strings = off`。脚本把这些全部报了出来：两条 BLOCK，退出码 2。
3. 对照测试：libc 区域的库里建的 pg_trgm 索引没有被误报，`-q` 在没问题时不出声。

没测到的：MULE_INTERNAL 编码（建库太麻烦，只看了查询语句）、`--docker` 模式、真实跑一次 18 到 19 的 pg_upgrade。
