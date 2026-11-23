import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/app/workout_port.dart';

String snap(String uuid, {int n = 0}) => jsonEncode({'uuid': uuid, 'n': n});

void main() {
  test('stub port is the rev authority and rejects a stale base', () async {
    final port = StubWorkoutPort();
    final seen = <String>[];
    port.snapshots.listen(seen.add);
    expect(await port.startSession(snap('w1')), 0);
    expect(await port.submitSnapshot(snap('w1', n: 1), 0), 1);
    expect(
      () => port.submitSnapshot(snap('w1', n: 2), 0),
      throwsA(isA<StaleRevException>()),
    );
    expect(await port.submitSnapshot(snap('w1', n: 2), 1), 2);
    await Future<void>.delayed(Duration.zero);
    expect(seen, hasLength(3));
  });

  test('finish marks finished; journal survives until deleteJournal', () async {
    final port = StubWorkoutPort();
    await port.startSession(snap('w1'));
    final done = jsonDecode(await port.finishSession()) as Map;
    expect(done['finished'], isTrue);
    expect(await port.readPendingJournal(), isNotNull);
    await port.deleteJournal('other');
    expect(await port.readPendingJournal(), isNotNull);
    await port.deleteJournal('w1');
    expect(await port.readPendingJournal(), isNull);
  });

  test('pause keeps the journal for resume', () async {
    final port = StubWorkoutPort();
    await port.startSession(snap('w1'));
    await port.pauseSession();
    expect(port.running, isFalse);
    expect(await port.readPendingJournal(), snap('w1'));
  });
}
