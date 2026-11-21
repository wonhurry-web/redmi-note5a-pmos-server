# Halo 博客（Redmi Note 5A / postmarketOS）

在手机上用 Docker 跑 Halo 2.27 社区版（arm64），通过 nginx 子路径 + 樱花FRP 隧道反代到公网。

## 架构

```
公网 HTTPS :<端口>
   └─ 樱花FRP 隧道（auto_https）→ 本机 5436
        └─ nginx
             ├─ /halo/  → halo:8090   （Halo 博客）
             └─ /       → daidai-panel:5700 （呆呆面板，原有服务）
```

- **数据库**：H2（内置，单容器，省内存；设备共 1.8G，可用约 1G）
- **工作目录**：`/opt/halo/halo2/`（数据库、附件、备份都在这）
- **JVM**：`-Xmx256m -Xms256m`
- **外网地址**：`https://<你的隧道域名>:<端口>/halo/`

## 文件说明

| 文件 | 用途 |
|---|---|
| `docker-compose.yml` | Halo 容器编排（加入 `dockersetup_proxy-net` 网络） |
| `halo.env.example` | 环境变量模板，复制为 `halo.env` 填真实公网地址 |
| `default.conf` | 完整 nginx 配置（Halo 子路径 + 面板根路径共存） |
| `95-halo-append.txt` | 追加到 `/etc/local.d/95-docker.start` 的开机自启段 |

## 子路径反代的三个关键点

Halo 2.x 前端资源写死根路径（`/js/`、`/styles/`、`/webjars/`），且不认 `X-Forwarded-Prefix`，所以 `/halo/` 子路径必须做三件事：

1. **`proxy_pass http://halo:8090/`（末尾带斜杠）** — 把 `/halo/xxx` 剥离成 `/xxx` 再转发，否则 Halo 返回 404。
2. **`sub_filter` 改写 HTML/JS/CSS 的资源路径** — 改成 `/halo/` 前缀，否则浏览器去根路径取资源（会落到面板）。必须先 `proxy_set_header Accept-Encoding ""` 禁用上游 gzip，sub_filter 才生效。**不要改写 JSON**，否则破坏 API 返回的数据字段。
3. **`proxy_redirect` 修正 302 Location** — Halo 返回根相对 `/login`，nginx 默认会用上游地址补全成绝对 URL（导致跳到 `127.0.0.1`）。显式写 `https://$http_host/halo/$1`，用浏览器真实域名 + 强制 https（隧道终结了 TLS）。负向 lookahead `(?!halo/)` 防止双前缀。

## 从备份恢复（Halo 2.8+ 内置备份功能）

> 备份恢复**不限制部署方式和数据库类型**——即使原备份来自 PostgreSQL/其它部署，也能直接恢复到当前 H2 站点。

### 方式一：从工作目录恢复（推荐，大文件适用）

1. 把备份 zip 传到手机：

   ```sh
   scp 你的备份.zip user@<手机IP>:/tmp/halo-backup.zip
   ssh user@<手机IP>
   sudo cp /tmp/halo-backup.zip /opt/halo/halo2/backups/
   sudo chown root:root /opt/halo/halo2/backups/halo-backup.zip
   ```

2. 浏览器打开 `https://<你的隧道域名>:<端口>/halo/`，完成首次初始化（设置管理员账号）。

3. Console 左侧菜单 → **备份** → **恢复** 选项卡 → 阅读须知 → 点「开始恢复」→ 选择「**从备份文件恢复**」→ 勾选刚上传的 zip → 确认。

4. 恢复完成后按提示重启 Halo：

   ```sh
   ssh user@<手机IP>
   sudo docker restart pmos-halo
   ```

### 方式二：控制台上传

恢复界面选「上传备份文件」，直接选本地 zip。文件较大时易因网络中断失败，推荐方式一。

### 恢复后检查

```sh
sudo docker logs pmos-halo --tail 30     # 无异常堆栈
curl http://127.0.0.1:8080/halo/actuator/health/readiness   # {"status":"UP"}
```

## 日常运维

```sh
# 状态
sudo docker ps --format '{{.Names}} {{.Status}}' | grep halo

# 日志
sudo docker logs -f pmos-halo

# 重启
sudo docker restart pmos-halo

# 手动备份（Console 里点「创建备份」后，文件在 /opt/halo/halo2/backups/）
sudo ls -lh /opt/halo/halo2/backups/
```

## 开机自启

`/etc/local.d/95-docker.start` 末尾已加 Halo 启动段（dockerd 就绪后会 `docker-compose --env-file halo.env up -d halo`）。容器本身 `restart: on-failure`。

## 脱敏说明

- `halo.env`（真实公网地址）已 gitignore，不进仓库
- 文档中的域名/端口均为占位符
