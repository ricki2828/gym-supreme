# Contract changes

- 2026-11-23: Pigeon v1, `WorkoutApi` + `WorkoutEvents` (live session, export share, native counters). Lane A.
- 2026-11-23: `HostInfo` gains `release`, `notificationsEnabled`, `batterySaver`; `GymHostApi.openNotificationSettings()` (Diagnostics, plan 6.2 banner). Additive. Native lane, with its Kotlin implementation.
- Planned v1.1 (additive, cut 2): service-to-Dart action events for lock-screen Done / +1 rep / Skip rest (WorkoutActionReceiver); Kotlin applies Done and Dart resyncs from the rev. Binary export (zip) would need a bytes variant of shareFile.
