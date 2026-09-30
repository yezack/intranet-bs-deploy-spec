"""版本化数据库迁移执行器（参考实现）—— 内网 B/S 架构开发规范 v2.7 §3.1 / §5.2

放置位置：`backend/app/migrate.py`；在 FastAPI 的 lifespan 里调用
`run_migrations(create_engine_from_env())`。

**首次部署与每次升级都必须应用尚未执行的迁移**——本模块在应用启动时执行，
因此 `init.sh` 与 `update.sh` 不需要额外的迁移步骤，镜像换新即自动前滚。

目录解析顺序（`deploy/migrations/` 是权威位置，规范 §3.1）：

    1. 环境变量 MIGRATIONS_DIR
    2. /app/migrations           ← 镜像内（Dockerfile: COPY deploy/migrations /app/migrations）
    3. <仓库>/deploy/migrations  ← 本地开发（backend/app/migrate.py 往上三级）

迁移文件约定：

* 文件名 `NNNN_描述.sql`（如 `0001_init.sql`），按文件名字典序执行；
* 版本号 = 文件名去掉 `.sql`；
* 已执行的版本记录在 `schema_migrations` 表，重复启动是幂等的（规范 §5.1 幂等要求）；
* **已发布的迁移文件不得修改**，要改就新增 `0002_*.sql`；
* **必须前后兼容（expand-contract）**：新增列/表要先于代码使用，删列要晚于代码停用，
  否则规范 §5.2 的镜像回滚会与已前滚的库结构冲突；
* **只用三方言都认识的语法**（sqlite / MariaDB / PostgreSQL，规范 §3.6）。

SQL 切分只支持最朴素的 `;` 结尾语句与 `--` 整行注释。迁移文件里**不要**写
存储过程/触发器这类含内嵌分号的结构；确需复杂 DDL 时请拆成多条独立语句。

## 与探活预算（S7）的关系

本模块的重试上限（默认 10 × 3s = 30s）**必须小于** compose 的
`healthcheck.start_period`（模板 60s），否则启动期探活会先判失败（S9）。
"""

from __future__ import annotations

import logging
import os
import time
from pathlib import Path

from sqlalchemy import text
from sqlalchemy.engine import Engine

log = logging.getLogger(__name__)

VERSION_TABLE = "schema_migrations"

# 建版本表：三种方言（sqlite / mariadb / pgsql）都认识这段 DDL
_CREATE_VERSION_TABLE = f"""
CREATE TABLE IF NOT EXISTS {VERSION_TABLE} (
    version       VARCHAR(128) NOT NULL,
    applied_at_ms BIGINT       NOT NULL,
    PRIMARY KEY (version)
)
"""


class MigrationError(RuntimeError):
    """迁移无法完成。启动期抛出，让容器立刻失败而不是带病提供服务。"""


def resolve_migrations_dir() -> Path:
    """按约定顺序找迁移目录，找不到就报错（静默跳过迁移会造成"表不存在"的诡异故障）。"""
    candidates: list[Path] = []

    env_dir = (os.environ.get("MIGRATIONS_DIR") or "").strip()
    if env_dir:
        candidates.append(Path(env_dir))

    # 镜像内（Dockerfile 的 COPY 目标）
    candidates.append(Path("/app/migrations"))

    # 本地开发：backend/app/migrate.py → backend/app → backend → <仓库根>/deploy/migrations
    here = Path(__file__).resolve()
    if len(here.parents) >= 3:
        candidates.append(here.parents[2] / "deploy" / "migrations")

    for candidate in candidates:
        if candidate.is_dir():
            return candidate

    raise MigrationError(
        "找不到迁移目录。已尝试：" + "；".join(str(c) for c in candidates) + "。"
        "镜像内应存在 /app/migrations（Dockerfile: COPY deploy/migrations /app/migrations）；"
        "本地开发可用 MIGRATIONS_DIR 指定。"
    )


def list_migrations(directory: Path) -> list[Path]:
    return sorted((p for p in directory.glob("*.sql") if p.is_file()), key=lambda p: p.name)


def _strip_comments(sql: str) -> str:
    kept = []
    for line in sql.splitlines():
        if line.lstrip().startswith("--"):
            continue
        kept.append(line)
    return "\n".join(kept)


def split_statements(sql: str) -> list[str]:
    """朴素切分：`--` 整行注释剔除后按 `;` 断开。"""
    return [chunk.strip() for chunk in _strip_comments(sql).split(";") if chunk.strip()]


def _applied_versions(engine: Engine) -> set[str]:
    with engine.connect() as conn:
        rows = conn.execute(text(f"SELECT version FROM {VERSION_TABLE}")).fetchall()
    return {str(row[0]) for row in rows}


def run_migrations(engine: Engine, *, retries: int = 10, retry_delay_seconds: float = 3.0) -> list[str]:
    """应用尚未执行的迁移，返回本次执行的版本列表。

    带重试：内网开机自启时，应用可能先于共享数据库就绪
    （因此在启动期宁可等待，也不要让容器反复崩溃让运维误判镜像有问题）；
    但**重试上限必须小于 healthcheck.start_period**（规范 §3.5 S9）。

    注意：重试耗尽后**主动抛错退出**，由 `restart: unless-stopped` 接管——
    这是"启动期库不可达"与"运行期库掉线"的分界（规范 §3.5 S9）：
    前者退出、后者绝不退出（运行期退出会造成重启风暴）。
    """
    directory = resolve_migrations_dir()
    files = list_migrations(directory)
    if not files:
        log.warning("迁移目录 %s 下没有 *.sql，跳过迁移（表结构可能不存在）", directory)
        return []

    last_error: Exception | None = None
    for attempt in range(1, max(1, retries) + 1):
        try:
            with engine.begin() as conn:
                conn.execute(text(_CREATE_VERSION_TABLE))
            applied = _applied_versions(engine)

            done: list[str] = []
            for path in files:
                version = path.stem
                if version in applied:
                    continue
                statements = split_statements(path.read_text(encoding="utf-8"))
                log.info("应用迁移 %s（%d 条语句）", version, len(statements))
                # 每个迁移文件一个事务：失败时该文件整体不生效，不会留下半截结构
                with engine.begin() as conn:
                    for statement in statements:
                        conn.execute(text(statement))
                    conn.execute(
                        text(
                            f"INSERT INTO {VERSION_TABLE} (version, applied_at_ms) VALUES (:version, :ts)"
                        ),
                        {"version": version, "ts": int(time.time() * 1000)},
                    )
                done.append(version)

            if done:
                log.info("本次应用迁移：%s", ", ".join(done))
            else:
                log.info("迁移已是最新（共 %d 个版本）", len(files))
            return done

        except Exception as exc:  # 数据库未就绪 / 网络不通 / SQL 报错
            last_error = exc
            if attempt >= retries:
                break
            log.warning(
                "迁移失败（第 %d/%d 次）：%s；%.0fs 后重试",
                attempt,
                retries,
                exc,
                retry_delay_seconds,
            )
            time.sleep(retry_delay_seconds)

    log.error("[startup] 数据库不可达或迁移失败，已重试 %d 次，退出等待 restart 策略接管", retries)
    raise MigrationError(f"迁移失败，已重试 {retries} 次：{last_error}") from last_error
