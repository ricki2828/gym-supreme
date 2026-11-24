# Session snapshot, schema 1

Owner of the text: t5z (engine); approved by t5t and t5v. Dart: `packages/gym_engine/lib/src/snapshot.dart`. Kotlin twin: `android/core` (t5v).

One JSON object, used three ways: the Pigeon event payload, one journal line (fsync per line, torn tail ignored), and the finish payload.

## Canonical encoding (both sides must produce the same bytes)
- One line, no whitespace, no trailing newline inside the value (journal adds `\n`).
- Keys in exactly the order below. `null` is written out, never omitted. The one exception is the optional set key `entry` (0.3): written last in the set, and only when it has a value.
- Integers only (grams, ms). Booleans `true`/`false`.
- Strings: raw UTF-8 for non-ASCII (no `\uXXXX` for printable text). Escape `"` `\\`, and `\b \f \n \r \t`; other control chars < 0x20 as `\u00xx` (lowercase hex). `/` is not escaped. **U+2028, U+2029 and DEL (0x7f) are written raw** (the fresh fixture's name has both). A lone surrogate is written `\udxxx` (lowercase); writers should never produce one. (This is Dart's `jsonEncode`, checked 23-Nov.)
- **No floating-point numbers anywhere, including inside `block`.** Dart writes `1.0` for a double; every number in the snapshot is an integer (ms, grams, counts).
- **Strict decode, both sides:** every key above is required, present even when `null` (Dart enforces key presence; absent ≠ null); unknown enum values (`state`, `kind`, `completion`, `source`) are rejected; `paused_at_ms` is non-null exactly when `state` is `paused`; `completion` and `source` are non-null exactly when the set is `done`. Unknown extra keys are ignored. Optional keys (see `entry`) may be absent; absent = not recorded.
- Fixtures: `snapshot_v1_{fresh,resting,mid_set,paused,finished,typed}.json` (one canonical line + `\n`) and `journal_v1_torn_tail.jsonl` (3 whole lines + half a line; the reader returns line 3; the half line is a torn tail (not corrupt)). Kotlin is the journal reader of record: `readPendingJournal` returns its last good line; a Dart `readJournal` is for tests only. Corrupt = a whole line before the last that does not parse, or one with another uuid or a non-rising rev (skipped). Byte-identical in `packages/gym_engine/test/fixtures/contract/` and `android/core/src/test/fixtures/contract/`. The finished fixture has a name with an en dash and a quote on purpose.

## Top level
| key | type | notes |
|---|---|---|
| schema | int | 1. Readers refuse a higher value. |
| workout_uuid | string | UUID v4, set at start |
| rev | int | Written by Dart into every snapshot it sends: 0 at start, baseRev + 1 at submit. The service validates it (`bad_snapshot` on mismatch, `stale_rev` on a stale baseRev) and stores it as sent. Resume never calls startSession: readPendingJournal → rev R → submit (rev R+1, baseRev R). |
| app_version | string | |
| gym_id | string | |
| type_id | string\|null | push, pull, legs, core, engine |
| muscles | string[] | picked muscle ids |
| started_at_ms | int | UTC wall ms |
| tz_offset_min | int | local offset at start |
| state | "active"\|"paused" | `paused` requires an int `paused_at_ms` (decode refuses otherwise) |
| paused_at_ms | int\|null | set while paused |
| paused_total_ms | int | folded in on resume, on Done while paused, and on finish while paused |
| rest | object\|null | see below |
| finished | bool | |
| ended_at_ms | int\|null | set on finish |
| set_ready_at_ms | int\|null | when the current set became ready: start, rest end (set at Done), skipped rest, extended rest end, resume; an undo of the set whose rest is running restores it to that set's start. A Done while paused resumes first, so that set has zero length (paused time is never set time) |
| next_set_n | int\|null | next set id number; ids are never reused. Decode rejects a value ≤ the highest `<uuid>:n` present. Null only in lines written before this field: derive from the highest id |
| swaps | int | exercises swapped out this session (plan 3 gate); 0 at start |
| exercises | object[] | in current order (drag reorder changes it) |

## rest
`{set_id, ends_at_wall_ms, duration_ms}`. The set whose Done started it. Kotlin re-anchors to elapsedRealtime on receipt. Null when skipped, on pause, on finish, and after the last pending set.

## exercises[]
`exercise_id, name (as logged), load_kind (dumbbell|stack|barbell|bodyweight|timed|...), unilateral (bool), rest_s (int), rep_lo (int|null), rep_hi (int|null), sets[]`.

## sets[]
`set_id, set_ordinal, kind (reps|timed), plan_load_g, plan_reps, target_load_g, target_reps, state (pending|done|skipped), load_g, reps, completion, source, started_at_ms, ended_at_ms, offset_ms, block`.
- `set_id` = `<workout_uuid>:<n>`, n unique and never reused within a workout.
- `set_ordinal` 1-based within its exercise; closes up when a pending set is removed.
- plan_* = the engine's prefill, fixed when the set is created; never changed by +/-.
- target_* = what Done (app or lock screen) will log untouched; +/- moves these. `target_load_g` null = cold start or plain bodyweight.
- completion (done only): `tap_unchanged | adjusted | typed | cold_start`; null for pending and skipped (also in storage and export). Judged against what was SHOWN (0.2): per field, the plan_* value or the value carried from the lift's last logged (done) set of the same kind. `cold_start` if a loaded kind (dumbbell/stack/barbell) had `plan_load_g` null and no earlier done set of that lift logged a load (from any source, lock screen included); else `tap_unchanged` if source is lockscreen or each logged value equals plan or the last logged set's value; else `adjusted` (`typed` only when the UI says so). Known edges (accepted for 0.2, no shown_* field yet): a +/- landing exactly on the last logged value counts as `tap_unchanged`; a value carried from a set later skipped or undone is judged against the plan.
- Carry-forward (0.2): a changed target or logged value moves to later pending sets of the same lift that have the same plan_* and still hold the old target; null never carries; timed sets do not carry.
- source (done only): `app | lockscreen`. A lock-screen Done is `tap_unchanged`.
- `offset_ms` = ended_at − started_at_ms(workout) − paused_total_ms (R6 ghost key).
- `started_at_ms` of a set = `set_ready_at_ms` capped at now (so rest, skipped rest and paused time are not set time; R2 joins HR by these times).
- `block`: object|null, timer blocks (R4). Stored as `set_row.block_json`. Keys below.
- `entry` (**optional**, 0.3 X1; schema stays 1): `"typed"` when his reps or load for this set were typed on the number pad, so Done logs `completion: typed` after a pause, a restart and Resume (it used to be per controller and logged `adjusted`). Written last in the set and only when set; absent in every journal written before 0.3 and for sets never typed. Dart decode reads it as optional (an unknown value reads as absent); Kotlin ignores it (extra key; a lock-screen Done still logs `tap_unchanged` and keeps the key as it copies the set). Kept after Done, cleared by undo. `snapshot_v1_typed.json` carries it; the five 0.2-shaped fixtures do not and must keep decoding.

### `block` — cut-2 additive keys (t61 + t5v, 23-Nov; producer gym_engine/lib/src/cut2/timers.dart)
All optional; absent = cut-1 behaviour. Canonical bytes: Kotlin keeps `block` keys in the order Dart wrote them (pass-through, no re-sort). Kotlin plays any unknown cue `kind` as the default cue.
- Definition: `type` (emom|amrap|interval), `work_ms` (EMOM period / interval work), `rest_ms`, `rounds`, `cap_ms` (AMRAP), `lead_in_ms` (get-ready before the block), `warn_ms` (AMRAP warning before cap).
- `run` (int ≥ 0; absent = 0): the block's arming generation. Kotlin's durable dedup key is (set_id, run, index), not (set_id, index). Dart bumps `run` by 1 on every re-arm: replacing a block's definition, an explicit reset, and an undo of a done or skipped timed set. Start, pause and resume keep `run`, so a cue already fired in this run stays suppressed (the resume grace relies on this). Kotlin may forget the dedup entries of a set's older runs once it sees a higher `run`.
- `Session.undo` of a timed set keeps `run` and the Definition keys; it drops only run state and results (`started_at_wall_ms` → null, `elapsed_before_ms` → 0, `cues` → [], result keys removed). TimerSession.undo (cut 2) then re-arms with `run + 1` and the full cue list in the same rev.
- Run: `started_at_wall_ms` (int|null; null until Start; the lead-in start), `elapsed_before_ms` (block time already run before this anchor; 0 fresh).
- `cues`: [{`index`, `at_ms`, `kind`, `label`}] sorted by at_ms. `at_ms` = offset from `started_at_wall_ms`. `index` is stable for the block's lifetime: a resume snapshot drops cues more than 1000 ms behind elapsed_before_ms; one within that grace is resent at at_ms 0 (Kotlin's durable set_id+index dedup makes it harmless, so block_end is never lost); the rest are rebased, keeping index. Kotlin fires each (set_id, run, index) at most once. Kinds: go, emom_minute, interval_work, interval_rest, amrap_warn, block_end.
- Pause: Kotlin clears the block timer. Dart's pause snapshot sets `started_at_wall_ms` null, `elapsed_before_ms` = the frozen elapsed time, `cues` []. Dart's resume snapshot carries the new anchor + remaining cues.
- Result (written by Dart when the set is Done): `round_marks_ms` (int[], offsets from block start, lead-in excluded, ascending), `amrap_rounds` (int|null), `amrap_extra_reps` (int|null), `stopped_at_ms` (int|null, early stop, offset from block start).
- Timed rows stay out of load volume and the one-tap rate; they still light their muscles (R4).


## Current set
The first `pending` set in exercise order. The notification shows its exercise, `set_ordinal` of the exercise's set count, and target load × reps.

## Kotlin-side transitions (cut 1: Done/rest/etc. come from Dart)
Kotlin applies only finish stamping: `finished=true`, `rev+1`, `rest=null`, `ended_at_ms` if null, **and if `state=="paused"`: `paused_total_ms += now - paused_at_ms`, `paused_at_ms=null`, `state="active"`** (matches Dart `Session.finish`). Preferred path in cut 1: Dart submits `Session.finish(...)` itself, then `finishSession()` fsyncs and returns it unchanged.

## Kotlin-side transitions (v1.1, cut L1: lock screen, flag `lockdone`)
Done, +1 rep and Skip rest from the notification, applied by `android/core/.../session/LockReducer.kt` to the journal head and journalled as rev + 1, only while the session service runs (never started from the lock screen) and only when the tap's rev is still the head. Each is the twin of a Dart transition: Done = `Session.done(setId, nowMs, source: lockscreen)` (logs the targets; `cold_start` wins over `tap_unchanged`; does not finish on the last set); +1 rep = `Session.retarget(reps: max(1, target + 1))` with carry-forward; Skip rest = `Session.skipRest`. Refused (no-op) when paused or finished, for a non-pending or unknown set, and for Done / +1 on a timed set, a set with a `block`, null target reps, or a loaded lift with null target load. Shared vectors `lockscreen_v1_*.json` ({case, before, steps, after}) are generated from Dart by `tool/gen_contract_fixtures.dart`; Kotlin must reproduce the bytes.

## Changes
Additive only after C2. A breaking change: hc ping t5t + affected lanes and a line in `contracts/CHANGES.md`; bump `schema`.
