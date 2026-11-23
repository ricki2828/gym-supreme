import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/body_screen.dart';
import 'package:gym_supreme/screens/history_screen.dart';
import 'package:gym_supreme/screens/post_workout_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';
import 'package:gym_supreme/widgets/body_map.dart';

import 'fixtures.dart';
import 'summary_fixtures.dart';

void main() {
  Widget app(Widget w) => MaterialApp(home: w);

  group('post-workout', () {
    testWidgets('headline numbers', (tester) async {
      phone(tester);
      var done = false;
      await tester.pumpWidget(
        app(PostWorkoutScreen(view: pushDone, onDone: () => done = true)),
      );
      expect(find.text('PUSH, DONE'), findsOneWidget);
      expect(find.text('6 WK STREAK'), findsOneWidget);
      expect(find.text('4 MUSCLES LIT'), findsOneWidget);
      expect(find.text('CONDO GYM · 48:12'), findsOneWidget);
      expect(find.text('24 × 10'), findsOneWidget);
      expect(find.text('was 22 × 10'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('7,220 KG'), 200);
      expect(find.text('volume, up 6%'), findsOneWidget);
      expect(find.text('10 · 3 · 3'), findsOneWidget);
      final week = find.text('This week: 4 of 5 lit. Engine is left.');
      await tester.scrollUntilVisible(week, 200);
      expect(week, findsOneWidget);
      expect(find.text('Share'), findsNothing, reason: 'no share in cut 1');
      await tester.tap(find.text('DONE'));
      expect(done, isTrue);
    });

    testWidgets('first session of a type: no delta, no PB card', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(
        app(
          const PostWorkoutScreen(
            view: PostWorkoutView(
              type: WorkoutType.core,
              gymName: 'Condo gym',
              durationS: 600,
              volumeKg: 0,
              setCount: 3,
              musclesLit: ['abs'],
              setsPerGroup: [('Core', 3)],
              weeklyStreak: 0,
            ),
          ),
        ),
      );
      expect(find.text('1 MUSCLE LIT'), findsOneWidget);
      expect(find.textContaining('WK STREAK'), findsNothing);
      expect(find.textContaining('PB ·'), findsNothing);
      await tester.scrollUntilVisible(find.text('volume'), 200);
    });

    testWidgets('slot renders', (tester) async {
      phone(tester);
      await tester.pumpWidget(
        app(PostWorkoutScreen(view: pushDone, totalExtra: const Text('ghost'))),
      );
      await tester.scrollUntilVisible(find.text('ghost'), 200);
    });
  });

  group('history', () {
    testWidgets('rows and open', (tester) async {
      phone(tester);
      String? opened;
      await tester.pumpWidget(
        app(HistoryScreen(rows: historyRows, onOpen: (u) => opened = u)),
      );
      expect(find.text('PUSH'), findsOneWidget);
      expect(find.text('Tue 24 Nov · Condo gym'), findsOneWidget);
      expect(find.text('5,410 KG'), findsOneWidget);
      expect(find.text('MIXED'), findsOneWidget);
      await tester.tap(find.text('LEGS'));
      expect(opened, 'b');
    });

    testWidgets('empty', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(const HistoryScreen(rows: [])));
      expect(find.textContaining('Nothing logged yet'), findsOneWidget);
    });
  });

  group('resume card', () {
    testWidgets('says where to pick up and fires', (tester) async {
      var resumed = false;
      var ended = false;
      await tester.pumpWidget(
        app(
          Scaffold(
            body: ResumeCard(
              type: WorkoutType.legs,
              lift: 3,
              lifts: 6,
              set: 2,
              pausedWhen: 'Sunday',
              onResume: () => resumed = true,
              onDiscard: () => ended = true,
            ),
          ),
        ),
      );
      expect(find.text('LEGS, LIFT 3 OF 6'), findsOneWidget);
      expect(find.text('Paused Sunday. Pick it up at set 2.'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await tester.tap(find.text('End it here'));
      expect(resumed && ended, isTrue);
    });
  });

  group('body tab', () {
    testWidgets('rows, legend and map state', (tester) async {
      phone(tester);
      await tester.pumpWidget(
        app(const BodyScreen(muscles: bodyMuscles, weeklyStreak: 6)),
      );
      expect(find.text('DAYS SINCE'), findsOneWidget);
      expect(find.text('Pull, 3 days ago'), findsOneWidget);
      expect(find.text('Legs, yesterday'), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('longest rest: abs, 6 days'), findsOneWidget);
      final map = tester.widget<BodyMap>(find.byType(BodyMap));
      expect(map.fills.keys.toSet(), {
        'rear-delts',
        'biceps',
        'forearms',
        'traps',
        'lats',
        'lower-back',
      });
      expect(map.resting, {'glutes', 'quads', 'hamstrings', 'calves'});
      final calves = find.textContaining('Calves', findRichText: true);
      await tester.scrollUntilVisible(calves, 200);
      expect(calves, findsOneWidget);
    });

    testWidgets('never trained shows new', (tester) async {
      phone(tester);
      await tester.pumpWidget(
        app(
          const BodyScreen(
            muscles: [
              BodyMuscle(
                id: 'chest',
                name: 'Chest',
                days: null,
                resting: false,
              ),
            ],
          ),
        ),
      );
      expect(find.text('NEW'), findsOneWidget);
    });
  });
}
