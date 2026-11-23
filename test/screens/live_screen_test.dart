import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';

import 'fixtures.dart';
import 'live_fixtures.dart';

void main() {
  Widget app(Widget w) => MaterialApp(home: w);

  testWidgets('as planned: Done says so and fires', (tester) async {
    phone(tester);
    var done = 0;
    await tester.pumpWidget(
      app(LiveScreen(view: liveView(), onDone: () => done++)),
    );
    expect(find.text('LIFT 1 OF 5 · SET 3 OF 3'), findsOneWidget);
    expect(find.text('10 × 22 kg ea, as planned'), findsOneWidget);
    await tester.tap(find.text('DONE'));
    expect(done, 1);
  });

  testWidgets('a changed load says changed', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(LiveScreen(view: liveView(loadG: 24000))));
    expect(find.text('10 × 24 kg ea, changed'), findsOneWidget);
  });

  testWidgets('+/- report steps; load buttons respect the gym range', (
    tester,
  ) async {
    phone(tester);
    final reps = <int>[];
    final load = <int>[];
    await tester.pumpWidget(
      app(
        LiveScreen(
          view: LiveView(
            type: WorkoutType.push,
            exerciseName: 'Dumbbell bench press',
            lift: 1,
            lifts: 5,
            set: 1,
            sets: 3,
            rail: const [SetTile.current, SetTile.pending, SetTile.pending],
            reps: 10,
            loadG: 25000,
            unit: LoadUnit.kgEach,
            targetReps: 10,
            targetLoadG: 25000,
            restS: 90,
            upNext: const [],
            elapsedS: 0,
            canLoadUp: false,
          ),
          onReps: reps.add,
          onLoad: load.add,
        ),
      ),
    );
    final more = find.bySemanticsLabel('More');
    final less = find.bySemanticsLabel('Less');
    await tester.tap(more.first);
    await tester.tap(less.first);
    await tester.tap(more.last); // top of the rack: disabled
    await tester.tap(less.last);
    expect(reps, [1, -1]);
    expect(load, [-1]);
  });

  testWidgets('cold start: Done waits for a weight', (tester) async {
    phone(tester);
    var done = 0;
    await tester.pumpWidget(
      app(
        LiveScreen(
          view: liveView(loadG: null, targetLoadG: null),
          onDone: () => done++,
        ),
      ),
    );
    expect(find.textContaining('First time here'), findsOneWidget);
    expect(find.text('Set a weight first'), findsOneWidget);
    await tester.tap(find.text('DONE'));
    expect(done, 0);
    await tester.pumpWidget(
      app(
        LiveScreen(
          view: liveView(loadG: 12000, targetLoadG: null),
          onDone: () => done++,
        ),
      ),
    );
    expect(find.text('10 × 12 kg ea, first time'), findsOneWidget);
    await tester.tap(find.text('DONE'));
    expect(done, 1);
  });

  testWidgets('rest: countdown, ±15 and skip', (tester) async {
    phone(tester);
    final deltas = <int>[];
    var skipped = false;
    await tester.pumpWidget(
      app(
        LiveScreen(
          view: liveView(restLeftS: 75),
          onRestDelta: deltas.add,
          onSkipRest: () => skipped = true,
        ),
      ),
    );
    expect(find.text('1:15'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('15 seconds more rest'));
    await tester.tap(find.bySemanticsLabel('15 seconds less rest'));
    await tester.tap(find.text('SKIP REST'));
    expect(deltas, [15, -15]);
    expect(skipped, isTrue);
  });

  testWidgets('all done shows only Finish', (tester) async {
    phone(tester);
    var finished = false;
    await tester.pumpWidget(
      app(
        LiveScreen(
          view: liveView(allDone: true),
          onFinish: () => finished = true,
        ),
      ),
    );
    expect(find.text('DONE'), findsNothing);
    await tester.tap(find.text('FINISH'));
    expect(finished, isTrue);
  });

  testWidgets('pause and finish are reachable mid-session', (tester) async {
    phone(tester);
    final got = <String>[];
    await tester.pumpWidget(
      app(
        LiveScreen(
          view: liveView(),
          onPause: () => got.add('pause'),
          onFinish: () => got.add('finish'),
        ),
      ),
    );
    await tester.scrollUntilVisible(find.text('Pause'), 300);
    await tester.ensureVisible(find.text('Pause'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pause'));
    await tester.tap(find.text('Finish'));
    expect(got, ['pause', 'finish']);
  });

  testWidgets('cut-2 slots render', (tester) async {
    phone(tester);
    await tester.pumpWidget(
      app(
        LiveScreen(
          view: liveView(),
          setExtra: const Text('ghost'),
          actions: const [Text('timer')],
        ),
      ),
    );
    expect(find.text('ghost'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('timer'), 300);
    expect(find.text('timer'), findsOneWidget);
  });

  testWidgets('timed sets read as time, not reps', (tester) async {
    phone(tester);
    await tester.pumpWidget(
      app(
        LiveScreen(
          view: liveView(
            name: 'Plank',
            unit: LoadUnit.timed,
            reps: 45,
            targetReps: 45,
            loadG: null,
            targetLoadG: null,
          ),
        ),
      ),
    );
    expect(find.text('0:45, as planned'), findsOneWidget);
    await tester.pumpWidget(
      app(
        LiveScreen(
          view: liveView(
            name: 'Plank',
            unit: LoadUnit.timed,
            reps: 45,
            targetReps: 45,
            loadG: null,
            targetLoadG: null,
            restLeftS: 30,
          ),
        ),
      ),
    );
    expect(find.text('0:45'), findsOneWidget);
    expect(find.textContaining('REPS'), findsNothing);
  });

  testWidgets('1.3x text: Done keeps its sub line, nothing overflows', (
    tester,
  ) async {
    phone(tester, textScale: 1.3);
    await tester.pumpWidget(app(LiveScreen(view: liveView())));
    expect(tester.takeException(), isNull);
    expect(find.text('10 × 22 kg ea, as planned'), findsOneWidget);
  });

  testWidgets(
    'a timer block hides steppers, DONE and rest; setExtra drives it',
    (tester) async {
      phone(tester);
      final base = liveView(
        name: 'Wall balls',
        unit: LoadUnit.timed,
        reps: 0,
        targetReps: 0,
        loadG: null,
        targetLoadG: null,
      );
      final v = LiveView(
        type: base.type,
        exerciseName: base.exerciseName,
        lift: base.lift,
        lifts: base.lifts,
        set: base.set,
        sets: base.sets,
        rail: base.rail,
        reps: base.reps,
        loadG: base.loadG,
        unit: base.unit,
        targetReps: base.targetReps,
        targetLoadG: base.targetLoadG,
        restS: base.restS,
        upNext: base.upNext,
        elapsedS: base.elapsedS,
        timerBlock: true,
      );
      await tester.pumpWidget(
        app(LiveScreen(view: v, setExtra: const Text('timer panel'))),
      );
      expect(find.text('timer panel'), findsOneWidget);
      expect(find.text('DONE'), findsNothing);
      expect(find.text('SEC'), findsNothing);
      expect(find.textContaining('THEN REST'), findsNothing);
      // No timer panel given (a build without cut 2): normal controls.
      await tester.pumpWidget(app(LiveScreen(view: v)));
      expect(find.text('DONE'), findsOneWidget);
      // A plank (timed, no block) keeps its stepper and DONE.
      await tester.pumpWidget(app(LiveScreen(view: base)));
      expect(find.text('DONE'), findsOneWidget);
      expect(find.text('SEC'), findsOneWidget);
    },
  );

  testWidgets('rest before a timer block names the block, not 0:00', (
    tester,
  ) async {
    phone(tester);
    final b = liveView(restLeftS: 40, unit: LoadUnit.timed, reps: 0);
    await tester.pumpWidget(
      app(
        LiveScreen(
          view: LiveView(
            type: b.type,
            exerciseName: 'Wall balls',
            lift: b.lift,
            lifts: b.lifts,
            set: b.set,
            sets: b.sets,
            rail: b.rail,
            reps: 0,
            loadG: null,
            unit: LoadUnit.timed,
            targetReps: 0,
            targetLoadG: null,
            restS: b.restS,
            upNext: b.upNext,
            elapsedS: 125, // header clock 2:05, so '0:00' would be the line
            restLeftS: 40,
            timerBlock: true,
            blockTitle: 'EMOM 20 × 1:00',
          ),
        ),
      ),
    );
    expect(find.text('EMOM 20 × 1:00'), findsOneWidget);
    expect(find.text('0:00'), findsNothing);
  });
}
