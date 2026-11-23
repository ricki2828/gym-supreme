import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/app/workout_port.dart';
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/screens/notification_access.dart';

import 'fixtures.dart';

class FakeAccess implements NotificationAccess {
  FakeAccess({this.on = false, this.asked = false, this.grant = true});
  bool on;
  bool asked;
  bool grant;
  Object? failRequest;
  final calls = <String>[];

  @override
  Future<bool> enabled() async => on;
  @override
  Future<bool> request() async {
    calls.add('request');
    if (failRequest != null) throw failRequest!;
    on = grant;
    return on;
  }

  @override
  Future<void> openSettings() async => calls.add('settings');
  @override
  Future<bool> askedBefore() async => asked;
  @override
  Future<void> markAsked() async {
    calls.add('mark');
    asked = true;
  }
}

void main() {
  group('askNotificationsOnce', () {
    test('already on: no dialog, not marked', () async {
      final a = FakeAccess(on: true);
      expect(await askNotificationsOnce(a), isTrue);
      expect(a.calls, isEmpty);
    });
    test('first time off: marks, then asks', () async {
      final a = FakeAccess();
      expect(await askNotificationsOnce(a), isTrue);
      expect(a.calls, ['mark', 'request']);
    });
    test('denied once: never asks again', () async {
      final a = FakeAccess(grant: false);
      expect(await askNotificationsOnce(a), isFalse);
      expect(await askNotificationsOnce(a), isFalse);
      expect(a.calls, ['mark', 'request']);
    });
  });

  group('in the app', () {
    final catalog = eng.Catalog.fromJson(
      File('assets/exercises_taxonomy.json').readAsStringSync(),
      File('assets/exercises.json').readAsStringSync(),
    );
    late eng.GymEngine engine;
    late StubWorkoutPort port;
    late FakeAccess access;
    late GymDeps deps;
    const now = 1795395600000; // 24-Nov-2026 01:00 UTC

    setUp(() {
      engine = eng.GymEngine(
        catalog: catalog,
        store: eng.MemoryStore(),
        nowMs: () => now,
        tzOffsetMin: () => 480,
        random: Random(9),
      );
      engine.saveGym(engine.gymFromPreset('condo'));
      port = StubWorkoutPort();
      access = FakeAccess(grant: false);
      deps = GymDeps(
        engine: engine,
        port: port,
        catalog: catalog,
        nowMs: () => now,
        tzOffsetMin: () => 480,
        notifications: access,
      );
    });

    Future<void> pumpRoot(WidgetTester tester) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(home: GymRoot(deps: deps)));
      await tester.pumpAndSettle();
    }

    Future<void> tapText(WidgetTester tester, String t) async {
      await tester.ensureVisible(find.text(t).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t).first);
      await tester.pumpAndSettle();
    }

    Future<void> startChest(WidgetTester tester) async {
      await tapText(tester, 'LIGHT SOMETHING UP');
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Chest, ')));
      await tester.pumpAndSettle();
      await tapText(tester, 'START PUSH');
    }

    testWidgets('banner while off; Turn on opens settings', (tester) async {
      await pumpRoot(tester);
      expect(find.byKey(const Key('today.notifications_off')), findsOneWidget);
      await tapText(tester, 'Turn on');
      expect(access.calls, ['settings']);
    });

    testWidgets('no banner when on', (tester) async {
      access.on = true;
      await pumpRoot(tester);
      expect(find.byKey(const Key('today.notifications_off')), findsNothing);
    });

    testWidgets('asks once before the first Start; denied still starts', (
      tester,
    ) async {
      await pumpRoot(tester);
      await startChest(tester);
      expect(access.calls, ['mark', 'request']);
      expect(find.byType(LiveScreen), findsOneWidget, reason: 'never blocks');
      await tapText(tester, 'Pause');
      // Second start (after resume/finish path): no second ask.
      await tapText(tester, 'Resume');
      await tapText(tester, 'Pause');
      expect(access.calls, ['mark', 'request']);
      expect(find.byKey(const Key('today.notifications_off')), findsOneWidget);
    });

    testWidgets('granted at the ask: banner goes', (tester) async {
      access.grant = true;
      await pumpRoot(tester);
      expect(find.byKey(const Key('today.notifications_off')), findsOneWidget);
      await startChest(tester);
      await tapText(tester, 'Pause');
      expect(find.byKey(const Key('today.notifications_off')), findsNothing);
    });

    testWidgets('a failing ask never blocks the start', (tester) async {
      access.failRequest = StateError('host');
      await pumpRoot(tester);
      await startChest(tester);
      expect(find.byType(LiveScreen), findsOneWidget);
      await tapText(tester, 'Pause');
    });

    testWidgets('no access given: no banner, no ask', (tester) async {
      deps = GymDeps(
        engine: engine,
        port: port,
        catalog: catalog,
        nowMs: () => now,
        tzOffsetMin: () => 480,
      );
      await pumpRoot(tester);
      expect(find.byKey(const Key('today.notifications_off')), findsNothing);
      await startChest(tester);
      expect(find.byType(LiveScreen), findsOneWidget);
      await tapText(tester, 'Pause');
    });
  });
}
