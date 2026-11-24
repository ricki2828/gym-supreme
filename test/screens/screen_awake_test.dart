import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/live_controller.dart';
import 'package:gym_supreme/screens/screen_awake.dart';

import 'flaky_port.dart';

class _Recorder implements ScreenAwake {
  final List<bool> calls = [];
  Object? failWith;

  @override
  Future<void> set(bool on) async {
    calls.add(on);
    if (failWith != null) throw failWith!;
  }
}

/// 0.3 X1: the screen stays on while a session runs. The Kotlin side logs a
/// `keep_screen_on` line per call; the emulator smoke checks it.
void main() {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  late int now;
  late eng.GymEngine engine;
  late FlakyPort port;
  late _Recorder awake;
  late String gymId;

  setUp(() {
    now = DateTime.utc(2026, 11, 24, 1).millisecondsSinceEpoch;
    engine = eng.GymEngine(
      catalog: catalog,
      store: eng.MemoryStore(),
      nowMs: () => now,
      tzOffsetMin: () => 480,
      random: Random(7),
    );
    final g = engine.gymFromPreset('condo').withWeights('dumbbells', [
      for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
    ]);
    engine.saveGym(g);
    gymId = g.id;
    port = FlakyPort();
    awake = _Recorder();
  });

  LiveController controller({bool tearDown = true}) {
    final c = LiveController(
      engine: engine,
      port: port,
      nowMs: () => now,
      tzOffsetMin: 480,
      tick: const Duration(days: 1),
      awake: awake,
    );
    if (tearDown) addTearDown(c.dispose);
    return c;
  }

  eng.SessionPlan plan() => engine.suggest(
    gymId: gymId,
    muscleIds: const ['chest', 'triceps'],
    typeId: 'push',
  );

  test('on at start, off at finish', () async {
    final c = controller(tearDown: false);
    await c.start(plan());
    expect(awake.calls, [true]);
    await c.load(1);
    await c.done();
    expect(awake.calls, [true], reason: 'taps do not toggle it');
    expect(await c.finish(), isNotNull);
    expect(awake.calls, [true, false]);
    c.dispose();
    expect(awake.calls, [true, false], reason: 'dispose adds nothing');
  });

  test('off at pause, on again at resume', () async {
    final c = controller();
    await c.start(plan());
    expect(await c.pause(), isTrue);
    expect(awake.calls, [true, false]);
    final pending = eng.readJournal((await port.readPendingJournal())!).last;
    final c2 = controller();
    await c2.resume(pending!);
    expect(awake.calls, [true, false, true]);
  });

  test('off at discard', () async {
    final c = controller();
    await c.start(plan());
    expect(await c.discard(), isTrue);
    expect(awake.calls, [true, false]);
  });

  test('dispose turns it off if the session was left running', () async {
    final c = controller(tearDown: false);
    await c.start(plan());
    c.dispose();
    expect(awake.calls, [true, false]);
  });

  test('a failing host call never blocks logging', () async {
    awake.failWith = StateError('no activity');
    final c = controller();
    await c.start(plan());
    await c.load(1);
    await c.done();
    expect(c.lastError, isNull);
    expect(c.view()!.doneSets, 1);
  });

  test('no ScreenAwake: nothing happens', () async {
    final c = LiveController(
      engine: engine,
      port: port,
      nowMs: () => now,
      tzOffsetMin: 480,
      tick: const Duration(days: 1),
    );
    addTearDown(c.dispose);
    await c.start(plan());
    expect(await c.finish(), isNotNull);
  });
}
