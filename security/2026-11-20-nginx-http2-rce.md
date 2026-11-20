# Nginx 1.30.7 / 1.31.9 修了两个 HTTP/2 远程代码执行漏洞：怎么查、怎么修

**一句话结论**：2026-11-18 Nginx 发布 1.30.7（stable）和 1.31.9（mainline），一次修了 10 个漏洞。最严重的两个都在 HTTP/2，未登录就能远程执行代码，其中一个连只放静态文件的站都能打。Debian、Ubuntu 当天就出了修复包。开了 HTTP/2 的 Nginx 今天就升级，升完记得重启。暂时升不了，就先关掉 HTTP/2。

## 要点

- **两个严重漏洞**（CVSS 4.0 都是 9.2，前提都是开了 HTTP/2）：
  - **CVE-2026-123007**：HTTP/2 流量控制的账算错了（整数下溢），导致非法内存拷贝。影响 1.9.5 到 1.31.8，也就是 2015 年加入 HTTP/2 以来的几乎所有版本。Wiz 在 64 位系统上实测：只放普通静态文件、没有后端、没有第三方模块的 Nginx，也能被远程执行代码。
  - **CVE-2026-123633**：HTTP/2 的 use-after-free（内存释放后还在用），发生在反向代理、可用连接槽快用完的时候。影响 1.19.7 到 1.31.8，条件是 HTTP/2 + 反代。
- **同一批还有 8 个**，升到修复版一起解决。和自建关系大的几个：
  - CVE-2026-121810：HTTP/3 做反代时的 use-after-free，9.2 分，1.25.0 起受影响；
  - CVE-2026-123634：DNS 解析器的 use-after-free，攻击者能控制上游主机名时可执行代码，9.2 分；
  - CVE-2026-113425：邮件代理模块（配了 auth_http）的 use-after-free，9.2 分；
  - CVE-2026-118899：开了 TLS 1.3 时读请求体可能死循环，可被拒绝服务，8.7 分；
  - 另外四个是 proxy_protocol v2 空指针、alias + try_files 缓冲区溢出、stream ssl_preread 校验不足、特定 SNI 配置下绕过客户端证书，6.3 到 6.9 分。
- **发现者**：Wiz 报给 F5 并协助修复，Ikotas Labs、Metnir、Rapid7、Xint 也各自独立报了。
- **发行版看包版本**：Debian、Ubuntu 把补丁回移植到旧版本号上，`nginx -v` 显示 1.24.0 不代表没修。用 `dpkg-query -W nginx nginx-core` 看包版本，对照下表。nginx.org 官方源的包和 Docker 官方镜像才看上游版本号。
- **升级后要重启**：我实测，`apt` 升级包以后，已经在跑的 nginx 进程还是旧程序（`/proc/<pid>/exe` 显示 deleted）。容器里也一样，要拉新镜像重建容器。

## 各发行版的修复包

下表是 2026-11-20 从 Debian 和 Ubuntu 的安全追踪页抄来的，之后可能还会更新，以官方页面为准：

| 发行版 | 修复的 nginx 包版本 |
| --- | --- |
| Debian 12 bookworm | 1.22.1-9+deb12u11（DLA-4918-1） |
| Debian 13 trixie | 1.26.3-3+deb13u11（DSA-6642-1） |
| Debian forky（testing） | 写这篇笔记时还是 1.30.6-3，没修 |
| Debian sid | 1.30.6-4 |
| Ubuntu 26.10 | 1.30.4-7ubuntu1.2 |
| Ubuntu 26.04 LTS | 1.28.3-2ubuntu1.13 |
| Ubuntu 24.04 LTS | 1.24.0-2ubuntu7.20 |
| Ubuntu 22.04 LTS | 1.18.0-6ubuntu14.23 |
| Ubuntu 20.04 / 18.04 / 16.04 | 有修复包，但要 Ubuntu Pro（ESM）才装得到 |
| nginx.org 官方源、Docker 官方镜像、自己编译 | 上游 1.30.7 或 1.31.9 及以上 |

## 怎么查

用配套脚本 [nginx-h2-cve-check.sh](../scripts/README.md#nginx-h2-cve-checksh)，只读，不改配置：

```bash
curl -fsSLO https://raw.githubusercontent.com/onesin507/selfhost-notes/main/scripts/nginx-h2-cve-check.sh
chmod +x nginx-h2-cve-check.sh
sudo ./nginx-h2-cve-check.sh
```

想手动查，就看三件事：

```bash
# 1. 包版本（对照上表）
dpkg-query -W nginx nginx-core 2>/dev/null

# 2. 生效配置里有没有开 HTTP/2（两种写法都算）
sudo nginx -T 2>/dev/null | grep -nE 'listen[^;]*\shttp2|http2\s+on'

# 3. 正在跑的是不是升级前的旧程序（有输出就要重启）
for p in $(pgrep -x nginx); do sudo readlink /proc/$p/exe; done | grep deleted
```

Docker 里的 Nginx：

```bash
docker exec <容器名> nginx -v
# 或者把版本号交给脚本判断
./nginx-h2-cve-check.sh -V "$(docker exec <容器名> nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
```

## 怎么修

```bash
sudo apt update
sudo apt install --only-upgrade 'nginx*'
sudo nginx -t && sudo systemctl restart nginx
```

Docker 用户把镜像标签换到 1.30.7 / 1.31.9 或之后，`docker compose pull && docker compose up -d` 重建容器。

修完验证：再跑一遍脚本，结论应该是 OK。

## 暂时升不了：先关 HTTP/2

Wiz 给的临时办法是先把 HTTP/2 关掉，升级后再打开：

1. Nginx 1.25.1 及以后，在受影响的 `server` 块里写 `http2 off;`；
2. 把所有 `listen ... http2` 里的 `http2` 参数去掉；
3. `sudo nginx -t && sudo systemctl reload nginx`，然后确认旧的 worker 进程已经退出。

关掉 HTTP/2 只是让浏览器退回 HTTP/1.1，网站照常能访问，但同批不靠 HTTP/2 的漏洞还在，最终还是要升级。

自查时可以留意意外的 worker 崩溃，或者 nginx 进程启动了别的命令。Wiz 说这只是一般性的警示信号，不是这两个漏洞的确切痕迹。

## 来源

- Nginx 官方安全公告：https://nginx.org/en/security_advisories.html （2026-11-18）
- Nginx 首页发布消息：https://nginx.org/ （2026-11-18）
- Wiz 技术文章：https://www.wiz.io/blog/nginx-http2-rce-vulnerabilities
- Debian 安全追踪：https://security-tracker.debian.org/tracker/CVE-2026-123007 、https://security-tracker.debian.org/tracker/CVE-2026-123633
- Ubuntu 安全页：https://ubuntu.com/security/CVE-2026-123007 、https://ubuntu.com/security/CVE-2026-123633

原文版权归原作者，这里只是中文整理和实测记录。
