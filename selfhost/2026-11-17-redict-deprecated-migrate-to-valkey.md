# Redict 停更了，换 Valkey 不能只搬配置文件：RDB 格式不兼容，要先转成 AOF

**一句话结论**：Redis 的 copyleft 分支 Redict 在 2026-11-17 宣布停止维护，7.3.6 是最后一版，官方建议换 Valkey，说“装上 valkey、把配置文件挪过去”就行。我实测发现没这么简单：Redict 7.3.6 存下的 `dump.rdb` 是 RDB 第 12 版格式，Valkey 8.1 和 9.0 都读不了，直接报错退出。先让 Redict 把数据写成纯 AOF，再让 Valkey 从 AOF 加载，数据和过期时间都能完整带过去。

- 来源：Redict 官方公告《Redict is deprecated》，Drew DeVault，2026-11-17
  https://redict.io/posts/2026-11-17-redict-deprecated/
- Valkey 官网：https://valkey.io/

## 公告说了什么

- Redict 正式废弃，**7.3.6 是最后一个版本**，之后不会再有安全修复。
- 原因：Valkey 做起来了，Redis 自己也换回了 copyleft 许可证，Redict 没能形成能持续的社区。
- 建议换 **Valkey**（宽松许可证，前景更好）。不建议换回 Redis：虽然又开源了，但要求贡献者签 CLA，哪天财报不好看还可能再改许可证。
- 官方给的迁移方法只有一句：用包管理器装的，装 valkey 后 `mv /etc/redict.conf /etc/valkey.conf`；用容器的，换成 valkey 镜像、挂上配置。

## 我实测碰到的问题

环境：Debian 13，Docker 29.8，镜像 `registry.redict.io/redict:7.3.6`、`valkey/valkey:8.1`（实际版本 8.1.11）、`valkey/valkey:9.0`。

1. Redict 里写了 7 个键：字符串、哈希、列表、有序集合、集合、Stream、一个带 1 小时过期时间的字符串，`SAVE` 存盘。
2. `dump.rdb` 开头是 `REDIS0012`，也就是 RDB 第 12 版。Redict 的 `INFO server` 里 `redis_version` 是 7.2.4。
3. 同一个数据目录交给 Valkey 8.1，启动就退出：
   ```
   # Can't handle RDB format version 12
   # Fatal error loading the DB, check server logs. Exiting.
   ```
   换 Valkey 9.0 也是同样两行。
4. 改走 AOF（下面的做法），Valkey 8.1 正常启动：7 个键都在，内容和长度都对，过期时间还剩 3588 秒。
5. 又试了“正在跑、只开了 RDB 的 Redict 在线切到 AOF”这种更常见的情况，同样成功。数据目录里旧的 RDB 12 文件还在，Valkey 开着 AOF 时会无视它。

我只测了 Redict 7.3.6。更早的 7.3.x 写的是不是也是第 12 版，用 `head -c 9 dump.rdb` 看一眼就知道。让 Valkey 做 Redict 的从库来同步数据，这条路我没试。

## 迁移步骤（示例，按自己的路径和端口改）

**0. 先备份**

```sh
redict-cli SAVE
head -c 9 /var/lib/redict/dump.rdb; echo     # 显示 REDIS0012 就得走下面的 AOF 路线
cp -a /var/lib/redict/dump.rdb /root/redict-backup-$(date +%F).rdb
redict-cli DBSIZE                              # 记下键数，最后对数
```

**1. 在线让 Redict 写一份纯 AOF**

```sh
redict-cli CONFIG SET aof-use-rdb-preamble no   # 关键：不要在 AOF 里嵌 RDB，不然还是第 12 版格式
redict-cli CONFIG SET appendonly yes            # 会自动重写一份完整的 AOF

# 等重写完：两项都是 0，状态是 ok
redict-cli INFO persistence | grep -E 'aof_rewrite_in_progress|aof_rewrite_scheduled|aof_last_bgrewrite_status'
```

数据目录里会多出 `appendonlydir/`，里面有 `*.base.aof`、`*.incr.aof` 和 `appendonly.aof.manifest`。

**2. 停应用写入，关掉 Redict**

```sh
redict-cli SHUTDOWN          # 或 systemctl stop redict
```

**3. 用同一个数据目录启动 Valkey，开着 AOF**

配置里至少要有这几行（其他照搬原来的 redict.conf）：

```
dir /var/lib/redict          # 指向原来的数据目录，或者把整个目录拷到 Valkey 的目录
appendonly yes
appenddirname "appendonlydir"
```

容器的话：

```sh
docker run -d --name valkey -v /srv/redict-data:/data valkey/valkey:8.1 \
  valkey-server --dir /data --appendonly yes
```

**4. 对数，并让 Valkey 自己存一份 RDB**

```sh
valkey-cli DBSIZE            # 跟第 0 步记的一样
valkey-cli SAVE              # 用 Valkey 自己的格式覆盖掉旧的 RDB 12 文件
```

最后这步别省。不然哪天你关掉 AOF 重启，Valkey 会去读目录里那个旧的 RDB 12 文件，又启动不了。跑稳了想改回只用 RDB，先 `SAVE` 再关 AOF。

## 其他要注意的

- **Debian 包的配置路径不是 `/etc/valkey.conf`**：Debian 13 的 `valkey-server`（trixie-security 里是 8.1.1+dfsg1-3+deb13u3）把配置放在 `/etc/valkey/valkey.conf`，服务名 `valkey-server`。照公告把文件 mv 到 `/etc/valkey.conf`，服务不会读它。
- **命令行工具改名**：脚本里写死的 `redict-cli`、`redict-server` 要改成 `valkey-cli`、`valkey-server`。
- **先在副本上演练**：把第 0 步的备份和 `appendonlydir/` 拷一份到别的目录，用临时容器跑一遍第 3、4 步，对上数再动线上。
