#!/usr/bin/env bash
# ---------- 行尾自检 ----------
# 位置要求：紧跟 shebang 且在 `set` 之前 —— CRLF 会让 `set -Eeuo pipefail` 那行先报错，守卫就永远到不了。
# 写法要求：本行以注释结尾，使 CRLF 的尾部 \r 被吞进注释，从而保证本行在 CRLF 下仍可解析。
# 范围要求：检查整个文件（只查前 4096 字节会漏掉文件后半段的 CRLF）。
# 局限：直接 ./update.sh 执行 CRLF 脚本时 shebang 先失效（exit 127），守卫无法覆盖，需按 README 修复行尾。
if grep -q $'\r' "$0"; then printf '[EOL] 错误：%s 含 CRLF 行尾。修复： sed -i "s/\\r$//" "%s"，或 dos2unix "%s"\n' "$0" "$0" "$0" >&2; exit 1; fi  # EOL guard

#USAGE-BEGIN
# <项目名> 版本更新脚本（自动快照 → 导入 → 重建 → 校验 → 失败自动回滚并告警）
# 依据：内网 B/S 架构开发规范 v2.7 §5.2
#
# 用法： sudo ./update.sh [选项]
#   --tar <文件>        指定镜像包，默认取本目录下最新的 *.tar
#   --keep <N>          backups/ 中保留的快照目录个数（每个含 .env + docker-compose.yml + 镜像包），默认 5；0 = 全部删除
#   --allow-same-image  允许导入与当前完全相同的镜像（默认中止，防「更新成功但仍跑旧版本」）
#   --no-rollback       关闭自动回滚（仅排障使用）
#   --dry-run           只打印将要执行的动作，不做任何实际变更
#   --help              显示本帮助
#
# 退出码： 0 更新成功 | 1 预检失败 | 2 已回滚到旧版本 | 3 更新失败且回滚失败（需人工介入） | 127 解释器不可用（脚本为 CRLF 行尾时）
#USAGE-END

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# usage() 用绝对路径读脚本自身：脚本随后会 cd 到项目目录，相对形式的 $0 可能已失效
SELF="$SCRIPT_DIR/$(basename -- "$0")"
cd "$SCRIPT_DIR"

TAR=""
KEEP=5
DO_ROLLBACK=1
DRY_RUN=0
ALLOW_SAME_IMAGE=0
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"

usage() {
    awk '/^#USAGE-BEGIN$/{p=1;next} /^#USAGE-END$/{p=0} p' "$SELF" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tar)              TAR="${2:?--tar 需要一个文件参数}"; shift 2 ;;
        --tar=*)            TAR="${1#*=}"; shift ;;
        --keep)             KEEP="${2:?--keep 需要一个数字}"; shift 2 ;;
        --keep=*)           KEEP="${1#*=}"; shift ;;
        --allow-same-image) ALLOW_SAME_IMAGE=1; shift ;;
        --no-rollback)      DO_ROLLBACK=0; shift ;;
        --dry-run)          DRY_RUN=1; shift ;;
        --help|-h)          usage ;;
        *) echo "未知参数：$1（用 --help 查看用法）" >&2; exit 1 ;;
    esac
done

case "$KEEP" in
    ''|*[!0-9]*) echo "--keep 必须是非负整数，当前：$KEEP" >&2; exit 1 ;;
esac

ts()   { date '+%F %T'; }
log()  { printf '[%s] %s\n' "$(ts)" "$*"; }
warn() { printf '[%s] 警告：%s\n' "$(ts)" "$*" >&2; }
die()  { printf '[%s] 错误：%s\n' "$(ts)" "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then log "[dry-run] $*"; else log "$*"; "$@"; fi; }

log "===== <项目名> 版本更新开始（$( [ "$DRY_RUN" = 1 ] && echo dry-run || echo 实际执行 )）====="

# ---------- 阶段 1：预检与加锁 ----------
[ -f .env ] || die "缺少 .env（应从 ./init.sh 已完成首次部署）"
if grep -q $'\r' .env; then
    die ".env 含 CRLF 行尾，请先执行： sed -i 's/\r\$//' .env"
fi

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

"${DOCKER[@]}" compose version >/dev/null 2>&1 || die "docker compose（v2）不可用"

# 并发保护：同一项目同时只允许一个更新进程
if command -v flock >/dev/null 2>&1; then
    LOCK_FILE="$SCRIPT_DIR/.update.lock"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "已有另一个 update.sh 正在运行（锁文件：$LOCK_FILE）"
else
    warn "未找到 flock，跳过并发保护"
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

PROJECT_NAME="${PROJECT_NAME:-}"
[ -n "$PROJECT_NAME" ] || die ".env 中缺少 PROJECT_NAME"

# ---------- 数据库引擎开关（规范 §3.6）----------
# 与 init.sh 同一道闸门：升级时 .env 若被改回 sqlite 同样拦死。
# 「升级后数据全没了」是最难排查的一类故障，必须在动手前拦。
DB_ENGINE="${DB_ENGINE:-}"
case "$DB_ENGINE" in
    sqlite)
        die "DB_ENGINE=sqlite 不允许用于内网部署（容器只读且无持久卷，数据随容器丢失，违反 S2）。
     本地开发可以继续用 sqlite；请把 .env 的 DB_ENGINE 改回 mariadb 或 pgsql 后重试。" ;;
    mariadb|pgsql) : ;;
    *)
        die "DB_ENGINE 缺失或非法（当前 ${DB_ENGINE:-<空>}）。只允许 sqlite / mariadb / pgsql；
     sqlite 仅限本地开发，内网部署请用 mariadb 或 pgsql。" ;;
esac

IMAGE="${PROJECT_NAME}-app:latest"
CONTAINER="${PROJECT_NAME}-app"

# 网关容器名：只用于打印给运维的命令。真名按「谁发布了宿主 :80」探测，与名字无关（规范 §2.2）；
# 探测不到时回退到 .env 的 GATEWAY_CONTAINER（基准环境值只作兜底）。
GATEWAY_NAME="$("${DOCKER[@]}" ps --filter publish=80 --format '{{.Names}}' 2>/dev/null | head -n1)"
GATEWAY_NAME="${GATEWAY_NAME:-${GATEWAY_CONTAINER:-nginx-gateway}}"

[ -d backups ] || run mkdir -p backups

alert() {
    printf '\n[%s] \033[31m********** 告警：%s **********\033[0m\n\n' "$(ts)" "$*" >&2
    if [ -n "${ALERT_WEBHOOK:-}" ]; then
        curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "{\"project\":\"${PROJECT_NAME}\",\"level\":\"error\",\"message\":\"$*\",\"time\":\"$(ts)\"}" \
            "$ALERT_WEBHOOK" >/dev/null 2>&1 || warn "告警上报失败：$ALERT_WEBHOOK"
    fi
}

wait_healthy() {
    local deadline=$(( SECONDS + HEALTH_TIMEOUT )) status
    while [ "$SECONDS" -lt "$deadline" ]; do
        status="$("${DOCKER[@]}" inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo unknown)"
        [ "$status" = "healthy" ] && { log "容器 $CONTAINER 健康状态：healthy"; return 0; }
        sleep 3
    done
    return 1
}

# 解析待导入的镜像包
TAR_EXPLICIT=1
if [ -z "$TAR" ]; then
    TAR_EXPLICIT=0
    TAR="$(ls -1t ./*.tar 2>/dev/null | head -n1 || true)"
fi
[ -n "$TAR" ] || die "未找到镜像包。请把 <项目名>-app.tar 放入本目录，或用 --tar 指定"
[ -f "$TAR" ] || die "镜像包不存在：$TAR"
log "预检通过：PROJECT_NAME=$PROJECT_NAME  IMAGE=$IMAGE  待导入=$(basename "$TAR")  keep=$KEEP  自动回滚=$DO_ROLLBACK"

# ---------- 阶段 2：备份（时间戳快照目录：.env + docker-compose.yml + 镜像包） ----------
log "== 阶段 2/5：备份到快照目录 =="
TS="$(date '+%Y%m%d-%H%M%S')"
BAK_DIR="backups/${TS}"
BAK_IMG="${BAK_DIR}/${PROJECT_NAME}-app.tar"
ROLLBACK_IMG=""
IMG_ID_BEFORE="$("${DOCKER[@]}" image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
# 记录重建前的容器 IP：IP 变化会让网关（upstream 块写法）继续指向旧地址
IP_BEFORE="$("${DOCKER[@]}" inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$CONTAINER" 2>/dev/null || true)"

run mkdir -p "$BAK_DIR"
run cp -p .env "${BAK_DIR}/.env"
if [ -f docker-compose.yml ]; then
    run cp -p docker-compose.yml "${BAK_DIR}/docker-compose.yml"
else
    warn "未找到 docker-compose.yml，快照中将缺少编排文件（回滚时无法还原编排）"
fi

if "${DOCKER[@]}" image inspect "$IMAGE" >/dev/null 2>&1; then
    run "${DOCKER[@]}" save "$IMAGE" -o "$BAK_IMG"
    ROLLBACK_IMG="$BAK_IMG"
    log "已备份当前镜像 → $BAK_IMG"
else
    warn "当前镜像 $IMAGE 不存在（首次部署？），跳过镜像备份，本次将无法自动回滚"
fi

# 快照自描述：半年后仍能看出这是哪个版本、来自哪个交付包
if [ "$DRY_RUN" = 0 ]; then
    cat > "${BAK_DIR}/MANIFEST" <<EOF
project=${PROJECT_NAME}
image=${IMAGE}
image_id=${IMG_ID_BEFORE:-<无镜像>}
backup_time=$(date '+%F %T')
source_tar=$(basename "$TAR")
EOF
fi

# ---------- 阶段 3：导入新镜像并重建 ----------
log "== 阶段 3/5：导入新镜像并重建容器 =="

# 【强制】§5.2：版本化迁移必须随包交付，且必须前后兼容（expand-contract）。
# 原因是本脚本的回滚只还原镜像与编排文件 —— 库结构一旦被新版本前滚就不会自动退回，
# 不兼容的迁移会让「回滚」这个兜底手段失效。
if [ -d deploy/migrations ]; then
    n_mig="$(find deploy/migrations -type f \( -name '*.py' -o -name '*.sql' \) 2>/dev/null | wc -l | tr -d ' ')"
    log "deploy/migrations/ 内 ${n_mig} 个迁移文件；应用启动时须自动应用尚未执行的迁移（§5.2）"
else
    warn "未找到 deploy/migrations/ —— §3.1/§5.2 要求版本化迁移随包交付，否则库结构变更无迹可循；且本次回滚将无法覆盖库结构变化"
fi

run "${DOCKER[@]}" load -i "$TAR"

# 【强制】确认导入后确实换上了新镜像：tag 不匹配 / 贴错包会导致「更新成功但仍在跑旧版本」
if [ "$DRY_RUN" = 0 ]; then
    IMG_ID_AFTER="$("${DOCKER[@]}" image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
    [ -n "$IMG_ID_AFTER" ] || die "导入后镜像 $IMAGE 不存在：交付包的 tag 与 PROJECT_NAME（$PROJECT_NAME）不一致"
    if [ -n "$IMG_ID_BEFORE" ] && [ "$IMG_ID_BEFORE" = "$IMG_ID_AFTER" ]; then
        if [ "$ALLOW_SAME_IMAGE" = 1 ]; then
            warn "镜像 ID 未变化（$IMG_ID_AFTER）：按 --allow-same-image 继续重放同一版本"
        else
            die "镜像 ID 未变化（$IMG_ID_AFTER）：交付包可能仍是当前版本，已中止以免「更新成功但仍在跑旧版本」；确认要重放同一版本请加 --allow-same-image"
        fi
    else
        log "镜像已更新：${IMG_ID_BEFORE:-（首次导入）} → $IMG_ID_AFTER"
    fi
fi

run "${DOCKER[@]}" compose up -d --force-recreate

# 容器重建后 IP 可能变化；网关若仍是 upstream 块写法不会自动跟随，必须 reload（规范 §4.2）
if [ "$DRY_RUN" = 0 ]; then
    IP_AFTER="$("${DOCKER[@]}" inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$CONTAINER" 2>/dev/null || true)"
    if [ -n "$IP_BEFORE" ] && [ "$IP_BEFORE" != "$IP_AFTER" ]; then
        warn "容器 IP 已变化：${IP_BEFORE}→${IP_AFTER}"
        echo "  若网关配置仍是 upstream 块写法，请让运维立即执行："
        echo "    ${DOCKER_SHOW} exec ${GATEWAY_NAME} nginx -t && ${DOCKER_SHOW} exec ${GATEWAY_NAME} nginx -s reload"
        echo "  （改用 resolver + 变量 proxy_pass 的站点配置可自动跟随，见模板 deploy/gateway-site.conf）"
    fi
fi

# ---------- 阶段 4：健康校验（失败则回滚） ----------
log "== 阶段 4/5：健康校验（最长 ${HEALTH_TIMEOUT}s）=="

if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] 轮询 $CONTAINER 健康状态；失败则从快照 $BAK_DIR 回滚："
    log "[dry-run]   ${DOCKER[*]} load -i ${ROLLBACK_IMG:-<无备份>}"
    log "[dry-run]   cp -p ${BAK_DIR}/docker-compose.yml ./docker-compose.yml"
    log "[dry-run]   ${DOCKER[*]} compose up -d --force-recreate"
    log "[dry-run]   再次健康校验，并向告警通道上报"
else
    if ! wait_healthy; then
        alert "更新后健康检查未通过（镜像包 $(basename "$TAR")）"
        "${DOCKER[@]}" compose logs --tail=50 || true

        if [ "$DO_ROLLBACK" = 1 ] && [ -n "$ROLLBACK_IMG" ]; then
            log "== 开始回滚：恢复快照 $BAK_DIR =="
            warn "数据库迁移不随镜像回滚：新版本若已执行不兼容的迁移，旧镜像仍可能起不来（§5.2 expand-contract 即为此）"
            "${DOCKER[@]}" load -i "$ROLLBACK_IMG"
            # 编排文件与镜像同属一次交付，必须一起回滚，否则会留下「旧镜像 + 新编排」的混合态
            if [ -f "${BAK_DIR}/docker-compose.yml" ]; then
                cp -p "${BAK_DIR}/docker-compose.yml" ./docker-compose.yml
                log "已还原编排文件：docker-compose.yml"
            else
                warn "快照中没有 docker-compose.yml，编排保持现状"
            fi
            "${DOCKER[@]}" compose up -d --force-recreate
            if wait_healthy; then
                alert "已回滚到更新前版本（镜像 + docker-compose.yml），服务恢复正常。请排查新镜像后重新发布"
                echo "  注意：.env 未自动还原。如需一并回退："
                echo "    cp -p ${BAK_DIR}/.env ./.env && chmod 600 .env && ${DOCKER_SHOW} compose up -d --force-recreate"
                exit 2
            fi
            alert "回滚后服务仍不健康，需人工立即介入！容器：$CONTAINER"
            exit 3
        fi

        warn "未执行自动回滚（自动回滚=$DO_ROLLBACK，快照镜像=${ROLLBACK_IMG:-无}）"
        alert "更新失败且未回滚，服务可能不可用，需人工介入！"
        exit 3
    fi
fi

# ---------- 阶段 5：清理旧镜像与过期快照 ----------
log "== 阶段 5/5：清理旧镜像与过期快照（保留最近 ${KEEP} 个）=="
if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] 删除被替换掉的旧镜像 ${IMG_ID_BEFORE:-<无>}（悬空镜像会持续占用磁盘）"
    log "[dry-run] 删除 backups/ 中超出 ${KEEP} 个的快照目录"
else
    # 共享服务器磁盘共管：删掉本次被替换的旧镜像，避免 <none> 悬空镜像累积
    if [ -n "$IMG_ID_BEFORE" ] && [ "$IMG_ID_BEFORE" != "${IMG_ID_AFTER:-}" ]; then
        if "${DOCKER[@]}" image rm "$IMG_ID_BEFORE" >/dev/null 2>&1; then
            log "已清理被替换的旧镜像：$IMG_ID_BEFORE"
        else
            warn "旧镜像 $IMG_ID_BEFORE 清理失败（可能仍被引用）；可人工检查： ${DOCKER_SHOW} image ls -f dangling=true"
        fi
    fi

    if [ "$KEEP" -eq 0 ]; then
        warn "--keep 0：将删除 backups/ 中全部快照（之后无法自动回滚）"
    fi
    ls -1dt backups/*/ 2>/dev/null | tail -n +$(( KEEP + 1 )) | while read -r d; do
        [ -n "$d" ] && { log "删除过期快照：$d"; rm -rf -- "$d"; }
    done

    # 旧版（v2.1 之前）的平铺备份不会被上面的逻辑清理，只提示，避免误删
    shopt -s nullglob
    legacy=(backups/.env.* backups/"${PROJECT_NAME}"-app.*.tar)
    shopt -u nullglob
    if [ "${#legacy[@]}" -gt 0 ]; then
        warn "检测到旧版平铺备份 ${#legacy[@]} 个（backups/.env.* / backups/*.tar）：本版改用时间戳快照目录，旧文件不会被自动清理，请人工确认后删除"
    fi
fi

log "===== 更新成功 ====="
cat <<EOF

摘要：
  新镜像     : ${IMAGE}（来自 $(basename "$TAR")）
  快照目录   : ${BAK_DIR}（.env + docker-compose.yml + 镜像包 + MANIFEST）

验收：
  ${DOCKER_SHOW} compose ps
  ${DOCKER_SHOW} inspect --format '{{.State.Health.Status}}' ${CONTAINER}
  curl -s -H 'Host: ${SITE_DOMAIN:-<SITE_DOMAIN>}' http://127.0.0.1/api/v1/health

如需回滚到更新前版本：
  ${DOCKER_SHOW} load -i ${ROLLBACK_IMG:-<快照中的镜像包>}
  cp -p ${BAK_DIR}/docker-compose.yml ./docker-compose.yml
  ${DOCKER_SHOW} compose up -d --force-recreate
  # .env 未自动还原；如需一并回退： cp -p ${BAK_DIR}/.env ./.env && chmod 600 .env
  # 数据库不在回滚范围内：库结构只会前滚，不会退回。若本次含破坏性迁移，
  # 需由运维从 backups/ 或库备份恢复（见 §6.4 卸载与数据留存）。

EOF

exit 0
