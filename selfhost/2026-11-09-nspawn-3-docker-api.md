# nspawn 3.0：用 docker 命令管理 systemd-nspawn 容器

**一句话结论**：nspawn 3.0 在宿主机上提供一个兼容 Docker Engine API 的 socket，不装 Docker 也能用 `docker` 命令、compose 类工具和 GitLab Runner 的 docker executor 去跑 systemd-nspawn 容器；但 `docker build` 等功能还不支持。

## 要点

- **怎么用**：API 由 `nspawn-api.socket` 提供，安装包默认关着，要手动启用；第一次有连接时才拉起服务。把 `DOCKER_HOST` 指向它之后，`docker run`、`exec`、`cp`、`rm` 这些常用命令都能直接用。
- **兼容范围**：按 Docker API 1.51 的格式应答，也兼容客户端请求的低版本（最低 1.24）。容器的创建、启停、attach、exec、`docker cp`，镜像拉取和删除，卷和网络的增删都支持。
- **不支持的**：镜像 build、load、import、tag、push、commit，容器改名和导出，swarm 和插件，都返回 501。构建镜像要用 `nspawn build`。
- **权限模型**：走 polkit。root 什么都能做；普通用户要靠 polkit 规则授权（安装包里带了一个 wheel 组的示例规则）。和 docker 组一样，拿到管理权限的用户等于拿到了宿主机 root。
- **安装**：Debian 13+、Ubuntu 24.04+ 可以用 apt.nspawn.org，Fedora 44+ 用 rpm.nspawn.org，Arch 的包挂在 GitHub Release 里。
- **破坏性变化**：2.0 里挂进容器的 API socket 是只读的，3.0 改成按挂载方式决定：读写挂载就能在里面创建、删除容器；`:ro` 挂载只能读、看日志和 kill。

## 示例

以下按原文思路整理，标明是示例：

```bash
# 启用 Docker 兼容 socket
sudo systemctl enable --now nspawn-api.socket

# 让 docker 命令连到 nspawn
export DOCKER_HOST=unix:///run/nspawn/api.sock
docker run -d --name web -p 8080:80 nginx
docker exec -it web sh
docker rm -f web
```

只认 `/run/docker.sock` 的工具，可以给 socket 加一个 systemd drop-in，让它多建一个软链接（前提是这台机器上没有别的东西占用这个路径）：

```ini
# /etc/systemd/system/nspawn-api.socket.d/symlink.conf
[Socket]
Symlinks=/run/docker.sock
```

改完执行 `sudo systemctl daemon-reload && sudo systemctl restart nspawn-api.socket`。

## 适合谁

- 本来就偏好 systemd 生态、想少装一个 Docker 守护进程的人。
- 想让 Traefik、Dozzle 这类靠 Docker API 发现容器的工具，直接管理 nspawn 容器的人。

## 注意事项和坑

- **只读的工具一定挂 `:ro`**：反向代理、面板这类只需要读取的容器，挂 socket 时加 `:ro`。3.0 起读写挂载的 socket 可以在宿主机上创建容器、挂载任意路径，等于把 root 交出去。
- 容器内的 root 连上 socket 后，能看到所有容器和它们的 `-e` 环境变量（用 `--secret` 传的值不会显示），机密别用 `-e` 传。
- 停止状态的容器不挂载卷，这时往卷里 `docker cp` 会被拒绝，要先启动容器。
- 作者说某个 Docker API 客户端在 nspawn 下出问题、在 docker 下正常时，可以带上请求内容去提 issue。

## 来源

- 社区：Lobsters
- 原文：https://blog.nspawn.org/posts/nspawn-3-0-a-docker-compatible-engine-api-for-systemd-nspawn-containers/
- 原文日期：2026-11-08（Lobsters 发帖日期）
- 收录日期：2026-11-09
