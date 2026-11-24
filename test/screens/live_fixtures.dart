import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';

import 'fixtures.dart';

/// Set 3 of 3 on dumbbell bench press at the condo gym, as last time.
LiveView liveView({
  int reps = 10,
  int? loadG = 22000,
  int? targetLoadG = 22000,
  int targetReps = 10,
  int? restLeftS,
  bool allDone = false,
  LoadUnit unit = LoadUnit.kgEach,
  String name = 'Dumbbell bench press',
  String? undoLabel,
  bool canSwap = false,
  int doneSets = 0,
  int leftSets = 0,
  int? startingWeightG,
  String? plateLine,
}) => LiveView(
  plateLine: plateLine,
  startingWeightG: startingWeightG,
  undoLabel: undoLabel,
  canSwap: canSwap,
  type: WorkoutType.push,
  exerciseName: name,
  lift: 1,
  lifts: 5,
  set: 3,
  sets: 3,
  rail: const [SetTile.done, SetTile.done, SetTile.current],
  reps: reps,
  loadG: loadG,
  unit: unit,
  targetReps: targetReps,
  targetLoadG: targetLoadG,
  lastTime: targetLoadG == null ? null : 'Last time 3 × 10 · 22 kg ea',
  restS: 90,
  upNext: pushPlan.items.sublist(1),
  queue: pushPlan.items,
  canDoLater: true,
  elapsedS: 12 * 60 + 40,
  restLeftS: restLeftS,
  allDone: allDone,
  doneSets: doneSets,
  leftSets: leftSets,
);
