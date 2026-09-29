#!/usr/bin/env bash
# ---------- 行尾自检 ----------
if grep -q $'\r' "$0"; then printf '[EOL] 错误：%s 含 CRLF 行尾。修复： sed -i "s/\\r$//" "%s"\n' "$0" "$0" >&2; exit 1; fi  # EOL guard

#USAGE-BEGIN
# 现场验收脚本 —— 内网 B/S 架构开发规范 v2.3 §6.3
#
# 用法： cd /home/docker/<项目名> && bash tools/verify.sh [--help]
#   读同目录的 .env，逐项检查 §6.3 的 15 项验收要点，输出 PASS / WARN / FAIL。
#
# 退出码： 0 无 FAIL（可能有 WARN，需人工确认） | 1 存在 FAIL | 127 解释器不可用（脚本为 CRLF 行尾时）
#USAGE-END

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename -- "$0")"
cd "$SCRIPT_DIR/.." || exit 1          # tools/ 的上一级 = 项目根目录

usage() {
    awk '/^#USAGE-BEGIN$/{p=1;next} /^#USAGE-END$/{p=0} p' "$SELF" | sed 's/^# \{0,1\}//'
    exit 0
}

for a in "$@"; do
    case "$a" in
        --help|-h) usage ;;
        *) echo "未知参数：$a（用 --help 查看用法）" >&2; exit 1 ;;
    esac
done

n_pass=0; n_warn=0; n_fail=0
ok()   { n_pass=$((n_pass + 1)); printf '  [PASS] %s\n' "$*"; }
bad()  { n_fail=$((n_fail + 1)); printf '  [FAIL] %s\n' "$*"; }
warn() { n_warn=$((n_warn + 1)); printf '  [WARN] %s\n' "$*"; }
info() { printf '  [ -- ] %s\n' "$*"; }
sec()  { printf '\n== %s ==\n' "$*"; }

if [ ! -f .env ]; then
    echo "错误：当前目录没有 .env。请在 /home/docker/<项目名>/ 下执行： bash tools/verify.sh" >&2
    exit 1
fi

# 与 init.sh / update.sh 保持同一读取方式（.env 的值受 §3.3 字符集约束）
set -a
# shellcheck disable=SC1091
. ./.env
set +a

PROJECT_NAME="${PROJECT_NAME:-}"
[ -n "$PROJECT_NAME" ] || { echo "错误：.env 中缺少 PROJECT_NAME" >&2; exit 1; }
IMAGE="${PROJECT_NAME}-app:latest"
CONTAINER="${PROJECT_NAME}-app"
# 对外域名来自 .env 的 APP_DOMAIN（开发阶段确认、运维分配），不再假定 <项目名>.lan
DOMAIN="${APP_DOMAIN:-}"
if [ -z "$DOMAIN" ]; then
    warn "APP_DOMAIN 未配置：第 4-5/14-15 项无法用正确的 Host 头访问网关（见 §4.2）"
fi

if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
else
    echo "错误：无法访问 docker daemon（需 root 或可用的 sudo）。" >&2
    exit 1
fi

printf '现场验收：%s（项目 %s）\n' "$(pwd)" "$PROJECT_NAME"
command -v curl >/dev/null 2>&1 || warn "未找到 curl，HTTP 相关检查将跳过"

# ---------- 1 ----------
sec "1. 镜像 tag"
if "${DOCKER[@]}" image inspect "$IMAGE" >/dev/null 2>&1; then ok "$IMAGE 存在"; else bad "缺少镜像 $IMAGE"; fi

# ---------- 2 ----------
sec "2. 宿主端口映射"
ports="$("${DOCKER[@]}" ps --filter "name=^/${CONTAINER}$" --format '{{.Ports}}' 2>/dev/null || true)"
if [ -z "$ports" ]; then ok "PORTS 列为空（无宿主端口映射）"; else bad "存在宿主端口映射：$ports"; fi

# ---------- 3 ----------
sec "3. 健康状态"
health="$("${DOCKER[@]}" inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
if [ "$health" = "healthy" ]; then ok "healthy"; else bad "健康状态 = ${health}（期望 healthy）"; fi

# ---------- 4 / 5 ----------
sec "4-5. 网关与前端可达（经 127.0.0.1 + Host 头）"
if command -v curl >/dev/null 2>&1; then
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN" "http://127.0.0.1/api/v1/health" || true)"
    [ "$code" = "200" ] && ok "网关 /api/v1/health → 200" || bad "网关 /api/v1/health → ${code:-无响应}"
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN" "http://127.0.0.1/" || true)"
    [ "$code" = "200" ] && ok "前端 / → 200" || bad "前端 / → ${code:-无响应}"
else
    warn "无 curl，跳过 4-5"
fi

# ---------- 6 ----------
sec "6. 网络接入"
nets="$("${DOCKER[@]}" inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$CONTAINER" 2>/dev/null || true)"
case "$nets" in
    *gateway-network*) ok "已接入 gateway-network（当前：$nets）" ;;
    *) bad "未接入 gateway-network（当前：${nets:-无}）" ;;
esac

# ---------- 7 ----------
sec "7. 配置外置（.env → 容器环境变量）"
if "${DOCKER[@]}" inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null | grep -qx "PROJECT_NAME=${PROJECT_NAME}"; then
    ok "容器环境变量来自 .env"
else
    bad "容器环境变量中没有 PROJECT_NAME=${PROJECT_NAME}（env_file 未生效？）"
fi

# ---------- 7b ----------
sec "7b. 数据库引擎（DB_ENGINE）"
case "${DB_ENGINE:-}" in
    mariadb|pgsql)
        ok "DB_ENGINE=${DB_ENGINE}（连共享库）" ;;
    sqlite)
        bad "DB_ENGINE=sqlite —— 内网部署不允许：容器 read_only 且无持久卷，数据会随容器丢失（违反 S2，见 §3.6）" ;;
    *)
        bad "DB_ENGINE 缺失或非法（当前 ${DB_ENGINE:-<空>}）；只允许 sqlite / mariadb / pgsql，其中 sqlite 仅限本地开发（见 §3.6）" ;;
esac

# ---------- 8 ----------
sec "8. 敏感信息"
perm="$(stat -c '%a' .env 2>/dev/null || echo '?')"
[ "$perm" = "600" ] && ok ".env 权限 600" || bad ".env 权限为 ${perm}（期望 600）"
if [ -n "${DB_PASSWORD:-}" ]; then
    rc=0
    found="$("${DOCKER[@]}" run --rm --entrypoint sh "$IMAGE" -c "grep -rlsF '$DB_PASSWORD' /app /frontend" 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        bad "镜像内能搜到 DB_PASSWORD 明文：$found"
    elif [ "$rc" -eq 1 ]; then
        ok "镜像内未搜到 DB_PASSWORD 明文"
    else
        warn "镜像内搜索未能执行（rc=$rc），请人工确认未硬编码口令"
    fi
fi

# ---------- 9 ----------
sec "9. 离线自包含"
info "前端产物外域引用由构建机的 tools/preflight.sh 第 7 组负责；断网启动请在首次部署时演练"

# ---------- 10 ----------
sec "10. 日志输出"
if [ -n "$("${DOCKER[@]}" logs --tail 5 "$CONTAINER" 2>&1 || true)" ]; then
    ok "docker logs 有输出"
else
    bad "docker logs 无输出"
fi

# ---------- 11 ----------
sec "11. 时区 / 编码"
tz="$("${DOCKER[@]}" exec "$CONTAINER" date +%z 2>/dev/null || true)"
[ "$tz" = "+0800" ] && ok "容器 date +%z = +0800" || bad "容器 date +%z = ${tz:-未知}（期望 +0800）"
info "数据库字符集请用 SHOW CREATE DATABASE 确认是 utf8mb4（库由运维维护）"

# ---------- 12 ----------
sec "12. 脚本与备份"
for f in init.sh update.sh; do
    [ -x "$f" ] && ok "$f 存在且可执行" || bad "$f 缺失或无 exec 位"
done
[ -f tools/preflight.sh ] && ok "tools/preflight.sh 随包交付" || warn "缺少 tools/preflight.sh"
[ -d backups ] && ok "backups/ 已存在" || warn "backups/ 尚未创建（首次升级后由 update.sh 生成）"
info "「init.sh 可重复执行 / update.sh 能备份与回滚」无法在验收时自动验证，请在交付演练中确认（见 §5）"

# ---------- 13 ----------
sec "13. 资源限额"
mem="$("${DOCKER[@]}" inspect --format '{{.HostConfig.Memory}}' "$CONTAINER" 2>/dev/null || true)"
pids="$("${DOCKER[@]}" inspect --format '{{.HostConfig.PidsLimit}}' "$CONTAINER" 2>/dev/null || true)"
[ "$mem" = "536870912" ] && ok "内存限额 512M" || bad "内存限额 = ${mem:-未知}（期望 536870912）"
[ "$pids" = "256" ] && ok "pids 限额 256" || warn "pids 限额 = ${pids:-未知}（期望 256）"

# ---------- 14 ----------
sec "14. 防串站（多项目共用一台机时最易出的问题）"
if command -v curl >/dev/null 2>&1; then
    # 用 RFC 2606 保留域名 .invalid：它永远不可能出现在 conf.d 里，与项目域名无关
    code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: no-such-host.invalid' "http://127.0.0.1/" || true)"
    if [ "$code" != "200" ]; then
        ok "未知域名被拒绝（HTTP ${code:-无响应}）"
    else
        bad "未知域名也返回 200 —— 网关缺少 default_server 兜底，存在串站风险（见 §4.3）"
    fi
else
    warn "无 curl，跳过 14"
fi

# ---------- 15 ----------
sec "15. 域名解析"
if [ -z "$DOMAIN" ]; then
    warn "APP_DOMAIN 未配置，跳过域名解析检查（见 §4.2）"
elif command -v getent >/dev/null 2>&1 && getent hosts "$DOMAIN" >/dev/null 2>&1; then
    ok "$DOMAIN 可解析：$(getent hosts "$DOMAIN" | head -n1)"
else
    warn "$DOMAIN 在本机解析不到；多人使用必须由运维在内网 DNS 加 A 记录；单机模拟验证可在 /etc/hosts 写「<虚拟机 IP>  $DOMAIN」（见 §4.3）"
fi

# ---------- 汇总 ----------
printf '\n结果：PASS=%d  WARN=%d  FAIL=%d\n' "$n_pass" "$n_warn" "$n_fail"
if [ "$n_fail" -eq 0 ]; then
    printf '验收通过（WARN 项请人工确认）。\n'
    exit 0
fi
printf '存在 %d 项 FAIL，修正后重跑。\n' "$n_fail" >&2
exit 1
