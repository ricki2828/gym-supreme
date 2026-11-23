import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/app/workout_port.dart';

String snap(String uuid, {int rev = 0}) =>
    jsonEncode({'workout_uuid': uuid, 'rev': rev});

Matcher refused(String code) =>
    throwsA(isA<WorkoutPortException>().having((e) => e.code, 'code', code));

void main() {
  test('rev starts at 0; stale base refused; snapshots echoed', () async {
    final port = StubWorkoutPort();
    final seen = <String>[];
    port.snapshots.listen(seen.add);
    expect(await port.startSession(snap('w1')), 0);
    expect(await port.submitSnapshot(snap('w1', rev: 1), 0), 1);
    expect(
      () => port.submitSnapshot(snap('w1', rev: 2), 0),
      throwsA(isA<StaleRevException>()),
    );
    expect(await port.submitSnapshot(snap('w1', rev: 2), 1), 2);
    await Future<void>.delayed(Duration.zero);
    expect(seen, hasLength(3));
  });

  test('refusals match the service codes', () async {
    final port = StubWorkoutPort();
    expect(() => port.submitSnapshot(snap('w1'), 0), refused('not_running'));
    expect(port.finishSession, refused('not_running'));
    expect(() => port.startSession('nope'), refused('bad_snapshot'));
    await port.startSession(snap('w1'));
    expect(() => port.startSession(snap('w1')), refused('already_running'));
    expect(() => port.submitSnapshot(snap('w2'), 0), refused('wrong_workout'));
    expect(() => port.submitSnapshot('nope', 0), refused('bad_snapshot'));
    expect(() => port.deleteJournal('w1'), refused('still_running'));
    expect(
      () => port.shareFile('a/b.csv', 'text/csv', ''),
      refused('bad_file_name'),
    );
  });

  test(
    'finish order: finished flag, journal kept until deleteJournal',
    () async {
      final port = StubWorkoutPort();
      await port.startSession(snap('w1'));
      final done = jsonDecode(await port.finishSession()) as Map;
      expect(done['finished'], isTrue);
      expect(() => port.startSession(snap('w2')), refused('finish_pending'));
      expect(() => port.deleteJournal('other'), refused('wrong_workout'));
      await port.deleteJournal('w1');
      expect(await port.readPendingJournal(), isNull);
    },
  );

  test('resume continues the rev from the journal head; no restart', () async {
    final port = StubWorkoutPort();
    await port.startSession(snap('w1'));
    expect(await port.submitSnapshot(snap('w1', rev: 1), 0), 1);
    await port.pauseSession();
    expect(await port.readPendingJournal(), snap('w1', rev: 1));
    expect(() => port.startSession(snap('w1')), refused('already_running'));
    expect(() => port.startSession(snap('w2')), refused('already_running'));
    expect(
      () => port.submitSnapshot(snap('w1', rev: 2), 0),
      throwsA(isA<StaleRevException>()),
    );
    expect(await port.submitSnapshot(snap('w1', rev: 2), 1), 2);
    expect(port.running, isTrue);
  });

  test('a finished journal refuses submit until deleted', () async {
    final port = StubWorkoutPort();
    await port.startSession(snap('w1'));
    await port.finishSession();
    expect(
      () => port.submitSnapshot(snap('w1', rev: 2), 1),
      refused('finished'),
    );
    final again = jsonDecode(await port.finishSession()) as Map;
    expect(again['rev'], 1, reason: 'already finished: returned unchanged');
  });

  test('finish stamps finished and rev + 1 unless Dart already did', () async {
    final port = StubWorkoutPort();
    await port.startSession(snap('w1'));
    final stamped = jsonDecode(await port.finishSession()) as Map;
    expect(stamped['rev'], 1);
    expect(stamped['finished'], isTrue);

    final p2 = StubWorkoutPort();
    await p2.startSession(snap('w2'));
    final fin = jsonEncode({'workout_uuid': 'w2', 'rev': 1, 'finished': true});
    expect(await p2.submitSnapshot(fin, 0), 1);
    expect(p2.running, isFalse);
    expect(await p2.finishSession(), fin);
    await p2.deleteJournal('w2');
  });

  test('a paused snapshot stops the service; delete then allowed', () async {
    final port = StubWorkoutPort();
    await port.startSession(snap('w1'));
    final paused = jsonEncode({
      'workout_uuid': 'w1',
      'rev': 1,
      'state': 'paused',
    });
    await port.submitSnapshot(paused, 0);
    expect(port.running, isFalse);
    await port.pauseSession();
    await port.deleteJournal('w1');
    expect(await port.readPendingJournal(), isNull);
  });

  test('finish works while paused', () async {
    final port = StubWorkoutPort();
    await port.startSession(snap('w1'));
    await port.pauseSession();
    final done = jsonDecode(await port.finishSession()) as Map;
    expect(done['finished'], isTrue);
    await port.dispose();
  });

  test('resume using only the pending journal (as after a reboot)', () async {
    final port = StubWorkoutPort();
    await port.startSession(snap('w1'));
    await port.submitSnapshot(snap('w1', rev: 1), 0);
    await port.pauseSession();
    final head = jsonDecode((await port.readPendingJournal())!) as Map;
    final r = head['rev'] as int;
    expect(await port.submitSnapshot(snap('w1', rev: r + 1), r), r + 1);
  });

  test('a snapshot with the wrong rev is bad_snapshot', () async {
    final port = StubWorkoutPort();
    expect(
      () => port.startSession(snap('w1', rev: 3)),
      refused('bad_snapshot'),
    );
    await port.startSession(snap('w1'));
    expect(
      () => port.submitSnapshot(snap('w1', rev: 5), 0),
      refused('bad_snapshot'),
    );
  });

  test(
    'finish is emitted on the stream; a paused journal can be discarded',
    () async {
      final port = StubWorkoutPort();
      final seen = <String>[];
      port.snapshots.listen(seen.add);
      await port.startSession(snap('w1'));
      await port.finishSession();
      await Future<void>.delayed(Duration.zero);
      expect((jsonDecode(seen.last) as Map)['finished'], isTrue);

      final other = StubWorkoutPort();
      await other.startSession(snap('w2'));
      await other.pauseSession();
      await other.pauseSession(); // idempotent while the journal is unfinished
      expect(StubWorkoutPort().pauseSession, refused('not_running'));
      await other.deleteJournal('w2');
      expect(await other.readPendingJournal(), isNull);
    },
  );

  test(
    'workout_uuid is the key (schema 1); a missing id is bad_snapshot',
    () async {
      final port = StubWorkoutPort();
      expect(
        () => port.startSession(jsonEncode({'uuid': 'w1', 'rev': 0})),
        refused('bad_snapshot'),
      );
      await port.startSession(snap('w1'));
      expect(
        () => port.submitSnapshot(jsonEncode({'rev': 1}), 0),
        refused('bad_snapshot'),
      );
      await port.finishSession();
      await port.deleteJournal('w1'); // B1 finish order completes
      expect(await port.readPendingJournal(), isNull);
    },
  );
}
