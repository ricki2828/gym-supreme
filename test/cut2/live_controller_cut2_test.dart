import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/cut2.dart' as c2;
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/app/feature_flags.dart';
import 'package:gym_supreme/app/workout_port.dart';
import 'package:gym_supreme/screens/live_controller.dart';

/// Cut-2 timers through the real controller, engine (MemoryStore) and the
/// stub port: add → start → pause/resume → log → B1 finish → stored row.
void main() {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  late int now;
  late eng.MemoryStore store;
  late eng.GymEngine engine;
  late StubWorkoutPort port;
  late LiveController c;

  setUp(() async {
    now = DateTime.utc(2026, 11, 24, 1).millisecondsSinceEpoch;
    store = eng.MemoryStore();
    engine = eng.GymEngine(
      catalog: catalog,
      store: store,
      nowMs: () => now,
      tzOffsetMin: () => 480,
      random: Random(5),
    );
    engine.saveGym(engine.gymFromPreset('condo'));
    port = StubWorkoutPort();
    c = LiveController(
      engine: engine,
      port: port,
      nowMs: () => now,
      tzOffsetMin: 480,
      store: store,
    );
    final gym = engine.gyms().first;
    await c.start(
      engine.suggest(gymId: gym.id, muscleIds: const ['chest'], typeId: 'push'),
    );
  });

  tearDown(() => c.dispose());

  test('add timer: one rev, current set is the armed block', () async {
    final rev = c.snapshot!.rev;
    final firstEx = c.snapshot!.exercises.first.exerciseId;
    await c.addTimer(c2.TimerBlock.emom(rounds: 2));
    expect(c.snapshot!.rev, rev + 1);
    expect(c.currentTimer, c2.TimerBlock.emom(rounds: 2));
    expect(c.snapshot!.exercises.first.exerciseId, firstEx); // same lift
    expect(c.snapshot!.currentSet!.kind, eng.SetKind.timed);
    expect(c.timerRunning, isFalse);
  });

  test('start → pause → resume → log → finish stores the block', () async {
    await c.addTimer(c2.TimerBlock.amrap(capMs: 120000, warnMs: 0));
    final timedId = c.snapshot!.currentSet!.setId;
    await c.startTimer();
    expect(c.timerRunning, isTrue);

    now += 30000;
    expect(await c.pause(), isTrue);
    expect(c.timerRunning, isFalse);
    // A log tapped while paused is ignored (never resumes the session).
    await c.finishTimer(amrapRounds: 3);
    expect(c.snapshot!.state, eng.SessionState.paused);

    now += 60000;
    await c.resume(c.snapshot!);
    expect(c.timerRunning, isTrue);
    expect(c.timerElapsedMs(now + 5000), 35000);

    now += 90000; // past the 2:00 cap
    await c.finishTimer(amrapRounds: 4, amrapExtraReps: 2);
    final logged = c.snapshot!.exercises
        .expand((e) => e.sets)
        .firstWhere((s) => s.setId == timedId);
    expect(logged.state, eng.SetState.done);
    expect(logged.block!['amrap_rounds'], 4);
    expect(logged.block!['cues'], isEmpty);

    final uuid = await c.finish();
    expect(uuid, isNotNull);
    final rec = store.workouts().single;
    final row = rec.sets.firstWhere((s) => s.kind == eng.SetKind.timed);
    final block = jsonDecode(row.blockJson!) as Map<String, Object?>;
    expect(block['amrap_rounds'], 4);
    expect(block['amrap_extra_reps'], 2);
    expect(row.volumeGReps, 0); // R4: no load volume
    // Rotation advances only with its flag on (0.1: off, untouched).
    expect(c2.loadRotation(store).nextId, Features.rotation ? 'pull' : 'push');
  });

  test('plain DONE on a reps set is unchanged by cut 2', () async {
    final id = c.snapshot!.currentSet!.setId;
    await c.done();
    final s = c.snapshot!.exercises
        .expand((e) => e.sets)
        .firstWhere((x) => x.setId == id);
    expect(s.state, eng.SetState.done);
  });
}
