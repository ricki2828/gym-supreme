# Contract changes

- 2026-11-23: Pigeon v1, `WorkoutApi` + `WorkoutEvents` (live session, export share, native counters). Lane A.
- 2026-11-23: `HostInfo` gains `release`, `notificationsEnabled`, `batterySaver`; `GymHostApi.openNotificationSettings()` (Diagnostics, plan 6.2 banner). Additive. Native lane, with its Kotlin implementation.
- 2026-11-23: `GymHostApi.takeLaunchCommand()` (CI e2e; the `gym_e2e` launch extra, once; dogfood/debug only, null on play). Additive. Native lane.
- Planned v1.1 (additive, cut 2): service-to-Dart action events for lock-screen Done / +1 rep / Skip rest (WorkoutActionReceiver); Kotlin applies Done and Dart resyncs from the rev. Binary export (zip) would need a bytes variant of shareFile.
- 2026-11-23: session_snapshot schema 1, pre-merge (PR #7, t5z; t5v acked each round): added set keys `plan_load_g`, `plan_reps` (after `kind`); added top-level `set_ready_at_ms`, `next_set_n`, `swaps` (after `ended_at_ms`); strict decode on both sides; encoding pins (U+2028/2029/DEL raw, lone surrogates, no doubles); cut-2 `block` keys (t61). Nothing had shipped, so `schema` stays 1. Lane t5z.
- 2026-11-23: `block.run` added (additive, cut 2; t61 + t5v); Kotlin dedup key becomes (set_id, run, index). Session.undo keeps `run`. Lane t5z (PR #17).
- 2026-11-23: refusal code `io_error` (real I/O failure, e.g. deleteJournal), native counter `journal_delete_failed` (#19). Additive. Lane A doc, native lane code.
- 2026-11-23: `GymHostApi.requestNotificationPermission()` (@async bool; POST_NOTIFICATIONS on API 33+, notificationsEnabled below; refusal code `already_pending`). Additive. Native lane.
- 2026-11-24: `GymHostApi.pickImportFile()` (@async String?; I1 import). ACTION_OPEN_DOCUMENT, no permission; returns the file text (strict UTF-8) or null on cancel / activity gone; refusal codes `already_pending`, `too_large` (over 16 MiB), `io_error`. Logcat `import_pick_shown`, `import_pick` (result picked|cancelled|too_large|io_error|no_picker|activity_gone). Additive. Lane E/U (I1).
