CREATE TABLE IF NOT EXISTS wing_schedules (
  schedule_id  CHAR(36)     PRIMARY KEY,
  schedule_key VARCHAR(128) NOT NULL UNIQUE,
  next_run_at  DATETIME(3)  NOT NULL,
  last_run_at  DATETIME(3)  NULL,
  updated_at   DATETIME(3)  NOT NULL DEFAULT (UTC_TIMESTAMP(3))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
