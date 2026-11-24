# Release notes

Dogfood releases. The version label is `version:` in pubspec.yaml; API and contract changes are in
packages/gym_engine/API_CHANGES.md and contracts/CHANGES.md.

## 0.2.2

- Lock screen: Done, +1 rep and Skip rest buttons on the workout notification (feature flag
  `lockdone`). Done and +1 rep are not offered on timed sets, blocks, sets with no rep target, or a
  loaded lift with no target weight.
- Import from file: Diagnostics > Import reads an export from another phone (or this one). It shows
  what will be added before anything is written, and it never overwrites or brings back workouts
  already on this phone, including ones you deleted. Your gyms and settings are kept (settings are
  filled in only on a fresh install).
- Clock jumps: an imported workout whose end is before its start (the phone clock stepped back
  during the session) is imported with duration 0 instead of refusing the whole file. The import
  dialogs say how many workouts this applied to.
