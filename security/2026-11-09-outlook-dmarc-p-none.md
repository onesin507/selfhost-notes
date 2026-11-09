# Outlook.com 开始拒收没有 DMARC 记录的域名的邮件：补一条 p=none

**一句话结论**：据邮件服务商 MailRoute 观察，从 2026-11-05 起，Outlook.com、Hotmail、Live、MSN 会拒收一部分来自“没有 DMARC 记录”的域名的邮件，小发件量也会中招；自建邮件或用自己域名发信的人，最少补一条 `v=DMARC1; p=none` 的 TXT 记录。

## 要点

- **现象**：发件人收到退信 `550 5.7.1 Message rejected: Message lacks SPF/DKIM/DMARC Auth Records`，后面可能跟一个括号里的编号。被退的域名大多 SPF 是好的，不少连 DKIM 也有，缺的是 DMARC。
- **不是每封都退**：同一个域名，这封进了，下一封被退，重发又可能成功。所以“我的邮件能收到”不代表没问题。
- **和以前的规则不同**：微软 2025 年 5 月起要求每天给 Outlook.com 发 5000 封以上的域名通过 SPF、DKIM、DMARC，退信码是 5.7.515。这次是新的，小发件人也受影响，而且截至 11 月 6 日微软没有发任何公告。
- **怎么修**：在 DNS 加一条 TXT，名字 `_dmarc`，值 `v=DMARC1; p=none`。`p=none` 只是声明域名用了 DMARC，失败时不要求收件方做任何处理，不会改变 Gmail 等其他收件方对你邮件的处理。
- **前提条件**：DMARC 要通过，SPF 或 DKIM 至少一个要对“发件人 From 地址的域名”通过（对齐）。只加 DMARC、SPF 和 DKIM 都对不上，照样没用。

## 示例

以下是自己写的示例，`example.com` 换成你的域名：

```bash
# 1. 看有没有 DMARC 记录：有输出且以 "v=DMARC1 开头就是有，没输出就是没有
dig +short TXT _dmarc.example.com

# 2. 顺便确认 SPF
dig +short TXT example.com | grep spf1

# 3. 确认 DKIM（selector 换成你的发信服务用的那个，常见如 default、s1、google）
dig +short TXT default._domainkey.example.com
```

最小可用的 DMARC 记录：

```
名称: _dmarc
类型: TXT
值:   v=DMARC1; p=none
```

想收汇总报告，可以加上 `rua`（报告地址换成你自己能收信的邮箱）：

```
v=DMARC1; p=none; rua=mailto:dmarc-reports@example.com
```

## 适合谁

- 自建邮件服务器（Postfix、Mailcow、Mailu 等）的人。
- 用自己域名通过云邮箱或中继发信的人，尤其是网站、监控、自建服务的通知邮件会发到 Hotmail、Outlook 地址的。

## 注意事项和坑

- 这条消息目前只来自 MailRoute（邮件服务商，文章里有自家产品的推广）和他们提到的其他管理员报告，微软没有官方说明。规则可能还会变，以实际退信为准。
- 如果你的发信服务用它自己的域名签 DKIM（原文举例：Microsoft 365 没给自有域名开 DKIM 之前，用的是 onmicrosoft.com 签名），这个签名不算你域名的 DKIM，DMARC 对齐会失败。
- `p=none` 是起点。等报告看清楚哪些服务在替你发信、全部对齐后，再逐步收紧到 `quarantine`、`reject`，防止别人冒用你的域名发钓鱼邮件。一上来就 `reject` 容易把自己的正常邮件也拦掉。
- 只发通知、不收信的域名，同样建议配好 SPF、DKIM、DMARC。

## 来源

- 社区：Hacker News
- 原文：https://mailroute.net/blog/outlook-rejecting-email-without-dmarc
- 原文日期：2026-11-06
- 收录日期：2026-11-09
