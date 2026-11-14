# GitHub Actions 有锁文件了：用 gh actions-lock 锁住 Actions 依赖，不用再手写 SHA

**一句话结论**：GitHub 10 月 28 日把 Actions 的工作流锁文件（workflow lockfile）正式开放给免费、Team 和 Enterprise Cloud 账号。装一个 `gh` 扩展，跑一条 `gh actions-lock`，workflow 里就可以写回好读的 `@v7.0.1`，实际运行的却是锁文件里记下的那个 commit，连间接依赖的 action 也一起锁住了。以前“把 action 钉到完整 SHA”的写法可以换成这个。

## 要点

- **为什么要锁**：Actions 是从 Git 仓库拉的，tag 可以被人改指向。攻击者拿到某个 action 仓库的权限后，把原来安全的 tag 指到恶意代码上，所有引用这个 tag 的 workflow 下次运行就中招，tj-actions/changed-files 事件就是这么回事。以前的对策是写成 `uses: actions/checkout@3d3c42e5...  # v7.0.1`，难读，也难维护。
- **锁文件怎么工作**：`gh actions-lock` 生成 `.github/workflows/actions.lock`，里面记下 workflow 用到的每个 action 锁定在哪个 commit，**包括 action 自己再引用的其他 action**（间接依赖）。纳入锁文件的 workflow，运行时 GitHub 会要求每个依赖都在锁文件里，并运行记下的那个 commit。
- **可以一个一个接入**：不用一次改完整个仓库，可以先锁一个 workflow。管理员还能开 **Require lockfile** 策略，强制要求所有 workflow 都有锁文件。
- **升级不麻烦**：Dependabot 给某个 action 发版本更新 PR 时，会在同一个 PR 里顺便重新生成锁文件条目，不用额外配置。Renovate 也支持。安全检查工具 zizmor 从 v1.32.0 起认锁文件，之前的版本还会提示你“改成钉 SHA”。
- **在 CI 里校验**：`gh actions-lock --verify` 只检查、不改文件，锁文件过期或者某个锁定的 commit 在上游对不上了，就报错退出，适合作为 PR 的必过检查。
- **它不负责判断 action 安不安全**：锁文件只保证“跑的是你锁定时那份代码”。锁之前那份代码本身有没有问题，还得自己看。官方也建议把 `actions.lock` 加进 CODEOWNERS，改动必须有人审。

## 示例

以下按 gh-actions-lock 的 README 和 hugovk 的文章整理，`gh` 需要先 `gh auth login`。

```bash
# 装扩展
gh extension install github/gh-actions-lock

# 在仓库根目录执行：把所有能解析的 action 锁住，写出 actions.lock，
# 同时把 workflow 里的 SHA 写法改回 vX.Y.Z
gh actions-lock
git add .github/workflows/
git commit -m "ci: lock actions"
```

几种模式（摘自官方 README）：

| 命令 | 会改文件 | 要联网 | 用来干什么 |
| --- | --- | --- | --- |
| `gh actions-lock` | 是 | 是 | 首次接入、修复锁文件 |
| `gh actions-lock --relock` | 是 | 是 | 把 `main`、`v4` 这类会动的 ref 推进到上游最新 commit |
| `gh actions-lock --verify` | 否 | 是 | CI 校验，检查项和修复时一样 |
| `gh actions-lock --verify-local` | 否 | 否 | pre-commit 用：只查每个 `uses:` 都在锁文件里，不查来源 |
| `gh actions-lock --no-fix` | 否 | 是 | 只出报告 |

在已有的 workflow 里加一个校验 job（示例，照 hugovk 的写法改的，他用的是 `ubuntu-slim` 轻量 runner；扩展版本号用写这篇笔记时文章里的 v0.4.1，用之前去 releases 页看最新版）：

```yaml
  lockfile:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    env:
      GH_TOKEN: ${{ github.token }}
    steps:
      - uses: actions/checkout@v7.0.1
        with:
          persist-credentials: false
      - run: gh extension install github/gh-actions-lock --pin v0.4.1
      - run: gh actions-lock --verify
```

加完这个 job 之后，workflow 里多了 `uses:`，记得再跑一次 `gh actions-lock` 把它也锁上。

## 适合谁

- 在 GitHub 上维护开源项目、用 Actions 跑测试、发版、推镜像的人。发版、推送这类 job 能拿到 token 和密钥，被投毒的代价最大，最值得锁。
- 之前已经把 action 钉到 SHA、嫌难读难升级的人，可以换过来。
- 自建 GitHub Enterprise Server 的不适用，扩展目前不支持 GHES。

## 注意事项和坑

- **跨仓库调用的可复用 workflow 锁不住**：在 `jobs.<id>.uses` 里调用别的仓库的 reusable workflow，不在本仓库锁文件的覆盖范围内，要被调用的那个仓库自己也接入锁文件。开了 Require lockfile 策略时，被调用方没接入，调用方的运行会被拦下。
- **容器镜像不锁**：`container:`、`services:` 里的镜像不会被锁。没写 `@sha256:` 摘要的镜像，扩展只会给警告。
- **本地 action（`./...`）不跟进**：本地 action 里如果又引用了远程 action，会直接报错，要加 `--migrate-local-actions` 或 `--ignore-local-actions`。
- **会动的 ref 被改回旧 commit 时检测不到**：`v4`、`main` 这种引用，如果锁文件改动把它挪回历史上更早的 commit，工具发现不了。所以尽量写完整的 `vX.Y.Z`，并认真看锁文件的 diff。
- **`--accept-moved` 别放进自动化**：它的作用是接受“锁定的 commit 已经不在上游”的情况，先弄清楚为什么会这样再用。
- **改了 workflow 记得重锁**：新增 workflow 或改了任何 `uses:`，都要再跑一次 `gh actions-lock`，否则 `--verify` 会失败。

## 来源

- 社区：Hacker News（约 335 分）
- 原文：hugovk《Lock your GitHub Actions》<https://hugovk.dev/blog/2026/lock-github-actions/>
- HN 讨论：<https://news.ycombinator.com/item?id=50459485>
- GitHub 更新日志：<https://github.blog/changelog/2026-10-28-github-actions-workflow-lockfiles-are-generally-available/>
- 扩展仓库：<https://github.com/github/gh-actions-lock>
- 官方文档：<https://docs.github.com/en/actions/how-tos/administer/enforce-workflow-lockfiles>
- 原文日期：2026-11-11
- 收录日期：2026-11-14
