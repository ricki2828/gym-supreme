import 'dart:convert';
import 'dart:io';

import 'package:gym_engine/gym_engine.dart';
import 'package:test/test.dart';

import '../tool/gen_contract_fixtures.dart' as gen;

/// The same files live in android/core/src/test/fixtures/contract; CI diffs
/// the two directories and fails on any drift or an empty directory.
void main() {
  final dir = Directory('test/fixtures/contract');

  test('contract fixtures directory has files', () {
    final files = dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.json'),
    );
    expect(files, isNotEmpty);
  });

  test('every snapshot fixture decodes and re-encodes byte-identical', () {
    final files = dir.listSync().whereType<File>().where(
      (f) => f.path.contains('snapshot_v1_'),
    );
    expect(files.length, 5);
    for (final f in files) {
      final text = f.readAsStringSync();
      expect(text.endsWith('\n'), isTrue, reason: f.path);
      final line = text.substring(0, text.length - 1);
      expect(SessionSnapshot.decode(line).encode(), line, reason: f.path);
    }
  });

  test('fixtures match what the generator writes today', () {
    for (final e in gen.cases().entries) {
      final f = File('${dir.path}/${e.key}.json');
      expect(f.readAsStringSync(), '${e.value.encode()}\n', reason: e.key);
    }
  });

  test('lock-screen vectors match the Dart transitions today (0.3 L1)', () {
    // android/core LockReducerTest replays the same files through the Kotlin
    // reducer; this side proves they are what Session.* produces now.
    final v = gen.lockVectors();
    expect(v.length, greaterThanOrEqualTo(10));
    final onDisk = dir.listSync().whereType<File>().where(
      (f) => f.uri.pathSegments.last.startsWith('lockscreen_v1_'),
    );
    expect(onDisk.length, v.length, reason: 'stale or missing vector files');
    for (final e in v.entries) {
      final f = File('${dir.path}/${e.key}.json');
      expect(f.readAsStringSync(), '${e.value}\n', reason: e.key);
      // Every expected snapshot is a valid, canonical schema-1 line.
      final after = (jsonDecode(e.value) as Map)['after'] as List;
      for (final a in after) {
        final line = jsonEncode(a);
        expect(SessionSnapshot.decode(line).encode(), line, reason: e.key);
      }
    }
  });

  test('canonical key order equals the declared key lists', () {
    final s = SessionSnapshot.decode(
      File('${dir.path}/snapshot_v1_finished.json').readAsStringSync().trim(),
    );
    final j = s.toJson();
    expect(j.keys.toList(), SessionSnapshot.topKeys);
    final ex = (j['exercises'] as List).first as Map;
    expect(ex.keys.toList(), SnapshotExercise.keys);
    expect(((ex['sets'] as List).first as Map).keys.toList(), SnapshotSet.keys);
    expect(
      Session.done(
        s.copyWith(finished: false, endedAtMs: null),
        '${s.workoutUuid}:1',
        nowMs: 0,
      ).rest?.toJson().keys.toList(),
      anyOf(isNull, Rest.keys),
    );
  });

  test('every key is required: dropping any one is rejected', () {
    final line = File('${dir.path}/snapshot_v1_resting.json')
        .readAsStringSync()
        .trim();
    var checked = 0;
    for (final k in [
      ...SessionSnapshot.topKeys,
      'plan_reps',
      'rep_hi',
      'duration_ms',
    ]) {
      final dropped = line.replaceFirst(
        RegExp('"$k":(null|-?\\d+|"[^"]*"|true|false|\\[[^\\]]*\\]),?'),
        '',
      );
      if (dropped == line) continue; // nested objects (rest, exercises)
      expect(
        () => SessionSnapshot.decode(dropped),
        throwsFormatException,
        reason: k,
      );
      checked++;
    }
    expect(checked, greaterThan(15));
  });

  test('undo keeps exactly the contract block Definition keys', () {
    final md = File('../../contracts/session_snapshot.md').readAsStringSync();
    final line = md
        .split('\n')
        .firstWhere((l) => l.startsWith('- Definition:'));
    final keys = RegExp(r'`([a-z_]+)`')
        .allMatches(line)
        .map((m) => m.group(1)!)
        .toSet();
    expect(keys, blockDefinitionKeys);
  });

  test('torn journal: last whole line wins; half line is a torn tail', () {
    final r = readJournal(
      File('${dir.path}/journal_v1_torn_tail.jsonl').readAsStringSync(),
    );
    final midSet = File('${dir.path}/snapshot_v1_mid_set.json')
        .readAsStringSync();
    expect(r.last!.encode(), midSet.trim());
    expect(r.tornTail, isTrue);
    expect(r.corruptLines, 0);
  });

  test('timer-block vectors match the Dart transitions today (0.3 T1)', () {
    // android/core BlockSchedulerTest replays them through the native cue
    // scheduler; this side proves they are what TimerSession produces now.
    final v = gen.timerVectors();
    final onDisk = dir.listSync().whereType<File>().where(
      (f) => f.uri.pathSegments.last.startsWith('timer_v1_'),
    );
    expect(onDisk.length, v.length, reason: 'stale or missing vector files');
    for (final e in v.entries) {
      final f = File('${dir.path}/${e.key}.json');
      expect(f.readAsStringSync(), '${e.value}\n', reason: e.key);
      final steps = (jsonDecode(e.value) as Map)['steps'] as List;
      expect(steps, isNotEmpty);
      for (final st in steps) {
        final line = jsonEncode((st as Map)['snapshot']);
        expect(SessionSnapshot.decode(line).encode(), line, reason: e.key);
      }
    }
  });

  test('fixture states are what their names say', () {
    SessionSnapshot read(String n) => SessionSnapshot.decode(
      File('${dir.path}/snapshot_v1_$n.json').readAsStringSync().trim(),
    );
    expect(read('fresh').rev, 0);
    expect(read('fresh').currentSet!.setOrdinal, 1);
    expect(read('resting').rest, isNotNull);
    expect(read('mid_set').rest, isNull);
    expect(read('mid_set').currentSet!.targetLoadG, 20000);
    expect(read('paused').state, SessionState.paused);
    final fin = read('finished');
    expect(fin.finished, isTrue);
    expect(fin.endedAtMs, isNotNull);
    expect(fin.pausedTotalMs, 60000);
  });
}
