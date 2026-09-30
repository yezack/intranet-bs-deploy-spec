# AGENTS.md —— 本项目不可协商的部署约束（给 AI 与开发者）

> 用法：把本文件放在交付包**根目录**，作为 AI 写代码时的第一入口。
> 项目名占位符 `myapp` 必须整体替换为你的 `<项目名>`（与 `.env` 的 `PROJECT_NAME` 一致）。

本项目按《内网 B/S 架构开发规范 v2.7》交付，最终运行在**内网离线 Linux x86_64 服务器**上，
并与多个其他项目**共用同一台机器**。规范全文在上游规范仓库；**你只需要遵守本文件**。
违反以下任一条，交付即不合格。

## 一、红线（违反即返工）

1. **禁止任何公网资源**：不得使用 CDN、Google Fonts、外网图标库、地图/验证码/统计服务、外网图片。构建期可联网，**运行期必须零外网依赖**，前端产物必须自包含。
2. **`docker-compose.yml` 中禁止出现 `ports:`**。对外只有统一网关的 80 端口；应用在容器内监听 `0.0.0.0:80`。
3. **禁止自建数据库容器**。数据库是运维提供的基础服务，只通过 `.env` 的 `DB_HOST=mariadb|pgsql` 连接。
4. **基础镜像禁止用 `latest`**：必须写固定次版本，例如 `python:3.13-slim`。
5. **禁止在服务器上安装依赖**：`init.sh` / `update.sh` 里不得出现 `npm install` / `npm ci` / `pip install` / `apt install`。前端必须先在构建机 `npm run build`，把 `frontend/dist` 打进镜像。
6. **禁止硬编码口令与密钥**：所有可变配置只进 `.env`，代码里读环境变量。
7. **除 `GET /api/v1/health` 与"认证入口"外，所有 `/api/v1/**` 接口必须鉴权**。认证入口（登录/注册/刷新等，要求先鉴权会构成循环依赖）**必须在交付说明中逐条枚举、禁止通配，通常不超过 3 个**；禁止 `allow_origins=["*"]`（同源 SPA 应直接关闭 CORS）。
8. **必须实现 `GET /api/v1/health`，且永远返回 200**（数据库不可达也不例外），体内必须含 `status`、`database`（`ok|unavailable`）与 **`project`**（本项目代号，验收靠它确认 Host 打到的是本项目）。**探活必须有硬预算且 ≤ ½ × `healthcheck.timeout`**（模板 5s → ≤2.5s），所有可能阻塞的调用都要在预算内截断——否则库一挂容器就被判 unhealthy，**一次正常升级会被误回滚**（§3.5 S7/S8）。
9. **`mount_frontend(app)` 必须是 `main.py` 里最后一次调用**（在所有 `/api/v1` 路由注册之后）。
10. **前端只能请求相对路径 `/api/v1/...`**，不得在构建期注入 host/IP。
11. **宿主目录只映射三类**：`./conf:/app/conf:ro`、`./uploads:/data/uploads`、`./downloads:/data/downloads`；日志一律走 stdout/stderr，不得写日志文件。
12. **必须接入 `gateway-network`（`external: true`）**；容器名固定 `<项目名>-app`，镜像 tag 固定 `<项目名>-app:latest`。
13. **必须提供 `HEALTHCHECK`**，探测 `http://127.0.0.1:80/api/v1/health`；`start_period` 必须 ≥ 启动最坏耗时（**迁移重试上限 + 监听启动**，模板 60s），且 `HEALTH_TIMEOUT` ≥ `start_period + interval × retries`（§3.5 S9）。
14. **上传文件必须重命名 + 扩展名白名单 + 大小上限**，不得用用户提供的文件名拼接存储路径。
15. **交付说明不得与规范冲突**：不得出现"在服务器上执行 `npm install` / 修改代码 / 手工建表"之类的步骤。
16. **对外域名必须在开发启动前向运维确认**：写入 `.env.example` 的 `SITE_DOMAIN`，且 `deploy/gateway-site.conf` 的 `server_name` 必须与它逐字一致；**不得自行编造域名**（`tools/preflight.sh` 会因此拒绝交付）。

17. **启动期与运行期必须分开**：启动期库不可达 → 有限重试后**主动退出**（交给 `restart: unless-stopped`，退出前打一行可 grep 的 `[startup]` 日志）；**运行期库掉线 → 禁止退出进程**（避免重启风暴），只把 `database` 字段置为 `unavailable`（§3.5 S9）。

## 二、必须一并交付的文件

`docker-compose.yml`、`Dockerfile`、`init.sh`、`update.sh`、`.env.example`、`.dockerignore`、
`.gitattributes`、`.gitignore`、`AGENTS.md`、`tools/preflight.sh`、`tools/verify.sh`、`backend/`、`frontend/`（含源码与 `dist/`）、`deploy/`、
`<项目名>-app.tar`

## 三、交付前必须自测

```bash
bash -n init.sh update.sh     # 语法检查
bash tools/preflight.sh       # 交付前闸门：必须全部 PASS，否则禁止交付
```

## 四、拿不准时

查规范《强制条款》、以及《端口、路径与网关接入》两章。**任何"方便但违反红线"的做法都不接受。**
