CREATE TABLE IF NOT EXISTS users (
  id            CHAR(36) PRIMARY KEY,
  name          VARCHAR(255) NOT NULL,
  username      VARCHAR(255) NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
