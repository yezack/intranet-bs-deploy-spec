#!/usr/bin/env bash
# ---------- 行尾自检 ----------
# 位置要求：紧跟 shebang 且在 `set` 之前 —— CRLF 会让 `set -Eeuo pipefail` 那行先报错，守卫就永远到不了。
# 写法要求：本行以注释结尾，使 CRLF 的尾部 \r 被吞进注释，从而保证本行在 CRLF 下仍可解析。
# 范围要求：检查整个文件（只查前 4096 字节会漏掉文件后半段的 CRLF）。
# 局限：直接 ./init.sh 执行 CRLF 脚本时 shebang 先失效（exit 127），守卫无法覆盖，需按 README 修复行尾。
if grep -q $'\r' "$0"; then printf '[EOL] 错误：%s 含 CRLF 行尾。修复： sed -i "s/\\r$//" "%s"，或 dos2unix "%s"\n' "$0" "$0" "$0" >&2; exit 1; fi  # EOL guard

#USAGE-BEGIN
# <项目名> 首次部署脚本
# 依据：内网 B/S 架构开发规范 v2.9 §5.1
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
# 健康等待上限必须 ≥ compose 的 start_period + interval × retries（规范 §3.5 S9）。
# 模板 compose 为 60 + 30×3 = 150s；这里取 180s，为 3s 轮询粒度与探针耗时留余量。
# 调小它会让"启动偏慢但代码正常"的部署被判超时 → init.sh 保留现场报错、update.sh 误回滚。
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"

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

# 只有连共享库时才需要这几项（sqlite 分支已在上方终止）。
# 【DB_PROVISION=auto 时不要求 DB_PASSWORD 已填】——它由下方"数据库供给"随机生成并写回 .env。
# v2.6 把这两道校验放在 auto 分支之前，导致 auto 模式永远走不到生成分支（文档承诺与实现相反）。
if [ "${DB_PROVISION:-manual}" = "auto" ]; then
    for k in DB_HOST DB_PORT DB_DATABASE DB_USERNAME; do
        require_env "$k"
    done
else
    for k in DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD; do
        require_env "$k"
    done
fi

# 拒绝 .env.example 的占位值残留：原样复制后没填也要在预检阶段拦住
reject_placeholder() {
    local name="$1" val
    val="$(printenv "$name" 2>/dev/null || true)"
    case "$val" in
        *CHANGE_ME*)
            die "$name 仍是 .env.example 中的占位值，请替换为真实值后再部署" ;;
    esac
}

# DB_PROVISION=auto 时 DB_PASSWORD 允许仍是占位值（下方会重新生成并写回），因此不在此拦截
if [ "${DB_PROVISION:-manual}" = "auto" ]; then
    reject_placeholder ADMIN_PASSWORD
else
    for k in DB_PASSWORD ADMIN_PASSWORD; do
        reject_placeholder "$k"
    done
fi

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
SITE_DOMAIN="${SITE_DOMAIN:-}"
[ -n "$SITE_DOMAIN" ] || die ".env 中缺少 SITE_DOMAIN（对外域名）。它应在开发阶段向运维确认后填入，例：SITE_DOMAIN=xz.sjq.sh"
case "$SITE_DOMAIN" in
    *CHANGE_ME*) die "SITE_DOMAIN 仍是占位值（$SITE_DOMAIN）。请向运维确认本项目对外域名后再部署" ;;
    *://*|*/*)   die "SITE_DOMAIN 格式不合法（$SITE_DOMAIN）：只写域名本身，不要带 http:// 或路径" ;;
    *:*)         die "SITE_DOMAIN 格式不合法（$SITE_DOMAIN）：不要带端口" ;;
esac
case "$SITE_DOMAIN" in
    *.*) : ;;
    *) die "SITE_DOMAIN 至少应包含一个点（当前：$SITE_DOMAIN）" ;;
esac
log "对外域名：$SITE_DOMAIN（请确认网关 server_name 与它逐字一致）"

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

# 宿主 :80 的判定**与容器名无关**（规范 §2.2 / §4.1）：
#   ① 有容器发布了宿主 :80；② 该容器在 gateway-network 上。
# 第 ② 条是必需的：本项目按 §3.2 不发布任何宿主端口，网关只能通过 gateway-network 里的
# 容器名找到我们；宿主级 nginx/apache 即使占着 :80 也解析不到容器名（只能写死 IP，容器一重建就 502）。
# 另：网桥**不持有端口**；宿主侧监听者是 docker-proxy（发布动作的宿主侧代理）。
GATEWAY_NAME=""
if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE '[:.]80$'; then
    gateway_container="$("${DOCKER[@]}" ps --filter publish=80 --format '{{.Names}}' 2>/dev/null | head -n1)"
    if [ -z "$gateway_container" ]; then
        port80_proc="$(ss -lntp 2>/dev/null | awk 'NR>1 && $4 ~ /[:.]80$/' | grep -oE '"[A-Za-z0-9_.+-]+"' | tr -d '"' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        if [ -n "${GATEWAY_PROCESS:-}" ]; then
            log "宿主 :80 由宿主级进程「${port80_proc:-未知}」监听，且 .env 已用 GATEWAY_PROCESS=${GATEWAY_PROCESS} 显式确认，按运维约定放行"
        else
            die "宿主 :80 被「${port80_proc:-未知}」占用，但没有容器发布它。
     若这是运维约定的宿主级反向代理，请在 .env 里写 GATEWAY_PROCESS=<进程名> 显式确认后再执行；
     否则请先释放该端口（本项目对外只经容器化的统一网关）。"
        fi
    else
        GATEWAY_NAME="$gateway_container"
        if "${DOCKER[@]}" inspect "$gateway_container" \
                --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null \
                | grep -qw gateway-network; then
            log "宿主 :80 由网关容器 ${gateway_container} 发布，且它在 gateway-network 上，可按容器名解析到 ${CONTAINER}，符合预期"
        else
            warn "宿主 :80 由容器 ${gateway_container} 发布，但它不在 gateway-network 上：无法按容器名解析到 ${CONTAINER}（本项目不发布宿主端口）。请运维把网关接入 gateway-network 后 reload"
        fi
    fi
fi
# 打印给运维的命令用探测到的真名；探测不到（网关没在跑）时回退到 .env 的 GATEWAY_CONTAINER
GATEWAY_NAME="${GATEWAY_NAME:-${GATEWAY_CONTAINER:-nginx-gateway}}"

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

# ---------- 数据库供给（DB_PROVISION=auto 时自动建库建号）----------
# 规范 §3.3/§5.1：库与账号正常由运维创建；同一人兼任时可开 auto 让脚本代劳。
# 【强制】安全要求：root 口令**绝不进命令行**（`ps` / shell history / `docker inspect` 都会泄漏）——
# 这里把凭证写成 600 的文件再 `docker cp` 进容器，用完即删。
case "${DB_PROVISION:-manual}" in
    manual) : ;;
    auto)
        log "== 数据库供给：DB_PROVISION=auto =="
        case "$DB_ENGINE" in
            mariadb) sql_file="deploy/init-db.mariadb.sql" ;;
            pgsql)   sql_file="deploy/init-db.pgsql.sql" ;;
            *) die "DB_PROVISION=auto 不支持 DB_ENGINE=$DB_ENGINE" ;;
        esac
        [ -f "$sql_file" ] || die "DB_PROVISION=auto 需要 $sql_file（随交付包提供）"

        # 应用口令：缺失/占位/过短时随机生成并写回 .env（与 SECRET_KEY 同一套路）
        if [ -z "${DB_PASSWORD:-}" ] || [ "${#DB_PASSWORD}" -lt 16 ] || printf '%s' "$DB_PASSWORD" | grep -q 'CHANGE_ME'; then
            NEW_DB_PASSWORD="$(openssl rand -hex 16 2>/dev/null || od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
            if [ "$DRY_RUN" = 1 ]; then
                log "[dry-run] 将随机生成 DB_PASSWORD 并写回 .env"
            else
                sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${NEW_DB_PASSWORD}|" .env
                DB_PASSWORD="$NEW_DB_PASSWORD"
                log "已随机生成 DB_PASSWORD（16 字节 hex）并写回 .env"
            fi
        fi

        # root 口令：多来源探测（现场文件位置并不统一，不能硬编码单一路径）
        ROOT_PW=""
        if [ -n "${DB_ROOT_PASSWORD_FILE:-}" ] && [ -f "${DB_ROOT_PASSWORD_FILE}" ]; then
            ROOT_PW="$(tr -d '\r\n' < "${DB_ROOT_PASSWORD_FILE}")"
            log "root 口令来源：DB_ROOT_PASSWORD_FILE=${DB_ROOT_PASSWORD_FILE}"
        elif [ -n "${DB_ROOT_PASSWORD:-}" ]; then
            ROOT_PW="$DB_ROOT_PASSWORD"
            log "root 口令来源：环境变量 DB_ROOT_PASSWORD"
        else
            for f in /home/docker/mariadb/docker-compose.yml /home/docker/mariadb/.env /home/docker/docker-compose.yml; do
                [ -f "$f" ] || continue
                ROOT_PW="$(grep -m1 -E 'MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD' "$f" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d ' ')"
                [ -n "$ROOT_PW" ] && { log "root 口令来源：$f"; break; }
            done
        fi

        if [ -z "$ROOT_PW" ]; then
            warn "未能自动获取数据库 root 口令（可用 .env 的 DB_ROOT_PASSWORD_FILE 指定文件）。已跳过自动建库，请手工执行 ${sql_file}——执行方式见该文件头部注释（用 defaults-file 传凭证，不要把口令写进命令行）"
        elif [ "$DRY_RUN" = 1 ]; then
            log "[dry-run] 将渲染 ${sql_file} 并导入容器 ${DB_HOST} 执行（库 ${DB_DATABASE} / 用户 ${DB_USERNAME}）"
        else
            tmp_cnf="$(mktemp)"; tmp_sql="$(mktemp)"
            chmod 600 "$tmp_cnf" "$tmp_sql"
            # 按 .env 声明渲染：库名/用户/口令以 DB_* 为准，避免"建了 A 库却连 B 库"
            # 【哨兵渲染】SQL 文件里用的是 __DB_DATABASE__ / __DB_USERNAME__ / __DB_PASSWORD__，
            # 而不是 myapp_db 这类"看起来像真值"的占位——后者一旦被人工替换（文件头曾要求这么做），
            # sed 就不再匹配，结果是"建了 A 库、应用却连 B 库"。
            sed -e "s|__DB_DATABASE__|${DB_DATABASE}|g" \
                -e "s|__DB_USERNAME__|${DB_USERNAME}|g" \
                -e "s|__DB_PASSWORD__|${DB_PASSWORD}|g" "$sql_file" > "$tmp_sql"
            "${DOCKER[@]}" cp "$tmp_sql" "${DB_HOST}:/tmp/init-db.sql" >/dev/null
            if [ "$DB_ENGINE" = "pgsql" ]; then
                printf '*:*:*:postgres:%s\n' "$ROOT_PW" > "$tmp_cnf"
                chmod 600 "$tmp_cnf"
                "${DOCKER[@]}" cp "$tmp_cnf" "${DB_HOST}:/tmp/.pgpass" >/dev/null
                "${DOCKER[@]}" exec "$DB_HOST" sh -c 'chmod 600 /tmp/.pgpass; PGPASSFILE=/tmp/.pgpass psql -U postgres -v ON_ERROR_STOP=1 -f /tmp/init-db.sql; rc=$?; rm -f /tmp/.pgpass /tmp/init-db.sql; exit $rc' \
                    || die "自动建库失败（pgsql）：请检查 root 口令来源与 ${sql_file}，或改用 DB_PROVISION=manual 手工执行"
            else
                printf '[client]\nuser=root\npassword=%s\n' "$ROOT_PW" > "$tmp_cnf"
                chmod 600 "$tmp_cnf"
                "${DOCKER[@]}" cp "$tmp_cnf" "${DB_HOST}:/tmp/.my.cnf" >/dev/null
                "${DOCKER[@]}" exec "$DB_HOST" sh -c 'mysql --defaults-extra-file=/tmp/.my.cnf < /tmp/init-db.sql; rc=$?; rm -f /tmp/.my.cnf /tmp/init-db.sql; exit $rc' \
                    || die "自动建库失败（mariadb）：请检查 root 口令来源与 ${sql_file}，或改用 DB_PROVISION=manual 手工执行"
            fi
            rm -f "$tmp_cnf" "$tmp_sql"
            log "数据库供给完成：${DB_DATABASE} / ${DB_USERNAME}（口令已写入 .env）"
        fi
        ;;
    *) die "DB_PROVISION 只能是 manual 或 auto，当前为 ${DB_PROVISION}" ;;
esac

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
     确认 server_name 为 ${SITE_DOMAIN}（必须逐字一致）
     站点指向 ${CONTAINER}:80（resolver + 变量，禁止 upstream 块，见规范 §4.2）
  2) 运维执行（conf.d 路径以规范 §2.2 基准为准；现场路径不同请与运维确认，不要照抄）：
       sudo cp ${PROJECT_NAME}.conf <conf.d 路径>/
       sudo docker exec ${GATEWAY_NAME} nginx -t           # 必须先通过，通过后再 reload
       sudo docker exec ${GATEWAY_NAME} nginx -s reload
  3) 【必查】网关是否已有兜底站点 00-default.conf（返回 444）——没有它时，未知 Host 会命中本项目（串站，规范 §4.3）：
       curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: no-such-host.invalid' http://127.0.0.1/
       期望：非 200。若返回 200，请让运维把交付包的 deploy/gateway-default.conf 投放为 conf.d/00-default.conf。
       注意：同一个 listen 只允许一个 default_server；nginx -t 报 "a duplicate default server" 时，
             不要去删别人的 conf，先与运维确认保留哪一个。
       开发与运维同一人兼任时，按规范 §4.2 的例外流程：先备份 conf.d → nginx -t → reload。
  4) 确认终端可解析 ${SITE_DOMAIN}（内网 DNS；单机验证可在 /etc/hosts 写「<虚拟机 IP>  ${SITE_DOMAIN}」）

验收命令：

  ${DOCKER_SHOW} compose ps
  ${DOCKER_SHOW} inspect --format '{{.State.Health.Status}}' ${CONTAINER}
  curl -s -H 'Host: ${SITE_DOMAIN}' http://127.0.0.1/api/v1/health    # 响应体应含 "project":"${PROJECT_NAME}"
  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: ${SITE_DOMAIN}' http://127.0.0.1/
  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: no-such-host.invalid' http://127.0.0.1/   # 期望非 200

日常运维：

  ${DOCKER_SHOW} compose logs -f --tail=200
  ${DOCKER_SHOW} compose restart
  sudo ./update.sh            # 升级（自动备份 + 失败回滚）

EOF

log "===== 首次部署结束 ====="
exit 0
