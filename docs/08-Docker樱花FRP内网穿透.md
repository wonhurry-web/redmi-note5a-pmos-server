# 08 · Docker + 樱花FRP + nginx 内网穿透评估与部署

> 实测时间：2026-11-20
> 目标设备：Redmi Note 5A / postmarketOS edge / 主线内核 7.1.3-msm89x7 / aarch64
> 状态：**全链路打通**——frpc 已填 token，公网 HTTPS 访问返回 200（详见第九节）

---

## 一、可行性评估结论

**方案成立。** 用 nginx 反向代理把多个内部服务收敛到**一条**樱花FRP 隧道，是对付免费版限制的正确做法。

### 为什么这个架构合适

樱花FRP 免费版限制（官网 2026 数据）：

| 项目 | 免费版 |
|---|---|
| 隧道数 | **2 条** |
| 单隧道限速 | 10 Mbps |
| 月流量 | 5 GiB（每日签到可增加） |
| 实名认证 | 需大陆身份证，1 元门槛 |

如果每个服务单独占一条隧道，2 条很快用完。nginx 反代把 N 个服务按域名/路径分发，对外只占 1 条隧道，是这个限制下的最优解。

### 设备实测数据（支撑结论）

| 检查项 | 结果 | 判定 |
|---|---|---|
| Docker | 29.10.0 已预装（构建时 extra_packages 带入） | ✅ |
| 内核 cgroup/namespace | CGROUPS、NAMESPACES、NET_NS、PID_NS 全 =y | ✅ |
| overlayfs | `CONFIG_OVERLAY_FS=m`，可加载，作存储驱动 | ✅ |
| 网络模块 | br_netfilter / nf_nat / nf_conntrack 可加载 | ✅ |
| 内存 | 1832 MB（可用 ~1.3G） | ⚠️ 够用但别开太多容器 |
| 磁盘 | 8.9G，可用 7.5G | ⚠️ 镜像别堆太多 |
| 镜像加速 | daocloud / 1ms.run 实测可用 | ✅ |
| frpc 镜像 | natfrp/frpc:0.51 支持 aarch64 | ✅ |

---

## 二、最大的坑：cgroup v1 vs v2（务必理解）

这是本次排查花时间最多的地方，复现者最容易卡住。

**现象**：手动 `rc-service docker start` 能成功，但开机自启时 docker 起不来，报两种错：
- `ERROR: cannot start docker as cgroups would not start`
- `failed to start daemon: Devices cgroup isn't mounted`

**根因链条**：
1. 主线内核开机后，OpenRC 的 `cgroups` 服务状态在此设备上不可靠（时而是 cgroup v2，时而未挂载）
2. docker 29.x 在这个内核上**需要 cgroup v1 的 `devices` 控制器**；纯 cgroup v2 unified 会因为找不到 devices cgroup 而拒绝启动
3. docker 的 OpenRC init 脚本有 `need cgroups` 硬依赖，开机早期该依赖判定失败 → `rc-service docker start` 直接报错

**最终解法**（已落地在 `95-docker.start`）：
- 开机时**主动挂载 cgroup v1**（tmpfs + devices/cpu/cpuacct/blkio/freezer/pids 等子系统）
- **绕过 OpenRC**，用 `nohup /usr/bin/dockerd` 直接拉起守护进程
- docker **不加入任何 runlevel**，由这一个脚本单一管理生命周期，避免双重启动竞争

> 结论：在这台主线内核设备上，"cgroup v1 + 直接启动 dockerd" 是唯一稳定的组合。这也是 Alpine/postmarketOS 主线内核跑 Docker 的通用经验。

---

## 三、已部署内容

设备上路径 `/opt/dockersetup/`：

```
/opt/dockersetup/
├── docker-compose.yml          # nginx + frpc 编排
├── nginx/
│   ├── nginx.conf              # 主配置
│   └── conf.d/default.conf     # 反代规则骨架（默认页 + 示例注释）
└── frpc/
    └── creds.env               # 访问密钥 + 隧道 ID（占位符，需用户填）
```

开机自启：`/etc/local.d/95-docker.start`（编号 95，排在所有脚本最后）

网络规划：
- nginx 容器：`0.0.0.0:8080 -> 容器:80`，反代入口
- frpc 容器：host 网络，能访问宿主机端口及同网段设备
- 樱花FRP 隧道指向：**宿主机 8080 端口**

---

## 四、落地步骤（复现）

### 1. 前置：安装 compose 插件

```sh
apk add --no-cache docker-compose   # 装的是 docker-cli-compose v5.8
```

### 2. 配置镜像加速（国内必需）

`/etc/docker/daemon.json`：

```json
{"registry-mirrors":["https://docker.m.daocloud.io","https://docker.1ms.run"]}
```

```sh
rc-service docker restart
docker info | grep -A3 "Registry Mirrors"   # 确认生效
```

### 3. 部署骨架

把本目录 `docker-setup/` 整个拷到设备 `/opt/dockersetup/`，把 `95-docker.start` 拷到 `/etc/local.d/` 并 `chmod +x`。

### 4. 填樱花FRP 凭据

编辑 `/opt/dockersetup/frpc/creds.env`：

```ini
TOKEN=你的访问密钥
TUNNEL_ID=你的隧道ID
```

- 访问密钥：natfrp.com 控制台 → 账户信息
- 隧道 ID：控制台创建的隧道数字 ID；多隧道用英文逗号分隔（须同一节点）
- 隧道在控制台配置为：类型 HTTP（或 TCP），本地端口 `8080`

填完后启动 frpc（注意必须带 `--env-file`，原因见第九节）：

```sh
cd /opt/dockersetup && docker-compose --env-file ./frpc/creds.env up -d frpc
docker logs -f pmos-frpc      # 看到 "TCP 隧道启动成功 / 使用 >>域名:端口<<" 即成功
```

### 5. 验收

```sh
curl http://127.0.0.1:8080/              # 看到 "nginx proxy is alive"
docker-compose ps                        # nginx、frpc 均 Up
# 外网访问樱花FRP 分配的域名/地址，应看到同一页面（若开了 auto_https 需用 https://）
```

---

## 五、后续：添加自己的服务

编辑 `/opt/dockersetup/nginx/conf.d/default.conf`，取消注释示例并修改，例如把 `/app/` 转发到本机 3000 端口：

```nginx
location /app/ {
    proxy_pass http://127.0.0.1:3000/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

重载：`docker exec pmos-nginx nginx -s reload`

要按域名分发（需控制台绑域名 + 备案），加独立 `server { server_name ...; }` 块。

---

## 六、注意事项

- **安全**：公网暴露的服务务必设强密码/密钥；SSH 建议改非默认端口 + 只认密钥。免费隧道会被扫描。
- **内存有限**：设备仅 1.8G 内存，容器别开太多；nginx + frpc 本身占用很小。
- **内核无 memory cgroup**：日志会有 `No memory limit support` 等警告，属主线内核限制，不影响容器运行，但 `docker run -m` 内存限制不生效。
- **防火墙后端**：用 iptables（内核无完整 nft 工具），`nft: executable not found` 警告可忽略。
- **frpc 自动启动**：`95-docker.start` 会检测 `creds.env` 里 token 是否还是占位符，是则跳过 frpc；填好后重启或手动 up 即可。

---

## 九、实战填 token 全链路打通记录（2026-11-20）

首次填入真实 token 后，从「隧道连不上」到「公网 200」踩了三个坑，均为樱花FRP + 精简 frpc 镜像的特性，复现者必看。

### 坑 1：frpc 镜像无 `/bin/sh`，compose 里不能用 shell 展开变量

初版 compose 用 `entrypoint: [/bin/sh, -c, "exec frpc -f $$TOKEN:$$TUNNEL_ID -n"]`，
容器启动直接报 `exec: "/bin/sh": stat /bin/sh: no such file or directory`。

`natfrp/frpc:latest`（0.51）是精简镜像，里面**只有 /frpc 一个二进制，没有 shell**，
`$$TOKEN` 这种依赖容器内 shell 展开的写法完全失效。

**正解**：用 compose 层变量替换，把凭据作为 `--env-file` 在宿主机侧展开：

```yaml
# docker-compose.yml（frpc 服务）
command: ["-f", "${TOKEN}:${TUNNEL_ID}", "-n"]   # 单 $，去掉 entrypoint
```

```sh
docker-compose --env-file ./frpc/creds.env up -d frpc
```

`95-docker.start` 里也同样带 `--env-file`。这样凭据只留在 `creds.env`（已 gitignore），
compose 文件可安全提交。

### 坑 2：控制台 local_port 与 nginx 监听端口不一致 → 502

隧道在樱花FRP 控制台的 `-f` 拉取配置里写死 `local_ip=127.0.0.1 / local_port=5436`，
而本机 nginx 只监听 8080。frpc 解密后转发到 5436 时无人监听，
公网返回 `502` + `dial tcp 127.0.0.1:5436: connect: connection refused`。

**排查方法**：把 frpc 拉下来的配置导出看真实端口（不猜）：

```sh
docker run --rm --network host -v /tmp/f:/run/frpc \
  natfrp/frpc:latest -f TOKEN:ID -n -w -c /run/frpc/frpc.ini
cat /tmp/f/frpc.ini     # 看 local_port / remote_port / auto_https
```

**正解（二选一）**：
- A：控制台把隧道本地端口改成 8080（最干净，但要去网页操作）；
- B：本机对齐控制台——给 nginx 容器加一条 `"5436:80"` 端口映射，让 5436 落到 nginx。
  本项目采用 B，无需动控制台，本地 8080 仍保留作验证入口。

### 坑 3：控制台开了 `auto_https=auto`，HTTP 访问返回 501

HTTP 访问公网地址得到 `501 Not Implemented`（`Server: SakuraFrp`），
正文提示「您已为本隧道启用自动 HTTPS，使用 HTTP 访问是无意义的」。

**正解**：公网入口必须用 `https://`，不能是 `http://`。frpc 会加载樱花FRP 下发的
`*.你的子域` 证书（自签/自动续期），浏览器可能提示证书错误，可忽略或装证书。

### 最终验收结果

- 隧道启动日志：`TCP 隧道启动成功 / 使用 >>你的域名:端口<< 连接你的隧道`
- 公网 `curl https://你的域名:端口/` → **HTTP 200 + `nginx proxy is alive`**（`Server: nginx/1.31.9`）
- 常驻容器仅 `pmos-nginx` + `pmos-frpc`；`95-docker.start` 已同步 `--env-file` 写法，开机自启可用

> 提示：本机 Windows 若开着 HTTP 代理，用 `curl --noproxy '*'` 绕过，否则会误判连通性。
