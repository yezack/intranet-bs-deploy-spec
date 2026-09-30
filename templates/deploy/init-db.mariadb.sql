-- 依据：内网 B/S 架构开发规范 v2.4 §3.3
-- 用途：由运维在共享 MariaDB 中为项目创建库与账号（开发方不直接操作共享数据库）
-- 执行：docker exec -i mariadb mysql -uroot -p'<root密码>' < init-db.mariadb.sql
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
