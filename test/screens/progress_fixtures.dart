import 'dart:io';

import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/progress_model.dart';

/// Thursday 26 Nov 2026, 12:00 UTC; every fixture offset is UTC.
final progressNow = DateTime.utc(2026, 11, 26, 12).millisecondsSinceEpoch;
const dayMs = 86400000;

const bench = 'barbell-bench-press-medium-grip';
const squat = 'barbell-squat';
const legPress = 'leg-press';
const cableRows = 'cable-seated-lateral-raise';

final eng.Catalog progressCatalog = eng.Catalog.fromJson(
  File('assets/exercises_taxonomy.json').readAsStringSync(),
  File('assets/exercises.json').readAsStringSync(),
);

const gymNames = {'g1': 'Condo gym', 'g2': 'Hotel gym'};

int _n = 0;

eng.SetRecord set(
  String ex,
  int ord,
  num kg,
  int reps, {
  eng.Completion completion = eng.Completion.adjusted,
}) => eng.SetRecord(
  setId: 'set${_n++}',
  exerciseId: ex,
  exerciseName: ex,
  exercisePosition: 0,
  setOrdinal: ord,
  loadG: (kg * 1000).round(),
  reps: reps,
  completion: completion,
);

/// A workout [daysAgo] before [progressNow] (at 09:00 UTC that day).
eng.WorkoutRecord workout(
  String id,
  int daysAgo,
  List<eng.SetRecord> sets, {
  String gym = 'g1',
}) {
  final start =
      DateTime.utc(2026, 11, 26, 9).millisecondsSinceEpoch - daysAgo * dayMs;
  return eng.WorkoutRecord(
    uuid: id,
    gymId: gym,
    startedAtMs: start,
    tzOffsetMin: 0,
    endedAtMs: start + 3600000,
    sets: sets,
  );
}

/// Six weeks of bench and squat, one session each every few days.
List<eng.WorkoutRecord> sixWeeks() => [
  for (var i = 0; i < 8; i++)
    workout('w$i', 40 - i * 5, [
      set(bench, 1, 40, 8),
      set(bench, 2, 60 + i * 2.5, 5),
      set(bench, 3, 60 + i * 2.5, 5),
      set(squat, 1, 60, 8),
      set(squat, 2, 90 + i * 5, 5),
      set(squat, 3, 90 + i * 5, 5),
    ]),
];

ProgressView view(
  List<eng.WorkoutRecord> ws, {
  Profile profile = const Profile(),
  Set<String> confirmed = const {},
  int? legacyG,
}) => buildProgress(
  workouts: ws,
  catalog: progressCatalog,
  gymNames: gymNames,
  profile: profile,
  nowMs: progressNow,
  tzOffsetMin: 0,
  legacyBodyweightG: legacyG,
  confirmed: confirmed,
);

/// Weighed in on [date] (82.5 kg).
Profile weighed(String date) =>
    const Profile(birthYear: 1990, sex: 'male').withWeighIn(date, 82500);

// Scenarios -----------------------------------------------------------

ProgressView noProfile() => view(sixWeeks());

ProgressView staleBodyweight() =>
    view(sixWeeks(), profile: weighed('2026-08-20'));

/// Bench best is a 12-rep set: rough, and no solid set to fall back on.
ProgressView roughE1rm() => view([
  workout('r1', 9, [set(bench, 1, 50, 12), set(bench, 2, 50, 12)]),
  workout('r2', 2, [set(bench, 1, 55, 12), set(bench, 2, 55, 11)]),
], profile: weighed('2026-11-20'));

/// One session, plus a stack lift at a gym he has never used.
ProgressView firstData() => view([
  workout('f1', 1, [
    set(bench, 1, 40, 8),
    set(bench, 2, 70, 5),
    set(legPress, 1, 100, 10, completion: eng.Completion.coldStart),
  ], gym: 'g2'),
], profile: weighed('2026-11-20'));

/// A fat-fingered 200 kg bench after a 70 kg history.
List<eng.WorkoutRecord> typoWorkouts() => [
  workout('t1', 20, [set(bench, 1, 70, 5)]),
  workout('t2', 10, [set(bench, 1, 72.5, 5)]),
  workout('t3', 1, [set(bench, 1, 70, 5), set(bench, 2, 200, 5)]),
];
