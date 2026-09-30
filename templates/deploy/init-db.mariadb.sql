-- 依据：内网 B/S 架构开发规范 v2.9 §3.3
-- 用途：在共享 MariaDB 中为项目创建库与账号。
--       正常由运维执行；开发与运维同一人兼任时用 DB_PROVISION=auto 让 init.sh 代劳。
--
-- 【强制】**不要手改本文件**。下面的 __DB_DATABASE__ / __DB_USERNAME__ / __DB_PASSWORD__ 是
--        **渲染哨兵**：手改成真实值后，init.sh 的自动渲染（或下面 B 的手工渲染）就不再匹配，
--         结果是"建了 A 库、应用却连 B 库" —— 正是本文件要防的事。
-- 【强制】三个哨兵必须与 .env 的 DB_DATABASE / DB_USERNAME / DB_PASSWORD 一致。
-- 【强制】渲染方式（二选一；**绝不要把口令写进命令行**：ps 与 shell history 都会泄漏）：
--   A. 让 init.sh 代劳：.env 里设 DB_PROVISION=auto（脚本会随机生成 DB_PASSWORD 并写回 .env）
--   B. 手工渲染 + 用 defaults-file 传 root 凭证：
--        sed -e "s|__DB_DATABASE__|$DB_DATABASE|g" \
--            -e "s|__DB_USERNAME__|$DB_USERNAME|g" \
--            -e "s|__DB_PASSWORD__|$DB_PASSWORD|g" deploy/init-db.mariadb.sql > /tmp/init-db.sql
--        install -m600 /dev/null /tmp/.my.cnf
--        printf '[client]\nuser=root\npassword=%s\n' "$ROOT_PW" > /tmp/.my.cnf
--        docker cp /tmp/.my.cnf mariadb:/tmp/.my.cnf
--        docker cp /tmp/init-db.sql mariadb:/tmp/init-db.sql
--        docker exec mariadb sh -c 'mysql --defaults-extra-file=/tmp/.my.cnf < /tmp/init-db.sql; rc=$?; rm -f /tmp/.my.cnf /tmp/init-db.sql; exit $rc'
--        rm -f /tmp/.my.cnf /tmp/init-db.sql
-- 【强制】字符集必须为 utf8mb4（规范 S6）
-- 注意：本文件由运维直接用 mysql 执行，**不经过** backend/app/migrate.py，
--       因此不适用"迁移文件禁止存储过程"的限制。

CREATE DATABASE IF NOT EXISTS `__DB_DATABASE__`
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_unicode_ci;

-- 幂等：存在则改口令，不存在则创建
CREATE USER IF NOT EXISTS '__DB_USERNAME__'@'%' IDENTIFIED BY '__DB_PASSWORD__';
ALTER  USER '__DB_USERNAME__'@'%' IDENTIFIED BY '__DB_PASSWORD__';

GRANT ALL PRIVILEGES ON `__DB_DATABASE__`.* TO '__DB_USERNAME__'@'%';
FLUSH PRIVILEGES;

-- ---------- 校验 ----------
SHOW CREATE DATABASE `__DB_DATABASE__`;
SELECT user, host FROM mysql.user WHERE user = '__DB_USERNAME__';
