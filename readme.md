# 内网 B/S 架构开发规范

面向「互联网侧 vibecoding 开发 → 内网离线 Linux（x86_64）部署」的 B/S 系统开发与交付规范。审核通过即意味着**可无缝迁移**：内网现场不编译、不联网、不改代码，只填 `.env`。

| 项 | 值 |
|---|---|
| 版本 | **v2.6** |
| 生效日期 | 2026-09-29 |
| 适用范围 | 在互联网侧开发、需无缝迁移至内网 Linux（x86_64）服务器运行的 B/S 系统 |
| 目标场景 | 几人到几十人小团队；**多个项目共用一台服务器** |
| 必要条件 | Linux 虚拟机（x86_64）+ Docker 28.x + Docker Compose v2 |
| 编写依据 | 原始需求 7 条 + 基础环境实测校准（见 [§2.2](docs/02-目标架构.md)） |
| 取代关系 | 取代《B/S 部署规范 v1.2》；v2.0 的章节结构已重构 |

**关键词**：`<项目名>` 一律指小写字母、数字与连字符组成的项目代号（如 `myapp`），且必须与交付包目录名、容器名前缀、镜像名前缀保持一致。
**`<SITE_DOMAIN>`** 指本项目的对外访问域名（`.env` 的 `SITE_DOMAIN`，由运维分配，**开发阶段确认**），如 `xz.sjq.sh`。

---

## 三分钟实施卡

**给 AI 与开发者的第一入口**：把 [`templates/AGENTS.md`](templates/AGENTS.md) 放进项目根目录——一页红线，违反任一即返工。

**第 0 步（开发启动前）：确认对外域名**
向运维确认本项目的访问域名，填入 `.env.example` 的 `SITE_DOMAIN`，并让 `deploy/gateway-site.conf` 的 `server_name` 与它**逐字一致**。未确认域名不得开工——交付前闸门会因此拒绝打包。

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
# .env：SITE_DOMAIN 已在开发阶段确认；DB_ENGINE 保持 mariadb（sqlite 仅本地开发，见 §3.6）；
#       DB_* 由运维下发；SECRET_KEY 可留空（init.sh 会自动生成并写回）
cd /home/docker/<项目名> && cp .env.example .env && vi .env && chmod 600 .env && chmod +x init.sh update.sh
sudo ./init.sh
```

之后请运维投放 `deploy/gateway-site.conf`（`nginx -t` + `nginx -s reload`）。单机验证可在**目标虚拟机自身**的 `/etc/hosts` 写 `<虚拟机 IP>  <SITE_DOMAIN>`；多人使用则必须由运维在内网 DNS 加 A 记录。

**验收：一条命令跑完 15 项**

```bash
cd /home/docker/<项目名> && bash tools/verify.sh
```

**十条红线（AI 最容易踩的）**：无 CDN/外链 · 无 `ports:` · 不自建数据库容器 · 基础镜像不用 `latest` · 部署期不装依赖 · 不硬编码口令 · 除 `/health` 外必须鉴权 · 必须实现 `/api/v1/health` · `mount_frontend()` 最后调用 · 交付说明不得与规范冲突。
（完整 16 条见 [`templates/AGENTS.md`](templates/AGENTS.md)；15 项验收要点见 [§6.3](docs/06-交付与验收.md)。）

---

## 文档地图

| 章节 | 文档 | 内容 |
|---|---|---|
| §1 | [适用范围、目标与技术边界](docs/01-适用范围与技术边界.md) | 适用边界、无缝迁移定义、内网离线约束、技术边界、域名前置条件 |
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
| `Dockerfile`、`docker-compose.yml`、`.env.example` | 单容器镜像与编排（`.env.example` 含 `SITE_DOMAIN` / `DB_ENGINE`） |
| `db.py` | 连接串唯一构造点（`DB_ENGINE` 开关：本地 sqlite / 内网共享库，§3.6） |
| `health.py`、`migrate.py` | 探活（2.5s 硬预算 + 永远 200）与启动时迁移的**参考实现**（§3.5 S7/S8、§5.2） |
| `deploy/migrations/` | 迁移目录示例与三条硬规则说明 |
| `.dockerignore`、`.gitattributes`、`.gitignore` | 构建上下文裁剪、锁定 LF 行尾、版本库排除 |
| `init.sh`、`update.sh` | 首次部署与带自动回滚的升级 |
| `spa_static.py` | 单容器静态托管 + SPA 回退（关键实现） |
| `deploy/` | 建库脚本（mariadb / pgsql）、网关站点片段、防串站兜底配置 |

用法与「必改占位值」清单见 [`templates/README.md`](templates/README.md)。

## 修订记录

| 版本 | 变化 |
|---|---|
| **v2.6** | **修掉模板自身的工程性倒退与流程漏项**：`.gitignore` 不再排除 `frontend/src`、`package.json`、`package-lock.json`（源码必须入库，否则 clone 后无法重建镜像）；§6.1 打包命令补 `.gitignore`、把 `frontend/dist` 改为整个 `frontend`（交付包必须含前端源码供复核）；§4.3 新增**多项目 conf.d 机制与投放规则**（加载顺序、`default_server` 唯一性、跨项目重名只能靠台账、投放后自检三件事）与目录示例；§4.2 补"开发与运维同一人兼任"的例外流程（先备份 → `nginx -t` → `reload` → 不改别人的 conf）；验收第 12 项**脚本化**（`tools/verify.sh --drill` 真跑一次同镜像升级，覆盖备份/重建/健康校验）；`preflight.sh` 把"刻意保留的占位口令"由 `WARN` 改为 **`NOTE`**（不计入 WARN，避免被当噪声），并在 §3.1 写明这是预期。 |
| **v2.5** | **探活与启动语义定量化 + 参考实现固化**：新增 S7（探活必须有硬预算且 ≤ ½ × `healthcheck.timeout`；不截断会让一次正常升级被**误回滚**）、S8（`/api/v1/health` **永远 200** + `database` 字段表达依赖状态；就绪语义另开 `/api/v1/ready`）、S9（`start_period` 必须 ≥ 迁移重试上限，模板由 20s 调至 **60s**）；新增"**启动期库不可达 → 有限重试后退出；运行期库掉线 → 禁止退出**"强制条款与运维误判提示；把两个**已验证的参考实现**固化为模板（`health.py` 2.5s 预算、`migrate.py` 启动前滚 + 三方言，以及 `deploy/migrations/` 示例与三条硬规则）；`.env` 新增 `DB_PROVISION`（`manual`/`auto`）与 `DB_ROOT_PASSWORD_FILE`，`init.sh` 支持**自动建库建号**并把随机口令写回 `.env`；`deploy/init-db.*.sql` 的示例命令改为 **defaults-file / .pgpass** 传凭证（原示例把 root 口令写进命令行，`ps` 可读）。 |
| **v2.4** | **把真实部署踩到的问题回灌进规范**（参考 Kali VM 上的 snake）：验收第 2 项改以 `HostConfig.PortBindings` 为判据（原按 `docker ps` 的 `PORTS` 列判，与模板 `Dockerfile` 的 `EXPOSE 80` 自相矛盾，**任何合规部署都必然 FAIL**）；`init.sh` 的宿主 :80 判定改为**与容器名无关**（有容器发布 :80 且在 `gateway-network` 上），新增 `GATEWAY_CONTAINER` / `GATEWAY_PROCESS`；§2.2 明确「基准值必须运行时探测」与「网桥不持有端口 / `EXPOSE` ≠ `ports:`」；域名键统一为 **`SITE_DOMAIN`** 且**未配置直接报错**（不再静默回退 `<项目名>.lan`，避免假 PASS）；红线 7 与 §4.6 给出**可满足**的鉴权口径（认证入口须逐条枚举、禁止通配）；`.env` 值约束由「允许集」改为**禁止集**（`/` 等恢复正常，`ALERT_WEBHOOK` 填 URL 不再自相矛盾）；新增**跨方言 DDL 取舍表**与**迁移三条硬规则**；`.dockerignore` 不再排除 `deploy/`，`Dockerfile` 增加 `COPY deploy/migrations /app/migrations`。 |
| **v2.3** | **对外域名成为开发阶段的显式输入**：`.env.example` 新增 `SITE_DOMAIN`（占位值 `CHANGE_ME_DOMAIN`）；`AGENTS.md` 新增红线第 16 条；`tools/preflight.sh` 新增 **8b** 校验（占位值 / 格式 / 与 `deploy/gateway-site.conf` 的 `server_name` 一致性，不一致即禁止交付）；`init.sh` 在预检阶段校验但**不询问**，`update.sh` 与 `tools/verify.sh` 改为从 `SITE_DOMAIN` 派生；防串站验收改用 RFC 2606 保留域名 `no-such-host.invalid`；§4.3 增补「目标 VM `/etc/hosts` 单机模拟」指引。清掉了原先把 `<项目名>.lan` 写死在 17 处的硬编码——其中 `verify.sh` 的硬编码会让真实验收把正确的部署判为失败。 |
| v2.2 | 新增**数据库引擎开关** `DB_ENGINE`（`sqlite` 仅本地开发 / `mariadb`·`pgsql` 内网共享库），新增 [§3.6](docs/03-强制条款.md)；连接串收口到**唯一构造点** `backend/app/db.py`；`init.sh` / `update.sh` / `tools/verify.sh` 三处拒绝 `DB_ENGINE=sqlite`；新增 `.gitignore` 模板。 |
| v2.1 | **章节重构**：原 §3「技术栈」并入 §1.1；原 §5+§6 合并为 §4；原 §4→§3、§7→§5、§8→§6。新增 `AGENTS.md`、`tools/preflight.sh`、`tools/verify.sh`、`.dockerignore`、`.gitattributes`；网关站点配置改为 `resolver` + 变量 `proxy_pass`（**禁用 `upstream`**）并补安全响应头；`update.sh` 改为**时间戳快照备份**与编排回滚；资源限额改用 `mem_limit`/`cpus`/`pids_limit`；Dockerfile 显式安装 tzdata；`APP_UID`/`APP_GID` 统一映射目录属主；新增 `§6.5 项目下线`；验收扩至 15 项并脚本化。 |
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
