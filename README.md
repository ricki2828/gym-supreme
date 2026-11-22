# Gym Supreme

Local-only Android strength log (Flutter + a thin Kotlin service). Phase 0: repo, CI, signing,
theme package, Pigeon skeleton and the lock-screen spike.

## Layout

| Path | What | Owner (phase 0) |
|---|---|---|
| `lib/` | App | A, then B for `lib/spike/` |
| `packages/supreme_ui` | Theme copied from Run Supreme plus LIT tokens | A |
| `packages/gym_engine` | Pure Dart engine and exercise data | C |
| `android/app` | Android app; Gradle config is A's, Kotlin sources B's | A / B |
| `android/core` | Pure Kotlin: journal codec, timers, HR parse (standalone Gradle build) | B |
| `pigeons/` | Flutter/Kotlin channel contract; generated output committed | A |
| `tools/` | CI and emulator scripts | A |

## Rules

- No INTERNET, location or Health Connect permission; CI fails the build if one appears.
- No Gradle on the dev host: builds run in CI only.
- Public repo: run `tools/install_hooks.sh` once per clone (pre-push secret scan). Never commit a
  keystore, `local.properties` or `.env`.
- Pigeon: `dart run pigeon --input pigeons/platform_api.dart`, commit the output.
- Contract fixtures in `android/core/src/test/fixtures/contract` are copied to
  `packages/gym_engine/test/fixtures/contract`; CI fails on drift.
- Every PR goes through `ci-gate` plus a different-engine review before merge.

## CI

`.github/workflows/ci.yml`: secret scan, analyze/test/Pigeon drift, core tests, debug APK + lint,
signed dogfood APK with permission gate, emulator smoke on API 29/33/34/36, install-over of build
N on N-1 (API 36). Main publishes the phone APK to the prerelease `dogfood-latest`.
