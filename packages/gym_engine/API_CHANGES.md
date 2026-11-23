# gym_engine API changes

API v0 (C1, 23-Nov-2026): `lib/src/api.dart` (`GymApi` + view types), `GymEngine` over `HistoryStore` (`MemoryStore` fake; `SqliteStore` follows), `Session` transitions, `SessionSnapshot` schema 1.

Breaking changes after C1 are listed here, newest first, with an hc ping to t5t and the UI lane.

## Additive (PR #9)
- `SqliteStore` (`package:gym_engine/sqlite_store.dart`), `HistoryStore.setting/saveSetting`, `HistoryStore.hrSamples`.
- `SnapshotSet.copyWith(block:)`, `Session.replaceSet(s, setId, f)` for cut-2 timers (t61).
