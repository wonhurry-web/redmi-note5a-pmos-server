# Halo 博客（Redmi Note 5A / postmarketOS）

在手机上用 Docker 跑 Halo 2.27 社区版（arm64），通过 nginx + 两条樱花FRP 隧道反代到公网，与呆呆面板共存。

## 架构（当前：双隧道，各自独占根路径）

```
公网 nas.u4207154.nyat.app:36004 (隧道 Linux/29908643, auto_https)
   └─ 本机 5436 → nginx server :80
        └─ / → daidai-panel:5700        （呆呆面板，独占根路径）

公网 www.u4207154.nyat.app:16989 (隧道 halo/29924916, auto_https)
   └─ 本机 5437 → nginx server :5437
        └─ / → halo:8090                （Halo 前台+后台，独占根路径）
```

- **数据库**：H2（内置，单容器省内存）
- **工作目录**：`/opt/halo/halo2/`（数据库、附件、备份、主题、插件都在这）
- **JVM**：`-Xmx256m -Xms256m`
- **公网地址**：前台 `https://www.u4207154.nyat.app:16989/`，后台 `/console`，登录 `/login`

### 为什么必须两条隧道、不能共用一条

Halo 2.x 的 console 前端硬编码 `createWebHistory("/console/")`，且**前台首页就是根路径 `/`**。呆呆面板也是占根路径的 SPA。一个域名+端口下根路径只能给一个，如果把 Halo 挂子路径（如 `/halo/`），console 的 router base 会错位（`/halo/console` → `/console/halo/console` → 跳 `/dashboard` 落到面板），点主题预览/前台也会跳面板。给 Halo 独立端口独占根路径后，全部走原生路径，**无需任何 sub_filter**，零路由错位。

历史坑（已废弃，勿再尝试）：子路径 `/halo/` 需要改写 form action、`/apis/`、运行时拼接的 `/ui-assets/`、`X-Forwarded-Proto` 等一大堆 sub_filter，且治不了 router base 错位——不要走回头路。

## 文件说明

| 文件 | 用途 |
|---|---|
| `docker-compose.yml` | Halo 容器编排（加入 `proxy-net` 网络） |
| `halo.env.example` | 环境变量模板，复制为 `halo.env` 填真实公网地址 |
| `default.conf` | 完整 nginx 配置（两个 server 块：80→面板，5437→Halo） |
| `theme-layout-everus.html` | everus 主题的页面布局契约片段，补到 `templates/layout.html` 消除 MISSING 提示 |
| `95-halo-append.txt` | 追加到 `/etc/local.d/95-docker.start` 的开机自启段 |

## 樱花FRP 双隧道配置

两条隧道属于同一节点、同一 token，用一个 frpc 客户端即可（TUNNEL_ID 用英文逗号分隔）：

```sh
# /opt/dockersetup/frpc/creds.env
TOKEN=<访问密钥>
TUNNEL_ID=29908643,29924916    # 面板隧道, Halo 隧道
```

重建 frpc 时**必须带 --env-file**，否则变量为空报「访问密钥长度错误」：

```sh
cd /opt/dockersetup
docker-compose --env-file /opt/dockersetup/frpc/creds.env up -d --force-recreate --no-deps frpc
```

隧道 16989 是 HTTPS（auto_https）：HTTP 访问会返回 SakuraFrp 的 501，必须用 `https://`。`halo.env` 的 `HALO_EXTERNAL_URL` 也要写 https 版本。

## 忘记管理员密码（直接改 H2 库）

Halo 2.x 密码是 argon2（不是老教程的 bcrypt）。流程：

1. 全量备份：`cd /opt/halo && tar czf halo2-backup-$(date +%s).tar.gz halo2/`
2. 停服释放文件锁：`docker stop pmos-halo`（宿主机无 java，要借容器跑 H2 工具）
3. 用户数据在 `EXTENSIONS` 表，name = `/registry/users/<用户名>`，`DATA` 是 JSON，密码在 `spec.password`：
   ```sql
   -- 读：BLOB 要用 UTF8TOSTRING，直接 CAST 会报错
   SELECT UTF8TOSTRING(DATA) FROM EXTENSIONS WHERE NAME='/registry/users/wonhurry';
   -- 改：Python 只替换 spec.password，metadata.version+1，转义单引号后用 STRINGTOUTF8 写回
   UPDATE EXTENSIONS SET DATA=STRINGTOUTF8('<新json>') WHERE NAME='/registry/users/wonhurry';
   ```
4. 生成兼容哈希（本机 Python argon2-cffi）：
   ```python
   from argon2 import PasswordHasher
   ph = PasswordHasher(time_cost=2, memory_cost=16384, parallelism=1, hash_len=32, salt_len=16)
   h = '{argon2@SpringSecurity_v5_8}' + ph.hash('新密码')
   ```
5. 用挂载数据目录的一次性容器跑 H2 Shell：
   ```sh
   docker run --rm -v /opt/halo/halo2:/root/.halo2 --entrypoint sh \
     registry.fit2cloud.com/halo/halo:2.27 /root/.halo2/脚本.sh
   # 脚本内: java -cp /application/lib/h2-2.4.240.jar org.h2.tools.Shell \
   #   -url 'jdbc:h2:file:/root/.halo2/db/halo-next;MODE=MySQL;DB_CLOSE_ON_EXIT=FALSE' \
   #   -user admin -password 123456
   # 注意 H2 2.4 Shell 不支持 -i 文件输入，用 stdin 管道喂 SQL
   ```
6. `docker start pmos-halo`，等 readiness 200（插件加载约 1 分钟）。

验证登录：登录页密码框是 JSEncrypt RSA 加密的，直接 POST 明文必失败。脚本登录要先取页面里的 `publicKey`，用 RSA PKCS1v15 加密密码再提交；302 到 `/uc` 即成功。

## 页面布局缺失提示（templates/layout.html was not found）

Halo 2.26+ 新增「页面布局契约」：主题提供 `templates/layout.html` 并声明 `th:fragment="html (head, content)"` 后，Console 的 `Theme.status.pageLayout` 才是 SUPPORTED。这是**增量能力，不影响主题安装/启用/前台渲染**，仅影响插件渲染的独立页面外观（否则走 fallback 布局）。

- 检查状态：`GET /apis/api.console.halo.run/v1alpha1/themes?size=100`，看每个主题 `status.pageLayout.state`（SUPPORTED / MISSING / INVALID）
- everus 主题原本 MISSING，已用 `theme-layout-everus.html` 补上，重载后变 SUPPORTED
- 重载主题：`PUT /apis/api.console.halo.run/v1alpha1/themes/<主题名>/reload`
- `theme-halo-next`（当前激活主题）本身已 SUPPORTED

## 前台跳登录页（全局私密插件）

备份里若带 `global-private` 插件（"全局私密"，v1.0.9），未登录访问前台任意页都会 302 到 `/login?redirect_uri=`。它存在 H2 的 `/registry/configmaps/global-private-configmap`，`data.basic` 里 `enabled:true`。

- 想公开博客：Console → 插件 → 全局私密 → 关闭「启用插件」；或改库把该 configmap 的 `enabled` 设为 `false`（改库前先停服备份）
- 想保持私密：无需改动，这是预期行为

## 从备份恢复（Halo 2.8+ 内置）

备份恢复不限部署方式和数据库类型，PostgreSQL 备份也能恢复到当前 H2。

1. 传备份到手机：
   ```sh
   scp 备份.zip user@<手机IP>:/tmp/halo-backup.zip
   ssh user@<手机IP>
   sudo cp /tmp/halo-backup.zip /opt/halo/halo2/backups/
   sudo chown root:root /opt/halo/halo2/backups/halo-backup.zip
   ```
2. 浏览器打开 `https://www.u4207154.nyat.app:16989/console`，完成初始化（若全新站点）
3. Console → 备份 → 恢复 → 「从备份文件恢复」→ 选 zip → 确认
4. 按提示重启：`sudo docker restart pmos-halo`

恢复后检查：
```sh
sudo docker logs pmos-halo --tail 30
curl http://127.0.0.1:8090/actuator/health/readiness   # {"status":"UP"}
```

## 日常运维

```sh
sudo docker ps --format '{{.Names}} {{.Status}}' | grep -E 'halo|nginx|frpc'
sudo docker logs -f pmos-halo
sudo docker restart pmos-halo
sudo ls -lh /opt/halo/halo2/backups/          # 备份文件
```

## 开机自启

`/etc/local.d/95-docker.start`：dockerd 就绪后依次 `docker-compose up -d nginx`、带 `--env-file` 启 frpc、`docker-compose --env-file halo.env up -d halo`。容器均 `restart: unless-stopped`。

## 脱敏说明

- `halo.env`、`frpc/creds.env`（真实公网地址/密钥）已 gitignore，不进仓库
- 本文域名/端口为实际值示例，复现时替换成自己的隧道信息
