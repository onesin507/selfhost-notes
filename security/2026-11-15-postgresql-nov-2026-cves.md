# PostgreSQL 18.7 / 17.12 / 16.16 / 15.20 / 14.25：一次修了 52 个 CVE，普通账号就能执行系统命令

**一句话结论**：2026-11-12 PostgreSQL 给所有在维护的版本出了小版本更新，修了 52 个安全漏洞。最严重的 CVE-2026-6460 只要一个能建表、改表的普通登录账号，就能以运行数据库的系统用户身份执行任意代码。自己搭的 PostgreSQL（包括 Docker 里的）都要升级并重启，小版本升级不用导数据。Ubuntu 官方源写这篇时还没出修复包，可以先改用 PostgreSQL 官方 apt 源。

## 要点

- **CVE-2026-6460 是什么**：类型混淆。PostgreSQL 内部的值本身不带类型标记，用 `ALTER ... SET DATA TYPE` 改了复合类型里某个字段的类型后，旧值还会被当成新类型去读，进而破坏内存、执行代码。官方说还有别的 DDL 路径（比如加列、回滚、再加列）。CVSS 8.8，前提是攻击者有一个能创建对象的普通账号，不需要超级用户。
- **影响范围**：18.7、17.12、16.16、15.20、14.25 之前的版本全部受影响。发现者 Mehmet İnce 在博客里说，这个问题在核心代码里存在了 22 年；他把本地能跑的利用移植到几乎所有托管 PostgreSQL 平台上试过，没见到不受影响的，8 月起陆续私下通知了各家。他一共报了 21 个同类问题，这次的 52 个 CVE 里有 6 个和它直接相关。
- **同一批的其他高危漏洞**：十几个 8.8 分的代码执行问题，涉及 plperl、pltcl、全文检索函数 `tsvector_delete()` / `ts_rank_cd()`、并行查询等。自建用户特别要注意工具链这几个：`pg_restore` 不校验非纯文本格式的归档，恢复别人给的备份就可能被执行代码（CVE-2026-116314，不需要任何数据库权限）；`pg_dump` 的 tar 格式里 restore.sql 挡不住 psql 命令注入（CVE-2026-116330）；`reindexdb`、`vacuumdb` 也各有一个。
- **14 系列到头了**：14.25 是 14 的最后一版，之后不再修漏洞。还在用 14 或更早版本的，先升到 14.25 止血，再规划升大版本。
- **扩展也要跟着更新**：Debian 安全团队在追踪页上注明，要彻底修好 CVE-2026-6460，有些扩展需要重新编译。用了 PostGIS、pgvector 这类扩展的，升级时把同一个源里的扩展包一起升上去，自己编译的扩展对着新版本重新编译。
- **装完要重启**：包升级只替换磁盘上的程序，正在跑的数据库进程要重启后才是新版。用 `SHOW server_version;` 确认。

## 各发行版的修复包

下表是 2026-11-15 从各家安全追踪页和软件源里查到的，之后会变，以官方页面为准：

| 来源 | 状态 |
| --- | --- |
| Debian 12 bookworm（postgresql-15） | 已修：15.20-0+deb12u1（DLA-4905-1） |
| Debian 13 trixie（postgresql-17） | 已修：17.12-0+deb13u1（DSA-6625-1） |
| Debian sid（postgresql-18） | 已修：18.7-1；forky（testing）还是 18.6-3，没修 |
| Ubuntu 26.04 LTS（postgresql-18） | 追踪页显示 Needs evaluation，官方源里还是 18.6-0ubuntu0.26.04.1，没修 |
| Ubuntu 24.04 LTS（postgresql-16） | Needs evaluation，没修 |
| Ubuntu 22.04 LTS（postgresql-14） | Needs evaluation，没修 |
| PostgreSQL 官方 apt 源（apt.postgresql.org） | 已有 18.7、17.12、16.16、15.20（noble、bookworm、resolute 都查过） |
| Docker 官方镜像 postgres | 已有 18.7、16.16 等标签，含 alpine 变体 |

Debian、Ubuntu 和官方 apt 源都直接用上游小版本号，所以看 `postgres --version` 就能判断。红帽系这篇没有核对，请看各自的安全公告。

## 示例

以下命令是自己整理的示例。

```bash
# 1. 看版本：磁盘上的程序，和正在跑的库
ls /usr/lib/postgresql/*/bin/postgres | xargs -I{} sh -c '{} --version'
sudo -u postgres psql -XAtc 'SHOW server_version'

# 2. Debian 12 / 13：官方源已有修复包
sudo apt update && sudo apt install --only-upgrade 'postgresql-1[5-8]*'
sudo systemctl restart postgresql

# 3. Ubuntu 官方源还没修：加 PostgreSQL 官方 apt 源后升级
#    （大版本号不变，只是换了个源；之后 apt upgrade 都会跟官方源走）
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
  https://www.postgresql.org/media/keys/ACCC4CF8.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release; echo "$VERSION_CODENAME")-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt update && sudo apt install --only-upgrade postgresql-18   # 换成你的大版本
sudo systemctl restart postgresql

# 4. Docker / Compose：标签写到小版本，或者拉新的大版本标签后重建
#    image: postgres:18.7        # 或 postgres:16.16、postgres:17.12
docker compose pull db && docker compose up -d db
docker compose exec db postgres --version
```

第 3 步在 Ubuntu 26.04 上实际跑过：从 Ubuntu 自带的 18.6-0ubuntu0.26.04.1 升到 18.7-1.pgdg26.04+2，重启后 `SHOW server_version` 显示 18.7，原来的集群直接能用。

也可以用本仓库的脚本 [pg-cve-2026-6460-check.sh](../scripts/pg-cve-2026-6460-check.sh) 一次查本机和容器里的所有 PostgreSQL。

## 暂时升不了怎么办

没有配置开关能关掉这个漏洞，只能缩小能利用它的人的范围：

- **数据库端口别对公网开**：5432 只听本机或内网，`pg_hba.conf` 只放行需要的来源。
- **收紧建表权限**：从 14 或更早升上来的库，所有人默认都能在 public 模式里建对象（官方文档原话），可以执行 `REVOKE CREATE ON SCHEMA public FROM PUBLIC;`。只读、报表之类的账号不要给建表权限。
- **别恢复来路不明的备份**：`pg_restore` / `psql` 升级之前，别拿它们去恢复别人发来的 dump。

这些只是减少暴露面：应用自己用的账号通常就有建表、改表权限，应用一旦有 SQL 注入，攻击者就能拿它触发漏洞。最终还是要升级。

## 适合谁

- 在 VPS 或家里服务器上自己跑 PostgreSQL 的人，尤其是用 Docker Compose 跑 Nextcloud、Gitea、Immich、Outline 这类自建服务、里面带一个 postgres 容器的。
- 一个库给好几个应用或好几个人共用的。

## 注意事项 / 坑

- **Compose 里写的是 `postgres:16` 这种大版本标签**：不 `pull` 就一直是本地那份旧镜像，得手动 `docker compose pull` 再 `up -d`。别把标签顺手改成更高的大版本，大版本的数据目录不兼容，容器会起不来。
- **升级后的额外步骤**：官方公告说，使用 GIN 索引、`pg_trgm` 的 GiST 索引、无长度的 `bpchar` 列上的 B-tree 索引、分区表、增量备份的，升级后可能要 `REINDEX` 或重做一次全量备份。对照公告的 Updating 一节挑和自己相关的做。跳过了中间几个小版本的，还要看之前各版的发布说明。
- **换成官方 apt 源以后**：后续更新都跟官方源走，和 Ubuntu 自带的包版本号写法不同（`18.7-1.pgdg26.04+2`）。以后 Ubuntu 出了修复包也不会冲突，apt 会选版本更高的那个。
- **托管数据库**（RDS、Supabase、Neon 等）由平台升级，去控制台看维护通知和当前小版本。

## 来源

- PostgreSQL 官方公告（2026-11-12）：https://www.postgresql.org/about/news/postgresql-187-1712-1616-1520-1425-and-19-rc-2-released-3442/
- CVE-2026-6460 官方页：https://www.postgresql.org/support/security/CVE-2026-6460/
- 发现者博客（2026-11-09）：https://mehmetince.net/part-3-6-how-i-ended-up-turning-a-22-year-old-postgresql-type-confusion-primitive-into-rce-cve-2026-6460/
- Hacker News 讨论：https://news.ycombinator.com/item?id=50471761
- Debian 安全追踪：https://security-tracker.debian.org/tracker/CVE-2026-6460
- Ubuntu 安全追踪：https://ubuntu.com/security/CVE-2026-6460
- 官方文档 Schemas 一节：https://www.postgresql.org/docs/current/ddl-schemas.html
