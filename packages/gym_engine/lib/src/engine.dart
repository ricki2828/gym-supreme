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
import 'model.dart';
import 'snapshot.dart';
import 'store.dart';

/// Weighted sets a muscle needs in one workout to count as "trained hard"
/// (primary 1.0, secondary 0.5). Tunable; covered by tests.
const double hardSetThreshold = 2.0;

/// Under this, a muscle shows as resting (plan 5.2: under 2 days).
const int restingMs = 48 * 3600 * 1000;

/// Work time assumed per set when fitting the time budget.
const int workSecondsPerSet = 45;

/// Export bundle format version.
const int exportFormat = 1;

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
          uncoveredAtGym: !catalog.exercises.any(
            (e) => e.primary.contains(m.id) && e.availableWith(kit),
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
      for (final m in muscleIds)
        if (catalog.muscles.any((x) => x.id == m)) m,
    ];
    final status = muscleStatus(gymId: gymId);
    final workouts = store.workouts();
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

    int rank(Exercise a, Exercise b) {
      if (a.isCompound != b.isCompound) return a.isCompound ? -1 : 1;
      final h = (historyCount[b.id] ?? 0).compareTo(historyCount[a.id] ?? 0);
      if (h != 0) return h;
      return a.id.compareTo(b.id);
    }

    final need = <String, double>{
      for (var i = 0; i < picked.length; i++) picked[i]: i == 0 ? 9 : 6,
    };
    final chosen = <Exercise>[];
    final setsOf = <String, int>{};
    for (final m in picked) {
      final pool =
          available.where((e) => e.primary.contains(m) && allowed(e)).toList()
            ..sort(rank);
      for (final e in pool) {
        if ((need[m] ?? 0) <= 0) break;
        if (chosen.contains(e)) continue;
        chosen.add(e);
        setsOf[e.id] = 3;
        for (final p in e.primary) {
          if (need.containsKey(p)) need[p] = need[p]! - 3;
        }
        for (final s in e.secondary) {
          if (need.containsKey(s) && !e.primary.contains(s)) {
            need[s] = need[s]! - 1.5;
          }
        }
      }
    }

    // Rotate one slot per session for variety (plan 5.5).
    if (chosen.length > 1 && seed != 0) {
      final slot = seed.abs() % chosen.length;
      final out = chosen[slot];
      final lead = out.primary.firstWhere(
        picked.contains,
        orElse: () => out.primary.first,
      );
      final alt =
          available
              .where(
                (e) =>
                    !chosen.contains(e) &&
                    e.primary.contains(lead) &&
                    allowed(e) &&
                    e.isCompound == out.isCompound,
              )
              .toList()
            ..sort(rank);
      if (alt.isNotEmpty) {
        chosen[slot] = alt.first;
        setsOf[alt.first.id] = setsOf.remove(out.id)!;
      }
    }

    // Compounds first, then isolation, keeping pick order inside each.
    final ordered = [
      ...chosen.where((e) => e.isCompound),
      ...chosen.where((e) => !e.isCompound),
    ];

    int restOf(Exercise e) =>
        e.isCompound ? settings.restCompoundS : settings.restIsolationS;
    int estimate() {
      var t = 0;
      for (final e in ordered) {
        t += setsOf[e.id]! * (workSecondsPerSet + restOf(e));
      }
      return t;
    }

    // Fit the time: trim sets (isolation first, never below 2), then drop
    // exercises from the end.
    while (ordered.isNotEmpty && estimate() > budgetS) {
      Exercise? trim;
      for (final e in ordered.reversed) {
        if (setsOf[e.id]! > 2) {
          trim = e;
          break;
        }
      }
      if (trim != null) {
        setsOf[trim.id] = setsOf[trim.id]! - 1;
      } else {
        setsOf.remove(ordered.removeLast().id);
      }
    }

    final items = [
      for (final e in ordered)
        _plannedItem(
          e,
          gymId: gymId,
          sets: setsOf[e.id]!,
          restS: restOf(e),
          status: status,
          picked: picked,
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
    final kit = g?.equipmentIds ?? const <String>{};
    final have = {...kit, bodyweight};
    final set = e.equipmentSets.firstWhere(
      have.containsAll,
      orElse: () => e.equipmentSets.first,
    );
    final loads = <int>{};
    for (final id in set) {
      final eq = catalog.equipmentById(id);
      if (eq == null) continue;
      final item = g?.kit[id];
      if (eq.load == 'barbell') {
        final plates = g?.kit['plates']?.weightsG ?? const <int>[];
        loads.addAll(_barbellLoads(plates));
      } else if (eq.load == e.load) {
        final w = item?.weightsG ?? const <int>[];
        loads.addAll(w.isNotEmpty ? w : (defaultWeightsG[eq.load] ?? const []));
      }
    }
    if (loads.isEmpty) loads.addAll(defaultWeightsG[e.load] ?? const []);
    return LoadSteps(unit, loads.toList()..sort());
  }

  /// 20 kg bar plus pairs of plates, up to two pairs of each size. Without a
  /// plate list: 20-140 kg in 2.5 kg steps.
  List<int> _barbellLoads(List<int> plates) {
    const bar = 20000;
    if (plates.isEmpty) {
      return [for (var g = bar; g <= 140000; g += 2500) g];
    }
    var sums = <int>{0};
    for (final p in plates) {
      sums = {
        for (final s in sums) ...[s, s + 2 * p, s + 4 * p],
      };
    }
    return [for (final s in sums) bar + s];
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

  // ----------------------------------------------------- finish, resume

  @override
  void saveFinished(SessionSnapshot snapshot, {List<HrSample> hr = const []}) {
    if (!snapshot.finished) {
      throw ArgumentError('saveFinished needs a finished snapshot');
    }
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
    String? journalText,
  ) {
    final last = journalText == null ? null : readJournal(journalText).last;
    if (last == null) return (action: RecoveryAction.none, snapshot: null);
    if (store.hasWorkout(last.workoutUuid)) {
      return (action: RecoveryAction.deleteJournal, snapshot: last);
    }
    if (last.finished) {
      saveFinished(last);
      return (action: RecoveryAction.savedThenDelete, snapshot: last);
    }
    return (action: RecoveryAction.offerResume, snapshot: last);
  }

  // ------------------------------------------------- summary, history

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
      weeklyStreak: weeklyStreak(all.sublist(0, i + 1)),
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
    final all = store.workouts();
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
    );
  }

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
          'completion': s.completion.wire,
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
          s.completion.wire,
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
