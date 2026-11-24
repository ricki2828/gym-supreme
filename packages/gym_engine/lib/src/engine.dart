/// [GymEngine]: the [GymApi] implementation over a [HistoryStore].
///
/// Everything derived (days-since, suggestions, PBs, streak, counters) is
/// computed from the stored workouts on each call. A year of training is a
/// few hundred workouts, so this is cheap; cache later if a profile says so.
library;

import 'dart:convert';
import 'dart:math';

import 'api.dart';
import 'catalog.dart';
import 'cut2/plates.dart';
import 'cut2/rotation.dart';
import 'cut2/rotation_store.dart';
import 'import.dart';
import 'model.dart';
import 'snapshot.dart';
import 'starting_weights.dart';
import 'store.dart';

/// Weighted sets a muscle needs in one workout to count as "trained hard"
/// (primary 1.0, secondary 0.5). Tunable; covered by tests.
const double hardSetThreshold = 2.0;

/// Under this, a muscle shows as resting (plan 5.2: under 2 days).
const int restingMs = 48 * 3600 * 1000;

/// Work time assumed per set when fitting the time budget.
const int workSecondsPerSet = 45;

/// Most lifts a suggestion holds, however long the budget.
const int maxSuggestedLifts = 9;

/// Stable 32-bit FNV-1a of `seed:id` for tie-breaks (same on every
/// platform, unlike String.hashCode).
int tieHash(int seed, String id) {
  var h = 0x811c9dc5;
  for (final c in utf8.encode('$seed:$id')) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

/// Movement pattern (P1-4): compounds group by their primary muscles, with
/// an incline (or, for legs, one-sided) version as a distinct variant; at most two
/// compounds per group and never the same variant twice (so one overhead
/// press, not Arnold + seated + standing). Isolations group by primary
/// muscles, load kind and variant (a cable and a dumbbell raise may pair;
/// two dumbbell wrist curls may not).
String movementVariant(Exercise e) {
  if (e.id.contains('incline')) return 'incline';
  // One-sided is a different movement for legs (squat vs lunge), not for a
  // press, a row or an isolation (same machine, one arm).
  final legs = e.primary.any(_legMuscles.contains);
  return e.isCompound && legs && e.unilateral ? 'one-side' : 'base';
}

bool _samePrimary(Exercise a, Exercise b) =>
    a.primary.length == b.primary.length && a.primary.every(b.primary.contains);

const Set<String> _coreMuscles = {'abs', 'obliques'};

const Set<String> _legMuscles = {'quads', 'hamstrings', 'glutes', 'calves'};

String movementGroup(Exercise e) {
  final p = ([...e.primary]..sort()).join('+');
  return e.isCompound ? 'c:$p' : 'i:$p:${e.load}';
}

/// Whether [e] adds a new movement next to [chosen].
bool isFreshPattern(Exercise e, Iterable<Exercise> chosen) {
  final g = movementGroup(e);
  final same = chosen.where((x) => movementGroup(x) == g).toList();
  if (same.isEmpty) return true;
  if (!e.isCompound) {
    return same.every((x) => movementVariant(x) != movementVariant(e));
  }
  return same.length < 2 &&
      same.every((x) => movementVariant(x) != movementVariant(e));
}

/// Export bundle format version. 2 (0.2.1): deleted workouts left out,
/// `deleted_workout_uuids`, per-workout `edited_at_ms`,
/// `counters.workouts_deleted`.
const int exportFormat = 2;

class GymEngine implements GymApi {
  GymEngine({
    required this.catalog,
    required this.store,
    int Function()? nowMs,
    int Function()? tzOffsetMin,
    Random? random,
  }) : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _tz = tzOffsetMin ?? (() => DateTime.now().timeZoneOffset.inMinutes),
       _random = random ?? Random.secure();

  final Catalog catalog;
  final HistoryStore store;
  final int Function() _now;
  final int Function() _tz;
  final Random _random;

  // ---------------------------------------------------------------- gyms

  @override
  List<Gym> gyms() => store.gyms();

  @override
  Gym? gym(String id) => store.gym(id);

  @override
  Gym gymFromPreset(String presetId, {String? name}) {
    final p = catalog.preset(presetId);
    return Gym(
      id: _uuid(),
      name: name ?? p.name,
      presetId: p.id,
      createdAtMs: _now(),
      kit: {
        for (final e in p.equipment)
          e: KitItem(
            equipmentId: e,
            source: KitSource.preset,
            confirmed: false,
          ),
      },
    );
  }

  @override
  void saveGym(Gym gym) => store.upsertGym(gym);

  @override
  void deleteGym(String id) => store.deleteGym(id);

  @override
  Settings settings() => store.settings();

  @override
  void saveSettings(Settings settings) => store.saveSettings(settings);

  // ------------------------------------------------------------ days-since

  @override
  Map<String, MuscleStatus> muscleStatus({required String gymId}) {
    final g = store.gym(gymId);
    final kit = g?.equipmentIds ?? const <String>{};
    final last = _lastTrained(store.workouts());
    final now = _now();
    final tz = _tz();
    return {
      for (final m in catalog.muscles)
        m.id: MuscleStatus(
          muscleId: m.id,
          lastTrainedAtMs: last[m.id],
          daysSince: last[m.id] == null ? null : _dayDiff(last[m.id]!, now, tz),
          resting: last[m.id] != null && now - last[m.id]! < restingMs,
          // Same pool as suggest (timed moves are not suggested).
          uncoveredAtGym: !catalog.exercises.any(
            (e) =>
                e.primary.contains(m.id) &&
                e.load != 'timed' &&
                e.availableWith(kit),
          ),
        ),
    };
  }

  /// Muscle id → end time of the last workout that trained it hard.
  Map<String, int> _lastTrained(List<WorkoutRecord> workouts) {
    final out = <String, int>{};
    for (final w in workouts) {
      final load = _weightedSets(w);
      for (final e in load.entries) {
        if (e.value >= hardSetThreshold) {
          final prev = out[e.key];
          if (prev == null || w.endedAtMs > prev) out[e.key] = w.endedAtMs;
        }
      }
    }
    return out;
  }

  /// Weighted done sets per muscle (timed blocks still light muscles, R4).
  Map<String, double> _weightedSets(WorkoutRecord w) {
    final out = <String, double>{};
    for (final s in w.doneSets) {
      final ex = catalog.exercise(s.exerciseId);
      if (ex == null) continue;
      for (final m in ex.primary) {
        out[m] = (out[m] ?? 0) + 1.0;
      }
      for (final m in ex.secondary) {
        if (ex.primary.contains(m)) continue;
        out[m] = (out[m] ?? 0) + 0.5;
      }
    }
    return out;
  }

  // ------------------------------------------------------------- suggest

  @override
  SessionPlan suggest({
    required String gymId,
    required List<String> muscleIds,
    int? minutes,
    String? typeId,
    int seed = 0,
  }) {
    final g = store.gym(gymId);
    final kit = g?.equipmentIds ?? const <String>{};
    final settings = store.settings();
    final budgetS = (minutes ?? settings.defaultMinutes) * 60;
    final picked = [
      for (final m in {...muscleIds})
        if (catalog.muscles.any((x) => x.id == m)) m,
    ];
    final status = muscleStatus(gymId: gymId);
    final workouts = store.workouts();
    final starts = startingWeights(); // S1, read once for every item
    final historyCount = <String, int>{};
    for (final w in workouts.where((w) => w.gymId == gymId)) {
      for (final id in {for (final s in w.doneSets) s.exerciseId}) {
        historyCount[id] = (historyCount[id] ?? 0) + 1;
      }
    }

    final available = [
      for (final e in catalog.exercises)
        if (e.availableWith(kit) && e.load != 'timed') e,
    ];
    final uncovered = [
      for (final m in picked)
        if (!available.any((e) => e.primary.contains(m))) m,
    ];

    // An exercise may only hit resting muscles he picked (plan 5 property).
    bool allowed(Exercise e) => e.primary.every(
      (m) => picked.contains(m) || !(status[m]?.resting ?? false),
    );

    // Ties break on a hash of (seed, id), never on the alphabet (P1-4).
    // Order: loaded before bodyweight (P1-4; also over 0.1 history, which
    // led legs with a bodyweight squat), then lifts he has history on (plan
    // 5.5), then compounds before isolation (plan 5.3).
    int rank(Exercise a, Exercise b) {
      final la = a.load != bodyweight, lb = b.load != bodyweight;
      if (la != lb) return la ? -1 : 1;
      final h = (historyCount[b.id] ?? 0).compareTo(historyCount[a.id] ?? 0);
      if (h != 0) return h;
      if (a.isCompound != b.isCompound) return a.isCompound ? -1 : 1;
      final t = tieHash(seed, a.id).compareTo(tieHash(seed, b.id));
      return t != 0 ? t : a.id.compareTo(b.id);
    }

    List<Exercise> poolFor(String m) =>
        available.where((e) => e.primary.contains(m) && allowed(e)).toList()
          ..sort(rank);

    // Set targets (plan 5.3). Secondary work counts for at most half of a
    // muscle's target, so every picked muscle gets a direct lift (P1-4:
    // presses no longer use up the triceps).
    final target = <String, double>{
      for (var i = 0; i < picked.length; i++) picked[i]: i == 0 ? 9 : 6,
    };
    final need = {...target};
    final secondaryGot = <String, double>{};
    final chosen = <Exercise>[];
    final setsOf = <String, int>{};

    void credit(Exercise e, int sets) {
      for (final p in e.primary) {
        if (need.containsKey(p)) need[p] = need[p]! - sets;
      }
      for (final s in e.secondary) {
        if (!need.containsKey(s) || e.primary.contains(s)) continue;
        final room = target[s]! / 2 - (secondaryGot[s] ?? 0);
        final c = min(sets / 2, max(0.0, room));
        secondaryGot[s] = (secondaryGot[s] ?? 0) + c;
        need[s] = need[s]! - c;
      }
    }

    void add(Exercise e) {
      chosen.add(e);
      setsOf[e.id] = 3;
      credit(e, 3);
    }

    Exercise? rotatedOut; // the seed rotation's lift stays out, fill too
    bool fresh(Exercise e) => e != rotatedOut && isFreshPattern(e, chosen);

    for (final m in picked) {
      while ((need[m] ?? 0) > 0) {
        final cands = [
          for (final e in poolFor(m))
            if (!chosen.contains(e)) e,
        ];
        final f = cands.where(fresh);
        if (f.isNotEmpty) {
          add(f.first);
          continue;
        }
        // No new movement left: a 4th set on a lift he already has; never a
        // near-duplicate lift (he gets less than the target instead).
        final bump = chosen
            .where((e) => e.primary.contains(m) && setsOf[e.id]! < 4)
            .firstOrNull;
        if (bump != null) {
          setsOf[bump.id] = setsOf[bump.id]! + 1;
          credit(bump, 1);
          continue;
        }
        break;
      }
    }

    // Rotate one accessory per session for variety (plan 5.5). Only an
    // isolation slot rotates, so the main lifts keep their history,
    // progression and ghost.
    final iso = [
      for (var i = 0; i < chosen.length; i++)
        if (!chosen[i].isCompound) i,
    ];
    if (iso.isNotEmpty && seed != 0) {
      final slot = iso[seed.abs() % iso.length];
      final out = chosen[slot];
      final rest = [...chosen]..removeAt(slot);
      final lead = out.primary.firstWhere(
        picked.contains,
        orElse: () => out.primary.first,
      );
      final alt = [
        for (final e in poolFor(lead))
          if (!chosen.contains(e) && !e.isCompound && isFreshPattern(e, rest))
            e,
      ];
      if (alt.isNotEmpty) {
        rotatedOut = out;
        chosen[slot] = alt.first;
        setsOf[alt.first.id] = setsOf.remove(out.id)!;
      }
    }

    // Compounds first, then isolation, keeping pick order inside each.
    List<Exercise> ordered() => [
      ...chosen.where((e) => e.isCompound),
      ...chosen.where((e) => !e.isCompound),
    ];

    int restOf(Exercise e) =>
        e.isCompound ? settings.restCompoundS : settings.restIsolationS;
    int setCost(Exercise e) => workSecondsPerSet + restOf(e);
    int estimate() {
      var t = 0;
      for (final e in chosen) {
        t += setsOf[e.id]! * setCost(e);
      }
      return t;
    }

    // Fit the time, cheapest loss first: 4th sets; then a second lift for
    // a muscle other than the lead; then sets down to 2 (isolation first);
    // then any second lift; then from the end. Every picked muscle keeps a
    // direct lift as long as possible.
    bool covered(Exercise e) => e.primary
        .where(picked.contains)
        .every((p) => chosen.any((x) => x != e && x.primary.contains(p)));
    final lead = picked.isEmpty ? null : picked.first;
    bool trimTo(int floor) {
      for (final e in ordered().reversed) {
        if (setsOf[e.id]! > floor) {
          setsOf[e.id] = setsOf[e.id]! - 1;
          return true;
        }
      }
      return false;
    }

    bool drop(bool Function(Exercise) which) {
      for (final e in ordered().reversed) {
        if (which(e)) {
          chosen.remove(e);
          setsOf.remove(e.id);
          return true;
        }
      }
      return false;
    }

    while (chosen.isNotEmpty && estimate() > budgetS) {
      if (trimTo(3)) continue;
      if (drop((e) => covered(e) && !e.primary.contains(lead))) continue;
      if (trimTo(2)) continue;
      if (drop(covered)) continue;
      drop((_) => true);
    }

    // Fill the time (P1-4: 60 minutes is more than 45). The muscle furthest
    // below its target gets the next new movement that fits; when none
    // fits, a 4th set on a main lift; then 4th sets on the rest; core
    // muscles may then take a third move.
    double share(String m) {
      var v = 0.0;
      for (final e in chosen) {
        if (e.primary.contains(m)) {
          v += setsOf[e.id]!;
        } else if (e.secondary.contains(m)) {
          v += setsOf[e.id]! / 2;
        }
      }
      return v / target[m]!;
    }

    while (chosen.length < maxSuggestedLifts) {
      final room = budgetS - estimate();
      final byNeed = [
        for (final m in picked)
          if (!uncovered.contains(m)) m,
      ];
      final shares = {for (final m in byNeed) m: share(m)};
      byNeed.sort((a, b) => shares[a]!.compareTo(shares[b]!));
      Exercise? next;
      for (final m in byNeed) {
        for (final e in poolFor(m)) {
          if (!chosen.contains(e) && fresh(e) && 3 * setCost(e) <= room) {
            next = e;
            break;
          }
        }
        if (next != null) break;
      }
      if (next != null) {
        add(next);
        continue;
      }
      final more = ordered()
          .where((e) => e.isCompound && setsOf[e.id]! < 4 && setCost(e) <= room)
          .firstOrNull;
      if (more != null) {
        setsOf[more.id] = setsOf[more.id]! + 1;
        continue;
      }
      // Then 4th sets on the rest.
      final iso4 = ordered()
          .where((e) => setsOf[e.id]! < 4 && setCost(e) <= room)
          .firstOrNull;
      if (iso4 != null) {
        setsOf[iso4.id] = setsOf[iso4.id]! + 1;
        continue;
      }
      // Core moves are short variants of each other: up to three per muscle
      // (cable crunch, dead bug, reverse crunch) so a long core day fills.
      Exercise? core;
      for (final m in byNeed.where(_coreMuscles.contains)) {
        for (final e in poolFor(m)) {
          if (!chosen.contains(e) &&
              e != rotatedOut &&
              3 * setCost(e) <= room &&
              chosen.where((x) => _samePrimary(x, e)).length < 3) {
            core = e;
            break;
          }
        }
        if (core != null) break;
      }
      if (core == null) break;
      add(core);
    }

    final items = [
      for (final e in ordered())
        _plannedItem(
          e,
          gymId: gymId,
          sets: setsOf[e.id]!,
          restS: restOf(e),
          status: status,
          picked: picked,
          starts: starts,
          workouts: workouts,
        ),
    ];
    return SessionPlan(
      gymId: gymId,
      typeId: typeId,
      muscles: picked,
      items: items,
      uncovered: uncovered,
      estimatedMinutes: (estimate() / 60).ceil(),
    );
  }

  PlannedItem _plannedItem(
    Exercise e, {
    required String gymId,
    required int sets,
    required int restS,
    required Map<String, MuscleStatus> status,
    required List<String> picked,
    required Map<String, int> starts,
    required List<WorkoutRecord> workouts,
  }) {
    final (lo, hi) = repRange(e);
    final unit = unitFor(e);
    final steps = loadSteps(gymId: gymId, exerciseId: e.id);
    final last = lastTime(gymId: gymId, exerciseId: e.id);
    final lead = e.primary.firstWhere(
      picked.contains,
      orElse: () => e.primary.first,
    );
    final rested = status[lead]?.daysSince;
    final restLine = rested == null
        ? '${_muscleName(lead)}: no history yet.'
        : '${_muscleName(lead)} is $rested ${rested == 1 ? 'day' : 'days'} '
              'rested.';

    if (last == null || last.sets.isEmpty) {
      // S1: a starting weight he typed seeds the first session of a lift
      // with no logged history anywhere.
      final start = _startingLoad(gymId, e.id, starts, workouts);
      if (start != null) {
        final typed = starts[e.id]!;
        final snapped = typed == start
            ? ''
            : ' Nearest weight here is ${_kg(start, unit)}.';
        return PlannedItem(
          exerciseId: e.id,
          name: e.name,
          unit: unit,
          sets: [
            for (var i = 0; i < sets; i++)
              PlannedSet(loadG: start, reps: lo + 2),
          ],
          repLo: lo,
          repHi: hi,
          restS: restS,
          primary: e.primary,
          reason:
              '$restLine Starting weight you set: ${_kg(typed, unit)}.'
              '$snapped',
          loadFromStartingWeight: true,
        );
      }
      return PlannedItem(
        exerciseId: e.id,
        name: e.name,
        unit: unit,
        sets: [
          for (var i = 0; i < sets; i++) PlannedSet(loadG: null, reps: lo + 2),
        ],
        repLo: lo,
        repHi: hi,
        restS: restS,
        primary: e.primary,
        reason: unit == LoadUnit.bodyweight
            ? '$restLine First time here.'
            : '$restLine First time here: pick a weight you can do '
                  '${lo + 2} clean reps with.',
      );
    }

    final p = progress(e, last, steps);
    final lastLine = 'You did ${_describe(last.sets, unit)} last time.';
    return PlannedItem(
      exerciseId: e.id,
      name: e.name,
      unit: unit,
      sets: [
        for (var i = 0; i < sets; i++)
          PlannedSet(
            loadG: p.loadG,
            reps: i < p.reps.length ? p.reps[i] : p.reps.last,
          ),
      ],
      repLo: lo,
      repHi: hi,
      restS: restS,
      primary: e.primary,
      reason: '$restLine $lastLine${p.note.isEmpty ? '' : ' ${p.note}'}',
    );
  }

  /// Double progression (plan 5.6): all sets at the top of the range → the
  /// next load this gym has; else one more rep. At the gym's top weight: more
  /// reps, and a pointer to a harder variant if there is one (B7).
  ({int? loadG, List<int> reps, String note}) progress(
    Exercise e,
    LastTime last,
    LoadSteps steps,
  ) {
    final (_, hi) = repRange(e);
    final loads = [for (final s in last.sets) s.loadG ?? 0];
    final top = loads.reduce(max);
    final topSets = [
      for (final s in last.sets)
        if ((s.loadG ?? 0) == top) s,
    ];
    final allAtTop = topSets.every((s) => s.reps >= hi);
    final logged = top == 0 && last.sets.every((s) => s.loadG == null)
        ? null
        : top;
    // The suggested load must exist at this gym: snap a typed or since-
    // removed weight down to the nearest one the gym has.
    final lastLoad = logged == null || steps.loadsG.isEmpty
        ? logged
        : steps.loadsG.lastWhere(
            (l) => l <= logged,
            orElse: () => steps.loadsG.first,
          );
    final harder = catalog.exercises.where((x) => x.harderThan == e.id);
    final harderNote = harder.isEmpty ? '' : ', or try ${harder.first.name}';
    if (allAtTop) {
      final up = lastLoad == null ? null : steps.next(lastLoad);
      if (up != null) {
        return (
          loadG: up,
          reps: [for (final _ in topSets) _lo(e)],
          note: 'Up to ${_kg(up, unitFor(e))}.',
        );
      }
      // Top weight here, or bodyweight at the top of the range (B7).
      return (
        loadG: lastLoad,
        reps: [for (final s in topSets) s.reps + 1],
        note: lastLoad == null
            ? 'Top of the range: one more rep$harderNote.'
            : 'Top weight here: more reps$harderNote.',
      );
    }
    return (
      loadG: lastLoad,
      reps: [for (final s in topSets) s.reps >= hi ? hi : s.reps + 1],
      note: lastLoad != logged
          ? 'Nearest weight here is ${_kg(lastLoad!, unitFor(e))}.'
          : 'Aim for one more rep.',
    );
  }

  int _lo(Exercise e) => repRange(e).$1;

  /// Rep range per exercise: compounds 8-12, isolation 10-15.
  (int, int) repRange(Exercise e) => e.isCompound ? (8, 12) : (10, 15);

  LoadUnit unitFor(Exercise e) => switch (e.load) {
    'dumbbell' => LoadUnit.ea,
    'bodyweight' => LoadUnit.bodyweight,
    'timed' || 'distance' => LoadUnit.timed,
    _ => LoadUnit.kg,
  };

  // ------------------------------------------------------- live helpers

  @override
  LoadSteps loadSteps({required String gymId, required String exerciseId}) {
    final e = catalog.exercise(exerciseId);
    if (e == null) return const LoadSteps(LoadUnit.kg, []);
    final unit = unitFor(e);
    if (unit == LoadUnit.bodyweight || unit == LoadUnit.timed) {
      return LoadSteps(unit, const []);
    }
    final g = store.gym(gymId);
    final set = _equipmentSetAt(e, g);
    final loads = <int>{};
    for (final id in set) {
      final eq = catalog.equipmentById(id);
      if (eq == null) continue;
      final item = g?.kit[id];
      if (eq.load == 'barbell') {
        final bar = _barSetupOf(g, id);
        loads.addAll(_barbellLoads(bar));
      } else if (eq.load == e.load) {
        final w = item?.weightsG ?? const <int>[];
        loads.addAll(w.isNotEmpty ? w : (defaultWeightsG[eq.load] ?? const []));
      }
    }
    if (loads.isEmpty) loads.addAll(defaultWeightsG[e.load] ?? const []);
    return LoadSteps(unit, loads.toList()..sort());
  }

  /// The equipment set this gym can load the exercise with (the first it has
  /// all of, else the first listed).
  Set<String> _equipmentSetAt(Exercise e, Gym? g) {
    final have = {...?g?.equipmentIds, bodyweight};
    return e.equipmentSets.firstWhere(
      have.containsAll,
      orElse: () => e.equipmentSets.first,
    );
  }

  /// The bar item [barId] (`barbell`, `ez-bar`, `trap-bar`) with this gym's
  /// plates. Bar weight: the item's first weight, else the standard 20 kg
  /// bar. Plate pairs: the multiplicity of each size in the `plates` item;
  /// null (unlimited standard plates) when none are listed.
  BarSetup _barSetupOf(Gym? g, String barId) {
    final w = g?.kit[barId]?.weightsG ?? const <int>[];
    final plates = g?.kit['plates']?.weightsG ?? const <int>[];
    Map<int, int>? pairs;
    if (plates.isNotEmpty) {
      pairs = {};
      for (final p in plates) {
        if (p > 0) pairs[p] = (pairs[p] ?? 0) + 1;
      }
    }
    return BarSetup(
      barG: w.isNotEmpty && w.first > 0 ? w.first : standardBarG,
      pairs: pairs,
    );
  }

  /// Every total the bar makes from its plates, ascending. Without a plate
  /// list: the bar up to 140 kg in 2.5 kg steps (a pair of 1.25s).
  List<int> _barbellLoads(BarSetup bar) {
    final pairs = bar.pairs;
    if (pairs == null) {
      return [for (var g = bar.barG; g <= 140000; g += 2500) g];
    }
    return barSteps(barG: bar.barG, pairs: pairs);
  }

  @override
  BarSetup? barSetup({required String gymId, required String exerciseId}) {
    final e = catalog.exercise(exerciseId);
    if (e == null || e.load != 'barbell') return null;
    final g = store.gym(gymId);
    for (final id in _equipmentSetAt(e, g)) {
      if (catalog.equipmentById(id)?.load == 'barbell') {
        return _barSetupOf(g, id);
      }
    }
    return null;
  }

  @override
  LastTime? lastTime({required String gymId, required String exerciseId}) {
    final ws = store.workouts();
    for (final w in ws.reversed) {
      if (w.gymId != gymId) continue;
      final sets = w.doneSets.where((s) => s.exerciseId == exerciseId).toList()
        ..sort((a, b) => a.setOrdinal.compareTo(b.setOrdinal));
      if (sets.isEmpty) continue;
      return LastTime(
        workoutUuid: w.uuid,
        atMs: w.startedAtMs,
        sets: [
          for (final s in sets) PlannedSet(loadG: s.loadG, reps: s.reps ?? 0),
        ],
      );
    }
    return null;
  }

  // ---------------------------------------------------- starting weights

  @override
  Map<String, int> startingWeights() => loadStartingWeights(store);

  @override
  void setStartingWeight(String exerciseId, int? loadG) {
    final e = catalog.exercise(exerciseId);
    if (e == null) throw ArgumentError('unknown exercise $exerciseId');
    final unit = unitFor(e);
    if (unit != LoadUnit.kg && unit != LoadUnit.ea) {
      throw ArgumentError('$exerciseId takes no weight');
    }
    if (loadG != null && !validStartingWeight(loadG)) {
      throw ArgumentError('starting weight out of range: $loadG g');
    }
    final all = {...startingWeights()};
    if (loadG == null) {
      if (all.remove(exerciseId) == null) return;
    } else {
      all[exerciseId] = loadG;
    }
    saveStartingWeights(store, all);
  }

  @override
  int? startingLoad({required String gymId, required String exerciseId}) =>
      _startingLoad(gymId, exerciseId, startingWeights(), store.workouts());

  /// [startingLoad] with the stored weights and history read once by the
  /// caller (suggest builds every item from one read).
  int? _startingLoad(
    String gymId,
    String exerciseId,
    Map<String, int> starts,
    List<WorkoutRecord> workouts,
  ) {
    final typed = starts[exerciseId];
    if (typed == null) return null;
    // An import can carry an id this build treats as unloaded: never give
    // a bodyweight or timed lift a load.
    final e = catalog.exercise(exerciseId);
    if (e == null) return null;
    final unit = unitFor(e);
    if (unit != LoadUnit.kg && unit != LoadUnit.ea) return null;
    if (hasLoggedHistory(exerciseId, workouts)) return null;
    final steps = loadSteps(gymId: gymId, exerciseId: exerciseId);
    if (steps.loadsG.isEmpty) return typed;
    // Same rule as progression: the load must exist at this gym, so snap
    // down to the nearest one it has (the lightest if all are heavier).
    return steps.loadsG.lastWhere(
      (l) => l <= typed,
      orElse: () => steps.loadsG.first,
    );
  }

  @override
  List<StartingWeightLift> startingWeightLifts({required String gymId}) {
    final stored = startingWeights();
    final workouts = store.workouts();
    final order = loadRotation(store).order;
    final types = [
      for (final id in order.isEmpty ? defaultRotationOrder : order)
        if (workoutType(id) case final t? when t.muscles.isNotEmpty) t,
    ];
    final out = <StartingWeightLift>[];
    final seen = <String>{};
    StartingWeightLift row(Exercise e, String? typeId) => StartingWeightLift(
      exerciseId: e.id,
      name: e.name,
      unit: unitFor(e),
      typeId: typeId,
      loadG: stored[e.id],
      hasHistory: hasLoggedHistory(e.id, workouts),
    );
    // First the lifts his next session of each type would plan (the
    // picker's seed: stored sessions + 1), then every other loaded lift this
    // gym has, so a lift a later seed rotates in is never missing.
    final seed = counters().sessionsTotal + 1;
    for (final t in types) {
      final plan = suggest(
        gymId: gymId,
        muscleIds: t.muscles,
        typeId: t.id,
        minutes: 60,
        seed: seed,
      );
      for (final item in plan.items) {
        if (item.unit != LoadUnit.kg && item.unit != LoadUnit.ea) continue;
        final e = catalog.exercise(item.exerciseId);
        if (e != null && seen.add(e.id)) out.add(row(e, t.id));
      }
    }
    final kit = store.gym(gymId)?.equipmentIds ?? const <String>{};
    final rest = [
      for (final e in catalog.exercises)
        if (!seen.contains(e.id) &&
            (stored.containsKey(e.id) ||
                (e.availableWith(kit) &&
                    (unitFor(e) == LoadUnit.kg || unitFor(e) == LoadUnit.ea))))
          e,
    ]..sort((a, b) => a.name.compareTo(b.name));
    for (final e in rest) {
      out.add(row(e, null));
    }
    return out;
  }

  // ----------------------------------------------------- finish, resume

  /// Stores a finished workout once. A uuid already stored (deleted ones
  /// included) is left alone: a Finish retry after a failed journal delete
  /// must not overwrite sets edited in history or resurrect a delete.
  @override
  void saveFinished(SessionSnapshot snapshot, {List<HrSample> hr = const []}) {
    if (!snapshot.finished) {
      throw ArgumentError('saveFinished needs a finished snapshot');
    }
    if (store.hasWorkout(snapshot.workoutUuid)) return;
    store.upsertWorkout(
      snapshot.toRecord(),
      snapshotJson: snapshot.encode(),
      hr: hr,
    );
  }

  @override
  bool isStored(String workoutUuid) => store.hasWorkout(workoutUuid);

  @override
  ({RecoveryAction action, SessionSnapshot? snapshot}) recover(
    String? journalText, {
    String? hrText,
  }) {
    final last = journalText == null ? null : readJournal(journalText).last;
    if (last == null) return (action: RecoveryAction.none, snapshot: null);
    if (store.hasWorkout(last.workoutUuid)) {
      return (action: RecoveryAction.deleteJournal, snapshot: last);
    }
    if (last.finished) {
      saveFinished(last, hr: hrText == null ? const [] : readHrJsonl(hrText));
      return (action: RecoveryAction.savedThenDelete, snapshot: last);
    }
    return (action: RecoveryAction.offerResume, snapshot: last);
  }

  // ------------------------------------------------- summary, history

  @override
  WorkoutSummary? summaryOrNull(String workoutUuid) =>
      store.workout(workoutUuid) == null ? null : summary(workoutUuid);

  @override
  WorkoutSummary summary(String workoutUuid) {
    final all = store.workouts();
    final i = all.indexWhere((w) => w.uuid == workoutUuid);
    if (i < 0) throw ArgumentError('unknown workout $workoutUuid');
    final w = all[i];
    final earlier = all.sublist(0, i);
    WorkoutRecord? prevSameType;
    if (w.typeId != null) {
      for (final p in earlier.reversed) {
        if (p.typeId == w.typeId) {
          prevSameType = p;
          break;
        }
      }
    }
    final vol = w.volumeGReps / 1000.0;
    final prevVol = prevSameType == null
        ? null
        : prevSameType.volumeGReps / 1000.0;
    final weighted = _weightedSets(w);
    return WorkoutSummary(
      uuid: w.uuid,
      volumeKg: vol,
      volumeDeltaPct: prevVol == null || prevVol == 0
          ? null
          : (vol - prevVol) / prevVol * 100,
      setCount: w.doneSets.length,
      setsPerMuscle: weighted,
      musclesLit: [
        for (final m in catalog.muscles)
          if ((weighted[m.id] ?? 0) > 0) m.id,
      ],
      pbs: _pbs(w, earlier),
      weeklyStreak: weeklyStreak([
        for (final x in all.sublist(0, i + 1))
          if (x.doneSets.isNotEmpty) x,
      ]),
      durationMs: w.durationMs,
    );
  }

  List<Pb> _pbs(WorkoutRecord w, List<WorkoutRecord> earlier) {
    final out = <Pb>[];
    final ids = <String>[];
    for (final s in w.doneSets) {
      if (s.kind == SetKind.reps && !ids.contains(s.exerciseId)) {
        ids.add(s.exerciseId);
      }
    }
    for (final id in ids) {
      final before = [
        for (final p in earlier)
          for (final s in p.doneSets)
            if (s.exerciseId == id && s.kind == SetKind.reps) s,
      ];
      if (before.isEmpty) continue; // first time is not a PB
      final now = [
        for (final s in w.doneSets)
          if (s.exerciseId == id && s.kind == SetKind.reps) s,
      ];
      final name = now.first.exerciseName;
      int load(SetRecord s) => s.loadG ?? 0;
      final prevTop = before.map(load).reduce(max);
      final nowTop = now.map(load).reduce(max);
      if (nowTop > prevTop) {
        final best = now
            .where((s) => load(s) == nowTop)
            .map((s) => s.reps ?? 0)
            .reduce(max);
        final wasReps = before
            .where((s) => load(s) == prevTop)
            .map((s) => s.reps ?? 0)
            .reduce(max);
        out.add(
          Pb(
            exerciseId: id,
            name: name,
            kind: 'load',
            loadG: nowTop,
            reps: best,
            wasLoadG: prevTop,
            wasReps: wasReps,
          ),
        );
        continue;
      }
      // Most reps at a load already lifted: report the heaviest such load.
      final loads = now.map(load).toSet().toList()..sort((a, b) => b - a);
      for (final l in loads) {
        final prevAt = before.where((s) => load(s) == l);
        if (prevAt.isEmpty) continue;
        final was = prevAt.map((s) => s.reps ?? 0).reduce(max);
        final best = now
            .where((s) => load(s) == l)
            .map((s) => s.reps ?? 0)
            .reduce(max);
        if (best > was) {
          out.add(
            Pb(
              exerciseId: id,
              name: name,
              kind: 'reps',
              loadG: l == 0 ? null : l,
              reps: best,
              wasLoadG: l == 0 ? null : l,
              wasReps: was,
            ),
          );
          break;
        }
      }
    }
    return out;
  }

  /// Consecutive local weeks (Monday start) with 2+ sessions, ending at the
  /// week of the latest workout given. A current week still under 2 does not
  /// break the streak; it just is not counted yet.
  int weeklyStreak(List<WorkoutRecord> workouts) {
    if (workouts.isEmpty) return 0;
    final perWeek = <int, int>{};
    for (final w in workouts) {
      final k = _weekKey(w.startedAtMs, w.tzOffsetMin);
      perWeek[k] = (perWeek[k] ?? 0) + 1;
    }
    var week = _weekKey(workouts.last.startedAtMs, workouts.last.tzOffsetMin);
    if ((perWeek[week] ?? 0) < 2) week -= 1;
    var n = 0;
    while ((perWeek[week] ?? 0) >= 2) {
      n++;
      week -= 1;
    }
    return n;
  }

  @override
  List<HistoryRow> history({int limit = 100, int offset = 0}) {
    final gyms = {for (final g in store.gyms()) g.id: g.name};
    final all = store.workouts().reversed.skip(offset).take(limit);
    return [
      for (final w in all)
        HistoryRow(
          uuid: w.uuid,
          startedAtMs: w.startedAtMs,
          tzOffsetMin: w.tzOffsetMin,
          gymId: w.gymId,
          gymName: gyms[w.gymId] ?? '',
          typeId: w.typeId,
          durationMs: w.durationMs,
          volumeKg: w.volumeGReps / 1000.0,
          setCount: w.doneSets.length,
        ),
    ];
  }

  @override
  Counters counters() {
    // A start-then-finish with nothing done is not a session (gate).
    final all = store.workouts().where((w) => w.doneSets.isNotEmpty).toList();
    final now = _now();
    var done = 0;
    var tap = 0;
    var cold = 0;
    final versions = <String, int>{};
    for (final w in all) {
      versions[w.appVersion] = (versions[w.appVersion] ?? 0) + 1;
      for (final s in w.doneSets) {
        if (s.kind != SetKind.reps) continue; // R4: timed blocks left out
        done++;
        if (s.completion == Completion.tapUnchanged) tap++;
        if (s.completion == Completion.coldStart) cold++;
      }
    }
    return Counters(
      sessionsTotal: all.length,
      sessionsLast14Days: all
          .where((w) => now - w.startedAtMs < 14 * 24 * 3600 * 1000)
          .length,
      firstSessionAtMs: all.isEmpty ? null : all.first.startedAtMs,
      doneSets: done,
      tapUnchangedSets: tap,
      coldStartSets: cold,
      appVersions: versions,
      medianSwapsPerSession: _median([for (final w in all) w.swaps]),
      workoutsDeleted: store.deletedWorkoutUuids().length,
    );
  }

  // ------------------------------------------------ delete and edit

  @override
  DeletedWorkout? deleteWorkout(String uuid, {bool rotation = false}) {
    final w = store.workout(uuid);
    if (w == null) return null;
    final at = _now();
    if (!store.deleteWorkout(uuid, at)) return null;
    // Two writes, not one transaction (HistoryStore has no transaction hook
    // and MemoryStore cannot roll back). The delete is what matters: a
    // rotation failure is cosmetic (he can tap the right row) and never
    // undoes it.
    Rotation? before;
    if (rotation) {
      try {
        before = rotationAfterDelete(store, uuid, w.typeId);
      } on Object {
        before = null;
      }
    }
    return DeletedWorkout(uuid: uuid, deletedAtMs: at, rotationBefore: before);
  }

  @override
  bool undoDelete(String uuid, {Rotation? rotationBefore}) {
    if (!store.restoreWorkout(uuid)) return false;
    if (rotationBefore == null) return true;
    try {
      // Put the rotation back only if it is still what the delete left
      // (pointer on this type). Anything he changed since is kept.
      final type = store.workout(uuid)?.typeId;
      if (type != null &&
          rotationBefore.order.contains(type) &&
          loadRotation(store) == rotationBefore.pointAt(type)) {
        saveRotation(store, rotationBefore);
      }
    } on Object {
      // Cosmetic: the workout is back; the pointer stays where it is.
    }
    return true;
  }

  @override
  WorkoutRecord editWorkout(String uuid, List<WorkoutEdit> edits) {
    final w = store.workout(uuid);
    if (w == null) throw ArgumentError('unknown or deleted workout $uuid');
    if (edits.isEmpty) return w;
    var sets = [...w.sets];
    for (final e in edits) {
      final i = sets.indexWhere((s) => s.setId == e.setId);
      if (i < 0) throw ArgumentError('unknown set ${e.setId}');
      final s = sets[i];
      switch (e) {
        case SetValuesEdit(:final loadG, :final reps):
          if (s.kind == SetKind.timed) {
            throw ArgumentError('timed set ${s.setId}: remove only');
          }
          if (s.skipped) {
            throw ArgumentError('skipped set ${s.setId}: remove only');
          }
          if (reps < 1) throw ArgumentError('reps must be >= 1, got $reps');
          if (loadG != null && loadG < 0) {
            throw ArgumentError('load must be >= 0, got $loadG');
          }
          sets[i] = _setWith(s, loadG: loadG, reps: reps);
        case RemoveSetEdit():
          sets.removeAt(i);
          // Renumber that exercise 1..n by position (session.dart rule);
          // skipped sets hold a number too.
          final same = [
            for (final x in sets)
              if (x.exerciseId == s.exerciseId &&
                  x.exercisePosition == s.exercisePosition)
                x,
          ]..sort((a, b) => a.setOrdinal.compareTo(b.setOrdinal));
          final ordinal = {
            for (var k = 0; k < same.length; k++) same[k].setId: k + 1,
          };
          sets = [
            for (final x in sets)
              ordinal.containsKey(x.setId)
                  ? _setWith(
                      x,
                      loadG: x.loadG,
                      reps: x.reps,
                      setOrdinal: ordinal[x.setId],
                    )
                  : x,
          ];
      }
    }
    final edited = WorkoutRecord(
      uuid: w.uuid,
      gymId: w.gymId,
      typeId: w.typeId,
      muscles: w.muscles,
      startedAtMs: w.startedAtMs,
      tzOffsetMin: w.tzOffsetMin,
      endedAtMs: w.endedAtMs,
      pausedMs: w.pausedMs,
      appVersion: w.appVersion,
      swaps: w.swaps,
      sets: sets,
      editedAtMs: _now(),
    );
    // snapshotJson null keeps the as-finished copy; HR is only ever added.
    store.upsertWorkout(edited);
    return store.workout(uuid)!;
  }

  static SetRecord _setWith(
    SetRecord s, {
    required int? loadG,
    required int? reps,
    int? setOrdinal,
  }) => SetRecord(
    setId: s.setId,
    exerciseId: s.exerciseId,
    exerciseName: s.exerciseName,
    exercisePosition: s.exercisePosition,
    setOrdinal: setOrdinal ?? s.setOrdinal,
    completion: s.completion,
    skipped: s.skipped,
    kind: s.kind,
    loadG: loadG,
    reps: reps,
    startedAtMs: s.startedAtMs,
    endedAtMs: s.endedAtMs,
    offsetMs: s.offsetMs,
    source: s.source,
    blockJson: s.blockJson,
  );

  // ---------------------------------------------------------- export

  @override
  ExportFiles export({
    required String appVersion,
    Map<String, int> native = const {},
  }) {
    final c = counters();
    final gyms = store.gyms();
    final workouts = store.workouts();
    final bundle = {
      'export_format': exportFormat,
      'schema_version': store.schemaVersion,
      'snapshot_schema': snapshotSchema,
      'app_version': appVersion,
      'exported_at_ms': _now(),
      'counters': {
        'sessions_total': c.sessionsTotal,
        'sessions_last_14_days': c.sessionsLast14Days,
        'first_session_at_ms': c.firstSessionAtMs,
        'done_sets': c.doneSets,
        'tap_unchanged_sets': c.tapUnchangedSets,
        'cold_start_sets': c.coldStartSets,
        'median_swaps_per_session': c.medianSwapsPerSession,
        'one_tap_rate': c.oneTapRate,
        'one_tap_rate_incl_cold': c.oneTapRateInclCold,
        'app_versions': c.appVersions,
        'workouts_deleted': c.workoutsDeleted,
        'native': native,
      },
      'settings': store.settings().toJson(),
      'gyms': [
        for (final g in gyms)
          {
            'id': g.id,
            'name': g.name,
            'preset_id': g.presetId,
            'created_at_ms': g.createdAtMs,
            'kit': [for (final k in g.kit.values) k.toJson()],
          },
      ],
      'workouts': [for (final w in workouts) _workoutJson(w)],
      'deleted_workout_uuids': store.deletedWorkoutUuids(),
      // 0.3 S1, additive in format 2 (0.2.x imports ignore the key).
      'starting_weights': [
        for (final e
            in (startingWeights().entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key))))
          {'exercise_id': e.key, 'load_g': e.value},
      ],
    };
    final json = const JsonEncoder.withIndent(' ').convert(bundle);
    return ExportFiles(json: json, csv: _csv(gyms, workouts));
  }

  Map<String, Object?> _workoutJson(WorkoutRecord w) => {
    'uuid': w.uuid,
    'gym_id': w.gymId,
    'type_id': w.typeId,
    'muscles': w.muscles,
    'started_at_ms': w.startedAtMs,
    'tz_offset_min': w.tzOffsetMin,
    'ended_at_ms': w.endedAtMs,
    'paused_ms': w.pausedMs,
    'app_version': w.appVersion,
    'swaps': w.swaps,
    'edited_at_ms': w.editedAtMs,
    'sets': [
      for (final s in w.sets)
        {
          'set_id': s.setId,
          'exercise_id': s.exerciseId,
          'exercise_name': s.exerciseName,
          'exercise_position': s.exercisePosition,
          'set_ordinal': s.setOrdinal,
          'kind': s.kind.name,
          'load_g': s.loadG,
          'reps': s.reps,
          'completion': s.completion?.wire,
          'skipped': s.skipped,
          'source': s.source.name,
          'started_at_ms': s.startedAtMs,
          'ended_at_ms': s.endedAtMs,
          'offset_ms': s.offsetMs,
          'block': s.blockJson == null ? null : jsonDecode(s.blockJson!),
        },
    ],
  };

  static const csvHeader = [
    'workout_uuid', 'workout_start_utc', 'tz_offset_min', 'gym_name', //
    'type', 'exercise_position', 'exercise_id', 'exercise_name', //
    'set_ordinal', 'kind', 'load_kg', 'reps', 'completion', 'skipped', //
    'source', 'set_start_utc', 'set_end_utc', 'offset_ms',
  ];

  String _csv(List<Gym> gyms, List<WorkoutRecord> workouts) {
    final names = {for (final g in gyms) g.id: g.name};
    final b = StringBuffer()..write('${csvHeader.join(',')}\r\n');
    String iso(int? ms) => ms == null
        ? ''
        : DateTime.fromMillisecondsSinceEpoch(
            ms,
            isUtc: true,
          ).toIso8601String();
    for (final w in workouts) {
      for (final s in w.sets) {
        final row = [
          w.uuid,
          iso(w.startedAtMs),
          '${w.tzOffsetMin}',
          names[w.gymId] ?? '',
          w.typeId ?? '',
          '${s.exercisePosition}',
          s.exerciseId,
          s.exerciseName,
          '${s.setOrdinal}',
          s.kind.name,
          s.loadG == null ? '' : _num(s.loadG! / 1000),
          s.reps?.toString() ?? '',
          s.completion?.wire ?? '',
          s.skipped ? '1' : '0',
          s.source.name,
          iso(s.startedAtMs),
          iso(s.endedAtMs),
          s.offsetMs?.toString() ?? '',
        ];
        b.write('${row.map(csvField).join(',')}\r\n');
      }
    }
    return b.toString();
  }

  // ---------------------------------------------------------- import

  @override
  ImportCounts previewImport(String text) =>
      _import(parseImportBundle(text), write: false);

  @override
  ImportCounts importBundle(String text) {
    final bundle = parseImportBundle(text);
    try {
      return store.transaction(() => _import(bundle, write: true));
    } on ImportRefused {
      rethrow;
    } on Object catch (e) {
      // e.g. a set id that clashes with a set already stored: the
      // transaction rolled back, so nothing was written.
      throw ImportRefused('Import failed and nothing was written ($e).');
    }
  }

  /// Counts (and with [write], applies) [b] against the store. Workouts:
  /// insert unknown uuids; skip stored ones, deleted ones included, so a
  /// tombstone is never resurrected and an edited workout never reverts.
  /// Gyms: insert unknown ids with their kit; never touch a gym already
  /// here. Settings: applied only while this phone still has the defaults
  /// (a fresh install), so his own choices are never replaced. Rotation and
  /// the file's `deleted_workout_uuids` are not imported.
  ImportCounts _import(ImportBundle b, {required bool write}) {
    final deleted = store.deletedWorkoutUuids().toSet();
    var added = 0, existing = 0, wasDeleted = 0, hr = 0, clamped = 0;
    for (final w in b.workouts) {
      final uuid = w.record.uuid;
      if (deleted.contains(uuid)) {
        wasDeleted++;
      } else if (store.hasWorkout(uuid)) {
        existing++;
      } else {
        added++;
        hr += w.hr.length;
        if (w.endClamped) clamped++;
        if (write) store.upsertWorkout(w.record, hr: w.hr);
      }
    }
    var gymsAdded = 0, gymsKept = 0;
    for (final g in b.gyms) {
      if (store.gym(g.id) != null) {
        gymsKept++;
      } else {
        gymsAdded++;
        if (write) store.upsertGym(g);
      }
    }
    final defaults = jsonEncode(const Settings().toJson());
    final fileSettings = b.settings;
    final restore =
        fileSettings != null &&
        jsonEncode(store.settings().toJson()) == defaults &&
        jsonEncode(fileSettings.toJson()) != defaults;
    if (write && restore) store.saveSettings(fileSettings);
    // Starting weights: added for lifts without one here; his own kept.
    final mine = startingWeights();
    var startAdded = 0, startKept = 0;
    final merged = {...mine};
    for (final e in b.startingWeights.entries) {
      if (mine.containsKey(e.key)) {
        startKept++;
      } else {
        startAdded++;
        merged[e.key] = e.value;
      }
    }
    if (write && startAdded > 0) saveStartingWeights(store, merged);
    return ImportCounts(
      exportFormat: b.exportFormat,
      workoutsInFile: b.workouts.length,
      workoutsAdded: added,
      skippedExisting: existing,
      skippedDeleted: wasDeleted,
      gymsAdded: gymsAdded,
      gymsKept: gymsKept,
      hrSamplesAdded: hr,
      settingsRestored: restore,
      deletedInFile: b.deletedInFile,
      endsClamped: clamped,
      startingWeightsAdded: startAdded,
      startingWeightsKept: startKept,
    );
  }

  // ---------------------------------------------------------- helpers

  String _uuid() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  String _muscleName(String id) => catalog.muscles
      .firstWhere((m) => m.id == id, orElse: () => Muscle(id, id))
      .name;

  String _describe(List<PlannedSet> sets, LoadUnit unit) {
    final reps = sets.map((s) => s.reps).toSet();
    final loads = sets.map((s) => s.loadG).toSet();
    final repText = reps.length == 1
        ? '${sets.length} x ${reps.first}'
        : sets.map((s) => s.reps).join(', ');
    if (loads.length == 1 && loads.first != null) {
      return '$repText at ${_kg(loads.first!, unit)}';
    }
    if (loads.every((l) => l == null)) return '$repText reps';
    return '$repText at up to ${_kg(loads.whereType<int>().reduce(max), unit)}';
  }

  String _kg(int g, LoadUnit unit) {
    final s = '${_num(g / 1000)} kg';
    return switch (unit) {
      LoadUnit.ea => '$s ea',
      LoadUnit.bodyweight => '+$s',
      _ => s,
    };
  }
}

/// Parses the service's `hr.jsonl` (R2): `{"t_ms":wall,"e_ms":..,"bpm":n}`
/// per line. A torn or bad line is skipped.
List<HrSample> readHrJsonl(String text) {
  final out = <HrSample>[];
  for (final line in const LineSplitter().convert(text)) {
    try {
      final j = jsonDecode(line);
      if (j is Map && j['t_ms'] is int && j['bpm'] is int) {
        out.add(HrSample(j['t_ms'] as int, j['bpm'] as int));
      }
    } on FormatException {
      // torn tail
    }
  }
  return out;
}

double _median(List<int> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m].toDouble() : (s[m - 1] + s[m]) / 2;
}

/// 22.5 → "22.5", 22.0 → "22".
String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// RFC 4180 quoting, plus a leading `'` on values starting with = + - @ (and
/// tab/CR) so a spreadsheet does not run them as formulas. Phase-2 import
/// must strip that `'` again (round-trip test owed then).
String csvField(String v) {
  var out = v;
  if (out.isNotEmpty &&
      '=+-@\t\r'.contains(out[0]) &&
      double.tryParse(out) == null) {
    out = "'$out";
  }
  if (out.contains(RegExp('[",\r\n]'))) {
    out = '"${out.replaceAll('"', '""')}"';
  }
  return out;
}

/// Local calendar-day difference, both read in [tzOffsetMin].
int _dayDiff(int fromMs, int toMs, int tzOffsetMin) {
  int day(int ms) => ((ms + tzOffsetMin * 60000) / 86400000).floor();
  return day(toMs) - day(fromMs);
}

/// Monday-start week number in local time.
int _weekKey(int ms, int tzOffsetMin) {
  // 1970-01-01 was a Thursday: shift by 3 days so weeks start Monday.
  final day = ((ms + tzOffsetMin * 60000) / 86400000).floor();
  return ((day + 3) / 7).floor();
}
