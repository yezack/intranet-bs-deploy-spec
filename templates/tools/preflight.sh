#!/usr/bin/env bash
# ---------- 行尾自检 ----------
if grep -q $'\r' "$0"; then printf '[EOL] 错误：%s 含 CRLF 行尾。修复： sed -i "s/\\r$//" "%s"\n' "$0" "$0" >&2; exit 1; fi  # EOL guard

#USAGE-BEGIN
# 交付前闸门（在【外部构建机】执行）—— 内网 B/S 架构开发规范 v2.9 §3.1 / §6.1
#
# 用法： bash tools/preflight.sh [--no-docker] [--help]
#   --no-docker  跳过需要 docker 的检查（没有 docker 的机器也能跑基础检查）
#
# 退出码： 0 全部 PASS | 1 存在 FAIL | 127 解释器不可用（脚本为 CRLF 行尾时）
#
# 在项目根目录执行（脚本自身位置无关）；全部 PASS 才允许 docker build / docker save / tar 打包。
#USAGE-END

set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/$(basename -- "${BASH_SOURCE[0]}")"
PROJECT_ROOT="$(cd -- "$SELF_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

USE_DOCKER=1
while [ $# -gt 0 ]; do
    case "$1" in
        --no-docker) USE_DOCKER=0; shift ;;
        --help|-h) awk '/^#USAGE-BEGIN$/{p=1;next} /^#USAGE-END$/{p=0} p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1（用 --help 查看用法）" >&2; exit 1 ;;
    esac
done

FAILED=0
pass() { printf '  [PASS] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILED=$((FAILED + 1)); }
warn() { printf '  [WARN] %s\n' "$*"; }
note() { printf '  [NOTE] %s\n' "$*"; }   # 预期提示：不计入 FAIL/WARN，避免把"刻意保留的占位值"当成噪声
sec()  { printf '\n== %s ==\n' "$*"; }

printf '交付前闸门：%s\n' "$PROJECT_ROOT"

# ---------- 1. 必需文件 ----------
sec "1. 必需文件"
for f in docker-compose.yml Dockerfile init.sh update.sh .env.example .dockerignore .gitattributes \
         AGENTS.md tools/preflight.sh deploy/gateway-site.conf \
         deploy/init-db.mariadb.sql deploy/init-db.pgsql.sql frontend/dist/index.html; do
    if [ -e "$f" ]; then pass "$f"; else fail "缺少 $f"; fi
done

# ---------- 2. 敏感文件 ----------
sec "2. 敏感文件不得进交付包"
if [ -f .env ]; then
    fail ".env 位于项目根目录 —— 禁止随交付包分发"
else
    pass "根目录无 .env"
fi

# ---------- 3. 行尾与可执行位 ----------
sec "3. 行尾与可执行位"
for f in init.sh update.sh tools/preflight.sh .env.example .gitattributes docker-compose.yml; do
    [ -f "$f" ] || continue
    if grep -q $'\r' "$f" 2>/dev/null; then fail "$f 含 CRLF 行尾"; else pass "$f 为 LF"; fi
done
for f in init.sh update.sh; do
    [ -f "$f" ] || continue
    if [ -x "$f" ]; then pass "$f 有 exec 位"; else fail "$f 无 exec 位（chmod +x）"; fi
done
if [ -f tools/preflight.sh ] && [ ! -x tools/preflight.sh ]; then
    warn "tools/preflight.sh 无 exec 位（用 bash 调用即可；打包前建议 chmod +x）"
fi

# ---------- 4. 编排合规 ----------
sec "4. docker-compose.yml 合规"
c=docker-compose.yml
if grep -qE '^[[:space:]]*ports:' "$c" 2>/dev/null; then
    fail "出现 ports: —— 禁止宿主端口映射，对外只经网关"
else
    pass "无 ports:"
fi
if grep -qE '^[[:space:]]*version:' "$c" 2>/dev/null; then
    fail "出现 version: —— Compose v2 已废弃该字段"
else
    pass "无 version:"
fi
if grep -q 'gateway-network' "$c" 2>/dev/null && grep -qE 'external:[[:space:]]*true' "$c" 2>/dev/null; then
    pass "接入 gateway-network（external: true）"
else
    fail "未接入 gateway-network 或未声明 external: true"
fi
if grep -qE '^[[:space:]]*user:' "$c" 2>/dev/null; then pass "非 root 运行（user:）"; else warn "缺少 user:（建议非 root 运行）"; fi
if grep -qE '^[[:space:]]*(mem_limit|cpus|pids_limit):' "$c" 2>/dev/null; then pass "资源限额存在"; else warn "缺少资源限额（mem_limit / cpus / pids_limit）"; fi
if grep -q 'api/v1/health' "$c" 2>/dev/null; then pass "healthcheck 指向 /api/v1/health"; else fail "healthcheck 未指向 /api/v1/health"; fi
if grep -q 'max-size: "50m"' "$c" 2>/dev/null; then pass "日志轮转 50m"; else warn "日志轮转未按 json-file 50m/3 配置"; fi

# ---------- 4b. 启动预算不等式（S9） ----------
# 这三个数字分散在三处——compose 的 start_period / interval / retries，以及 init.sh 的
# HEALTH_TIMEOUT 默认值。单独改动任何一处都不会报错，只有放在一起算才会暴露矛盾：
# v2.5–v2.8 就带着"120s 满足 60 + 30×3 = 150s"的错判出厂（照它跑，启动偏慢但正常的
# 升级会被判超时并**误回滚**）。这类算术矛盾正适合机器校验，故在此固定一道闸门。
sec "4b. 启动预算不等式（S9）"
_sp="$(sed -nE 's/^[[:space:]]*start_period:[[:space:]]*([0-9]+)s.*/\1/p' "$c" 2>/dev/null | head -n1)"
_iv="$(sed -nE 's/^[[:space:]]*interval:[[:space:]]*([0-9]+)s.*/\1/p' "$c" 2>/dev/null | head -n1)"
_rt="$(sed -nE 's/^[[:space:]]*retries:[[:space:]]*([0-9]+).*/\1/p' "$c" 2>/dev/null | head -n1)"
_ht="$(sed -nE 's/.*HEALTH_TIMEOUT="\$\{HEALTH_TIMEOUT:-([0-9]+)\}".*/\1/p' init.sh 2>/dev/null | head -n1)"
if [ -z "$_sp" ] || [ -z "$_iv" ] || [ -z "$_rt" ]; then
    warn "compose 中读不到完整的 start_period / interval / retries，跳过启动预算校验"
elif [ -z "$_ht" ]; then
    warn "init.sh 中读不到 HEALTH_TIMEOUT 默认值，跳过启动预算校验"
else
    _need=$(( _sp + _iv * _rt ))
    if [ "$_ht" -ge "$_need" ]; then
        pass "HEALTH_TIMEOUT=${_ht}s ≥ start_period ${_sp}s + interval ${_iv}s × retries ${_rt} = ${_need}s"
    else
        fail "HEALTH_TIMEOUT=${_ht}s < start_period ${_sp}s + interval ${_iv}s × retries ${_rt} = ${_need}s：启动偏慢但正常的升级会被判超时并误回滚（§3.5 S9）——请把 init.sh / update.sh 的默认值提到 ≥${_need}s，或调小 interval / retries"
    fi
fi

# ---------- 5. Dockerfile ----------
sec "5. Dockerfile"
d=Dockerfile
if grep -qE '^FROM[[:space:]]+[^[:space:]]+:latest' "$d" 2>/dev/null; then
    fail "基础镜像使用了 latest"
else
    pass "基础镜像未用 latest"
fi
if grep -qE '^FROM[[:space:]]+[^[:space:]:]+[[:space:]]*$' "$d" 2>/dev/null; then
    fail "基础镜像缺少 tag（应写成 python:3.13-slim 这类固定次版本）"
else
    pass "基础镜像有 tag"
fi
if grep -qE 'COPY[[:space:]]+frontend/dist' "$d" 2>/dev/null; then
    pass "COPY frontend/dist"
else
    fail "镜像未包含 frontend/dist（前端产物必须预构建后打进镜像）"
fi
if grep -qE 'RUN[[:space:]].*npm[[:space:]]+(ci|install)' "$d" 2>/dev/null; then
    fail "镜像构建期执行 npm 安装 —— 前端必须在构建机预构建"
else
    pass "镜像内无 npm 安装"
fi

# ---------- 6. 部署脚本不得安装依赖 ----------
sec "6. 部署脚本不得安装依赖"
if grep -nE '(npm[[:space:]]+(ci|install)|pip[[:space:]]+install|apt(-get)?[[:space:]]+install|yum[[:space:]]+install)' init.sh update.sh 2>/dev/null; then
    fail "init.sh / update.sh 中出现安装依赖的命令"
else
    pass "部署脚本不含安装依赖命令"
fi

# ---------- 7. 前端产物自包含 ----------
sec "7. 前端产物自包含（内网无外网出口）"
hits="$(grep -rInE "(src|href|url|@import|import)[[:space:]]*[=(]?[[:space:]]*[\"']?https?://" frontend/dist 2>/dev/null \
        | grep -vE 'https?://(localhost|127\.0\.0\.1)' || true)"
if [ -n "$hits" ]; then
    fail "前端产物存在外域资源引用（运行期会 404 / 白屏）："
    printf '%s\n' "$hits" | head -n 20 | sed 's/^/         /'
else
    pass "未发现外域资源引用"
fi

# ---------- 8. 占位值残留 ----------
sec "8. 占位值残留"
NAME="$(grep -m1 -E '^PROJECT_NAME=' .env.example 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
if [ -z "$NAME" ]; then
    warn ".env.example 中未读到 PROJECT_NAME，跳过示例值检查"
elif [ "$NAME" = "myapp" ]; then
    warn "PROJECT_NAME=myapp（项目就叫 myapp 属正常），跳过示例值检查"
else
    # 只查命名面（compose 与 deploy/）；AGENTS.md 里的 myapp 是占位符说明文字，不算残留
    left="$(grep -rn 'myapp' docker-compose.yml deploy 2>/dev/null || true)"
    if [ -n "$left" ]; then
        fail "仍残留模板示例名 myapp（当前 PROJECT_NAME=$NAME）："
        printf '%s\n' "$left" | head -n 20 | sed 's/^/         /'
    else
        pass "模板示例名已整体替换"
    fi
fi
# 建库脚本的口令本就由运维在部署时统一替换，这里只提醒，不算 FAIL
# 【NOTE 而非 WARN】建库脚本里的占位口令是**刻意保留**的：开发方不知道运维将要设的口令，
# 交付时它必然是占位值，由运维执行前替换（见规范 §3.1 的"预期占位值"说明）。
# 用 NOTE 输出，避免每次交付都出现一条 WARN 而被当成噪声忽略。
if grep -rq 'CHANGE_ME' deploy/*.sql 2>/dev/null; then
    note "deploy/*.sql 保留 CHANGE_ME 占位口令（**预期**，不是缺陷）：请在交付说明中写明“运维执行前替换为与 .env 的 DB_PASSWORD 一致的口令”"
    grep -rn 'CHANGE_ME' deploy/*.sql 2>/dev/null | head -n 5 | sed 's/^/         /'
else
    pass "建库脚本无占位口令（已由 DB_PROVISION=auto 生成或人工替换）"
fi

# ---------- 8b. 对外域名（开发阶段必须确认） ----------
sec "8b. 对外域名（SITE_DOMAIN）"
DOMAIN="$(grep -m1 -E '^SITE_DOMAIN=' .env.example 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
CONF_DOMAIN="$(grep -m1 -E '^[[:space:]]*server_name' deploy/gateway-site.conf 2>/dev/null | sed -E 's/^[[:space:]]*server_name[[:space:]]+([^;[:space:]]+).*/\1/' || true)"
if [ -z "$DOMAIN" ]; then
    fail ".env.example 中缺少 SITE_DOMAIN —— 开发启动前必须向运维确认对外域名"
elif printf '%s' "$DOMAIN" | grep -q 'CHANGE_ME'; then
    fail "SITE_DOMAIN 仍是占位值（$DOMAIN）—— 开发启动前必须向运维确认对外域名"
elif ! printf '%s' "$DOMAIN" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'; then
    fail "SITE_DOMAIN 格式不合法（$DOMAIN）—— 只写域名本身，不要带 http://、端口或路径"
else
    pass "SITE_DOMAIN=$DOMAIN"
fi
if [ -z "$CONF_DOMAIN" ]; then
    fail "deploy/gateway-site.conf 中读不到 server_name"
elif [ -n "$DOMAIN" ] && [ "$CONF_DOMAIN" = "$DOMAIN" ]; then
    pass "server_name 与 SITE_DOMAIN 一致（$CONF_DOMAIN）"
elif printf '%s' "$CONF_DOMAIN" | grep -q 'CHANGE_ME'; then
    fail "deploy/gateway-site.conf 的 server_name 仍是占位值（$CONF_DOMAIN）"
else
    fail "server_name（$CONF_DOMAIN）与 SITE_DOMAIN（$DOMAIN）不一致 —— 网关将匹配不到该域名"
fi

# ---------- 9. 静态托管接入顺序 ----------
sec "9. 静态托管接入顺序"
m=backend/app/main.py
if [ ! -f "$m" ]; then
    warn "未找到 $m，跳过 mount_frontend 顺序检查"
else
    lm="$(grep -n 'mount_frontend' "$m" 2>/dev/null | tail -n1 | cut -d: -f1 || true)"
    li="$(grep -n 'include_router' "$m" 2>/dev/null | tail -n1 | cut -d: -f1 || true)"
    if [ -z "$lm" ]; then
        fail "$m 未调用 mount_frontend()"
    elif [ -n "$li" ] && [ "$lm" -lt "$li" ]; then
        fail "mount_frontend() 必须在所有 include_router 之后（当前 mount=$lm 行，最后 include_router=$li 行）"
    else
        pass "mount_frontend() 位于 API 路由注册之后"
    fi
fi

# ---------- 10. 编排语法与镜像架构 ----------
sec "10. 编排语法与镜像架构（需要 docker）"
if [ "$USE_DOCKER" = 1 ] && command -v docker >/dev/null 2>&1; then
    # 构建机通常没有 .env（本就不该有）；用 .env.example 临时顶替以完成插值与 env_file 校验
    TMP_ENV=0
    if [ ! -f .env ] && [ -f .env.example ]; then cp .env.example .env; TMP_ENV=1; fi
    if docker compose config -q >/dev/null 2>&1; then
        pass "docker compose config 通过"
    else
        fail "docker compose config 失败（编排语法或变量插值有问题）"
    fi
    if [ "$TMP_ENV" = 1 ]; then rm -f .env; fi

    img="${NAME:-myapp}-app:latest"
    arch="$(docker image inspect --format '{{.Architecture}}' "$img" 2>/dev/null || true)"
    if [ -z "$arch" ]; then
        warn "本地无镜像 $img，跳过架构检查（构建时务必加 --platform linux/amd64）"
    elif [ "$arch" = "amd64" ]; then
        pass "$img 架构为 amd64"
    else
        fail "$img 架构为 $arch —— 内网 x86_64 无法运行，请用 docker build --platform linux/amd64"
    fi
else
    warn "跳过 docker 相关检查（--no-docker 或 docker 不可用）"
fi

# ---------- 汇总 ----------
printf '\n'
if [ "$FAILED" -eq 0 ]; then
    printf '全部 PASS —— 可以执行 docker build / docker save / tar 打包。\n'
    exit 0
fi
printf '%d 项 FAIL —— 修正后重跑；禁止带 FAIL 交付。\n' "$FAILED"
exit 1
