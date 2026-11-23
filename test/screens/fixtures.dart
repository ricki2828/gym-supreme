import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/view_models.dart';

/// Shared UI fixtures: Ricki's condo gym (plan Q14) and the jam's day story
/// (pull Saturday, legs yesterday, today Tuesday).
const condo = GymView(
  id: 'condo',
  name: 'Condo gym',
  kit: {
    'adjustable-bench',
    'dumbbells',
    'cable-stack',
    'overhead-cable-bench',
    'leg-extension',
  },
);

const allMuscles = [
  'chest',
  'front-delts',
  'side-delts',
  'rear-delts',
  'biceps',
  'triceps',
  'forearms',
  'abs',
  'obliques',
  'traps',
  'lats',
  'lower-back',
  'glutes',
  'quads',
  'hamstrings',
  'calves',
];

MuscleDays _d(int days) => MuscleDays(days: days, resting: days < 2);

/// The jam story: push 5 days ago, pull 3, core 6, legs yesterday.
final Map<String, MuscleDays> storyDays = {
  for (final m in ['chest', 'front-delts', 'side-delts', 'triceps']) m: _d(5),
  for (final m in [
    'lats',
    'traps',
    'rear-delts',
    'biceps',
    'forearms',
    'lower-back',
  ])
    m: _d(3),
  for (final m in ['abs', 'obliques']) m: _d(6),
  for (final m in ['quads', 'hamstrings', 'glutes', 'calves']) m: _d(1),
};

final Map<String, MuscleDays> firstRunDays = {
  for (final m in allMuscles) m: const MuscleDays(),
};

final Map<String, MuscleDays> allRestingDays = {
  for (final m in allMuscles) m: _d(1),
  'abs': _d(2),
  'obliques': _d(2),
  'lats': _d(0),
  'traps': _d(0),
  'lower-back': _d(0),
  'biceps': _d(0),
  'forearms': _d(0),
};

const pushSelection = {
  'chest',
  'front-delts',
  'side-delts',
  'rear-delts',
  'triceps',
};

const pushPlan = SessionPlanView(
  type: WorkoutType.push,
  minutes: 45,
  items: [
    PlanItem(
      exerciseId: 'dumbbell-bench-press',
      name: 'Dumbbell bench press',
      sets: 3,
      reps: 10,
      loadG: 22000,
      unit: LoadUnit.kgEach,
    ),
    PlanItem(
      exerciseId: 'incline-dumbbell-press',
      name: 'Incline dumbbell press',
      sets: 3,
      reps: 10,
      loadG: 18000,
      unit: LoadUnit.kgEach,
    ),
    PlanItem(
      exerciseId: 'cable-fly',
      name: 'Cable fly',
      sets: 3,
      reps: 12,
      loadG: 15000,
      unit: LoadUnit.kg,
    ),
    PlanItem(
      exerciseId: 'dumbbell-shoulder-press',
      name: 'Dumbbell shoulder press',
      sets: 3,
      reps: 10,
      loadG: 16000,
      unit: LoadUnit.kgEach,
    ),
    PlanItem(
      exerciseId: 'cable-pushdown',
      name: 'Cable pushdown',
      sets: 3,
      reps: 12,
      loadG: 25000,
      unit: LoadUnit.kg,
    ),
  ],
);

SessionPlanView coldPlan() => SessionPlanView(
  type: WorkoutType.push,
  minutes: 45,
  items: [
    for (final p in pushPlan.items)
      PlanItem(
        exerciseId: p.exerciseId,
        name: p.name,
        sets: p.sets,
        reps: p.reps,
        loadG: null,
        unit: p.unit,
      ),
  ],
);

const corePlan = SessionPlanView(
  type: WorkoutType.core,
  minutes: 20,
  items: [
    PlanItem(
      exerciseId: 'cable-crunch',
      name: 'Cable crunch',
      sets: 3,
      reps: 12,
      loadG: 20000,
      unit: LoadUnit.kg,
    ),
    PlanItem(
      exerciseId: 'dumbbell-side-bend',
      name: 'Dumbbell side bend',
      sets: 3,
      reps: 12,
      loadG: 14000,
      unit: LoadUnit.kgEach,
    ),
    PlanItem(
      exerciseId: 'plank',
      name: 'Plank',
      sets: 3,
      reps: 45,
      loadG: null,
      unit: LoadUnit.timed,
    ),
  ],
);

const longNamesPlan = SessionPlanView(
  type: WorkoutType.push,
  minutes: 40,
  items: [
    PlanItem(
      exerciseId: 'a',
      name: 'Single-arm incline dumbbell bench press, neutral grip',
      sets: 3,
      reps: 10,
      loadG: 18000,
      unit: LoadUnit.kgEach,
    ),
    PlanItem(
      exerciseId: 'b',
      name: 'Half-kneeling single-arm cable chest press',
      sets: 3,
      reps: 12,
      loadG: 12000,
      unit: LoadUnit.kg,
    ),
    PlanItem(
      exerciseId: 'c',
      name: 'Seated dumbbell shoulder press, back supported',
      sets: 3,
      reps: 10,
      loadG: 16000,
      unit: LoadUnit.kgEach,
    ),
    PlanItem(
      exerciseId: 'd',
      name: 'Overhead cable triceps extension with rope',
      sets: 3,
      reps: 12,
      loadG: 20000,
      unit: LoadUnit.kg,
    ),
  ],
);

/// A 412 x 915 phone (the mockup frame) at 2.625 dpr, like a Pixel 8 Pro.
void phone(WidgetTester tester, {double textScale = 1.0}) {
  tester.view.physicalSize = const Size(1081.5, 2401.875);
  tester.view.devicePixelRatio = 2.625;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}
