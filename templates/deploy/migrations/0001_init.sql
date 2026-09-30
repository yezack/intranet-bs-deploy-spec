-- ============================================================================
-- 0001_init.sql —— 初始表结构（**示例**，按项目替换）
-- 内网 B/S 架构开发规范 v2.9 §3.1 / §3.6 / §5.2：版本化数据库迁移
--
-- 【必须三方言通用】同一份文件要在 sqlite（本地开发）/ MariaDB 10.11 /
-- PostgreSQL 三种 DB_ENGINE 上都能执行（规范 §3.6）。因此：
--   * 不用 AUTO_INCREMENT / SERIAL  —— 主键是应用生成的 UUID 字符串，三方言一致
--   * 不用 DATETIME / TIMESTAMP     —— 时间统一存 BIGINT 毫秒（无时区歧义、无 2038 问题）
--   * 所有语句都是 CREATE ... IF NOT EXISTS，重复执行安全（规范 §5.1 幂等）
--
-- 【前后兼容（expand-contract，规范 §5.2 强制）】
-- 本文件是**追加式**的：新版本只允许新增 0002_*.sql、0003_*.sql……
-- 已发布的迁移文件**不得修改**（别人的库已经执行过，改了不会重跑，只会让新老环境结构不一致）。
-- 删除列/表必须分两次发布：先停用（代码不再读写），隔一个版本再删。
-- 这样 update.sh 的健康检查失败回滚到旧镜像时，旧代码仍能读新结构。
--
-- 应用启动时由 backend/app/migrate.py 自动执行，已执行版本记录在 schema_migrations 表。
--
-- 注意：SQL 会被按最朴素的 `;` 切分执行，**不要**写存储过程/触发器（含内嵌分号会被切坏）。
-- ============================================================================

-- ---------------------------------------------------------------- 用户（示例）
CREATE TABLE IF NOT EXISTS users (
    id            VARCHAR(36)  NOT NULL,   -- UUID4（应用生成）
    username      VARCHAR(32)  NOT NULL,   -- 3~20 位，字母/数字/下划线/连字符
    password_hash VARCHAR(255) NOT NULL,   -- 例：pbkdf2_sha256$迭代次数$盐hex$散列hex
    created_at_ms BIGINT       NOT NULL,   -- 注册时间（UTC 毫秒）
    last_login_ms BIGINT       NULL,       -- 最近一次成功登录（UTC 毫秒）
    PRIMARY KEY (id)
);

-- 用户名唯一。注意 MariaDB 的 utf8mb4_unicode_ci 默认**不区分大小写**，
-- 而 sqlite 默认区分；**应用层必须统一**（例如入库前统一转小写，见规范 §3.6），
-- 否则同一条注册请求在本地与内网会得到不同结果。
CREATE UNIQUE INDEX IF NOT EXISTS ux_users_username ON users (username);

-- ---------------------------------------------------------------- 业务表示例
-- 演示外键与复合索引的写法（同样只用三方言通用语法）
CREATE TABLE IF NOT EXISTS items (
    id            VARCHAR(36) NOT NULL,    -- UUID4
    user_id       VARCHAR(36) NOT NULL,    -- → users.id
    title         VARCHAR(200) NOT NULL,
    payload       TEXT         NULL,       -- TEXT 三方言通用；长度超大的内容放这里
    created_at_ms BIGINT       NOT NULL,   -- UTC 毫秒
    PRIMARY KEY (id),
    CONSTRAINT fk_items_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

-- 常用查询：按用户 + 时间倒排
CREATE INDEX IF NOT EXISTS ix_items_user_created ON items (user_id, created_at_ms);
