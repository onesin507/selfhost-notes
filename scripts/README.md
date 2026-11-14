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
