# Release notes

Dogfood releases. The version label is `version:` in pubspec.yaml; API and contract changes are in
packages/gym_engine/API_CHANGES.md and contracts/CHANGES.md.

## 0.3.0

- Starting weights: Gyms > Set starting weights (or the button on an empty Today) lists the lifts
  your next push, pull and legs sessions use at that gym first, then every other loaded lift there. Type what you lift now, once; the first
  session of that lift starts there. Once you log it, your history takes over (delete that history
  and it falls back). Not a workout: no PBs, streak or history. Export and import carry them.
  The first set logged from a starting weight counts as a cold start (like a first time with no
  weight), so the one-tap rate still measures only the app's own suggestions; the same holds for
  Done on the lock screen.
- Reorder during a workout: "Do later" moves the current exercise to just after the next one (machine
  taken), and the order list now starts with the current exercise so you can drag it anywhere. Sets
  you already logged stay with their exercise, the rest timer keeps running, and the new order
  survives the app being killed. Lock-screen Done follows the new current exercise.
- Rest screen: change the next set's reps and weight while you rest. The rest screen has its own
  colour now (it used to match Pull days).
- Screen stays on during an active workout; it goes back to normal on pause, finish or discard.
- Gyms: rename and delete a gym. History from a deleted gym stays (shown as "Deleted gym"). A gym
  with a paused workout can't be deleted until you finish or discard it.
- Plate maths (barbell lifts): Gyms > Bar & plates (shows once a barbell or plates are ticked) sets your bar and the plate pairs you have; the
  live screen shows what goes on each side, and the app never suggests a load your plates can't make.
- Timers (ON): EMOM and interval blocks cue from the phone's own scheduler, so they keep time with
  the screen off and the app in the background. Proven on emulators (20 of 20 cues in a 20-minute
  screen-off run, under 60 ms late); not yet on your Pixel, so please run the 20-minute screen-off
  EMOM check and send the Diagnostics export.
- Health Connect: Diagnostics > Health Connect sends finished workouts to Health Connect (strength
  training; Engine sessions go as HIIT), so Body Age can use them. Off until you turn it on;
  "Send past workouts" sends your history and imported workouts. Edits and deletes follow.
- Typed weights: a weight you typed still counts as typed after the app restarts, and Done on the
  lock screen for a set you typed counts as typed (not as a one-tap on the app's suggestion).
- Swap: when a swap can't happen as asked, it says whether the exercise moved or the swap failed.
- New app icon: a barbell in the Run Supreme colours (works with themed icons).
- App size: about 360 KB larger (Health Connect library), in every build.

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
