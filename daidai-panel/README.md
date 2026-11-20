# daidai-panel 部署到 Redmi Note 5A / postmarketOS

> 部署时间：2026-11-20 · 状态：**公网 HTTPS 访问已打通**
> 面板版本 v3.4.4（镜像 `linzixuanzz/daidai-panel:latest`，arm64）

## 架构

```
公网 https://<你的隧道域名>:<端口>/
        │  (樱花FRP auto_https 解密)
        ▼
   frpc(host网络) → 本机 5436 → nginx 容器(5436:80)
        ▼  location / 反代（容器名解析）
   daidai-panel 容器 (proxy-net 内 daidai-panel:5700)
        ▼
   容器内 Nginx 5700 → Go 后端 5701 → SQLite
```

关键设计：
- 面板只绑 `127.0.0.1:5700`，不直接暴露公网，仅由 nginx 反代
- 面板与 nginx 同在 `dockersetup_proxy-net` 外部网络，nginx 用**容器名**反代
  （不能用 127.0.0.1，那指向 nginx 容器自身 → 502）
- nginx 反代关闭 `proxy_buffering`，保证 SSE 日志流实时

## 部署步骤（复现）

### 1. 拉镜像（已配 daocloud/1ms.run 加速）

```sh
docker pull linzixuanzz/daidai-panel:latest
```

### 2. 部署面板容器

把本目录 `docker-compose.yml` 放到设备 `/opt/daidai/docker-compose.yml`：

```sh
mkdir -p /opt/daidai
cd /opt/daidai && docker-compose up -d
```

compose 要点：
- `ports: 127.0.0.1:5700:5700`（仅本机）
- `volumes: ./Dumb-Panel:/app/Dumb-Panel`（数据持久化）
- `networks`: 加入外部网络 `dockersetup_proxy-net`（与 nginx 共享）
- 不启用 Watchtower（设备内存有限），更新走手动 `docker pull`

### 3. 配置 nginx 反代

把本目录 `default.conf` 覆盖到 `/opt/dockersetup/nginx/conf.d/default.conf`，
核心是 `location / { proxy_pass http://daidai-panel:5700; proxy_buffering off; ... }`。
另保留 `location = /healthz` 作隧道健康检查页。

```sh
docker exec pmos-nginx nginx -t && docker exec pmos-nginx nginx -s reload
```

> 网络声明（重要）：面板 compose 里 `proxy-net` 必须是 `external: true` 且
> `name: dockersetup_proxy-net`，否则重建后容器不在同一网络、反代 502。

### 4. 首次初始化（在浏览器做）

首次访问会进入管理员初始化向导，设置管理员用户名 + 密码。数据库 `users` 表初始为空。

## 外网访问地址

```
https://<你的隧道域名>:<端口>/
```

- 必须 `https://`（隧道开了 auto_https，HTTP 访问返回 501）
- 本机 Windows 开着 HTTP 代理时，测试用 `curl --noproxy '*' ...` 绕过
- 健康检查：`https://<你的隧道域名>:<端口>/healthz` → 200

## 运维

```sh
# 状态
docker exec daidai-panel ddp status

# 手动更新（无 Watchtower）
cd /opt/daidai && docker-compose pull && docker-compose up -d

# 日志
docker logs -f daidai-panel
docker exec daidai-panel ddp logs --lines 100

# 数据位置
/opt/daidai/Dumb-Panel/   # daidai.db / deps / logs / backups / .jwt_secret
```

## 踩坑记录

1. **nginx 反代 127.0.0.1:5700 返回 502**：面板绑在宿主机回环，nginx 容器内
   127.0.0.1 是它自己。改用共享网络 + 容器名 `daidai-panel:5700` 解决。
2. **网络不持久**：`docker network connect` 手动加的网络，容器重建后丢失。
   必须在 compose 里用 `networks: {proxy-net: {name: dockersetup_proxy-net, external: true}}` 声明。
3. **SSE 日志流**：反代必须 `proxy_buffering off`，否则执行日志不实时刷新。
4. **内存占用**：面板内存占用约 40%（~730MB），设备 1.8G 内存，暂不要再开重容器。
