# selfhost-notes

自建服务、开源工具、服务器安全的中文实操笔记。

Self-hosting, dev tools & server hardening notes, written in Chinese.

每天从 linux.do、V2EX、Hacker News、Lobsters、GitHub Trending、Reddit（r/selfhosted、r/linux、r/sysadmin 等）、少数派等社区挑 1 到 3 条有干货的帖子、文章或项目，用自己的话写成实操笔记，附上原链接。能给出命令或配置的，尽量给一段可以直接改了用的示例。

## 三个主题

| 目录 | 内容 |
| --- | --- |
| [selfhost/](selfhost/) | 自建服务与 Linux 运维：Docker / Podman、反向代理、备份、监控、systemd、家用服务器、小内存 VPS 调优。 |
| [devtools/](devtools/) | 好用的开源工具和效率技巧：命令行工具、终端、Git 技巧、编辑器配置、自动化脚本。 |
| [security/](security/) | 服务器安全加固：SSH 加固、防火墙、fail2ban、证书、密钥和机密管理、日志审计、常见漏洞的修复。只写防御，不写攻击教程。 |

## 不收什么

本仓库和 AI 编程代理、A 股量化、免费云资源无关，这三类内容一律不收。

## 收录原则

- **自己的话**：每条都是重新组织的中文笔记，不整段照搬原文。
- **附原链接**：写明来源社区、原文链接和日期，原文版权归原作者。
- **只搬公开内容**：需要登录才能看的内容不往外搬。
- **不放推广和个人信息**：没有推广链接、邀请码、返利链接，也没有任何人的个人信息、token、密码、IP。
- **安全类只写防御**：怎么加固、怎么修、怎么查，不写怎么打。
- **宁缺毋滥**：没有好素材的日子宁可不加，或者回头更新旧条目（工具出了新版、做法过时了）。

详细格式见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 索引

按日期倒序，每条一行：日期 · 主题 · 标题。

<!-- INDEX:START -->
- 2026-11-09 · security · [Outlook.com 开始拒收没有 DMARC 记录的域名的邮件：补一条 p=none](security/2026-11-09-outlook-dmarc-p-none.md)
- 2026-11-09 · selfhost · [nspawn 3.0：用 docker 命令管理 systemd-nspawn 容器](selfhost/2026-11-09-nspawn-3-docker-api.md)
- 2026-11-09 · selfhost · [512 MB 内存的 10 美元小盒子能跑哪些自建服务](selfhost/2026-11-09-openstick-512mb-homelab.md)
<!-- INDEX:END -->

## 许可证

- 笔记正文：[知识共享 署名 4.0 国际许可协议（CC BY 4.0）](https://creativecommons.org/licenses/by/4.0/deed.zh-hans)，转载请注明出处。
- 笔记里的命令和配置片段：MIT 许可证，可以随意复制使用。
- 被引用、被总结的原帖和原文，版权归各自原作者所有，不在上述许可范围内；每条笔记都附有原文链接。

Notes are licensed under [CC BY 4.0](LICENSE); code and config snippets in the notes are MIT-licensed. Copyright of the original posts belongs to their authors; every entry links to its source.
