CREATE TABLE IF NOT EXISTS credentials (
  credential_id CHAR(36) PRIMARY KEY,
  secret_hash   CHAR(64) NOT NULL,
  user_id       CHAR(36) NOT NULL,
  issue_at      BIGINT UNSIGNED NOT NULL,
  expire_at     BIGINT UNSIGNED NULL,
  UNIQUE INDEX (secret_hash),
  INDEX (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
