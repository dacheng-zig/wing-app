CREATE TABLE IF NOT EXISTS wing_jobs (
  job_id        CHAR(36) PRIMARY KEY,
  kind          VARCHAR(128)      NOT NULL,
  queue         VARCHAR(64)       NOT NULL DEFAULT 'default',
  state         ENUM('available','running','retryable',
                     'completed','cancelled','discarded')
                                  NOT NULL DEFAULT 'available',
  priority      TINYINT           NOT NULL DEFAULT 0,
  args          JSON              NOT NULL,
  attempt       SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  max_attempts  SMALLINT UNSIGNED NOT NULL DEFAULT 20,
  errors        JSON              NULL,
  unique_key    VARBINARY(32)     NULL,
  unique_keep   TINYINT(1)        NOT NULL DEFAULT 0,
  scheduled_at  DATETIME(3)       NOT NULL,
  attempted_at  DATETIME(3)       NULL,
  attempted_by  VARCHAR(128)      NULL,
  finalized_at  DATETIME(3)       NULL,
  created_at    DATETIME(3)       NOT NULL DEFAULT (UTC_TIMESTAMP(3)),

  KEY idx_fetch  (state, queue, priority, scheduled_at, job_id),
  KEY idx_rescue (state, attempted_at),
  KEY idx_prune  (state, finalized_at),
  UNIQUE KEY uq_wing_jobs_unique_key (unique_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
