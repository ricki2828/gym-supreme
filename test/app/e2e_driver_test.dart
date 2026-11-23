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
}
