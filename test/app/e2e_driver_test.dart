import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_engine/sqlite_store.dart';
import 'package:gym_supreme/app/e2e_driver.dart';
import 'package:gym_supreme/app/services.dart';
import 'package:gym_supreme/app/workout_port.dart';

/// The stub has no native rest alert; this one fires it when asked.
class AlertingStubPort extends StubWorkoutPort {
  int fired = 0;

  /// (submitted at, rest ends at) for every snapshot that carries a rest.
  final rests = <(int, int)>[];
  @override
  Future<Map<String, int>> nativeCounters() async => {
    'rest_alerts_fired': fired++,
  };
  @override
  Future<int> submitSnapshot(String snapshotJson, int baseRev) {
    final rest = (jsonDecode(snapshotJson) as Map)['rest'] as Map?;
    if (rest != null) {
      rests.add((
        DateTime.now().millisecondsSinceEpoch,
        rest['ends_at_wall_ms'] as int,
      ));
    }
    return super.submitSnapshot(snapshotJson, baseRev);
  }
}

AppServices services(SqliteStore store, WorkoutPort port) {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  return AppServices(
    catalog: catalog,
    store: store,
    engine: eng.GymEngine(catalog: catalog, store: store),
    port: port,
    appVersion: 't',
  );
}

Map<String, Object?> step(String line) =>
    jsonDecode(line.substring('GymSupreme/e2e '.length))
        as Map<String, Object?>;

void main() {
  test('run: full loop logs every step and ends ok', () async {
    final store = SqliteStore.inMemory();
    addTearDown(store.close);
    final lines = <String>[];
    final port = AlertingStubPort();
    await E2eDriver(services(store, port), out: lines.add).run('run:n1');
    expect(lines.map(step).every((m) => m['nonce'] == 'n1'), isTrue);
    final steps = lines.map(step).map((m) => m['step']).toList();
    expect(steps, [
      'plan',
      'start',
      'set1',
      'rest',
      'rest_alert',
      'set2',
      'finish',
      'ok',
    ], reason: lines.join('\n'));
    final fin = lines.map(step).firstWhere((m) => m['step'] == 'finish');
    expect(fin['stored'], isTrue);
    expect(fin['journal_gone'], isTrue);
    expect(fin['history_top'], fin['uuid']);
    // restDelta really cut a rest to about 5 s from when it was submitted.
    expect(
      port.rests.any((r) => r.$2 - r.$1 <= 6000 && r.$2 - r.$1 >= 3000),
      isTrue,
      reason: '${port.rests}',
    );
  });

  test('refuses on a phone that has a real gym', () async {
    final store = SqliteStore.inMemory();
    addTearDown(store.close);
    final s = services(store, AlertingStubPort());
    s.engine.saveGym(s.engine.gymFromPreset('condo', name: 'Condo'));
    final lines = <String>[];
    await E2eDriver(s, out: lines.add).run('run:x');
    expect(lines.map(step).single['step'], 'refused');
    expect(s.engine.history(limit: 5), isEmpty);
  });

  test(
    'start_only then resume: the pending journal is finished and stored',
    () async {
      final store = SqliteStore.inMemory();
      addTearDown(store.close);
      final port = AlertingStubPort();
      final s = services(store, port);
      final lines = <String>[];
      await E2eDriver(s, out: lines.add).run('start_only:a');
      expect(lines.map(step).last['step'], 'set1');
      expect(await port.readPendingJournal(), isNotNull);
      lines.clear();
      await E2eDriver(s, out: lines.add).run('resume:b');
      final steps = lines.map(step).map((m) => m['step']).toList();
      expect(steps, [
        'recover',
        'resume',
        'finish',
        'ok',
      ], reason: lines.join('\n'));
    },
  );

  test('discard: journal gone, nothing stored, a new start accepted', () async {
    final store = SqliteStore.inMemory();
    addTearDown(store.close);
    final port = AlertingStubPort();
    final s = services(store, port);
    final lines = <String>[];
    await E2eDriver(s, out: lines.add).run('run:r');
    lines.clear();
    await E2eDriver(s, out: lines.add).run('discard:d');
    final steps = lines.map(step).map((m) => m['step']).toList();
    expect(steps, [
      'start',
      'set2',
      'discard',
      'restart',
      'ok',
    ], reason: lines.join('\n'));
    final d = lines.map(step).firstWhere((m) => m['step'] == 'discard');
    expect(d['ok'], isTrue);
    expect(d['journal_gone'], isTrue);
    expect(d['stored'], isFalse);
    expect(d['history_before'], 1);
    expect(d['history_after'], 1);
    expect(await port.readPendingJournal(), isNull);
    expect(s.engine.history(limit: 5), hasLength(1));
    lines.clear();
    await E2eDriver(s, out: lines.add).run('history:h');
    final h = lines.map(step).firstWhere((m) => m['step'] == 'history');
    expect(h['pending_journal'], isFalse);
    expect(h['count'], 1);
  });

  // The stub has no service and no queued start callback, so it cannot reach
  // the race: this only checks the command's steps. The emulator smoke
  // (start_ignored stale=true, no service_started, no foreground service) is
  // the proof that the stale-start path works.
  test(
    'stale_start: start + paused submit back to back, then cleaned up',
    () async {
      final store = SqliteStore.inMemory();
      addTearDown(store.close);
      final port = AlertingStubPort();
      final s = services(store, port);
      final lines = <String>[];
      await E2eDriver(s, out: lines.add).run('stale_start:s');
      final steps = lines.map(step).map((m) => m['step']).toList();
      expect(steps, [
        'stale_start',
        'stale_cleanup',
        'ok',
      ], reason: lines.join('\n'));
      final c = lines.map(step).firstWhere((m) => m['step'] == 'stale_start');
      expect(c['rev'], 1);
      expect(await port.readPendingJournal(), isNull);
      expect(s.engine.history(limit: 5), isEmpty);
    },
  );

  test('delete: the second workout leaves history and the export keeps '
      'its tombstone', () async {
    final store = SqliteStore.inMemory();
    addTearDown(store.close);
    final s = services(store, AlertingStubPort());
    final lines = <String>[];
    await E2eDriver(s, out: lines.add).run('delete:x');
    final steps = lines.map(step).map((m) => m['step']).toList();
    expect(steps, ['delete', 'export', 'ok'], reason: lines.join('\n'));
    final d = lines.map(step).firstWhere((m) => m['step'] == 'delete');
    expect(d['in_history'], isFalse);
    expect(d['kept_in_history'], isTrue);
    expect(
      d['is_stored'],
      isTrue,
      reason: 'isStored stays true: not "visible"',
    );
    expect(d['history_count'], 1);
    final e = lines.map(step).firstWhere((m) => m['step'] == 'export');
    expect(e['format'], 2);
    expect(e['workouts'], 1);
    expect(e['deleted'], [d['deleted']]);
    // Another process start: still gone, tombstone kept.
    lines.clear();
    await E2eDriver(s, out: lines.add).run('export_check:y');
    final e2 = lines.map(step).firstWhere((m) => m['step'] == 'export');
    expect(e2['deleted'], [d['deleted']]);
  });

  test('reorder, then the journal comes back reordered (R1)', () async {
    final store = SqliteStore.inMemory();
    addTearDown(store.close);
    final port = AlertingStubPort();
    final s = services(store, port);
    final lines = <String>[];
    await E2eDriver(s, out: lines.add).run('reorder:r');
    final r = lines.map(step).firstWhere((m) => m['step'] == 'reorder');
    final before = (r['before'] as List).cast<String>();
    expect(r['order'], [before[1], before[0], ...before.skip(2)]);
    expect(r['current'], before[1]);
    expect(
      (r['done_per'] as List)[1],
      1,
      reason: 'the logged set moved with it',
    );
    // "Another process": a fresh driver over the same journal.
    lines.clear();
    await E2eDriver(s, out: lines.add).run('reorder_check:c');
    final steps = lines.map(step).map((m) => m['step']).toList();
    expect(steps, [
      'recover',
      'reorder_resumed',
      'ok',
    ], reason: lines.join('\n'));
    final c = lines.map(step).firstWhere((m) => m['step'] == 'reorder_resumed');
    expect(c['order'], r['order']);
    expect(c['current'], r['current']);
    expect(c['done_per'], r['done_per']);
    expect(c['view_exercise'], c['current_name']);
    expect(await port.readPendingJournal(), isNull);
  });

  test('export_dump then import.<bundle> on a fresh store: same digest, '
      'tombstone not resurrected, re-import adds 0', () async {
    final a = SqliteStore.inMemory();
    addTearDown(a.close);
    final sa = services(a, AlertingStubPort());
    final lines = <String>[];
    await E2eDriver(sa, out: lines.add).run('delete:d1');
    await E2eDriver(sa, out: lines.add).run('delete:d2');
    final gone = [
      for (final m in lines.map(step))
        if (m['step'] == 'delete') m['deleted'],
    ];
    lines.clear();
    await E2eDriver(sa, out: lines.add).run('export_dump:x');
    final dump = lines.map(step).firstWhere((m) => m['step'] == 'export_dump');
    expect(dump['count'], 2);
    final chunks = [
      for (final m in lines.map(step))
        if (m['step'] == 'chunk') m,
    ];
    expect(chunks, hasLength(dump['chunks']));
    for (final c in chunks) {
      expect((c['data'] as String).length, lessThanOrEqualTo(600));
    }
    final b64 = chunks.map((c) => c['data']).join();
    expect(b64.length, dump['chars']);
    expect(b64, isNot(contains(':')), reason: 'the command splits on ":"');

    final b = SqliteStore.inMemory();
    addTearDown(b.close);
    final sb = services(b, AlertingStubPort());
    lines.clear();
    await E2eDriver(sb, out: lines.add).run('import.$b64:y');
    expect(lines.map(step).last['step'], 'ok', reason: lines.join('\n'));
    final imp = lines.map(step).firstWhere((m) => m['step'] == 'import');
    expect(imp['added'], 2);
    expect(imp['preview_added'], 2);
    expect(imp['digest'], dump['digest']);
    expect(imp['count'], 2);
    final uuids = [for (final h in sb.engine.history()) h.uuid];
    for (final u in gone) {
      expect(uuids, isNot(contains(u)));
    }
    lines.clear();
    await E2eDriver(sb, out: lines.add).run('import.$b64:z');
    final again = lines.map(step).firstWhere((m) => m['step'] == 'import');
    expect(again['added'], 0);
    expect(again['skipped_existing'], 2);
    expect(again['digest'], dump['digest']);
    // Tombstone: delete one here, import again: it stays deleted.
    lines.clear();
    await E2eDriver(sb, out: lines.add).run('delete_one:t');
    final del = lines.map(step).firstWhere((m) => m['step'] == 'delete_one');
    expect(del['count'], 1);
    lines.clear();
    await E2eDriver(sb, out: lines.add).run('import.$b64:u');
    final third = lines.map(step).firstWhere((m) => m['step'] == 'import');
    expect(third['added'], 0);
    expect(third['skipped_deleted'], 1);
    expect(third['skipped_existing'], 1);
    expect(third['count'], 1);
    expect(third['digest'], del['digest']);
    expect(
      sb.engine.history().map((h) => h.uuid),
      isNot(contains(del['deleted'])),
    );
  });

  test('an error line puts the error first and cuts a long command', () async {
    final b = SqliteStore.inMemory();
    addTearDown(b.close);
    final lines = <String>[];
    await E2eDriver(
      services(b, AlertingStubPort()),
      out: lines.add,
    ).run('import.${'A' * 5000}:e');
    final m = step(lines.single);
    expect(m['step'], 'error');
    expect(
      m.keys.toList().indexOf('error'),
      lessThan(m.keys.toList().indexOf('command')),
    );
    expect((m['command'] as String).length, lessThan(50));
  });

  test('history lists stored workouts for the restore drill', () async {
    final store = SqliteStore.inMemory();
    addTearDown(store.close);
    final s = services(store, AlertingStubPort());
    final lines = <String>[];
    await E2eDriver(s, out: lines.add).run('run:r');
    lines.clear();
    await E2eDriver(s, out: lines.add).run('history:h');
    final h = lines.map(step).firstWhere((m) => m['step'] == 'history');
    expect(h['count'], 1);
    expect((h['uuids'] as List).single, isA<String>());
    expect(h['restore_failed'], 0);
    expect(h['restore_pending'], isFalse);
  });
}
