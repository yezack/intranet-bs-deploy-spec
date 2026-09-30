-- 依据：内网 B/S 架构开发规范 v2.6 §3.3
-- 用途：由运维在共享 MariaDB 中为项目创建库与账号（开发方不直接操作共享数据库）
-- 执行方式（**不要把 root 口令写进命令行**：`ps` 与 shell history 都会泄漏）：
--   1) 推荐：让 init.sh 代劳 —— 在 .env 里设 DB_PROVISION=auto，
--      它会按 DB_DATABASE/DB_USERNAME 建库建号，并随机生成 DB_PASSWORD 写回 .env。
--   2) 手工：用 defaults-file 传凭证
--        install -m600 /dev/null /tmp/.my.cnf
--        printf '[client]\nuser=root\npassword=%s\n' "$ROOT_PW" > /tmp/.my.cnf
--        docker cp /tmp/.my.cnf mariadb:/tmp/.my.cnf
--        docker cp init-db.mariadb.sql mariadb:/tmp/init-db.sql
--        docker exec mariadb sh -c 'mysql --defaults-extra-file=/tmp/.my.cnf < /tmp/init-db.sql; rc=$?; rm -f /tmp/.my.cnf /tmp/init-db.sql; exit $rc'
--        rm -f /tmp/.my.cnf
--
-- 【强制】库名 / 用户名 / 口令必须与项目 .env 中
--         DB_DATABASE / DB_USERNAME / DB_PASSWORD 完全一致
-- 【强制】示例值 myapp_db / myapp_user 必须替换为你的 <项目>_db / <项目>_user
-- 【强制】执行前把下面的 CHANGE_ME_STRONG_PASSWORD 换成真实强口令
-- 【强制】字符集必须为 utf8mb4（规范 S6）

CREATE DATABASE IF NOT EXISTS `myapp_db`
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_unicode_ci;

-- 幂等：存在则改口令，不存在则创建
CREATE USER IF NOT EXISTS 'myapp_user'@'%' IDENTIFIED BY 'CHANGE_ME_STRONG_PASSWORD';
ALTER  USER 'myapp_user'@'%' IDENTIFIED BY 'CHANGE_ME_STRONG_PASSWORD';

GRANT ALL PRIVILEGES ON `myapp_db`.* TO 'myapp_user'@'%';
FLUSH PRIVILEGES;

-- ---------- 校验 ----------
SHOW CREATE DATABASE `myapp_db`;
SELECT user, host FROM mysql.user WHERE user = 'myapp_user';
