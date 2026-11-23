# Contract changes

- 2026-11-23: Pigeon v1, `WorkoutApi` + `WorkoutEvents` (live session, export share, native counters). Lane A.
- 2026-11-23: `HostInfo` gains `release`, `notificationsEnabled`, `batterySaver`; `GymHostApi.openNotificationSettings()` (Diagnostics, plan 6.2 banner). Additive. Native lane, with its Kotlin implementation.
- Planned v1.1 (additive, cut 2): service-to-Dart action events for lock-screen Done / +1 rep / Skip rest (WorkoutActionReceiver); Kotlin applies Done and Dart resyncs from the rev. Binary export (zip) would need a bytes variant of shareFile.
- 2026-11-23: session_snapshot schema 1, pre-merge (PR #7, t5z; t5v acked each round): added set keys `plan_load_g`, `plan_reps` (after `kind`); added top-level `set_ready_at_ms`, `next_set_n`, `swaps` (after `ended_at_ms`); strict decode on both sides; encoding pins (U+2028/2029/DEL raw, lone surrogates, no doubles); cut-2 `block` keys (t61). Nothing had shipped, so `schema` stays 1. Lane t5z.
