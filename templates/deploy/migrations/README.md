# 数据库迁移（deploy/migrations/）

规范依据：§3.1 交付物清单、§3.6 跨方言 DDL 取舍、§5.2 update.sh 行为契约。

## 约定

| 项 | 约定 |
|---|---|
| 文件名 | `NNNN_描述.sql`（如 `0001_init.sql`），**按文件名字典序执行** |
| 版本号 | 文件名去掉 `.sql`，例如 `0001_init` |
| 执行时机 | **应用启动时自动执行**（`backend/app/migrate.py`，FastAPI lifespan） |
| 记录位置 | 库内 `schema_migrations` 表（`version` / `applied_at_ms`） |
| 幂等 | 已记录的版本不会重复执行；重复执行 `init.sh` 安全 |
| 事务 | 每个文件一个事务：失败时该文件整体不生效，不留半截结构 |
| 三方言 | 同一份 SQL 必须能在 **sqlite / MariaDB / PostgreSQL** 上执行（§3.6） |
| 容器内路径 | Dockerfile 执行 `COPY deploy/migrations /app/migrations`，本目录是唯一权威来源 |

因此 `init.sh` 与 `update.sh` **不需要**任何迁移步骤：换镜像 → 容器启动 → 自动前滚。

## 新增迁移的三条硬规则

1. **已发布的文件不得修改。** 别人的库已经执行过，改了不会重跑，只会让新老环境结构不一致。
   要改就新增 `0002_xxx.sql`。
2. **必须前后兼容（expand-contract）。** `update.sh` 在健康检查失败时会回滚到**旧镜像**，
   而数据库**不会**回滚。所以：
   - 新增列/表 → 先发布迁移，再在下个版本让代码使用它；
   - 删除列/表 → 先让代码停用，隔一个版本再删。
   否则回滚后的旧代码会读到一个自己不认识的结构。
3. **只用三方言都认识的语法。** 不要用 `AUTO_INCREMENT` / `SERIAL`（主键是应用生成的 UUID）、
   不要用 `DATETIME`（用 `BIGINT` 毫秒）、不要写含内嵌分号的存储过程/触发器
   （`migrate.py` 只做朴素的 `;` 切分）。

## 与启动预算的关系（§3.5 S9）

`migrate.py` 的启动重试上限（默认 **10 × 3s = 30s**）必须**小于** compose 的
`healthcheck.start_period`（模板 **60s**）；否则启动期探活先失败，容器会带着"其实正在正常迁移"
的状态被判 unhealthy，进而让 `update.sh` 误回滚。

## 手工执行（排障用）

应用会自动执行，正常不需要手工跑。需要手工介入时，**不要把口令写进命令行**
（`ps` 与 shell history 都会泄漏），用 defaults-file 传凭证：

```bash
# MariaDB
install -m600 /dev/null /tmp/.my.cnf
printf '[client]\nuser=root\npassword=%s\n' "$ROOT_PW" > /tmp/.my.cnf
docker cp /tmp/.my.cnf mariadb:/tmp/.my.cnf
docker cp deploy/migrations/0001_init.sql mariadb:/tmp/m.sql
docker exec mariadb sh -c 'mysql --defaults-extra-file=/tmp/.my.cnf < /tmp/m.sql; rc=$?; rm -f /tmp/.my.cnf /tmp/m.sql; exit $rc'
rm -f /tmp/.my.cnf

# PostgreSQL（用 .pgpass，同样不进命令行）
printf '*:*:*:postgres:%s\n' "$ROOT_PW" > /tmp/.pgpass && chmod 600 /tmp/.pgpass
docker cp /tmp/.pgpass pgsql:/tmp/.pgpass
docker cp deploy/migrations/0001_init.sql pgsql:/tmp/m.sql
docker exec pgsql sh -c 'PGPASSFILE=/tmp/.pgpass psql -U postgres -v ON_ERROR_STOP=1 -f /tmp/m.sql; rc=$?; rm -f /tmp/.pgpass /tmp/m.sql; exit $rc'
rm -f /tmp/.pgpass
```

执行后记得**同步补一条** `schema_migrations` 记录，否则应用启动时会尝试重放
（由于全部是 `IF NOT EXISTS`，重放通常无害，但会让版本表与真实情况不一致）。
