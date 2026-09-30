"""健康检查（参考实现）—— 内网 B/S 架构开发规范 v2.8 §3.5 S1/S7/S8

放置位置：`backend/app/routers/health.py`（按项目结构调整导入路径；本文件假定
`..database` 提供 `get_engine()` / `engine_label()`）。

规范依据：**必须实现 `GET /api/v1/health`，返回 200 与 JSON 体**。它是 compose 的
HEALTHCHECK 目标、网关探活目标、以及 `tools/verify.sh` 第 3/4 项的判据。

## 关键设计一：即使数据库不可达也返回 200（S8）

容器一直卡在 unhealthy 会让运维失去唯一的诊断入口——`docker compose logs` 之外什么都拿不到。
这里的做法是让健康检查始终可达，并把数据库状态放进响应体（`database: "ok" | "unavailable"`）。
若项目需要"就绪"语义，**另开** `/api/v1/ready`（可返回 503），但**不得**把它写进 healthcheck。

## 关键设计二：探测带硬预算 + 结果缓存（S7）

* **硬预算**（`_PROBE_TIMEOUT_SECONDS`）：驱动自己的 `connect_timeout` 默认是 10 秒（PyMySQL），
  而 compose 的 HEALTHCHECK `timeout` 只有 5 秒。不在健康检查侧截断，库一不可达整个端点就会超时，
  容器被判 unhealthy —— 而 `update.sh` 的健康校验失败会**直接触发回滚**，
  把一次正常的升级判成失败（这条是离线部署演练里实测踩到的问题）。
  规则：**探活预算 ≤ ½ × healthcheck.timeout**（5s → ≤2.5s）。
* **缓存**（`_PROBE_TTL_SECONDS`）：HEALTHCHECK 每 30 秒一次，共享库正忙时没必要每次都真的建连接
  （多项目共用一台机，探活不该成为额外负载）。

## 注意区分两种"库不可达"（S9）

    * 运行中库掉线 —— 本端点仍返回 200（database=unavailable），容器保持 healthy，便于诊断；
    * 启动时库就不可达 —— 迁移失败（`migrate.py` 重试 10 次 × 3 秒后抛错），进程退出，
      `restart: unless-stopped` 会不断重试，直到共享库就绪。因此内网开机自启时
      **容器先崩后起是正常现象**，不是镜像坏了。
"""

from __future__ import annotations

import logging
import os
import threading
import time
from datetime import datetime, timezone

from fastapi import APIRouter
from sqlalchemy import text

from ..database import engine_label, get_engine

log = logging.getLogger(__name__)

router = APIRouter(tags=["health"])

_PROBE_TTL_SECONDS = 10.0
_probe_lock = threading.Lock()
_probe_state: dict[str, object] = {"at": 0.0, "ok": False, "detail": "未探测"}

# 探活的时间预算。**必须明显小于 compose HEALTHCHECK 的 timeout（5s）**。
# 共享库不可达时，驱动会一直等到自己的 connect_timeout（PyMySQL 默认 10s），
# 不截断就会让健康检查端点整体超时 —— 后果是容器被判 unhealthy，
# 而 update.sh 的健康校验失败会直接触发回滚，把一次正常的升级判成失败。
_PROBE_TIMEOUT_SECONDS = 2.5

# 版本号：优先取包内 __version__，取不到就退回环境变量（模板不假设包结构）
try:  # pragma: no cover - 取决于项目结构
    from .. import __version__ as APP_VERSION  # type: ignore
except Exception:  # pragma: no cover
    APP_VERSION = os.environ.get("APP_VERSION") or "unknown"


def _probe_database() -> tuple[bool, str]:
    """真实探一次库；结果缓存 10 秒。

    探活在**独立线程**里跑，最多等 `_PROBE_TIMEOUT_SECONDS` 就返回，保证
    `GET /api/v1/health` 永远能快速应答（库不可达时返回 200 + database=unavailable，
    而不是把请求挂住）。线程用 daemon，即使驱动还在等自己的超时也不会拖住进程退出。
    """
    now = time.monotonic()
    with _probe_lock:
        cached_at = float(_probe_state.get("at") or 0.0)
        if cached_at and (now - cached_at) < _PROBE_TTL_SECONDS:
            return bool(_probe_state.get("ok")), str(_probe_state.get("detail"))

    outcome: dict[str, object] = {}

    def worker() -> None:
        try:
            with get_engine().connect() as conn:
                conn.execute(text("SELECT 1"))
            outcome["ok"] = True
            outcome["detail"] = "ok"
        except Exception as exc:  # 配置错误、库未就绪、网络不通都走这里
            outcome["ok"] = False
            outcome["detail"] = type(exc).__name__
            log.warning("数据库探活失败：%s", exc)

    thread = threading.Thread(target=worker, name="db-probe", daemon=True)
    thread.start()
    thread.join(_PROBE_TIMEOUT_SECONDS)

    if thread.is_alive():
        ok, detail = False, "timeout"
        log.warning("数据库探活超过 %.1fs 未返回，按不可达处理", _PROBE_TIMEOUT_SECONDS)
    else:
        ok = bool(outcome.get("ok"))
        detail = str(outcome.get("detail") or "unreachable")

    with _probe_lock:
        _probe_state.update({"at": now, "ok": ok, "detail": detail})
    return ok, detail


@router.get("/health", summary="健康检查（免鉴权）")
def health() -> dict:
    db_ok, detail = _probe_database()

    # 读配置可能在缺键时抛错；健康检查必须仍然返回 200，
    # 因此这里单独兜住，并把配置问题作为字段暴露出去（便于运维看响应/日志定位）。
    try:
        from ..config import get_settings

        settings = get_settings()
        project_name = settings.project_name
        conf_file = str(settings.conf_file)
        config_state = "ok"
    except Exception as exc:
        project_name = os.environ.get("PROJECT_NAME") or "unknown"
        conf_file = ""
        config_state = f"invalid: {type(exc).__name__}"

    local_now = datetime.now(timezone.utc).astimezone()
    return {
        "status": "ok",
        "project": project_name,
        "version": APP_VERSION,
        "time": local_now.isoformat(timespec="seconds"),
        "utc_offset": local_now.strftime("%z"),
        # 以下两个字段是**机器可读的依赖状态**：容器探活只看 HTTP 状态码，
        # 运维告警与巡检看这两个字段，两者互不干扰。
        "database": "ok" if db_ok else "unavailable",
        "database_detail": detail,
        "db_engine": engine_label(),
        "config": config_state,
        "conf_file": conf_file,
    }
