-- 依据：内网 B/S 架构开发规范 v2.7 §3.3
-- 用途：由运维在共享 PostgreSQL 中为项目创建库与账号（pgsql 待运维部署）
-- 执行方式（**不要把 root 口令写进命令行**：`ps` 与 shell history 都会泄漏）：
--   1) 推荐：让 init.sh 代劳 —— 在 .env 里设 DB_PROVISION=auto（pg 分支用 .pgpass 传凭证）。
--   2) 手工：用 .pgpass 传凭证
--        printf '*:*:*:postgres:%s\n' "$ROOT_PW" > /tmp/.pgpass && chmod 600 /tmp/.pgpass
--        docker cp /tmp/.pgpass pgsql:/tmp/.pgpass
--        docker cp init-db.pgsql.sql pgsql:/tmp/init-db.sql
--        docker exec pgsql sh -c 'chmod 600 /tmp/.pgpass; PGPASSFILE=/tmp/.pgpass psql -U postgres -v ON_ERROR_STOP=1 -f /tmp/init-db.sql; rc=$?; rm -f /tmp/.pgpass /tmp/init-db.sql; exit $rc'
--        rm -f /tmp/.pgpass
--
-- 【强制】库名 / 用户名 / 口令必须与项目 .env 中
--         DB_DATABASE / DB_USERNAME / DB_PASSWORD 完全一致
-- 【强制】示例值 myapp_db / myapp_user 必须替换为你的 <项目>_db / <项目>_user
-- 【强制】执行前把下面的 CHANGE_ME_STRONG_PASSWORD 换成真实强口令
-- 注意：若扩展（如 pg_trgm/uuid-ossp）在 template1 中不可用，
--       请改用 CREATE DATABASE ... TEMPLATE template0 并单独 CREATE EXTENSION

-- ---------- 1. 账号（幂等）----------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'myapp_user') THEN
        ALTER ROLE myapp_user WITH LOGIN PASSWORD 'CHANGE_ME_STRONG_PASSWORD';
    ELSE
        CREATE ROLE myapp_user WITH LOGIN PASSWORD 'CHANGE_ME_STRONG_PASSWORD';
    END IF;
END
$$;

-- ---------- 2. 数据库 ----------
-- CREATE DATABASE 不能在事务/DO 块中执行；若库已存在会报错，可忽略该提示
CREATE DATABASE myapp_db
  OWNER myapp_user
  ENCODING 'UTF8'
  LC_COLLATE 'C'
  LC_CTYPE 'C'
  TEMPLATE template0;

GRANT ALL PRIVILEGES ON DATABASE myapp_db TO myapp_user;

-- ---------- 3. schema 权限（PG 15+ 起 public schema 默认不再对所有人可写）----------
\connect myapp_db
GRANT ALL ON SCHEMA public TO myapp_user;

-- ---------- 校验 ----------
\l myapp_db
\du myapp_user
