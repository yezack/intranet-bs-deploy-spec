# 内网 B/S 架构开发规范

面向「互联网侧 vibecoding 开发 → 内网离线 Linux（x86_64）部署」的 B/S 系统开发与交付规范。审核通过即意味着**可无缝迁移**：内网现场不编译、不联网、不改代码，只填 `.env`。

| 项 | 值 |
|---|---|
| 版本 | **v2.2** |
| 生效日期 | 2026-09-29 |
| 适用范围 | 在互联网侧开发、需无缝迁移至内网 Linux（x86_64）服务器运行的 B/S 系统 |
| 目标场景 | 几人到几十人小团队；**多个项目共用一台服务器** |
| 必要条件 | Linux 虚拟机（x86_64）+ Docker 28.x + Docker Compose v2 |
| 编写依据 | 原始需求 7 条 + 基础环境实测校准（见 [§2.2](docs/02-目标架构.md)） |
| 取代关系 | 取代《B/S 部署规范 v1.2》；v2.0 的章节结构已重构 |

**关键词**：`<项目名>` 一律指小写字母、数字与连字符组成的项目代号（如 `myapp`），且必须与交付包目录名、容器名前缀、镜像名前缀保持一致。

---

## 三分钟实施卡

**给 AI 与开发者的第一入口**：把 [`templates/AGENTS.md`](templates/AGENTS.md) 放进项目根目录——一页红线，违反任一即返工。

**五步交付（构建机）**

```bash
# 1) 前端预构建
cd <项目名>/frontend && npm ci && npm run build
# 2) 构建镜像（tag 固定 latest；构建机为 arm64 时须加 --platform linux/amd64）
cd .. && docker build -t <项目名>-app:latest .
# 3) 导出离线镜像包
docker save <项目名>-app:latest -o <项目名>-app.tar
# 4) 过闸门：必须全部 PASS，否则禁止交付（§3.1 强制）
bash tools/preflight.sh
# 5) 按 §6.1 的命令打包 delivery tar
```

**四步部署（内网，离线）**

```bash
sudo mkdir -p /home/docker/<项目名>
sudo tar xzf <项目名>-delivery.tar.gz -C /home/docker/<项目名>
# .env：DB_ENGINE 保持 mariadb（sqlite 仅本地开发，见 §3.6）；DB_* 由运维下发；
#       SECRET_KEY 可留空（init.sh 会自动生成并写回）
cd /home/docker/<项目名> && cp .env.example .env && vi .env && chmod 600 .env && chmod +x init.sh update.sh
sudo ./init.sh
```

之后请运维投放 `deploy/gateway-site.conf`（`nginx -t` + `nginx -s reload`），并确认内网 DNS 已解析 `<项目名>.lan`。

**验收：一条命令跑完 15 项**

```bash
cd /home/docker/<项目名> && bash tools/verify.sh
```

**十条红线（AI 最容易踩的）**：无 CDN/外链 · 无 `ports:` · 不自建数据库容器 · 基础镜像不用 `latest` · 部署期不装依赖 · 不硬编码口令 · 除 `/health` 外必须鉴权 · 必须实现 `/api/v1/health` · `mount_frontend()` 最后调用 · 交付说明不得与规范冲突。
（完整 15 条见 [`templates/AGENTS.md`](templates/AGENTS.md)；15 项验收要点见 [§6.3](docs/06-交付与验收.md)。）

---

## 文档地图

| 章节 | 文档 | 内容 |
|---|---|---|
| §1 | [适用范围、目标与技术边界](docs/01-适用范围与技术边界.md) | 适用边界、无缝迁移定义、内网离线约束、技术边界 |
| §2 | [目标架构](docs/02-目标架构.md) | 部署拓扑、**基准环境（实测值）** |
| §3 | **[强制条款](docs/03-强制条款.md)** | 交付物、镜像、编排、部署路径、安全与运行基线、数据库引擎开关 |
| §4 | [端口、路径与网关接入](docs/04-端口路径与网关接入.md) | 端口分配、网关接入与防串站、交付包结构、容器内路径、API 路径、SPA 托管 |
| §5 | [脚本行为契约](docs/05-脚本行为契约.md) | `init.sh` / `update.sh` 的参数、退出码、快照备份与回滚、数据库迁移 |
| §6 | [交付与验收](docs/06-交付与验收.md) | 构建命令、部署步骤、15 项验收要点、运维命令、项目下线 |
| 附录 | [附录](docs/07-附录.md) | 术语表、口径对照表、原始需求原文归档 |

## 配套模板

| 模板 | 用途 |
|---|---|
| `AGENTS.md`、`tools/preflight.sh`、`tools/verify.sh` | 一页红线、交付前闸门、现场验收（vibecoding 关键） |
| `Dockerfile`、`docker-compose.yml`、`.env.example` | 单容器镜像与编排 |
| `db.py` | 连接串唯一构造点（`DB_ENGINE` 开关：本地 sqlite / 内网共享库，§3.6） |
| `.dockerignore`、`.gitattributes`、`.gitignore` | 构建上下文裁剪、锁定 LF 行尾、版本库排除 |
| `init.sh`、`update.sh` | 首次部署与带自动回滚的升级 |
| `spa_static.py` | 单容器静态托管 + SPA 回退（关键实现） |
| `deploy/` | 建库脚本（mariadb / pgsql）、网关站点片段、防串站兜底配置 |

用法与「必改占位值」清单见 [`templates/README.md`](templates/README.md)。

## 修订记录

| 版本 | 变化 |
|---|---|
| **v2.2** | 新增**数据库引擎开关** `DB_ENGINE`（`sqlite` 仅本地开发 / `mariadb`·`pgsql` 内网共享库），新增 [§3.6](docs/03-强制条款.md)；连接串收口到**唯一构造点** `backend/app/db.py`（含口令 URL 编码、`utf8mb4` 强制、`max_overflow: 0` 连接池硬上限、`pool_pre_ping`）；`init.sh` / `update.sh` / `tools/verify.sh` 三处拒绝 `DB_ENGINE=sqlite`（防"升级后数据静默丢失"）；新增 `.gitignore` 模板（含 `.env` 与 `.local/`）；`db.py`、`.gitignore` 登记进 §3.1 交付物与 §4.4 结构。 |
| v2.1 | **章节重构**：原 §3「技术栈」并入 §1.1；原 §5+§6 合并为 §4；原 §4→§3、§7→§5、§8→§6，模板与脚本注释中的章节引用已全量重写。新增 `AGENTS.md`、`tools/preflight.sh`、`tools/verify.sh`、`.dockerignore`、`.gitattributes`；网关站点配置改为 `resolver` + 变量 `proxy_pass`（**禁用 `upstream`**，防单个项目拖垮全站）并补安全响应头；`update.sh` 改为**时间戳快照备份**（`.env` + `docker-compose.yml` + 镜像包 + `MANIFEST`）、回滚编排文件、清理被替换的旧镜像；资源限额改用 `mem_limit`/`cpus`/`pids_limit`；Dockerfile 显式安装 tzdata；`APP_UID`/`APP_GID` 统一映射目录属主；`.env` 值加字符集约束与 `DB_POOL_SIZE`；CRLF 自检清单收敛为唯一来源；新增 `§6.5 项目下线`；验收扩至 15 项并脚本化。 |
| v2.0 | 按原始需求 7 条重构为 §1–§8 章节结构，取代 v1.2。 |

**章节对应（v2.0 → v2.1）**

| v2.0 | v2.1 |
|---|---|
| §1 适用范围与目标 | §1 |
| §2 目标架构 | §2 |
| §3 技术栈 | §1.1 技术边界 |
| §4 强制条款 | §3 |
| §5 端口规划与对外反向代理 | §4.1–4.3 |
| §6 目录与路径规范 | §4.4–4.7 |
| §7 脚本行为契约 | §5 |
| §8 交付与验收 | §6 |
| 附录 | 附录 |

## 修订约定

- 修改任何条款时，同步更新 [`templates/`](templates/README.md) 模板、脚本注释中的章节引用，并在「修订记录」留痕。
- 环境基线（Docker / Compose 版本、网络网段、共享容器名）以 [§2.2 基准环境表](docs/02-目标架构.md) 为**唯一出处**，其他文档不得重复罗列。
- 涉及需求取舍的变更，同步更新[附录 B 口径对照表](docs/07-附录.md)，保留可审计的决策痕迹。
