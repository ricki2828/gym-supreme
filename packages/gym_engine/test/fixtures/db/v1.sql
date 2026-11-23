-- Schema v1 (APK 0.1) with sample rows. Never edit: R7 install-over fixture.
CREATE TABLE gym (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  preset_id TEXT,
  created_at_ms INTEGER NOT NULL
);
CREATE TABLE gym_item (
  gym_id TEXT NOT NULL REFERENCES gym(id) ON DELETE CASCADE,
  equipment_id TEXT NOT NULL,
  source TEXT NOT NULL CHECK (source IS NOT NULL AND source IN ('preset','manual','scan')),
  confirmed INTEGER NOT NULL CHECK (confirmed IN (0,1)),
  weights_g TEXT NOT NULL DEFAULT '[]',
  PRIMARY KEY (gym_id, equipment_id)
);
CREATE TABLE setting (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE workout (
  uuid TEXT PRIMARY KEY,
  gym_id TEXT NOT NULL,
  type_id TEXT,
  muscles TEXT NOT NULL DEFAULT '[]',
  started_at_ms INTEGER NOT NULL,
  tz_offset_min INTEGER NOT NULL,
  ended_at_ms INTEGER NOT NULL,
  paused_ms INTEGER NOT NULL DEFAULT 0,
  app_version TEXT NOT NULL DEFAULT '',
  snapshot_json TEXT
);
CREATE INDEX workout_started ON workout(started_at_ms);
CREATE TABLE set_row (
  set_id TEXT PRIMARY KEY,
  workout_uuid TEXT NOT NULL REFERENCES workout(uuid) ON DELETE CASCADE,
  gym_id TEXT NOT NULL,
  exercise_id TEXT NOT NULL,
  exercise_name TEXT NOT NULL,
  exercise_position INTEGER NOT NULL,
  set_ordinal INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK (kind IS NOT NULL AND kind IN ('reps','timed')),
  load_g INTEGER,
  reps INTEGER,
  completion TEXT NOT NULL CHECK (completion IS NOT NULL AND completion IN ('tap_unchanged','adjusted','typed','cold_start')),
  skipped INTEGER NOT NULL CHECK (skipped IN (0,1)),
  source TEXT NOT NULL CHECK (source IS NOT NULL AND source IN ('app','lockscreen')),
  started_at_ms INTEGER,
  ended_at_ms INTEGER,
  offset_ms INTEGER,
  block_json TEXT
);
CREATE INDEX set_ghost ON set_row(gym_id, exercise_id, workout_uuid);
CREATE INDEX set_workout ON set_row(workout_uuid);
CREATE TABLE hr_sample (
  workout_uuid TEXT NOT NULL REFERENCES workout(uuid) ON DELETE CASCADE,
  t_ms INTEGER NOT NULL,
  bpm INTEGER NOT NULL,
  PRIMARY KEY (workout_uuid, t_ms)
);
INSERT INTO gym VALUES ('g1','Condo gym','condo',1795400000000);
INSERT INTO gym_item VALUES ('g1','dumbbells','preset',1,'[2000,4000,22500]');
INSERT INTO setting VALUES ('settings','{"bodyweight_g":80000,"default_minutes":45,"rest_compound_s":120,"rest_isolation_s":75}');
INSERT INTO workout VALUES ('3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b','g1','push','["chest"]',1795400000000,480,1795400800000,60000,'0.1.0+1',NULL);
INSERT INTO set_row VALUES ('3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b:0','3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b','g1','dumbbell-bench-press','Dumbbell Bench Press',0,1,'reps',22500,10,'tap_unchanged',0,'app',1795400000000,1795400095000,95000,NULL);
INSERT INTO hr_sample VALUES ('3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b',1795400001000,118);
PRAGMA user_version = 1;
