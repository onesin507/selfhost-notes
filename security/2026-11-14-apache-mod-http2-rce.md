# Apache 2.4.71 修了 mod_http2 远程代码执行漏洞 CVE-2026-119618：怎么查、怎么修

**一句话结论**：Apache httpd 2.4.55 到 2.4.70 只要开了 HTTP/2，就可能被未登录的远程攻击者执行代码。2026-11-11 发布的 2.4.71 修了这个漏洞，Debian 和 Ubuntu 也已经出了修复包。用 Apache 的机器今天就 `apt upgrade`。暂时升不了，就先把 HTTP/2 关掉。

## 要点

- **漏洞是什么**：mod_http2 的 `assign_headers()` 在多个线程共用资源时没有同步好（竞态），攻击者可以借此破坏堆内存，进而以 Web 服务进程的权限执行任意命令。Apache 官方定为 critical（严重）。发现者是 Anthropic 的开源代码扫描器和 Google Cloud 漏洞研究团队，两边分别在 10 月 26 日和 11 月 3 日报告。
- **影响范围**：官方写的是 httpd 2.4.55 到 2.4.70，以及 GitHub 上单独发布的 mod_h2 模块 2.0.8 到 2.0.42。前提是 HTTP/2 真的开着：既加载了 mod_http2，配置里的 `Protocols` 也写了 `h2` 或 `h2c`。
- **发行版别只看 2.4.x 版本号**：发行版会把新版模块和补丁回移植到旧版本号上。Ubuntu 22.04 的 apache2 是 2.4.52，比官方给的 2.4.55 还低，照样受影响：Ubuntu 安全团队的说明是，新版 mod_http2 已经回移植到了 Ubuntu 的稳定版里。所以 Debian、Ubuntu 一律看**包版本**，对照下面的表。
- **同一版还修了两个**：mod_md 的空指针问题 CVE-2026-106023（important，2.4.30 到 2.4.70，能让子进程崩溃），以及 mod_vhost_alias 的 1 字节栈溢出 CVE-2026-109163（low，只影响 2.4.69 和 2.4.70）。升到修复版就一起解决了。
- **利用情况**：Wiz 11 月 11 日的文章说，当时还没有公开的利用代码，也没有在野利用的报告。Wiz 自己的数据显示 64% 的云环境里有带漏洞版本的资源，51% 有暴露在公网的实例，不过这个统计没考虑 HTTP/2 开没开。
- **Ubuntu 默认怎么配**：在 Ubuntu 26.04 上实测（apache2 2.4.66-2ubuntu2.8），模块自带的 `http2.conf` 里就有一行 `Protocols h2 h2c http/1.1`，`a2enmod http2` 会把它一起启用。也就是说，只要启用了这个模块，HTTP/2 就是开着的。

## 各发行版的修复包

下表是 2026-11-14 从 Debian 和 Ubuntu 的安全追踪页抄来的，之后可能还会更新，以官方页面为准：

| 发行版 | 修复的 apache2 包版本 |
| --- | --- |
| Debian 12 bookworm | 2.4.71-1~deb12u1（DLA-4902-1） |
| Debian 13 trixie | 2.4.71-1~deb13u1（DSA-6620-1） |
| Debian forky（testing） | 写这篇笔记时还是 2.4.69-1，没修 |
| Debian sid | 2.4.71-1 |
| Ubuntu 26.10 | 2.4.68-1ubuntu6.2 |
| Ubuntu 26.04 LTS | 2.4.66-2ubuntu2.8 |
| Ubuntu 24.04 LTS | 2.4.58-1ubuntu8.19 |
| Ubuntu 22.04 LTS | 2.4.52-1ubuntu4.27 |
| Ubuntu 20.04 LTS | 2.4.41-4ubuntu3.23+esm11（要 Ubuntu Pro） |
| Ubuntu 18.04 及更早 | 不受影响 |

Ubuntu 对应的安全通告是 USN-9090-1（11 月 12 日）。红帽系（RHEL、Rocky、Alma）这篇笔记没有逐个核对，请看各自的安全公告。

## 示例

以下命令是自己整理的示例，以 Debian / Ubuntu 为例。

```bash
# 1. 看包版本，对照上表
dpkg-query -W apache2

# 2. 看 HTTP/2 开没开：模块加载了，且生效的配置里有 h2 / h2c
sudo apache2ctl -M | grep http2_module
sudo grep -RIn --exclude-dir='*-available' '^\s*Protocols' /etc/apache2

# 3. 升级并重启
sudo apt update && sudo apt install --only-upgrade apache2
sudo systemctl restart apache2
dpkg-query -W apache2   # 确认已经是修复版本
```

暂时升不了时的临时办法：把 `Protocols` 改成只留 HTTP/1.1，这是 Wiz 给的临时缓解措施。

```apache
# 在 apache2.conf / httpd.conf 或各站点的 VirtualHost 里，把含 h2、h2c 的 Protocols 行改成：
Protocols http/1.1
```

```bash
# Debian / Ubuntu 也可以直接停用模块（会连带去掉 mods-enabled/http2.conf 里那行 Protocols）
sudo a2dismod http2
# 站点配置里自己写的 Protocols h2 行也要改掉；先检查语法，再重载
sudo apache2ctl configtest && sudo systemctl reload apache2
```

本仓库的 [scripts/apache-h2-cve-check.sh](../scripts/apache-h2-cve-check.sh) 能把上面几步一次查完，按包版本和 HTTP/2 开关给出 OK / WARN / CRIT。用法见 [scripts/README.md](../scripts/README.md#apache-h2-cve-checksh)。

## 适合谁

- 用 Apache 跑网站、反向代理、WordPress、Nextcloud 一类服务的人，尤其是 Apache 直接对公网的。
- 用 Docker 官方 `httpd` 镜像或其他自带 Apache 的镜像的人：容器里的 Apache 不会跟着宿主机升级，要拉新镜像重建容器，再用 `httpd -v` 确认版本到了 2.4.71 或以上。
- 只用 Nginx、Caddy，机器上根本没装 Apache 的，这个漏洞和你无关。

## 注意事项和坑

- **装了补丁要重启**：升级完包，正在跑的旧进程还在内存里，要 `systemctl restart apache2` 才算修好。
- **别被版本号骗**：Ubuntu 22.04 上 2.4.52 这个号看着在影响范围外，实际受影响。反过来，Ubuntu 24.04 的修复包版本号也还是 2.4.58，不会变成 2.4.71。
- **自己编译的、或用 GitHub 版 mod_h2 的**：httpd 升到 2.4.71，独立的 mod_h2 也要升到修复版。Wiz 建议升到 2.0.42 以后的版本。
- **关 HTTP/2 之前先确认**站点或反代后端有没有必须走 HTTP/2 的功能，有的话只能尽快升级，不能靠关 h2 顶着。
- **前面套了 CDN 或 Nginx 也要升级**：攻击流量能不能到 Apache，要看前面那一层怎么转发，别因为“前面有一层”就不升级。

## 来源

- 社区：Hacker News（约 370 分）
- Apache 官方漏洞页：<https://httpd.apache.org/security/vulnerabilities_24.html#CVE-2026-119618>
- Wiz 分析：<https://www.wiz.io/blog/cve-2026-119618-rce-apache-http-server-vulnerability>
- HN 讨论：<https://news.ycombinator.com/item?id=50462177>
- Debian 安全追踪：<https://security-tracker.debian.org/tracker/CVE-2026-119618>
- Ubuntu 安全页：<https://ubuntu.com/security/CVE-2026-119618>
- 原文日期：2026-11-11
- 收录日期：2026-11-14
