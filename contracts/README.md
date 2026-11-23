# Contracts

Cross-language and cross-lane contracts for Gym Supreme. Lane A (integrator) lands changes here.

| File | What | Author | Consumers |
|---|---|---|---|
| `session_snapshot.md` | Live-session snapshot schema v1: Pigeon payload = journal line = finish payload | gym1-engine (Dart types + fixtures) | WorkoutService (Kotlin mirror), gym_engine, UI |
| `../pigeons/platform_api.dart` | Flutter/Kotlin channel (`WorkoutApi`, `WorkoutEvents`, `GymHostApi`) | lane A | all |

Fixtures: `android/core/src/test/fixtures/contract/*.json` are byte-identical copies of
`packages/gym_engine/test/fixtures/contract/*.json`; CI diffs them.

Rules: after schema v1 and engine API v0 merge, changes are additive only. A breaking change
needs a ping to lane A and every consumer, a `schema_version` bump and a line in `CHANGES.md`.
