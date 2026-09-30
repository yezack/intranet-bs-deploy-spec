#!/usr/bin/env bash
# ---------- 行尾自检 ----------
if grep -q $'\r' "$0"; then printf '[EOL] 错误：%s 含 CRLF 行尾。修复： sed -i "s/\\r$//" "%s"\n' "$0" "$0" >&2; exit 1; fi  # EOL guard

#USAGE-BEGIN
# 现场验收脚本 —— 内网 B/S 架构开发规范 v2.9 §6.3
#
# 用法： cd /home/docker/<项目名> && bash tools/verify.sh [--drill] [--help]
#   读同目录的 .env，逐项检查 §6.3 的 15 项验收要点，输出 PASS / WARN / FAIL。
#   --drill  额外做一次**升级演练**：真跑 ./update.sh --allow-same-image，
#            覆盖「备份 → 重建 → 健康校验」全路径（会重建容器，属主动操作；默认不做）。
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

DRILL=0     # 【必须在参数解析之前】初始化：v2.6 把它放在参数循环之后，`--drill` 会被这行覆盖成死开关
for a in "$@"; do
    case "$a" in
        --drill)   DRILL=1; shift ;;
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
# 对外域名来自 .env 的 SITE_DOMAIN（开发阶段确认、运维分配），不再假定 <项目名>.lan。
# 【与 init.sh 同口径】未配置时**不允许静默继续**：直接判 FAIL，并跳过依赖域名的检查项。
# 否则第 4/5 项会拿空 Host 头去请求，给出"看起来通过"的错误结论（规范 §4.2 / §6.3）。
DOMAIN="${SITE_DOMAIN:-}"
DOMAIN_OK=1
if [ -z "$DOMAIN" ]; then
    DOMAIN_OK=0
    bad "SITE_DOMAIN 未配置：验收第 4/5/15 项无法判定（init.sh 会直接报错，见 §4.2）"
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
# 判据是**真正的宿主端口绑定**（HostConfig.PortBindings），不是 `docker ps` 的 PORTS 列——
# 两者不等价：Dockerfile 里的 `EXPOSE 80`（模板就有）会让 PORTS 列显示 "80/tcp"，
# 那只是"声明容器内监听"，并没有发布到宿主（`docker port` 为空、PortBindings 为 {}）。
# 规范 §3.2 禁止的是 compose 里的 `ports:`，即真正把容器端口发布到宿主。
# 按 PORTS 列判会与模板 Dockerfile 自相矛盾、永远 FAIL，故此处以 PortBindings 为准判据。
sec "2. 宿主端口映射"
bindings="$("${DOCKER[@]}" inspect --format '{{json .HostConfig.PortBindings}}' "$CONTAINER" 2>/dev/null || true)"
ports="$("${DOCKER[@]}" ps --filter "name=^/${CONTAINER}$" --format '{{.Ports}}' 2>/dev/null || true)"
case "$bindings" in
    ""|"{}"|"null")
        if [ -z "$ports" ]; then
            ok "无宿主端口映射（PortBindings 为空，PORTS 列也为空）"
        else
            ok "无宿主端口绑定（PortBindings 为空）；PORTS 列的 ${ports} 只是 Dockerfile 的 EXPOSE 声明，未发布到宿主"
        fi ;;
    *)
        bad "存在宿主端口映射：$bindings" ;;
esac

# ---------- 3 ----------
sec "3. 健康状态"
health="$("${DOCKER[@]}" inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
if [ "$health" = "healthy" ]; then ok "healthy"; else bad "健康状态 = ${health}（期望 healthy）"; fi

# ---------- 4 / 5 ----------
sec "4-5. 网关与前端可达（经 127.0.0.1 + Host 头）"
# 只判 HTTP 200 会**假 PASS**：Host 被路由到别的项目同样返回 200。
# 因此第 4 项必须校验响应体里的项目身份（后端 health 必须回传 project 字段，见 §3.5 S8）。
if ! command -v curl >/dev/null 2>&1; then
    warn "无 curl，跳过 4-5"
elif [ "$DOMAIN_OK" != 1 ]; then
    info "跳过 4-5：SITE_DOMAIN 未配置（已在上面判 FAIL）"
else
    body="$(curl -s -H "Host: $DOMAIN" "http://127.0.0.1/api/v1/health" || true)"
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN" "http://127.0.0.1/api/v1/health" || true)"
    if [ "$code" != "200" ]; then
        bad "网关 /api/v1/health → ${code:-无响应}（期望 200）"
    elif printf '%s' "$body" | grep -q "\"project\":\"${PROJECT_NAME}\""; then
        ok "网关 /api/v1/health → 200，且响应体 project=${PROJECT_NAME}（确认打到本项目）"
    else
        bad "网关 /api/v1/health → 200，但响应体里没有 project=${PROJECT_NAME}：Host 可能被路由到别的项目（响应体前 120 字节：$(printf '%s' "$body" | head -c 120)）"
    fi
    # 第 5 项：静态可达（项目身份已由第 4 项确认），这里只要求返回 HTML
    body="$(curl -s -H "Host: $DOMAIN" "http://127.0.0.1/" || true)"
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN" "http://127.0.0.1/" || true)"
    if [ "$code" = "200" ] && printf '%s' "$body" | grep -qi '<html'; then
        ok "前端 / → 200 且返回 HTML"
    else
        bad "前端 / → ${code:-无响应}，或响应体不像 HTML（前 80 字节：$(printf '%s' "$body" | head -c 80)）"
    fi
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
# 运行期零公网依赖：对**已经构建进镜像的前端产物**再验一次（镜像才是最终交付物；
# 构建机的 tools/preflight.sh 第 7 组只管构建目录，两者判据一致）。
ext="$("${DOCKER[@]}" run --rm --entrypoint sh "$IMAGE" -c "grep -rIlE '(src|href|url|import).{0,20}https?://' /frontend 2>/dev/null" || true)"
if [ -z "$ext" ]; then
    ok "镜像内 /frontend 未发现外域资源引用"
else
    bad "镜像内 /frontend 存在外域资源引用（断网会失效）：$(printf '%s' "$ext" | head -n 3 | tr '\n' ' ')"
fi
info "断网演练（无法自动判定）：在测试机断开外网后重启容器，确认服务正常且日志无外网请求超时"

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
if [ "$DRILL" = 1 ]; then
    # 升级演练：同镜像重放（--allow-same-image），覆盖 备份 → 重建 → 健康校验 全路径。
    info "开始升级演练：./update.sh --allow-same-image（会重建容器）"
    # 判据用「最新快照是否变了」，不能用「数量是否增加」：
    # update.sh 默认 --keep 5，稳态机器上新快照会顶掉最旧的，总数不变（用数量判会永久假 FAIL）。
    before_newest="$(ls -1d backups/*/ 2>/dev/null | sort | tail -n1)"
    marker="$(mktemp)"      # 时间戳兜底：防同一秒内新旧目录名相同
    sleep 1
    if ./update.sh --allow-same-image >/tmp/verify-drill.log 2>&1; then
        after_newest="$(ls -1d backups/*/ 2>/dev/null | sort | tail -n1)"
        if [ -n "$after_newest" ] && { [ "$after_newest" != "$before_newest" ] || [ "$after_newest" -nt "$marker" ]; }; then
            ok "升级演练通过（退出码 0），并产生了新备份快照：${before_newest:-<无>} → $after_newest"
        else
            bad "升级演练退出码 0，但 backups/ 没有产生新快照（最新仍是 ${after_newest:-<无>}）—— update.sh 的备份步骤可能已失效"
        fi
        rm -f "$marker"
    else
        rm -f "$marker"
        bad "升级演练失败（日志 /tmp/verify-drill.log 末尾）：$(tail -n 3 /tmp/verify-drill.log 2>/dev/null | tr '\n' ' ')"
    fi
else
    info "「update.sh 能备份与回滚」可脚本化验证：bash tools/verify.sh --drill（会真跑一次同镜像升级；不加 --drill 时只做上面的存在性检查）"
fi

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
# 只判「有输出」会**假 PASS**：解析到 198.18.0.54（RFC2544 保留段）或合成 AAAA 都算"有输出"。
# 正确判据：解析到**本机地址**（本项目就部署在这台 VM 上，见 §2.1/§4.3）。
if [ "$DOMAIN_OK" != 1 ]; then
    info "跳过 15：SITE_DOMAIN 未配置（已在上面判 FAIL）"
elif ! command -v getent >/dev/null 2>&1; then
    warn "无 getent，跳过域名解析检查"
else
    ips="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    local_ips="$( { hostname -I 2>/dev/null; ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1; } | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    if [ -z "$ips" ]; then
        if getent ahosts "$DOMAIN" >/dev/null 2>&1; then
            bad "$DOMAIN 只解析到非 IPv4 地址（可能是合成 AAAA）：$(getent ahosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
        else
            bad "$DOMAIN 在本机解析不到；多人使用必须由运维在内网 DNS 加 A 记录；单机模拟可在 /etc/hosts 写「<虚拟机 IP>  $DOMAIN」（见 §4.3）"
        fi
    else
        hit=""
        for ip in $ips; do
            case " $local_ips " in *" $ip "*) hit="$ip"; break ;; esac
        done
        if [ -n "$hit" ]; then
            ok "$DOMAIN 解析到本机地址 $hit（本机地址：$local_ips）"
        else
            bad "$DOMAIN 解析到 $ips，但都不是本机地址（本机：${local_ips:-未知}）——请求会打到别处（见 §4.3）"
        fi
    fi
fi

# ---------- 汇总 ----------
printf '\n结果：PASS=%d  WARN=%d  FAIL=%d\n' "$n_pass" "$n_warn" "$n_fail"
if [ "$n_fail" -eq 0 ]; then
    printf '验收通过（WARN 项请人工确认）。\n'
    exit 0
fi
printf '存在 %d 项 FAIL，修正后重跑。\n' "$n_fail" >&2
exit 1
