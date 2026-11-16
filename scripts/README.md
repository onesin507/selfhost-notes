# scripts：可以直接用的小脚本

自己写的运维和开发小脚本，以 Bash、Python 为主。每个脚本是一个独立文件，开头注释写了用途、用法和依赖，`-h` 可以看帮助。

约定：

- 收录前都在 Linux 上实际跑过；Bash 脚本过了 shellcheck，Python 脚本过了 `python3 -m py_compile`。
- 会删东西、改东西的脚本默认只演示（dry-run），要加参数才真的执行。
- 借鉴了别人思路的，在脚本注释和下面的清单里注明来源链接。
- 脚本代码按 MIT 许可证授权，可以随意复制、修改、商用。

## 脚本清单

| 脚本 | 语言 | 用途 | 收录日期 |
| --- | --- | --- | --- |
| [kernel-fallback-check.sh](kernel-fallback-check.sh) | Bash | 升级内核、重启之前，检查有没有能退回去的旧内核，以及下次重启会进哪个内核（可标出已知有问题的版本） | 2026-11-16 |
| [pg-cve-2026-6460-check.sh](pg-cve-2026-6460-check.sh) | Bash | 检查本机和 Docker / Podman 容器里的 PostgreSQL 有没有修 2026-11-12 这批漏洞（CVE-2026-6460 等） | 2026-11-15 |
| [apache-h2-cve-check.sh](apache-h2-cve-check.sh) | Bash | 检查本机 Apache 有没有中 CVE-2026-119618（mod_http2 远程代码执行） | 2026-11-14 |
| [cert-expiry-check.sh](cert-expiry-check.sh) | Bash | 检查线上站点和本地证书文件还剩几天过期，用退出码告警 | 2026-11-09 |

## cert-expiry-check.sh

给一串域名（可带端口）或本地 PEM 证书文件，列出每张证书的到期日和剩余天数。剩余天数不超过 `-w`（默认 21 天）标 WARN，不超过 `-c`（默认 7 天）或已过期、连不上的标 CRIT。只读，不改任何东西。

**依赖**：bash 4+、openssl、GNU date、timeout（Linux 一般都自带）。

**常用写法**（示例）：

```sh
# 查几个站点，邮件服务这类非 443 端口写上端口
./cert-expiry-check.sh example.com www.example.com mail.example.com:993

# 查本机 certbot 申请的证书（需要有读权限，一般要 sudo）
sudo ./cert-expiry-check.sh -w 30 -c 10 /etc/letsencrypt/live/*/fullchain.pem

# 目标多了写进文件，一行一个，# 后面是注释
./cert-expiry-check.sh -f ~/sites.txt
```

输出大概长这样：

```
STATE   DAYS  EXPIRES     TARGET
WARN      15  2026-11-24  www.example.com
CRIT       5  2026-11-14  mail.example.com:993
CRIT       -  -           old.example.com（连不上或读不出证书）
OK       200  2027-05-28  example.com
```

**退出码**：0 全部正常，1 有 WARN，2 有 CRIT，64 用法错误。

**放进 cron 每天跑**（示例）：`-q` 只在有问题时打印，配合 cron 的 MAILTO，没事就不会发邮件。

```cron
# 每天早上 9 点查一次，输出非空时 cron 会把输出发给 MAILTO
MAILTO=admin@example.com
0 9 * * * /usr/local/bin/cert-expiry-check.sh -q -f /etc/cert-targets.txt
```

也可以接到自己的通知脚本上：

```sh
out=$(/usr/local/bin/cert-expiry-check.sh -q -f /etc/cert-targets.txt) || your-notify-command "$out"
```

**注意**：

- 站点只看叶子证书（也就是你自己的那张），不验证证书链是否完整、是否受信任。用了 CDN 的域名，查到的是 CDN 边缘节点的证书，不是你源站的。
- 剩余天数向下取整，还剩 6.9 天按 6 天算。
- 本地文件只读第一张证书，`fullchain.pem` 和 `cert.pem` 的第一张都是叶子证书，结果一样。
- 端口只支持 `主机名:端口` 写法，不支持裸 IPv6 地址。需要 STARTTLS 的端口（比如 SMTP 587）不在支持范围里，只支持一连上就是 TLS 的端口，如 443、993、995、465。
- macOS 自带的 date 不是 GNU 版，要先装 coreutils。

## kernel-fallback-check.sh

内核更新偶尔会出事，比如 2026-11 Debian 12 的 6.1.192-1：重启后几分钟到几小时内整机卡死，背景见 [这篇笔记](../selfhost/2026-11-16-debian12-kernel-6.1.192-1-ext4-freeze.md)。出了事能不能救回来，取决于重启前的状态。这个脚本就是在重启前看一遍：

- 现在跑的是哪个内核，下次重启默认进哪个（装着的最新那个）；
- 除此之外还有没有 vmlinuz 和 initrd 都在的旧内核可以退回去；
- 用 `-b` 指定的有问题版本是不是正在跑，或者下次重启就会进；
- GRUB 默认启动项、启动菜单是不是隐藏的、unattended-upgrades 会不会自动重启、内核包有没有被 hold。

只读，不改 GRUB，不装卸软件包，不重启。

`-b` 同时匹配 `uname -r` 的写法（如 `6.1.0-55-cloud-arm64`）和内核包的版本号（如 `6.1.192-1`，从 dpkg 读）。Debian 的修复版常常沿用同一个 `uname -r`，这时一定要写包版本，不然修好的内核也会被判成坏的。

**依赖**：bash 4+、coreutils（`sort -V`）、grep、sed；Debian / Ubuntu 上有 dpkg-query 时会显示包版本。适用于 `/boot` 下放 `vmlinuz-版本` 和 `initrd.img-版本`（或 `initramfs-版本.img`）的系统；用 systemd-boot / UKI 的机器结果只作参考。

**常用写法**（示例）：

```sh
# 普通检查
./kernel-fallback-check.sh

# 这次 Debian 12 的情况：标出 6.1.192-1
./kernel-fallback-check.sh -b 6.1.192-1

# 救援模式下检查挂到 /mnt 的系统
sudo ./kernel-fallback-check.sh -R /mnt -b 6.1.192-1

# 放进 cron：只在有问题时输出
./kernel-fallback-check.sh -q -b 6.1.192-1 || echo "这台重启前要先处理"
```

结论有四种：

- **OK**：这一项没问题。
- **INFO**：只是告诉你，比如 GRUB 菜单是隐藏的、开了自动重启。
- **WARN**：没有可以退回去的旧内核；某个内核缺 initrd；正在跑的内核文件已经被删了；或者 `/boot` 下根本没有内核，判断不了。
- **CRIT**：正在跑的内核，或者下次重启要进的内核，匹配 `-b` 指定的有问题版本。

**退出码**：0 正常，1 有 WARN，2 有 CRIT，64 用法错误。

**实测**：从 security.debian.org 下了 Debian 12 真实的内核包 linux-image-6.1.0-54-cloud-amd64（6.1.190-1）和 linux-image-6.1.0-55-cloud-amd64（6.1.192-1），解到一个测试目录里，用 `-R` 检查。
- 正在跑 6.1.0-54、装了 6.1.192-1：「下次重启」判 CRIT，退路是 6.1.0-54，退出码 2。
- 正在跑 6.1.192-1：「正在运行」和「下次重启」都判 CRIT，退出码 2。
- 把包版本改成修复版 6.1.192-2、`uname -r` 不变：全部 OK，退出码 0。同样的情况写成 `-b 6.1.0-55`，会误判成 CRIT，所以上面要求写包版本。

另外用假的 `/boot` 测了几种情况：
- 只剩一个内核、正在跑的内核文件已被删掉：两条 WARN，退出码 1。
- 旧内核缺 initrd：WARN，退出码 1。
- GRUB 菜单隐藏、`GRUB_DEFAULT=saved`、开了自动重启：都显示成 INFO。
- 一切正常时加 `-q`：不输出，退出码 0。

在没有 `/boot` 内核的容器里跑，判为 WARN，退出码 1。没有在真的会重启的机器上跑过。脚本过了 shellcheck 0.11.0。

## pg-cve-2026-6460-check.sh

检查本机的 PostgreSQL 有没有修 2026-11-12 公布的那批漏洞，以 CVE-2026-6460（普通账号借 `ALTER ... SET DATA TYPE` 执行系统命令）为代表，背景见 [这篇笔记](../security/2026-11-15-postgresql-nov-2026-cves.md)。它会找三处：本机装的服务端程序、正在跑的 Docker / Podman 容器（镜像名带 postgres、postgis、timescale、pgvector 的），加 `-c` 时再用 psql 连上正在跑的库读 `server_version`。按小版本号判断，修复版是 18.7、17.12、16.16、15.20、14.25。只读，不改配置，不重启服务，不拉镜像。

Debian、Ubuntu 和 PostgreSQL 官方 apt 源都直接用上游小版本号，所以看版本号就准。红帽系可能把补丁回移植到旧版本号上，结论只作参考。修复版本是 2026-11-15 从官方公告抄的。

**依赖**：bash 4+、grep、sed；查容器要能执行 docker 或 podman（一般要 sudo 或在 docker 组里）；`-c` 要有 psql。

**常用写法**（示例）：

```sh
# 查本机和容器
sudo ./pg-cve-2026-6460-check.sh

# 连上正在跑的库，确认重启后真的是新版本
sudo -u postgres ./pg-cve-2026-6460-check.sh -c

# 放进 cron：只在有问题时输出
sudo ./pg-cve-2026-6460-check.sh -q || echo "这台的 PostgreSQL 要处理"

# 不在本机跑：直接判断一个版本号
./pg-cve-2026-6460-check.sh -V 16.15
```

结论有三种：

- **OK**：已修。
- **WARN**：已修但大版本停止维护（14 系列）；或者判断不了，比如版本号格式不认识、`-c` 连不上库。
- **CRIT**：没修，或者是 13 及更早、没有修复版的大版本。

**退出码**：0 全部已修，1 有 WARN，2 有 CRIT，3 本机没找到 PostgreSQL，64 用法错误。

**实测**：在 Ubuntu 26.04 上装了官方源的 postgresql-18（18.6-0ubuntu0.26.04.1，还没修），本机程序和 `-c` 连库两项都判为 CRIT，退出码 2；按笔记里的办法换到 PostgreSQL 官方 apt 源、升到 18.7-1.pgdg26.04+2 并重启后，两项都变成 OK，退出码 0。卸掉以后再跑，提示没找到，退出码 3。另外用 `-V` 测了边界：18.6、17.11、16.15、14.24、13.22、9.6.24 判 CRIT，18.7、17.12、16.16、15.20 判 OK，14.25 判 WARN。容器检查这部分没有实际跑过，因为测试机上没有 Docker。脚本过了 shellcheck。

## apache-h2-cve-check.sh

检查本机的 Apache 有没有中 2026-11-11 公布的 CVE-2026-119618（mod_http2 远程代码执行，背景见 [这篇笔记](../security/2026-11-14-apache-mod-http2-rce.md)）。它看三件事：apache2 的包版本有没有到各发行版的修复版本、mod_http2 有没有加载、生效的配置里有没有 `Protocols h2` / `h2c`。只读，不改配置，不重启服务。

Debian / Ubuntu 上按**包版本**判断，因为发行版会把补丁回移植到旧的 2.4.x 版本号上。别的系统没有 dpkg，就按上游版本号判断（受影响的是 2.4.55 至 2.4.70），红帽系请再对照厂商公告。修复版本表是 2026-11-14 抄的，之后可能更新。

**依赖**：bash 4+、coreutils、grep；Debian / Ubuntu 上用 dpkg。读模块列表和完整配置一般要 sudo。

**常用写法**（示例）：

```sh
# 在要检查的机器上跑
sudo ./apache-h2-cve-check.sh

# 放进 cron 或批量巡检：-q 只在有问题时输出，退出码非 0 就要处理
sudo ./apache-h2-cve-check.sh -q || echo "这台的 Apache 要处理"

# 不在本机跑：把别的机器 dpkg-query -W apache2 的版本贴进来，配上发行版代号
./apache-h2-cve-check.sh -P 2.4.58-1ubuntu8.18 -C noble
```

结论有三种：

- **OK**：已修复，或者根本没装 Apache。
- **WARN**：版本没修，但 HTTP/2 没开；或者有一项判断不了，比如没用 sudo 读不到模块列表。
- **CRIT**：版本没修，而且 HTTP/2 开着，要尽快升级。暂时升不了，就先把 `Protocols` 改成只留 `http/1.1`。

**退出码**：0 OK，1 WARN，2 CRIT，64 用法错误。

**实测**：在 Ubuntu 26.04 上装了 apache2 2.4.66-2ubuntu2.8（已修复版）跑过。分别试了 HTTP/2 开、关，用 sudo 和不用 sudo，还把修复版本临时改高来模拟“没修”，三种结论和退出码都对得上。另外用假的 `httpd` 测了上游版本号的边界：2.4.54 和 2.4.71 判为 OK，2.4.55 和 2.4.70 判为 CRIT。脚本过了 shellcheck。
