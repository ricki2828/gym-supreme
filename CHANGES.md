# Release notes

Dogfood releases. The version label is `version:` in pubspec.yaml; API and contract changes are in
packages/gym_engine/API_CHANGES.md and contracts/CHANGES.md.

## Unreleased (0.3.0)

- Starting weights: Gyms > Set starting weights (or the button on an empty Today) lists the lifts
  your next push, pull and legs sessions use at that gym first, then every other loaded lift there. Type what you lift now, once; the first
  session of that lift starts there. Once you log it, your history takes over (delete that history
  and it falls back). Not a workout: no PBs, streak or history. Export and import carry them.

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
