# 512 MB 内存的 10 美元小盒子能跑哪些自建服务

**一句话结论**：一台只有 512 MB 内存、4 核 1 GHz ARM 的 OpenStick（4G 随身 Wi-Fi 棒刷成 Debian），挑对软件也能同时跑 DNS 去广告、监控、服务探活、RSS、书签存档等一整套家用服务，每个服务大多只占 10 到 40 MB。

## 要点

- **硬件**：作者花 10 美元（含运费）买的 OpenStick，约 450 MB 可用内存、4 GB eMMC、Wi-Fi 和 4G 模块，被动散热没有噪音。刷机过程有点折腾，刷好后是 Debian，有 systemd 和 Podman 可用。
- **DNS 去广告**：AdGuard Home 约 40 MB。作者加了几个拦截列表后，约 60% 的 DNS 查询被拦下。官方版配小一点的列表（约 20 万条）就够用；作者自己有个能处理超大列表的分支，但他也提醒别随便跑陌生人编译的二进制。
- **监控分两层**：Beszel 看机器（CPU、内存、磁盘曲线，带告警，agent 和 server 加起来约 20 MB），Gatus 看服务（网站、数据库挂了就通知，约 10 MB）。作者原来在 Kubernetes 上跑 Grafana 全家桶，觉得对家用来说太重。
- **日志和更新提醒**：Dozzle 看容器日志，界面比 Beszel 好用，但两者功能有重叠，内存吃紧时可以只留一个。Diun 约 9 MB，容器镜像有新版本时发通知。
- **日常小工具**：Fusion RSS 阅读器约 22 MB；Shiori 书签管理约 10 到 20 MB，会顺手把网页存档，防止链接失效；CastSponsorSkip 5 到 10 MB，自动跳过 Chromecast 上 YouTube 视频里的赞助片段。
- **对外访问**：用 Cloudflare Tunnel（约 8 到 20 MB）把服务暴露出去，不用在路由器上开端口。作者也直说了代价：流量要经过 Cloudflare。

## 示例

下面是自己写的示例，不是原文内容。小内存机器上，先看清每个容器实际用了多少内存，再给容器设上限，避免一个服务把整台机器拖进 OOM：

```bash
# 看各容器当前内存占用（Podman 和 Docker 用法一样）
podman stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}"

# 启动时给容器设内存上限，例如 RSS 阅读器限制在 64 MB
podman run -d --name rss --memory 64m --restart unless-stopped <镜像名>

# 看系统整体还剩多少
free -m
```

## 适合谁

- 想入门自建、又不想买 NAS 或树莓派的人。
- 手上有闲置小内存 VPS（512 MB、1 GB）的人：这份清单基本可以照搬，内存数字也有参考价值。

## 注意事项和坑

- 文中的内存数字是作者自己机器上的观察值，拦截列表大小、RSS 订阅数量不同，占用会有出入。
- 4 GB eMMC 很小，日志和书签存档要留意容量，记得给 journald 和容器日志设上限。
- 用 Cloudflare Tunnel 对外开放的服务，最好再加一层登录或访问控制，别把管理界面裸露在公网上。
- 刷机步骤原文没有展开，按 OpenStick 社区的刷机教程来，刷之前备份原厂固件。

## 来源

- 社区：Hacker News（热门，700+ 分）
- 原文：https://blog.bosscher.ch/posts/openstick/
- 原文日期：2026-11-07
- 收录日期：2026-11-09
