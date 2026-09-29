"""数据库连接串唯一构造点 —— 内网 B/S 架构开发规范 v2.2 §3.3

**同一份代码，本地用 SQLite，内网连共享库，切换只改 `.env` 的一行 `DB_ENGINE`。**

    DB_ENGINE=sqlite    →  本地开发 / 测试   文件库，零依赖，`git clone` 后即可跑
    DB_ENGINE=mariadb   →  内网部署          连运维提供的共享 mariadb
    DB_ENGINE=pgsql     →  内网部署          连运维提供的共享 pgsql

用法（本项目所有数据库连接**必须**经由本模块，禁止各自拼字符串）：

    from app.db import database_url, create_engine_from_env

    # 方式一：只要连接串（给 Alembic、迁移脚本、第三方 ORM 用）
    url = database_url()

    # 方式二：直接拿 SQLAlchemy Engine（连接池已按 DB_POOL_SIZE 配好）
    engine = create_engine_from_env()

    # FastAPI 常见写法
    from sqlalchemy.orm import sessionmaker
    SessionLocal = sessionmaker(bind=create_engine_from_env())

设计约束（为什么值得单开一个文件）：

1. **单一构造点**。连接串散落在多处时，「本地能跑、内网连不上」这类问题会极难定位——
   总有一处忘了改。收口到本文件后，`grep -rn "DB_HOST" backend/` 应该零命中。
2. **口令必须 URL 编码**。口令里出现 `@ : / # ?` 之一（例如 `P@ssw0rd#1`），
   手工拼串会得到一个语法上成立、指向错误主机的连接串，报错信息还指不到真因。
3. **utf8mb4 强制**（规范 S6）。mariadb 不走驱动默认值，显式带上 `charset=utf8mb4`，
   否则中文按 latin1 存储，写入就报错或变问号。
4. **SQLite 只服务于本地**。内网部署时 `init.sh` / `update.sh` 会直接拒绝 `DB_ENGINE=sqlite`
   （容器层只读且无持久卷，数据和容器同生共死，违反 S2），`tools/verify.sh` 也会把它判为 FAIL。
   本模块不重复拦截，只做一次醒目提示——这样本地用 docker 跑开发环境不会被误伤。
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from urllib.parse import quote_plus

__all__ = [
    "ENGINES",
    "DEFAULT_SQLITE_PATH",
    "DEFAULT_POOL_SIZE",
    "ConfigError",
    "get_engine_name",
    "is_sqlite",
    "database_url",
    "engine_kwargs",
    "create_engine_from_env",
]

ENGINES = ("sqlite", "mariadb", "pgsql")

# SQLite 仅本地开发用；相对路径相对于**进程工作目录**，默认落在项目根的 .local/ 下
DEFAULT_SQLITE_PATH = ".local/dev.db"

DEFAULT_POOL_SIZE = 5

# 引擎 → SQLAlchemy 驱动。用纯 Python 驱动（pymysql / psycopg2-binary），
# 免去内网编译期依赖；如项目已有别的驱动，用 DB_DRIVER 覆盖即可。
_DEFAULT_DRIVER = {
    "sqlite": "sqlite",
    "mariadb": "mysql+pymysql",
    "pgsql": "postgresql+psycopg2",
}

_DEFAULT_PORT = {"mariadb": "3306", "pgsql": "5432"}

# 仅 sqlite 认识这两个建库参数
_SQLITE_CONNECT_ARGS = {"check_same_thread": False}

_warned_sqlite_in_container = False


class ConfigError(RuntimeError):
    """`.env` 配置缺失或不合法。刻意用独立类型，便于启动期快速定位。"""


def _env(name: str, default: str = "") -> str:
    return (os.environ.get(name) or "").strip()


def _require(name: str, hint: str = "") -> str:
    val = _env(name)
    if not val:
        msg = f"缺少环境变量 {name}（应在 .env 中设置）"
        if hint:
            msg += f"。{hint}"
        raise ConfigError(msg)
    return val


def get_engine_name() -> str:
    """返回规范化后的 `DB_ENGINE`。

    刻意**不做**隐式推断（例如从 `DB_HOST` 猜引擎）：`.env` 少写一行时静默连到
    错误目标，比启动即报错危险得多。缺失或非法一律抛 `ConfigError`，错误信息带上候选值。
    """
    raw = _env("DB_ENGINE").lower()
    if not raw:
        raise ConfigError(
            "缺少 DB_ENGINE（应在 .env 中设置）。"
            f"本地开发填 sqlite；内网部署填 mariadb 或 pgsql。候选值：{' / '.join(ENGINES)}"
        )
    if raw not in ENGINES:
        raise ConfigError(f"DB_ENGINE 只能是 {' / '.join(ENGINES)}，当前为 {raw!r}")
    return raw


def is_sqlite() -> bool:
    return get_engine_name() == "sqlite"


def _warn_if_sqlite_in_container() -> None:
    """容器里用 sqlite 几乎必然是误配置：镜像层只读、无持久卷，数据随容器消亡（违反 S2）。

    只提示不拦截——本地 docker 跑开发环境是正当用法；真正的闸门在 init.sh / update.sh / verify.sh。
    """
    global _warned_sqlite_in_container
    if _warned_sqlite_in_container:
        return
    if Path("/.dockerenv").exists():
        _warned_sqlite_in_container = True
        print(
            "[db.py] 警告：检测到在容器内使用 DB_ENGINE=sqlite。"
            "sqlite 仅限本地开发；内网部署请改为 mariadb 或 pgsql，否则数据会随容器丢失。",
            file=sys.stderr,
        )


def database_url() -> str:
    """按 `DB_ENGINE` 构造 SQLAlchemy 连接串。**全项目唯一的连接串来源。**

    sqlite
        `sqlite:///<DB_SQLITE_PATH>`，默认 `.local/dev.db`；父目录不存在时自动创建。

    mariadb / pgsql
        `mysql+pymysql://user:pass@host:port/db?charset=utf8mb4`
        `postgresql+psycopg2://user:pass@host:port/db`
        四项 `DB_*` 复用运维下发的值，与规范 §3.3 完全一致，不多一个变量。
    """
    engine = get_engine_name()

    if engine == "sqlite":
        _warn_if_sqlite_in_container()
        raw_path = _env("DB_SQLITE_PATH") or DEFAULT_SQLITE_PATH
        if raw_path == ":memory:":
            return "sqlite://"
        path = Path(raw_path).expanduser()
        # 提前建父目录：否则 SQLite 报 "unable to open database file"，信息量极低
        path.parent.mkdir(parents=True, exist_ok=True)
        # 用 resolve() 拿绝对路径，避免工作目录变化导致连到另一个库
        return f"sqlite:///{path.resolve().as_posix()}"

    driver = _env("DB_DRIVER") or _DEFAULT_DRIVER[engine]

    host = _require("DB_HOST", "内网由运维提供数据库容器名，通常为 mariadb 或 pgsql")
    port = _env("DB_PORT") or _DEFAULT_PORT[engine]
    database = _require("DB_DATABASE", "库名以 <项目名>_db 命名")
    username = _require("DB_USERNAME", "用户名以 <项目名>_user 命名")
    password = _require("DB_PASSWORD", "口令应与 deploy/init-db.*.sql 中一致")

    # quote_plus 而非 quote：口令含空格时也必须安全（规范 §3.3 虽已禁空格，这里不赌）
    userinfo = f"{quote_plus(username)}:{quote_plus(password)}"
    query = "?charset=utf8mb4" if engine == "mariadb" else ""

    return f"{driver}://{userinfo}@{host}:{port}/{database}{query}"


def engine_kwargs() -> dict:
    """传给 `create_engine()` 的额外参数。不要绕过它自己拼。

    - 连接池上限取自 `DB_POOL_SIZE`（默认 5）。多项目共用同一个 mariadb，
      各项目池上限之和必须 ≤ 运维设定的 `max_connections`（规范 §3.3）。
    - `pool_pre_ping=True`：内网交换机/防火墙会掐掉空闲连接，没有它就会出现
      "服务跑了一夜，早上第一个请求必失败"。
    - sqlite 无连接池语义，且需关闭线程校验（FastAPI 的同步路由跑在线程池里）。
    """
    if is_sqlite():
        return {"connect_args": dict(_SQLITE_CONNECT_ARGS)}

    raw = _env("DB_POOL_SIZE") or str(DEFAULT_POOL_SIZE)
    try:
        pool_size = int(raw)
    except ValueError:
        raise ConfigError(f"DB_POOL_SIZE 必须是整数，当前为 {raw!r}") from None
    if pool_size < 1:
        raise ConfigError(f"DB_POOL_SIZE 至少为 1，当前为 {pool_size}")

    return {
        "pool_size": pool_size,
        "max_overflow": 0,          # 池上限就是硬上限，超了排队而不是再开连接
        "pool_pre_ping": True,
        "pool_recycle": 1800,       # 30 分钟回收，早于常见的内网 NAT 空闲超时
    }


def create_engine_from_env(**overrides):
    """构造 SQLAlchemy `Engine`。需要 SQLAlchemy 时才 import，便于无 ORM 的项目只取连接串。"""
    try:
        from sqlalchemy import create_engine
    except ModuleNotFoundError:  # pragma: no cover - 取决于项目依赖
        raise ConfigError(
            "需要 SQLAlchemy 才能使用 create_engine_from_env()；"
            "若项目不用 ORM，请改用 database_url() 自行连接。"
        ) from None

    kwargs = engine_kwargs()
    kwargs.update(overrides)
    return create_engine(database_url(), **kwargs)
