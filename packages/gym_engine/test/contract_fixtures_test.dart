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
