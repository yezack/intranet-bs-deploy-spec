# <项目名> 应用镜像 —— 内网 B/S 架构开发规范 v2.5 合规
#
# 架构：单容器。FastAPI 同时提供
#   ① 前端静态： /frontend  （SPA，镜像内置，无宿主映射）
#   ② 业务接口： /api/v1/**
# 并监听 0.0.0.0:80 —— 即规范第 5 条“容器内只提供 0.0.0.0:80”
#
# 构建前提（在外部联网机构建）：
#   frontend/dist 已由 npm run build 产出
#   构建上下文 = 交付包根目录，命令： docker build -t myapp-app:latest .

FROM python:3.13-slim

# 运行期不得访问公网；此处镜像源仅用于构建期加速
ENV TZ=Asia/Shanghai \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple

# 时区数据：TZ 只有在 /usr/share/zoneinfo 存在时才生效，而 python:*-slim 是否自带
# tzdata 随版本变化，这里显式保证（构建期联网，符合 §1）。验收：date +%z → +0800
RUN apt-get update \
 && apt-get install -y --no-install-recommends tzdata \
 && ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
 && echo "${TZ}" > /etc/timezone \
 && rm -rf /var/lib/apt/lists/*

# 非 root 运行用户（规范推荐项；绑定 80 由 compose 的 NET_BIND_SERVICE 授权）
RUN groupadd --gid 1000 app \
 && useradd --uid 1000 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app

# 先装依赖，充分利用层缓存
COPY backend/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# 业务代码
COPY backend/app ./app

# 版本化迁移（规范 §5.2）：应用启动时自动前滚，因此必须打进镜像。
# 注意：.dockerignore 不得排除 deploy/，否则这里没有文件可 COPY。
COPY deploy/migrations /app/migrations

# 前端构建产物 → 容器内 /frontend（规范 §4.5 强制路径）
COPY frontend/dist /frontend

# 宿主会映射 conf / uploads / downloads 三个目录，先在镜像内占位
RUN mkdir -p /app/conf /data/uploads /data/downloads \
 && chown -R app:app /app /frontend /data

USER 1000:1000

# 反代与健康检查都走 80
EXPOSE 80

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "80"]
