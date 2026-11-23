import 'package:gym_supreme/screens/body_screen.dart';
import 'package:gym_supreme/screens/history_screen.dart';
import 'package:gym_supreme/screens/post_workout_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';

const pushDone = PostWorkoutView(
  type: WorkoutType.push,
  gymName: 'Condo gym',
  durationS: 48 * 60 + 12,
  volumeKg: 7220,
  volumeDeltaPct: 6,
  setCount: 16,
  musclesLit: ['chest', 'front-delts', 'side-delts', 'triceps'],
  setsPerGroup: [('Chest', 10), ('Shoulders', 3), ('Triceps', 3)],
  weeklyStreak: 6,
  pbs: [
    PbView(
      exercise: 'Dumbbell bench press',
      loadG: 24000,
      reps: 10,
      unit: LoadUnit.kgEach,
      wasLoadG: 22000,
      wasReps: 10,
    ),
  ],
  weekTypes: {
    WorkoutType.push,
    WorkoutType.pull,
    WorkoutType.legs,
    WorkoutType.core,
  },
);

final historyRows = [
  HistoryRowView(
    uuid: 'a',
    startedAt: DateTime(2026, 11, 24, 7, 5),
    gymName: 'Condo gym',
    type: WorkoutType.push,
    durationS: 2892,
    volumeKg: 7220,
    setCount: 16,
  ),
  HistoryRowView(
    uuid: 'b',
    startedAt: DateTime(2026, 11, 22, 18, 30),
    gymName: 'Condo gym',
    type: WorkoutType.legs,
    durationS: 2500,
    volumeKg: 5410.4,
    setCount: 14,
  ),
  HistoryRowView(
    uuid: 'c',
    startedAt: DateTime(2026, 11, 21, 6, 50),
    gymName: 'Condo gym',
    type: WorkoutType.pull,
    durationS: 2700,
    volumeKg: 6120,
    setCount: 15,
  ),
  HistoryRowView(
    uuid: 'd',
    startedAt: DateTime(2026, 11, 18, 7, 0),
    gymName: 'Condo gym',
    type: null,
    durationS: 1500,
    volumeKg: 2100,
    setCount: 8,
  ),
];

/// b2-body's story: pull Saturday (3), legs yesterday (1), push 5, core 6.
const bodyMuscles = [
  BodyMuscle(id: 'chest', name: 'Chest', days: 5, lastType: WorkoutType.push),
  BodyMuscle(
    id: 'front-delts',
    name: 'Front delts',
    days: 5,
    lastType: WorkoutType.push,
  ),
  BodyMuscle(
    id: 'side-delts',
    name: 'Side delts',
    days: 5,
    lastType: WorkoutType.push,
  ),
  BodyMuscle(
    id: 'rear-delts',
    name: 'Rear delts',
    days: 3,
    lastType: WorkoutType.pull,
  ),
  BodyMuscle(id: 'biceps', name: 'Biceps', days: 3, lastType: WorkoutType.pull),
  BodyMuscle(
    id: 'triceps',
    name: 'Triceps',
    days: 5,
    lastType: WorkoutType.push,
  ),
  BodyMuscle(
    id: 'forearms',
    name: 'Forearms',
    days: 3,
    lastType: WorkoutType.pull,
  ),
  BodyMuscle(id: 'abs', name: 'Abs', days: 6, lastType: WorkoutType.core),
  BodyMuscle(
    id: 'obliques',
    name: 'Obliques',
    days: 6,
    lastType: WorkoutType.core,
  ),
  BodyMuscle(id: 'traps', name: 'Traps', days: 3, lastType: WorkoutType.pull),
  BodyMuscle(id: 'lats', name: 'Lats', days: 3, lastType: WorkoutType.pull),
  BodyMuscle(
    id: 'lower-back',
    name: 'Lower back',
    days: 3,
    lastType: WorkoutType.pull,
  ),
  BodyMuscle(id: 'glutes', name: 'Glutes', days: 1, lastType: WorkoutType.legs),
  BodyMuscle(id: 'quads', name: 'Quads', days: 1, lastType: WorkoutType.legs),
  BodyMuscle(
    id: 'hamstrings',
    name: 'Hamstrings',
    days: 1,
    lastType: WorkoutType.legs,
  ),
  BodyMuscle(id: 'calves', name: 'Calves', days: 1, lastType: WorkoutType.legs),
];
