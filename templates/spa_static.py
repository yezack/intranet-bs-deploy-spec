"""单容器静态托管工具 —— 内网 B/S 架构开发规范 v2.6 §4.7

用法（**务必放在所有 /api/v1 路由注册之后**）：

    from fastapi import FastAPI
    from app.spa_static import mount_frontend

    app = FastAPI(title="<项目名>")
    app.include_router(auth.router, prefix="/api/v1")
    app.include_router(projects.router, prefix="/api/v1")

    @app.get("/api/v1/health")
    def health():
        return {"status": "ok"}

    mount_frontend(app)          # ← 必须是最后一次调用

行为（已在真实容器中实测验证）：

    GET /                      → 200 index.html
    GET /assets/<hashed>.js    → 200 真实文件 + Cache-Control: public, max-age=31536000, immutable
    GET /<前端路由>             → 200 index.html（SPA 回退）
    GET /api/v1/<已注册>        → 交给 API 路由
    GET /api/v1/<未注册>        → 404 JSON，绝不回退成 index.html
    GET /../<越界路径>          → 404（防目录穿越）

设计说明：静态请求统一走**同一个**处理函数，而不是再 `app.mount("/assets", StaticFiles(...))`。
原因（实测踩过）：mount 挂出去的路径会绕开本函数的缓存头逻辑，导致构建产物拿不到长缓存头。
另外如果直接把静态目录挂在 `/`，未注册的 API 路径会返回 index.html 而不是 404，
前端把 HTML 当 JSON 解析失败，会把「接口不存在」误判成「后端异常」。
"""

from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse

FRONTEND_DIR = Path("/frontend")
API_PREFIX = "/api"

# 构建产物中带内容哈希的文件可长缓存；其余（index.html 等）按 no-cache 处理
_IMMUTABLE_SUFFIXES = {
    ".js", ".mjs", ".css", ".map",
    ".woff", ".woff2", ".ttf", ".eot",
    ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".ico",
}

_IMMUTABLE_HEADERS = {"Cache-Control": "public, max-age=31536000, immutable"}
_NO_CACHE_HEADERS = {"Cache-Control": "no-cache"}


def _cache_headers(path: Path) -> dict[str, str]:
    return _IMMUTABLE_HEADERS if path.suffix.lower() in _IMMUTABLE_SUFFIXES else _NO_CACHE_HEADERS


def mount_frontend(app: FastAPI, frontend_dir: Path | str = FRONTEND_DIR) -> None:
    """在 `app` 上挂载前端静态资源与 SPA 回退。必须在 API 路由注册之后调用。"""
    root = Path(frontend_dir).resolve()
    index = root / "index.html"

    if not index.is_file():
        raise RuntimeError(
            f"未找到前端产物 {index}；请在 Dockerfile 中执行 COPY frontend/dist /frontend"
        )

    api_root = API_PREFIX.strip("/")

    @app.get("/{full_path:path}", include_in_schema=False)
    async def spa_fallback(full_path: str):
        # 1) /api 前缀一律不接管：未注册的接口路径返回 JSON 404，绝不回退成 index.html
        if full_path == api_root or full_path.startswith(api_root + "/"):
            return JSONResponse({"detail": "Not Found"}, status_code=404)

        # 2) 真实文件优先，并阻止目录穿越（../）
        if full_path:
            candidate = (root / full_path).resolve()
            try:
                candidate.relative_to(root)
            except ValueError:
                raise HTTPException(status_code=404, detail="Not Found")
            if candidate.is_file():
                return FileResponse(candidate, headers=_cache_headers(candidate))

        # 3) SPA 回退：前端路由（/users、/logs 等）刷新时仍返回首页
        return FileResponse(index, headers=_NO_CACHE_HEADERS)
