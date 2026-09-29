#!/usr/bin/env bash
# ---------- 行尾自检 ----------
# 位置要求：紧跟 shebang 且在 `set` 之前 —— CRLF 会让 `set -Eeuo pipefail` 那行先报错，守卫就永远到不了。
# 写法要求：本行以注释结尾，使 CRLF 的尾部 \r 被吞进注释，从而保证本行在 CRLF 下仍可解析。
# 范围要求：检查整个文件（只查前 4096 字节会漏掉文件后半段的 CRLF）。
# 局限：直接 ./init.sh 执行 CRLF 脚本时 shebang 先失效（exit 127），守卫无法覆盖，需按 README 修复行尾。
if grep -q $'\r' "$0"; then printf '[EOL] 错误：%s 含 CRLF 行尾。修复： sed -i "s/\\r$//" "%s"，或 dos2unix "%s"\n' "$0" "$0" "$0" >&2; exit 1; fi  # EOL guard

#USAGE-BEGIN
# <项目名> 首次部署脚本
# 依据：内网 B/S 架构开发规范 v2.3 §5.1
#
# 用法： sudo ./init.sh [--tar <文件>] [--dry-run] [--help]
#   --tar <文件>  指定镜像包；省略时取本目录下最新的 *.tar（按修改时间）
#   --dry-run     只打印将要执行的动作，不做任何实际变更
#
# 退出码： 0 成功 | 1 预检失败 | 2 启动后健康检查未通过 | 127 解释器不可用（脚本为 CRLF 行尾时）
#USAGE-END

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# usage() 用绝对路径读脚本自身：脚本随后会 cd 到项目目录，相对形式的 $0 可能已失效
SELF="$SCRIPT_DIR/$(basename -- "$0")"
cd "$SCRIPT_DIR"

TAR=""
DRY_RUN=0
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"

usage() {
    awk '/^#USAGE-BEGIN$/{p=1;next} /^#USAGE-END$/{p=0} p' "$SELF" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tar)     TAR="${2:?--tar 需要一个文件参数}"; shift 2 ;;
        --tar=*)   TAR="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) usage ;;
        *) echo "未知参数：$1（用 --help 查看用法）" >&2; exit 1 ;;
    esac
done

ts()   { date '+%F %T'; }
log()  { printf '[%s] %s\n' "$(ts)" "$*"; }
warn() { printf '[%s] 警告：%s\n' "$(ts)" "$*" >&2; }
die()  { printf '[%s] 错误：%s\n' "$(ts)" "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then log "[dry-run] $*"; else log "$*"; "$@"; fi; }

log "===== <项目名> 首次部署开始（$( [ "$DRY_RUN" = 1 ] && echo dry-run || echo 实际执行 )）====="

# ---------- 阶段 1：预检 ----------
log "== 阶段 1/6：预检 =="

[ -f .env ] || die "缺少 .env。请先执行： cp .env.example .env && vi .env && chmod 600 .env"
if grep -q $'\r' .env; then
    die ".env 含 CRLF 行尾，请先执行： sed -i 's/\r\$//' .env"
fi

# 选择可用的 docker 命令（实测部署用户可能不在 docker 组）
if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
    log "当前用户无 docker 权限，改用 sudo docker"
else
    die "无法访问 docker daemon。请以 root 运行，或把该用户加入 docker 组后重新登录。"
fi

# 打印给人工复制的命令一律带 sudo：规范 §2.2 明确部署用户不在 docker 组
DOCKER_SHOW="sudo docker"

"${DOCKER[@]}" compose version >/dev/null 2>&1 || die "docker compose（v2）不可用，请安装 Docker Compose v2"

# 载入 .env（导出为环境变量）
set -a
# shellcheck disable=SC1091
. ./.env
set +a

PROJECT_NAME="${PROJECT_NAME:-}"
[ -n "$PROJECT_NAME" ] || die ".env 中缺少 PROJECT_NAME"
case "$PROJECT_NAME" in
    *[!a-z0-9-]*|"") die "PROJECT_NAME 只允许小写字母、数字、连字符，当前：$PROJECT_NAME" ;;
esac

require_env() {
    local name="$1" val
    val="$(printenv "$name" 2>/dev/null || true)"
    [ -n "$val" ] || die ".env 中缺少必填项：$name"
}

# ---------- 数据库引擎开关（规范 §3.6）----------
# 本地开发允许 sqlite；内网部署必须连共享库。这里在预检阶段就把它拦死，
# 而不是留到运行期 —— sqlite 落在只读容器层里，数据和容器同生共死，属于静默数据丢失（违反 S2）。
require_env DB_ENGINE
case "$DB_ENGINE" in
    sqlite)
        die "DB_ENGINE=sqlite 不允许用于内网部署。
     原因：容器 read_only 且未挂持久卷，sqlite 文件随容器删除而丢失（违反 S2）。
     本地开发继续用 sqlite 没问题；部署前请把 .env 改为下面之一：
       DB_ENGINE=mariadb   运维提供的共享库（规范基准环境 mariadb:10.11，推荐）
       DB_ENGINE=pgsql     运维提供的共享库（pgsql 待运维部署）
     注意：DB_ENGINE 决定「用哪种方言」（驱动/字符集/连接串），DB_HOST 决定「连哪台」，
           两者都要改：mariadb → DB_HOST=mariadb / DB_PORT=3306；pgsql → DB_HOST=pgsql / DB_PORT=5432。" ;;
    mariadb|pgsql) : ;;
    *) die "DB_ENGINE 只能是 sqlite / mariadb / pgsql，当前为 ${DB_ENGINE}。
     sqlite 仅限本地开发，内网部署请用 mariadb 或 pgsql。" ;;
esac

# 只有连共享库时才需要这五项（sqlite 分支已在上方终止）
for k in DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD; do
    require_env "$k"
done

# 拒绝 .env.example 的占位值残留：原样复制后没填也要在预检阶段拦住
reject_placeholder() {
    local name="$1" val
    val="$(printenv "$name" 2>/dev/null || true)"
    case "$val" in
        *CHANGE_ME*)
            die "$name 仍是 .env.example 中的占位值，请替换为真实值后再部署" ;;
    esac
}

for k in DB_PASSWORD ADMIN_PASSWORD; do
    reject_placeholder "$k"
done

# 库名/用户名只在「与 PROJECT_NAME 不匹配」时才算占位值残留：
# 项目恰好叫 myapp 时，myapp_db / myapp_user 正是正确值，不能误判
if [ "$PROJECT_NAME" != "myapp" ]; then
    [ "$DB_DATABASE" != "myapp_db" ] || die "DB_DATABASE 仍是模板示例值 myapp_db，请改为 ${PROJECT_NAME}_db"
    [ "$DB_USERNAME" != "myapp_user" ] || die "DB_USERNAME 仍是模板示例值 myapp_user，请改为 ${PROJECT_NAME}_user"
fi

# SECRET_KEY 不由现场手填：缺失、占位或过短时由脚本生成并写回 .env（幂等，只在需要时写一次）
_sk="${SECRET_KEY:-}"
secret_needs_fix=0
if [ -z "$_sk" ] || [ "${#_sk}" -lt 32 ]; then secret_needs_fix=1; fi
case "$_sk" in *CHANGE_ME*) secret_needs_fix=1 ;; esac
if [ "$secret_needs_fix" = 1 ]; then
    if command -v openssl >/dev/null 2>&1; then
        NEW_SECRET="$(openssl rand -hex 32)"
    else
        NEW_SECRET="$(od -An -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
    fi
    [ -n "$NEW_SECRET" ] || die "无法生成 SECRET_KEY（缺少 openssl，且 /dev/urandom 不可用）"
    if [ "$DRY_RUN" = 1 ]; then
        log "[dry-run] SECRET_KEY 为占位值或过短：将以新生成的 32 字节 hex 写回 .env"
    else
        if grep -q '^SECRET_KEY=' .env; then
            sed -i "s|^SECRET_KEY=.*|SECRET_KEY=${NEW_SECRET}|" .env
        else
            printf '\nSECRET_KEY=%s\n' "$NEW_SECRET" >> .env
        fi
        SECRET_KEY="$NEW_SECRET"
        log "已自动生成 SECRET_KEY（32 字节 hex）并写回 .env，现场无需手工填写"
    fi
fi

# ---------- 对外域名（开发阶段确认，部署侧只校验）----------
# 域名由运维分配、在项目开发阶段写入 .env.example；这里只拦「没确认」和「格式不对」。
APP_DOMAIN="${APP_DOMAIN:-}"
[ -n "$APP_DOMAIN" ] || die ".env 中缺少 APP_DOMAIN（对外域名）。它应在开发阶段向运维确认后填入，例：APP_DOMAIN=xz.sjq.sh"
case "$APP_DOMAIN" in
    *CHANGE_ME*) die "APP_DOMAIN 仍是占位值（$APP_DOMAIN）。请向运维确认本项目对外域名后再部署" ;;
    *://*|*/*)   die "APP_DOMAIN 格式不合法（$APP_DOMAIN）：只写域名本身，不要带 http:// 或路径" ;;
    *:*)         die "APP_DOMAIN 格式不合法（$APP_DOMAIN）：不要带端口" ;;
esac
case "$APP_DOMAIN" in
    *.*) : ;;
    *) die "APP_DOMAIN 至少应包含一个点（当前：$APP_DOMAIN）" ;;
esac
log "对外域名：$APP_DOMAIN（请确认网关 server_name 与它逐字一致）"

# 端口按引擎取默认值（§3.3 / §2.2）；不同则告警，仍以运维下发的值为准
case "$DB_ENGINE" in
    mariadb) expect_port=3306 ;;
    pgsql)   expect_port=5432 ;;
esac
[ "$DB_PORT" = "$expect_port" ] \
    || warn "DB_ENGINE=${DB_ENGINE} 的端口通常为 ${expect_port}，当前为 ${DB_PORT}"

# DB_ENGINE 定方言、DB_HOST 定地址，两者刻意解耦：运维自定义容器名同样合法，故不阻断。
# 但「切了引擎忘改 DB_HOST」是最常见的手误，标准部署下两者同名，这里显式点名提醒。
case "${DB_ENGINE}:${DB_HOST}" in
    mariadb:mariadb|pgsql:pgsql) : ;;
    *) warn "DB_ENGINE=${DB_ENGINE} 与 DB_HOST=${DB_HOST} 不一致（标准部署下两者同名）。若运维确以该名提供共享库可忽略，否则请按 §2.2 与运维核对。" ;;
esac

IMAGE="${PROJECT_NAME}-app:latest"
CONTAINER="${PROJECT_NAME}-app"

# gateway-network 由运维创建，脚本只校验不创建
"${DOCKER[@]}" network inspect gateway-network >/dev/null 2>&1 \
    || die "缺少 gateway-network（统一网关网络）。请运维先执行： docker network create gateway-network"

# 宿主 80 端口应恰好由 nginx-gateway 占用
if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE '[:.]80$'; then
    if "${DOCKER[@]}" ps --format '{{.Names}}' 2>/dev/null | grep -qx nginx-gateway; then
        log "宿主 80 端口由 nginx-gateway 占用，符合预期"
    else
        die "宿主 80 端口被非 nginx-gateway 进程占用，请先释放： ss -lntp | grep ':80'"
    fi
fi

log "预检通过：PROJECT_NAME=$PROJECT_NAME  IMAGE=$IMAGE"

# ---------- 阶段 2：目录 ----------
log "== 阶段 2/6：准备目录（conf/ uploads/ downloads/ backups/）=="

OWNER=""
if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    OWNER="$SUDO_USER"
fi

# 容器运行身份（compose 的 user:），必须与三类映射目录的属主一致，否则容器内不可写
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
case "$APP_UID" in ''|*[!0-9]*) die "APP_UID 必须是非负整数，当前：$APP_UID" ;; esac
case "$APP_GID" in ''|*[!0-9]*) die "APP_GID 必须是非负整数，当前：$APP_GID" ;; esac
log "容器运行身份：${APP_UID}:${APP_GID}（conf/ uploads/ downloads/ 属主将与之对齐）"

for d in conf uploads downloads backups; do
    run mkdir -p "$d"
done

if [ "$DRY_RUN" = 0 ]; then
    chmod 700 backups 2>/dev/null || true
    chmod 600 .env 2>/dev/null || true
    # 【强制】三类映射目录属主 = 容器运行 uid:gid（规范 §3.4 / §4.5）
    chown -R "$APP_UID:$APP_GID" conf uploads downloads 2>/dev/null \
        || warn "chown $APP_UID:$APP_GID 失败（非 root 执行？），上传/下载目录可能不可写"
    if [ -n "$OWNER" ]; then
        chown "$OWNER:$OWNER" backups .env 2>/dev/null \
            || warn "调整属主为 $OWNER 失败，请手工检查权限"
    fi
fi

# ---------- 阶段 3：导入镜像 ----------
log "== 阶段 3/6：导入离线镜像 =="

# 目录内可能残留历史交付包：按修改时间取最新，避免旧包覆盖新包（glob 展开是字典序，不可靠）
if [ -n "$TAR" ]; then
    [ -f "$TAR" ] || die "指定的镜像包不存在：$TAR"
    log "使用 --tar 指定的镜像包：$TAR"
else
    shopt -s nullglob
    TARS=(./*.tar)
    shopt -u nullglob

    if [ "${#TARS[@]}" -eq 0 ]; then
        log "目录内无 *.tar，跳过导入（假定 ${IMAGE} 已存在）"
    else
        TAR="$(ls -1t -- "${TARS[@]}" | head -n1)"
        if [ "${#TARS[@]}" -gt 1 ]; then
            warn "目录内有 ${#TARS[@]} 个 *.tar，仅导入最新的：${TAR}。如需指定请用： ./init.sh --tar <文件>"
        fi
    fi
fi

if [ -n "${TAR:-}" ]; then
    run "${DOCKER[@]}" load -i "$TAR"
fi

if [ "$DRY_RUN" = 0 ]; then
    "${DOCKER[@]}" image inspect "$IMAGE" >/dev/null 2>&1 \
        || die "镜像 $IMAGE 不存在。请确认交付包已放入本目录，且其 tag 与 PROJECT_NAME（$PROJECT_NAME）一致"
fi

# ---------- 阶段 4：启动 ----------
log "== 阶段 4/6：启动服务 =="
run "${DOCKER[@]}" compose up -d --remove-orphans

# ---------- 阶段 5：健康校验 ----------
log "== 阶段 5/6：健康校验（最长 ${HEALTH_TIMEOUT}s）=="

wait_healthy() {
    local deadline=$(( SECONDS + HEALTH_TIMEOUT )) status
    while [ "$SECONDS" -lt "$deadline" ]; do
        status="$("${DOCKER[@]}" inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo unknown)"
        [ "$status" = "healthy" ] && { log "容器 $CONTAINER 健康状态：healthy"; return 0; }
        sleep 3
    done
    return 1
}

if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] 轮询 $CONTAINER 健康状态直至 healthy"
else
    if ! wait_healthy; then
        warn "健康检查未在 ${HEALTH_TIMEOUT}s 内变为 healthy，保留现场供排查"
        "${DOCKER[@]}" compose ps || true
        "${DOCKER[@]}" compose logs --tail=50 || true
        echo
        echo "排查建议："
        echo "  1) 查看日志     : ${DOCKER_SHOW} compose logs -f ${CONTAINER}"
        echo "  2) 容器内自测   : ${DOCKER_SHOW} exec ${CONTAINER} python -c \"import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:80/api/v1/health').read())\""
        echo "  3) 数据库连通性 : 检查 .env 的 DB_ENGINE/DB_HOST/DB_PORT/DB_DATABASE，以及运维的开通情况"
        exit 2
    fi
fi

# ---------- 阶段 6：完成 ----------
log "== 阶段 6/6：完成 =="

cat <<EOF

部署完成。下一步请运维接入统一网关：

  1) 将交付包 deploy/gateway-site.conf 复制为 <项目名>.conf
     确认 server_name 为 ${APP_DOMAIN}（必须逐字一致）
     站点指向 ${CONTAINER}:80（resolver + 变量，禁止 upstream 块，见规范 §4.2）
  2) 运维执行：
       sudo cp ${PROJECT_NAME}.conf /home/docker/nginx/conf.d/
       sudo docker exec nginx-gateway nginx -t
       sudo docker exec nginx-gateway nginx -s reload
  3) 确认终端可解析 ${APP_DOMAIN}（内网 DNS；单机验证可在 /etc/hosts 写「<虚拟机 IP>  ${APP_DOMAIN}」）

验收命令：

  ${DOCKER_SHOW} compose ps
  ${DOCKER_SHOW} inspect --format '{{.State.Health.Status}}' ${CONTAINER}
  curl -s -H 'Host: ${APP_DOMAIN}' http://127.0.0.1/api/v1/health
  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: ${APP_DOMAIN}' http://127.0.0.1/

日常运维：

  ${DOCKER_SHOW} compose logs -f --tail=200
  ${DOCKER_SHOW} compose restart
  sudo ./update.sh            # 升级（自动备份 + 失败回滚）

EOF

log "===== 首次部署结束 ====="
exit 0
