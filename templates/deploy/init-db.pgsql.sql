-- 依据：内网 B/S 架构开发规范 v2.8 §3.3
-- 用途：在共享 PostgreSQL 中为项目创建库与账号（pgsql 待运维部署）。
--
-- 【强制】**不要手改本文件**。下面的 __DB_DATABASE__ / __DB_USERNAME__ / __DB_PASSWORD__ 是
--        **渲染哨兵**：手改成真实值后，init.sh 的自动渲染（或下面 B 的手工渲染）就不再匹配，
--         结果是"建了 A 库、应用却连 B 库" —— 正是本文件要防的事。
-- 【强制】三个哨兵必须与 .env 的 DB_DATABASE / DB_USERNAME / DB_PASSWORD 一致。
-- 【强制】渲染方式（二选一；**绝不要把口令写进命令行**）：
--   A. 让 init.sh 代劳：.env 里设 DB_PROVISION=auto（pg 分支用 .pgpass 传凭证）
--   B. 手工渲染 + 用 .pgpass 传凭证：
--        sed -e "s|__DB_DATABASE__|$DB_DATABASE|g" \
--            -e "s|__DB_USERNAME__|$DB_USERNAME|g" \
--            -e "s|__DB_PASSWORD__|$DB_PASSWORD|g" deploy/init-db.pgsql.sql > /tmp/init-db.sql
--        printf '*:*:*:postgres:%s\n' "$ROOT_PW" > /tmp/.pgpass && chmod 600 /tmp/.pgpass
--        docker cp /tmp/.pgpass pgsql:/tmp/.pgpass
--        docker cp /tmp/init-db.sql pgsql:/tmp/init-db.sql
--        docker exec pgsql sh -c 'chmod 600 /tmp/.pgpass; PGPASSFILE=/tmp/.pgpass psql -U postgres -v ON_ERROR_STOP=1 -f /tmp/init-db.sql; rc=$?; rm -f /tmp/.pgpass /tmp/init-db.sql; exit $rc'
--        rm -f /tmp/.pgpass /tmp/init-db.sql
--
-- 注意 1：本文件由运维直接用 psql 执行，**不经过** backend/app/migrate.py，因此允许 DO $$ 块。
-- 注意 2：`CREATE DATABASE` 不能在事务/DO 块中执行；库已存在时会报错，
--         而 `ON_ERROR_STOP=1` 会立即中止（后面的 GRANT 不会执行）——重复执行前请先确认库不存在。
-- 注意 3：若扩展（如 pg_trgm/uuid-ossp）在 template1 中不可用，
--         请改用 `CREATE DATABASE ... TEMPLATE template0` 并单独 `CREATE EXTENSION`。

-- ---------- 1. 账号（幂等）----------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '__DB_USERNAME__') THEN
        ALTER ROLE __DB_USERNAME__ WITH LOGIN PASSWORD '__DB_PASSWORD__';
    ELSE
        CREATE ROLE __DB_USERNAME__ WITH LOGIN PASSWORD '__DB_PASSWORD__';
    END IF;
END
$$;

-- ---------- 2. 数据库 ----------
CREATE DATABASE __DB_DATABASE__
  OWNER __DB_USERNAME__
  ENCODING 'UTF8'
  LC_COLLATE 'C'
  LC_CTYPE 'C'
  TEMPLATE template0;

GRANT ALL PRIVILEGES ON DATABASE __DB_DATABASE__ TO __DB_USERNAME__;

-- ---------- 3. schema 权限（PG 15+ 起 public schema 默认不再对所有人可写）----------
\connect __DB_DATABASE__
GRANT ALL ON SCHEMA public TO __DB_USERNAME__;

-- ---------- 校验 ----------
\l __DB_DATABASE__
\du __DB_USERNAME__
