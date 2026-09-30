# 内网 B/S 交付模板使用说明

配套《内网 B/S 架构开发规范 v2.4》。规范正文按章拆分在上一级 `docs/`，入口见上一级 [`readme.md`](../readme.md)。

**模板中的 `myapp` / `myapp-app` 等示例值需整体替换为你自己的 `<项目名>`。**

## 一、模板清单

| 文件 | 用途 | 目标位置（交付包内） |
|---|---|---|
| `AGENTS.md` | 给 AI / 开发者的一页红线（**先读它**） | `<项目名>/AGENTS.md` |
| `tools/preflight.sh` | 交付前闸门，必须全部 PASS | `<项目名>/tools/preflight.sh` |
| `tools/verify.sh` | 现场验收（自动跑 §6.3 的 15 项） | `<项目名>/tools/verify.sh` |
| `db.py` | 连接串唯一构造点（`DB_ENGINE` 开关，见 §3.6） | `<项目名>/backend/app/db.py` |
| `.gitignore` | 版本库排除规则（必须含 `.env` / `.local/`） | `<项目名>/.gitignore` |
| `Dockerfile` | 单容器镜像构建 | `<项目名>/Dockerfile` |
| `docker-compose.yml` | 编排 | `<项目名>/docker-compose.yml` |
| `.env.example` | 环境变量模板 | `<项目名>/.env.example` |
| `.dockerignore`、`.gitattributes` | 构建上下文裁剪 / 锁定 LF 行尾 | `<项目名>/` |
| `init.sh`、`update.sh` | 首次部署 / 版本更新（含自动回滚） | `<项目名>/` |
| `spa_static.py` | 单容器静态托管 + SPA 回退 | `<项目名>/backend/app/spa_static.py` |
| `deploy/init-db.mariadb.sql`、`deploy/init-db.pgsql.sql` | 建库建用户 | `<项目名>/deploy/` |
| `deploy/gateway-site.conf` | 网关站点片段（`resolver` + 变量，**勿用 `upstream`**） | `<项目名>/deploy/` |
| `deploy/gateway-default.conf` | 网关兜底防串站 | 交运维放 `/home/docker/nginx/conf.d/` |

## 二、使用顺序

1. **替换项目名**：把 `myapp` 整体替换为你的 `<项目名>`（`docker-compose.yml` 已用 `${PROJECT_NAME}`，只需改 `.env` 与 `deploy/`）。
2. **放置文件**：按上表复制进交付包。
3. **接入静态托管**：在 `backend/app/main.py` 按 `spa_static.py` 顶部注释调用 `mount_frontend(app)`，**必须放在所有 `/api/v1` 路由注册之后**。
4. **构建**（外部联网机）：`npm run build` → `docker build -t <项目名>-app:latest .` → `docker save <项目名>-app:latest -o <项目名>-app.tar`。
5. **过闸门**：`bash tools/preflight.sh` 必须全部 PASS（[§3.1](../docs/03-强制条款.md) 强制）。
6. **交付**：按 [§6.1](../docs/06-交付与验收.md) 的 `tar` 命令打包。
7. **内网部署**：解包到 `/home/docker/<项目名>/` → `cp .env.example .env` 填写 → `chmod 600 .env` → `chmod +x init.sh update.sh` → `sudo ./init.sh`。

## 三、必须人工确认的占位值

- [ ] `.env` 中 `PROJECT_NAME`、`DB_*`、`SECRET_KEY`、`ADMIN_PASSWORD`（`APP_UID`/`APP_GID` 默认 1000，仅当宿主 uid 冲突时调整）
- [ ] **`.env` 的 `SITE_DOMAIN`（对外域名，开发启动前向运维确认）**；`deploy/gateway-site.conf` 中与它逐字一致的 `server_name`，以及容器名（`<项目名>-app`）
- [ ] `deploy/init-db.*.sql` 中库名、用户名、口令（与 `.env` 保持一致）
- [ ] 网关 `client_max_body_size`（上传上限）与 `proxy_read_timeout`（导出耗时）
- [ ] 域名解析：多人使用必须由运维在**内网 DNS** 加记录；`hosts` 仅用于 1–2 台机器临时验证

## 四、三个容易踩的坑

### 1. 行尾必须是 LF

权威清单见 [§5](../docs/05-脚本行为契约.md)：交付前查 `init.sh update.sh .env.example`，内网生成 `.env` 后追加查 `.env`。

```bash
grep -c $'\r' init.sh update.sh .env.example   # 交付前（期望全 0）
grep -c $'\r' .env                             # 内网 cp 之后（期望为 0）
sed -i 's/\r$//' init.sh update.sh .env.example .env
```

表现：`./init.sh` 直接执行会报 `env: 'bash\r'`（退出码 127，shebang 先失效）；用 `bash init.sh` 调用时守卫会给出修复提示（退出码 1）。
**根治**：把 `.gitattributes` 放进交付包，并**在 Linux（WSL/容器）里打交付包**。

### 2. `chmod +x`

Windows 打的包通常不带 exec 位，解包后 `sudo ./init.sh` 会 permission denied：`chmod +x init.sh update.sh`。

### 3. 映射目录属主必须等于容器运行 uid

`.env` 的 `APP_UID`/`APP_GID`（默认 `1000:1000`）同时是 compose 的 `user:` 与 `init.sh` 的 `chown` 目标。手工解包而未跑 `init.sh` 时须自行对齐：

```bash
sudo chown -R 1000:1000 conf uploads downloads
```

## 五、脚本自测（不产生实际变更）

```bash
bash -n init.sh update.sh            # 语法检查
bash tools/preflight.sh --no-docker  # 无 docker 也能跑基础检查
sudo ./init.sh --dry-run             # 只打印将执行的动作
sudo ./update.sh --dry-run           # 只打印备份 / 导入 / 回滚计划
```

> 基准环境（Docker / Compose / 网关 / 共享库 / 网络段的实测值）以规范 [§2.2 基准环境表](../docs/02-目标架构.md) 为**唯一出处**，本文件不再重复罗列。
