# libghostty-vt 1.0：Ghostty 的终端内核拆成独立 C 库，JetBrains 和 Neovim 都在用

**一句话结论**：libghostty-vt 是从 Ghostty 终端里拆出来的终端模拟库，1.0 起 C ABI 稳定、按语义化版本发布；普通用户会在 JetBrains IDE 和（将来的）Neovim 内置终端里间接用到它，要自己做终端、Web 终端或 TUI 测试工具的人可以直接拿来用。

## 要点

- **它是什么**：你把程序输出的字节（含转义序列）喂给它，它维护屏幕、光标、滚动缓冲这些终端状态，你再读出来自己渲染。它不管窗口和字体渲染，只管“终端该长什么样”。MIT 授权，运行时只依赖 libc，依赖树里没有 copyleft 代码。
- **谁在用**：作者文章说 JetBrains 全家桶（IntelliJ、PyCharm、GoLand 等）的内置终端已经换成它；Neovim 有一个已批准的 PR 用它替换 libvterm，顺带解决“窗口缩放时滚动内容不重排”这个十年老 issue，维护者在等 1.0 正式版再合并。此外 Turborepo 的 TUI、Emacs 插件 Ghostel、OrbStack 也在用，KDE 有人在试着用它做 Konsole 替代品。
- **Web 终端可以考虑它**：ghostty-web 是它的 WASM 版，接口兼容 Xterm.js。小的那个 WASM 模块所有功能全开也不到 1 MB，只做只读查看器时还能再编译掉输入、搜索、选择等子系统，体积大约减半。自建 Web SSH、在线终端一类服务可以留意。
- **很省资源**：库自己不开线程，内存分配器可自定义。作者在 4 核 8 GB 的 Linux 机器上跑了 1 万个带实时 shell 输出的终端，而且 bash 太吃内存放不下，只好换成 dash。
- **1.0 承诺了什么**：C ABI 稳定，CI 用 libabigail 卡 ABI 变化；ELF 平台上每个导出符号都带版本。库有自己的发布节奏和 `vt-X.Y.Z` 标签，和 Ghostty 应用版本号无关。发布包带 minisign 签名和离线依赖包，发行版可以完全离线构建。
- **平台和语言**：CI 里实测 Linux（glibc / musl）、macOS、iOS、FreeBSD、Windows、Android、WebAssembly；社区有 Rust、Go、JavaScript、Swift、Python、.NET 等语言绑定，awesome-libghostty 列了一百多个项目。

## 示例

以下是按官方 PACKAGING-LIBGHOSTTY.md 整理的示例流程，把 1.0.0 装到自己的 `~/.local`，没有在本仓库环境里实际编译过。构建需要 **Zig 0.17.x**，0.16 和 0.18 都不行。

```sh
# 示例：下载源码包和配套的依赖包（同一版本，不要混用）
V=1.0.0
BASE=https://release.files.ghostty.org/libghostty-vt/$V
curl -LO $BASE/libghostty-vt-$V.tar.gz
curl -LO $BASE/libghostty-vt-$V.tar.gz.minisig
curl -LO $BASE/libghostty-vt-$V-deps.tar.gz
curl -LO $BASE/libghostty-vt-$V-deps.tar.gz.minisig

# 验签（公钥以官方文档为准，和 Ghostty 应用发布用的是同一把）
PUB=RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV
minisign -V -P "$PUB" -m libghostty-vt-$V.tar.gz
minisign -V -P "$PUB" -m libghostty-vt-$V-deps.tar.gz

# 解压并离线构建；ZIG_GLOBAL_CACHE_DIR 必须是一个新的空目录
tar -xzf libghostty-vt-$V.tar.gz
tar -xzf libghostty-vt-$V-deps.tar.gz
cd libghostty-vt-$V
ZIG_GLOBAL_CACHE_DIR="$(mktemp -d)" zig build \
  --prefix "$HOME/.local" \
  --system ../libghostty-vt-$V-deps \
  -Doptimize=ReleaseFast

# 之后用 pkg-config 找库（库目录可能是 lib 或 lib64，按实际安装位置改）
export PKG_CONFIG_PATH="$HOME/.local/lib/pkgconfig:$PKG_CONFIG_PATH"
pkg-config --modversion libghostty-vt
```

官方文档首页有一个完整的最小 C 程序：建一个 80x24 的终端，写入带颜色转义序列的文字，再把屏幕内容读成纯文本。它用到的是 `ghostty_terminal_new`、`ghostty_terminal_vt_write` 和 `ghostty_formatter_*` 这几个函数，照着它改最快。

## 适合谁

- 想做终端、多路复用器、Web 终端、会话录制回放工具的人，不用再自己写转义序列解析。
- 要给 TUI 程序写自动化测试的人：程序输出喂进去，直接断言屏幕上显示了什么。作者提到 Antithesis 用它做模糊测试，在 btop 等程序里找到了真 bug。
- 只是日常用终端的人不用做任何事，升级 JetBrains IDE、等 Neovim 合并就行。

## 注意事项和坑

- 它只是“终端状态机”，不含窗口、字体渲染，也不帮你开 PTY，这些要自己接。
- 源码包不等于 Git 仓库：直接在 Ghostty 仓库里 `zig build` 会去编 Ghostty 应用而不是这个库。非要从 Git 构建，每条 `zig build` 都要加 `-Demit-lib-vt`。
- Zig 版本卡得很死：主次版本号必须完全一致，构建前先 `zig version` 确认是 0.17.x，不对的话构建会直接报错停下。
- 官方文档说：用 Zig 0.17 时，如果构建缓存里已经有依赖包的压缩包，可能报 "reached unreachable code" 崩溃。所以 `ZIG_GLOBAL_CACHE_DIR` 要用空目录，别用 `~/.cache/zig`。
- Neovim 那个 PR 在写这篇笔记时还没合并，具体哪个版本带上以 Neovim 发布说明为准。

## 来源

- 社区：Hacker News（约 1,080 分）
- 原文：<https://mitchellh.com/writing/libghostty-1-0>
- HN 讨论：<https://news.ycombinator.com/item?id=50399933>
- 官方文档：<https://lib.ghostty.org/>
- 打包说明：<https://github.com/ghostty-org/ghostty/blob/main/PACKAGING-LIBGHOSTTY.md>
- 原文日期：2026-11-06
- 收录日期：2026-11-09
