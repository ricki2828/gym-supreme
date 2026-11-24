import 'dart:io';

import 'package:gym_engine/gym_engine.dart';
import 'package:test/test.dart';

import '../tool/gen_contract_fixtures.dart' as gen;

/// 0.3 X1: the optional set key `entry: "typed"` (schema stays 1).
void main() {
  final dir = Directory('test/fixtures/contract');
  SessionSnapshot start() => Session.start(
    gen.plan(),
    nowMs: gen.t0,
    tzOffsetMin: gen.tz,
    appVersion: '0.3.0+1',
    workoutUuid: gen.uuid,
  );
  SnapshotSet set(SessionSnapshot s, int n) =>
      [for (final e in s.exercises) ...e.sets]
          .firstWhere((x) => x.setId == '${gen.uuid}:$n');

  test('typed retarget marks the set; the key is written last', () {
    final s = Session.retarget(start(), '${gen.uuid}:0', reps: 7, typed: true);
    expect(set(s, 0).entry, SetEntry.typed);
    expect(set(s, 1).entry, isNull, reason: 'carry-forward is not typing');
    final line = s.encode();
    expect(line, contains(',"block":null,"entry":"typed"}'));
    final j = (s.toJson()['exercises'] as List).first as Map;
    final keys = ((j['sets'] as List).first as Map).keys.toList();
    expect(keys, [...SnapshotSet.keys, 'entry']);
    expect(SessionSnapshot.decode(line).encode(), line);
    expect(set(SessionSnapshot.decode(line), 0).entry, SetEntry.typed);
  });

  test('+/- never sets it and never clears it', () {
    var s = Session.retarget(start(), '${gen.uuid}:0', reps: 9);
    expect(set(s, 0).entry, isNull);
    expect(s.encode(), isNot(contains('"entry"')));
    s = Session.retarget(s, '${gen.uuid}:0', loadG: 25000, typed: true);
    expect(set(s, 0).entry, SetEntry.typed);
    // Stepping with + / - afterwards, up and back to net zero: still typed.
    for (final r in [10, 11, 10, 9]) {
      s = Session.retarget(s, '${gen.uuid}:0', reps: r);
      expect(set(s, 0).entry, SetEntry.typed, reason: 'reps $r');
    }
    // A no-op retarget (same value) is the same snapshot, even with typed.
    expect(Session.retarget(s, '${gen.uuid}:0', reps: 9, typed: true), same(s));
  });

  test('Done keeps it; undo clears it; new sets never get it', () {
    var s = Session.retarget(
      start(),
      '${gen.uuid}:0',
      loadG: 21000,
      typed: true,
    );
    s = Session.done(
      s,
      '${gen.uuid}:0',
      nowMs: gen.t0 + 60000,
      completion: Completion.typed,
    );
    expect(set(s, 0).state, SetState.done);
    expect(set(s, 0).entry, SetEntry.typed);
    expect(set(s, 0).completion, Completion.typed);
    final undone = Session.undo(s, '${gen.uuid}:0');
    expect(set(undone, 0).entry, isNull, reason: 'undo restores the plan');
    expect(set(undone, 0).state, SetState.pending);
    final added = Session.addSet(s, 0);
    expect(added.exercises[0].sets.last.entry, isNull);
  });

  test('a 0.2 journal line (no entry key) decodes and re-encodes as is', () {
    for (final n in ['fresh', 'resting', 'mid_set', 'paused', 'finished']) {
      final line = File('${dir.path}/snapshot_v1_$n.json')
          .readAsStringSync()
          .trim();
      expect(line, isNot(contains('"entry"')), reason: n);
      final s = SessionSnapshot.decode(line);
      for (final e in s.exercises) {
        for (final x in e.sets) {
          expect(x.entry, isNull, reason: n);
        }
      }
      expect(s.encode(), line, reason: '$n: no key appears from nowhere');
    }
    // The journal reader takes a 0.2 journal the same way.
    final r = readJournal(
      File('${dir.path}/journal_v1_torn_tail.jsonl').readAsStringSync(),
    );
    expect(r.last, isNotNull);
    expect(r.corruptLines, 0);
  });

  test('the typed fixture decodes with the key and is stable', () {
    final line = File('${dir.path}/snapshot_v1_typed.json')
        .readAsStringSync()
        .trim();
    final s = SessionSnapshot.decode(line);
    expect(set(s, 2).entry, SetEntry.typed);
    expect(set(s, 2).targetLoadG, 20000);
    expect(s.encode(), line);
  });

  test(
    'an unknown entry value reads as not recorded, other keys stay strict',
    () {
      final line = File('${dir.path}/snapshot_v1_typed.json')
          .readAsStringSync()
          .trim();
      final odd = line.replaceFirst('"entry":"typed"', '"entry":"voice"');
      expect(set(SessionSnapshot.decode(odd), 2).entry, isNull);
      // Dropping a required key is still refused.
      expect(
        () => SessionSnapshot.decode(line.replaceFirst('"swaps":0,', '')),
        throwsFormatException,
      );
      // An absent entry is fine; a null one is fine too.
      final nul = line.replaceFirst('"entry":"typed"', '"entry":null');
      expect(set(SessionSnapshot.decode(nul), 2).entry, isNull);
    },
  );
}
