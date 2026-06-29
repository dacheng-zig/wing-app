CREATE TABLE IF NOT EXISTS credentials (
  credential_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
  secret_hash   CHAR(64) NOT NULL,
  user_id       BIGINT UNSIGNED NOT NULL,
  issue_at      BIGINT UNSIGNED NOT NULL,
  expire_at     BIGINT UNSIGNED NULL,
  UNIQUE INDEX (secret_hash),
  INDEX (user_id)
) ENGINE=InnoDB
