CREATE TABLE IF NOT EXISTS roles (
  user_id CHAR(36) NOT NULL,
  role    VARCHAR(64) NOT NULL,
  PRIMARY KEY (user_id, role)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
