# Session snapshot, schema 1

Owner of the text: t5z (engine); approved by t5t and t5v. Dart: `packages/gym_engine/lib/src/snapshot.dart`. Kotlin twin: `android/core` (t5v).

One JSON object, used three ways: the Pigeon event payload, one journal line (fsync per line, torn tail ignored), and the finish payload.

## Canonical encoding (both sides must produce the same bytes)
- One line, no whitespace, no trailing newline inside the value (journal adds `\n`).
- Keys in exactly the order below. `null` is written out, never omitted.
- Integers only (grams, ms). Booleans `true`/`false`.
- Strings: raw UTF-8 for non-ASCII (no `\uXXXX` for printable text). Escape `"` `\\`, and `\b \f \n \r \t`; other control chars < 0x20 as `\u00xx` (lowercase hex). `/` is not escaped. (This is Dart's `jsonEncode`.)
- Fixtures: `snapshot_v1_{fresh,resting,mid_set,paused,finished}.json` (one canonical line + `\n`) and `journal_v1_torn_tail.jsonl` (3 whole lines + half a line; the reader returns line 3 and counts 1 corrupt). Byte-identical in `packages/gym_engine/test/fixtures/contract/` and `android/core/src/test/fixtures/contract/`. The finished fixture has a name with an en dash and a quote on purpose.

## Top level
| key | type | notes |
|---|---|---|
| schema | int | 1. Readers refuse a higher value. |
| workout_uuid | string | UUID v4, set at start |
| rev | int | 0 at start. Each submit: baseRev = current, new rev = base + 1. Kotlin is the authority; stale → `stale_rev`. Resume never calls startSession: readPendingJournal → rev R → submit (rev R+1, baseRev R). |
| app_version | string | |
| gym_id | string | |
| type_id | string\|null | push, pull, legs, core, engine |
| muscles | string[] | picked muscle ids |
| started_at_ms | int | UTC wall ms |
| tz_offset_min | int | local offset at start |
| state | "active"\|"paused" | |
| paused_at_ms | int\|null | set while paused |
| paused_total_ms | int | folded in on resume, on Done while paused, and on finish while paused |
| rest | object\|null | see below |
| finished | bool | |
| ended_at_ms | int\|null | set on finish |
| exercises | object[] | in current order (drag reorder changes it) |

## rest
`{set_id, ends_at_wall_ms, duration_ms}`. The set whose Done started it. Kotlin re-anchors to elapsedRealtime on receipt. Null when skipped, on pause, on finish, and after the last pending set.

## exercises[]
`exercise_id, name (as logged), load_kind (dumbbell|stack|barbell|bodyweight|timed|...), unilateral (bool), rest_s (int), rep_lo (int|null), rep_hi (int|null), sets[]`.

## sets[]
`set_id, set_ordinal, kind (reps|timed), target_load_g, target_reps, state (pending|done|skipped), load_g, reps, completion, source, started_at_ms, ended_at_ms, offset_ms, block`.
- `set_id` = `<workout_uuid>:<n>`, n unique and never reused within a workout.
- `set_ordinal` 1-based within its exercise; closes up when a pending set is removed.
- target_* = what Done will log untouched. `target_load_g` null = cold start or plain bodyweight.
- completion (done only): `tap_unchanged | adjusted | typed | cold_start`; null for pending/skipped.
- source (done only): `app | lockscreen`. A lock-screen Done is `tap_unchanged`.
- `offset_ms` = ended_at − started_at_ms(workout) − paused_total_ms (R6 ghost key).
- `started_at_ms` of a set = the running rest's end if any (capped at now), else the latest done set's end (or workout start + pauses).
- `block`: object|null, timer blocks (R4, cut 2). Opaque in cut 1.

## Current set
The first `pending` set in exercise order. The notification shows its exercise, `set_ordinal` of the exercise's set count, and target load × reps.

## Kotlin-side transitions (cut 1: Done/rest/etc. come from Dart)
Kotlin applies only finish stamping: `finished=true`, `rev+1`, `rest=null`, `ended_at_ms` if null, **and if `state=="paused"`: `paused_total_ms += now - paused_at_ms`, `paused_at_ms=null`, `state="active"`** (matches Dart `Session.finish`). Preferred path in cut 1: Dart submits `Session.finish(...)` itself, then `finishSession()` fsyncs and returns it unchanged.

## Changes
Additive only after C2. A breaking change: hc ping t5t + affected lanes and a line in `contracts/CHANGES.md`; bump `schema`.
