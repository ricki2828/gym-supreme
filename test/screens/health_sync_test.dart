import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/app/health_sync.dart';
import 'package:gym_supreme/platform/platform_api.g.dart';
import 'package:gym_supreme/screens/diagnostics_panel.dart';
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/history_screen.dart';
import 'package:gym_supreme/screens/live_controller.dart';
import 'package:gym_supreme/screens/workout_detail_screen.dart';

import 'fixtures.dart';
import 'flaky_port.dart';

/// Kotlin's HealthApi as Dart sees it: records every call.
class FakeHealthApi extends HealthApi {
  FakeHealthApi({
    this.availability = HealthAvailability.available,
    this.grant = true,
  });

  HealthAvailability availability;

  /// What Health Connect's permission screen answers.
  bool grant;
  bool granted = false;
  bool enabled = false;
  HealthOutcome outcome = HealthOutcome.ok;
  bool throwOnWrite = false;
  final writes = <List<HealthSession>>[];
  final deletes = <List<String>>[];
  int asks = 0;

  HealthStatus _st() => HealthStatus(
    availability: availability,
    granted: granted,
    enabled: enabled,
  );

  @override
  Future<HealthStatus> status() async => _st();

  @override
  Future<HealthStatus> setEnabled(bool on) async {
    if (!on) {
      enabled = false;
    } else if (availability == HealthAvailability.available) {
      if (!granted) {
        asks++;
        granted = grant;
      }
      enabled = granted;
    }
    return _st();
  }

  @override
  Future<HealthResult> writeSessions(List<HealthSession> sessions) async {
    if (throwOnWrite) throw StateError('channel gone');
    writes.add(sessions);
    return HealthResult(outcome: outcome, count: sessions.length);
  }

  @override
  Future<HealthResult> deleteSessions(List<String> ids) async {
    deletes.add(ids);
    return HealthResult(outcome: outcome, count: ids.length);
  }

  /// Writes and deletes in order, as `w:<uuid>@<version>` / `d:<uuid>`.
  List<String> get calls => [
    for (final w in writes)
      for (final s in w) 'w:${s.clientRecordId}@${s.version}',
    for (final d in deletes)
      for (final id in d) 'd:$id',
  ];
}

/// 0.3 H1: Health Connect write of finished workouts. Mapping, the switch,
/// and the triggers (finish, edit, delete, undo; never a discard), over the
/// real engine (MemoryStore) and the stub port.
void main() {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  late int now;
  late eng.MemoryStore store;
  late eng.GymEngine engine;
  late FlakyPort port;
  late FakeHealthApi api;
  late HealthSync health;
  late GymDeps deps;
  late String gymId;

  setUp(() {
    now = DateTime.utc(2026, 11, 24, 1).millisecondsSinceEpoch;
    store = eng.MemoryStore();
    engine = eng.GymEngine(
      catalog: catalog,
      store: store,
      nowMs: () => now,
      tzOffsetMin: () => 780,
      random: Random(7),
    );
    final g = engine.gymFromPreset('condo').withWeights('dumbbells', [
      for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
    ]);
    engine.saveGym(g);
    gymId = g.id;
    port = FlakyPort();
    api = FakeHealthApi();
    // flag: true stands in for a build with GS_FEATURES=health.
    health = HealthSync(api: api, store: store, flag: true);
    deps = GymDeps(
      engine: engine,
      port: port,
      catalog: catalog,
      appVersion: 'test',
      nowMs: () => now,
      tzOffsetMin: () => 780,
      store: store,
      health: health,
    );
  });

  eng.SessionPlan plan() => engine.suggest(
    gymId: gymId,
    muscleIds: const ['chest', 'front-delts', 'side-delts', 'triceps'],
    typeId: 'push',
  );

  /// Started through the app's own controller (GymDeps), sets logged.
  Future<LiveController> started({int sets = 2}) async {
    final c = deps.liveController();
    addTearDown(c.dispose);
    await c.start(plan());
    await c.load(1);
    for (var i = 0; i < sets; i++) {
      now += 60000;
      await c.done();
    }
    return c;
  }

  Future<String> finished() async {
    final c = await started();
    now += 60000;
    final uuid = await c.finish();
    expect(uuid, isNotNull);
    await pumpEventQueue();
    return uuid!;
  }

  Future<void> switchOn() async {
    await health.setEnabled(true);
    expect(health.enabled, isTrue);
  }

  group('mapping', () {
    eng.WorkoutRecord rec({
      String? typeId = 'push',
      int tz = 780,
      int? edited,
      int paused = 0,
    }) => eng.WorkoutRecord(
      uuid: 'u1',
      gymId: 'g',
      typeId: typeId,
      startedAtMs: 1000000,
      tzOffsetMin: tz,
      endedAtMs: 4600000,
      pausedMs: paused,
      editedAtMs: edited,
      sets: const [],
    );

    test('uuid, type title, times and the workout\'s own offset', () {
      final s = healthSessionOf(rec());
      expect(s.clientRecordId, 'u1');
      expect(s.version, 0);
      expect(s.title, 'Push');
      expect(s.startEpochMs, 1000000);
      expect(s.endEpochMs, 4600000);
      expect(s.utcOffsetSeconds, 780 * 60);
    });

    test('negative and half-hour offsets', () {
      expect(healthSessionOf(rec(tz: -300)).utcOffsetSeconds, -18000);
      expect(healthSessionOf(rec(tz: 330)).utcOffsetSeconds, 19800);
    });

    test('an edit raises the version to edited_at_ms', () {
      expect(healthSessionOf(rec(edited: 9000000)).version, 9000000);
    });

    test('paused time stays inside start..end (only its total is kept)', () {
      final s = healthSessionOf(rec(paused: 600000));
      expect(s.startEpochMs, 1000000);
      expect(s.endEpochMs, 4600000);
    });

    test('a mixed pick (no type) gets the default title', () {
      expect(healthSessionOf(rec(typeId: null)).title, healthDefaultTitle);
    });
  });

  group('switch', () {
    test('off by default: a finish writes nothing', () async {
      await finished();
      expect(api.calls, isEmpty);
      expect(api.asks, 0);
    });

    test('on asks for the permission once; refused stays off', () async {
      api.grant = false;
      final st = await health.setEnabled(true);
      expect(api.asks, 1);
      expect(st!.enabled, isFalse);
      expect(health.enabled, isFalse);
      await finished();
      expect(api.calls, isEmpty);
    });

    test(
      'Health Connect missing: stays off, never asks, never throws',
      () async {
        api.availability = HealthAvailability.notInstalled;
        final st = await health.setEnabled(true);
        expect(st!.enabled, isFalse);
        expect(api.asks, 0);
        expect(healthStatusText(st), contains('not installed'));
        await finished();
        expect(api.calls, isEmpty);
      },
    );

    test('flag off: no call reaches Kotlin at all', () async {
      final off = HealthSync(api: api, store: store, flag: false);
      expect(await off.setEnabled(true), isNull);
      final uuid = await finished();
      // Even with Health Connect on and granted, the flag-off sync sends
      // nothing.
      api.enabled = api.granted = true;
      await off.sync(uuid);
      expect(await off.backfill(), isNull);
      expect(api.calls, isEmpty);
    });
  });

  group('triggers', () {
    test('finish writes the stored workout once, version 0', () async {
      await switchOn();
      final uuid = await finished();
      expect(api.calls, ['w:$uuid@0']);
      final s = api.writes.single.single;
      expect(s.title, 'Push');
      expect(s.utcOffsetSeconds, 780 * 60);
      expect(health.written, 1);
    });

    test('discard writes nothing', () async {
      await switchOn();
      final c = await started();
      expect(await c.discard(), isTrue);
      await pumpEventQueue();
      expect(api.calls, isEmpty);
      expect(store.workouts(), isEmpty);
    });

    test('a failed write never blocks the finish and is counted', () async {
      await switchOn();
      api.throwOnWrite = true;
      final uuid = await finished();
      expect(engine.isStored(uuid), isTrue);
      expect(await port.readPendingJournal(), isNull);
      expect(health.failed, 1);
      api.throwOnWrite = false;
      api.outcome = HealthOutcome.permissionDenied;
      await health.sync(uuid);
      expect(health.failed, 2);
    });

    test(
      'backfill sends every workout in history; again is the same ids',
      () async {
        await switchOn();
        final a = await finished();
        final b = await finished();
        api.writes.clear();
        final r = await health.backfill();
        expect(r!.outcome, HealthOutcome.ok);
        expect(r.count, 2);
        expect(api.calls, unorderedEquals(['w:$a@0', 'w:$b@0']));
        await health.backfill();
        expect(
          api.writes.last.map((s) => s.clientRecordId),
          unorderedEquals([a, b]),
        );
      },
    );

    test('backfill with the switch off sends nothing', () async {
      await finished();
      expect(await health.backfill(), isNull);
      expect(api.calls, isEmpty);
    });

    Future<void> tapKey(WidgetTester tester, String key) async {
      final f = find.byKey(Key(key));
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    Future<void> openDetail(WidgetTester tester) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(home: GymRoot(deps: deps)));
      await tester.pumpAndSettle();
      final row = find.byType(HistoryRowTile).first;
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byType(WorkoutDetailScreen), findsOneWidget);
    }

    testWidgets(
      'a workout finished while the app was dead is written on open',
      (tester) async {
        late String uuid;
        await tester.runAsync(() async {
          await switchOn();
          // Lock-screen finish with Flutter gone: the journal is finished, the
          // store does not have it yet. The controller here is not the app's.
          final c = LiveController(
            engine: engine,
            port: port,
            nowMs: () => now,
            tzOffsetMin: 780,
            tick: const Duration(days: 1),
          );
          await c.start(plan());
          await c.load(1);
          now += 60000;
          await c.done();
          c.dispose();
          now += 60000;
          uuid = eng.SessionSnapshot.decode(await port.finishSession())
              .workoutUuid;
        });
        expect(engine.isStored(uuid), isFalse);
        expect(api.calls, isEmpty);
        phone(tester);
        await tester.pumpWidget(MaterialApp(home: GymRoot(deps: deps)));
        await tester.pumpAndSettle();
        await tester.runAsync(pumpEventQueue);
        expect(engine.isStored(uuid), isTrue);
        expect(api.calls, ['w:$uuid@0']);
      },
    );

    testWidgets('edit rewrites with the edited version', (tester) async {
      late String uuid;
      await tester.runAsync(() async {
        await switchOn();
        uuid = await finished();
      });
      api.writes.clear();
      await openDetail(tester);
      final first = store.workout(uuid)!.sets.first;
      await tapKey(tester, 'set.${first.setId}');
      await tapKey(tester, 'edit.reps');
      await tester.enterText(find.byKey(const Key('live.keypad')), '14');
      await tapKey(tester, 'live.keypad.set');
      await tester.runAsync(pumpEventQueue);
      final edited = store.workout(uuid)!.editedAtMs!;
      expect(api.calls, ['w:$uuid@$edited']);
      expect(edited, greaterThan(0));
    });

    testWidgets('delete deletes the session; UNDO writes it again', (
      tester,
    ) async {
      late String uuid;
      await tester.runAsync(() async {
        await switchOn();
        uuid = await finished();
      });
      api.writes.clear();
      await openDetail(tester);
      await tapKey(tester, 'detail.menu');
      await tapKey(tester, 'detail.delete');
      await tapKey(tester, 'delete.confirm');
      await tester.runAsync(pumpEventQueue);
      expect(api.calls, ['d:$uuid']);
      await tester.tap(find.text('UNDO'));
      await tester.pumpAndSettle();
      await tester.runAsync(pumpEventQueue);
      expect(api.calls, ['w:$uuid@0', 'd:$uuid']);
      expect(api.writes.single.single.clientRecordId, uuid);
    });
  });

  group('Diagnostics section', () {
    Future<void> pump(WidgetTester tester, HealthSection s) async {
      phone(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ListView(children: [s])),
        ),
      );
    }

    testWidgets('off: switch can turn on, send past disabled', (tester) async {
      bool? asked;
      await pump(
        tester,
        HealthSection(
          statusText: healthStatusText(
            HealthStatus(
              availability: HealthAvailability.available,
              granted: false,
              enabled: false,
            ),
          ),
          enabled: false,
          canTurnOn: true,
          canSend: false,
          onChanged: (v) => asked = v,
          onSendPast: () {},
        ),
      );
      expect(find.textContaining('Off. Turn on'), findsOneWidget);
      final send = tester.widget<OutlinedButton>(
        find.byKey(const Key('diagnostics.health.backfill')),
      );
      expect(send.onPressed, isNull);
      await tester.tap(find.byKey(const Key('diagnostics.health.switch')));
      expect(asked, isTrue);
    });

    testWidgets('Health Connect missing: switch cannot turn on', (
      tester,
    ) async {
      await pump(
        tester,
        HealthSection(
          statusText: healthStatusText(
            HealthStatus(
              availability: HealthAvailability.unsupported,
              granted: false,
              enabled: false,
            ),
          ),
          enabled: false,
          canTurnOn: false,
          canSend: false,
          onChanged: (_) => fail('must not toggle'),
        ),
      );
      expect(find.textContaining('not available'), findsOneWidget);
      final sw = tester.widget<SwitchListTile>(
        find.byKey(const Key('diagnostics.health.switch')),
      );
      expect(sw.onChanged, isNull);
    });
  });
}
