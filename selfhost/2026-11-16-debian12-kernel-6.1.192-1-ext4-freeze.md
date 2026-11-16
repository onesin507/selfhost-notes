# Debian 12 内核 6.1.192-1（6.1.0-55）重启后几分钟死机：怎么查、怎么救、等哪个版本

**一句话结论**：Debian 12 在 2026-11-14 推了内核安全更新 6.1.192-1（`uname -r` 显示 6.1.0-55-*）。不少机器重启进这个内核后，过 25 秒到 5 小时不等就整机卡死，原因是 ext4 分配块代码里的一个空指针。退回 6.1.0-54 就稳定。修复版是 6.1.192-2，`uname -r` 还是 6.1.0-55，要看包版本号才分得出来。装了 6.1.192-1 但还没重启的，先别重启。

## 要点

- **症状**：开机正常、服务也起来了，过一阵就 ssh、网站全断，只能硬重启。控制台或上一次启动的日志（`journalctl -k -b -1`）里有 `BUG: kernel NULL pointer dereference`，调用栈停在 `ext4_mb_load_buddy_gfp ... [ext4]`。
- **谁会中**：Debian bug #1154101 定为 critical，已经合并了 7 份同样的报告。出过事的有物理机、KVM、Xen、Hyper-V，Hetzner Cloud（amd64 和 arm64）、OVH，amd64 / arm64 / i686 / cloud 内核都有，有人 5 台云主机全中。
- **看着没事不等于没事**：最快 25 秒、最慢约 5 小时才死。跑了半天没问题，可能只是还没触发。
- **会自己装上**：6.1.192-1 是走 bookworm-security 的安全更新（修了几个 io_uring 的 CVE），开了 unattended-upgrades 的机器会自动装。报告里就有人是自动重启之后才中招的。
- **修复版 6.1.192-2**：Debian 内核组 2026-11-16 放出，changelog 写的是 `ext4: fix NULL folio dereference in mballoc (Closes: #1154101)`。之前的测试版 6.1.192-1a~test1 已经有几个人确认不再死机，包括原来一分钟内就能复现的机器。整理本文时（2026-11-16 北京时间 20 点多），security.debian.org 上只有 6.1.192-2 的源码包，二进制包索引里还是 6.1.192-1，`apt` 暂时还装不到。

## 示例

以下都是示例，内核名和菜单标题按自己的机器改。

**1. 查自己中没中**

```bash
uname -rv
# 6.1.0-55-cloud-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.192-1 (2026-11-14)
#                                                 ^^^^^^^^^^ 看这里

dpkg-query -W 'linux-image-6.1.0-*'
# 装了哪些内核，各自的包版本
```

- `uname -v` 里是 `Debian 6.1.192-1`：正在跑有问题的那一版。
- `uname -r` 还是 6.1.0-54，但 `dpkg-query` 里 6.1.0-55 是 `6.1.192-1`：装了、还没重启进去。
- 包版本是 `6.1.192-2` 或更新：已经修了。

**2. 已经卡死了：选回旧内核**

硬重启，在 GRUB 菜单选 `Advanced options for Debian GNU/Linux`，再选 `Debian GNU/Linux, with Linux 6.1.0-54-...`。云主机要开厂商的串口或 VNC 控制台才看得到菜单。进去以后用下一步的办法，防止下次又进 6.1.0-55。

**3. 非重启不可：只让下一次启动进旧内核**

`grub-reboot` 只管下一次启动，再下一次就回默认，不用改 `/etc/default/grub`：

```bash
# 先看菜单标题，cloud、arm64 的内核名不一样
sudo grep -E "^\s*(submenu|menuentry) " /boot/grub/grub.cfg | cut -d"'" -f2

# 父菜单和子菜单用 > 连起来
sudo grub-reboot 'Advanced options for Debian GNU/Linux>Debian GNU/Linux, with Linux 6.1.0-54-cloud-amd64'
sudo grub-editenv list      # 应该看到 next_entry=...6.1.0-54...
sudo reboot
```

我在测试机上对一份空的 grubenv 跑过 `grub-reboot`，它写进的就是上面这行 `next_entry`。GRUB 2.06 的 `00_header` 里，不管 `GRUB_DEFAULT` 是不是 `saved`，`next_entry` 都会生效，用完就清掉。

**4. 修复版出来以后**

```bash
sudo apt update && apt list --upgradable 2>/dev/null | grep linux-image
sudo apt upgrade
dpkg-query -W 'linux-image-6.1.0-55-*'     # 要看到 6.1.192-2
sudo reboot
uname -v                                    # 要看到 Debian 6.1.192-2
```

**5. 重启前自动检查**

配套脚本 [kernel-fallback-check.sh](../scripts/README.md#kernel-fallback-checksh) 只读，会看正在跑哪个内核、下次重启进哪个、有没有能退回去的旧内核、GRUB 菜单是不是隐藏的、会不会自动重启：

```bash
./kernel-fallback-check.sh -b 6.1.192-1
```

## 适合谁

用 Debian 12（bookworm）自带 6.1 内核的机器，尤其是开了 unattended-upgrades 自动重启、又不方便进控制台的 VPS。这份 bug 报告只涉及 Debian 12 的 6.1.192-1。HN 上有人说自己的 Debian 12 跑的是 backports 内核，没受影响。别的发行版这里没核对。

## 注意事项和坑

- **别只看 6.1.0-55**：修复版沿用同一个 `uname -r` 和同一个包名，只有包版本号不同。脚本的 `-b` 也要写 `6.1.192-1`，写 `6.1.0-55` 会把修好的也当成坏的。
- **别 hold**：`apt-mark hold linux-image-6.1.0-55-*` 会把修复版也挡在外面。
- **先关自动重启**：如果 `/etc/apt/apt.conf.d/` 里有 `Unattended-Upgrade::Automatic-Reboot "true";`，修复版装上之前暂时改成 `"false"`，装好再改回来。
- **旧内核留着**：确认新内核跑稳之前别 `apt autoremove`，6.1.0-54 删了就没得退。
- **复现方法不搬**：bug 报告里有一个几秒内就能触发死机的办法，受影响的机器会直接挂掉，只适合随时能丢的测试虚拟机。

## 来源

- 社区：Hacker News
- 原文：https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1154101
- Hacker News 讨论：https://news.ycombinator.com/item?id=50514180
- Debian 6.1.192-2 源码包：https://security.debian.org/debian-security/pool/updates/main/l/linux/
- GRUB 2.06 `00_header.in`：https://git.savannah.gnu.org/cgit/grub.git/tree/util/grub.d/00_header.in?h=grub-2.06
- 原文日期：2026-11-15
- 收录日期：2026-11-16
