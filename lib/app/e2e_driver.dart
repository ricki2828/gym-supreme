import 'dart:async';
import 'dart:convert';

import 'package:gym_engine/gym_engine.dart' as eng;

import '../screens/live_controller.dart';
import 'services.dart';

/// Phase-1 exit e2e (CI emulator, dogfood/debug only). The real app flow
/// runs headless through the same LiveController the screens use, against
/// the real SQLite store and the real WorkoutService; every step prints one
/// `GymSupreme/e2e {json}` line that tools/emulator_smoke.sh asserts.
///
/// Commands (intent extra gym_e2e, via GymHostApi.takeLaunchCommand):
/// - `run`: condo gym -> plan -> start -> set 1 -> 5 s rest -> rest alert
///   fired natively -> set 2 -> finish -> stored -> journal gone.
/// - `start_only`: start and log one set, then stop (the script kills us).
/// - `resume`: the pending journal from start_only is resumed, finished and
///   stored (crash-safe resume, item 5).
class E2eDriver {
  E2eDriver(this.s, {void Function(String line)? out}) : _out = out ?? print;

  final AppServices s;
  final void Function(String line) _out;

  void _log(String step, [Map<String, Object?> extra = const {}]) =>
      _out('GymSupreme/e2e ${jsonEncode({'step': step, ...extra})}');

  LiveController _controller() => LiveController(
    engine: s.engine,
    port: s.port,
    nowMs: () => DateTime.now().millisecondsSinceEpoch,
    tzOffsetMin: DateTime.now().timeZoneOffset.inMinutes,
    appVersion: s.appVersion,
  );

  Future<void> run(String command) async {
    try {
      switch (command) {
        case 'run':
          await _run(fullFlow: true);
        case 'start_only':
          await _run(fullFlow: false);
        case 'resume':
          await _resume();
        default:
          _log('unknown', {'command': command});
      }
    } on Object catch (e) {
      _log('error', {'command': command, 'error': '$e'});
    }
  }

  String _gymId() {
    final gyms = s.engine.gyms();
    if (gyms.isNotEmpty) return gyms.first.id;
    final g = s.engine.gymFromPreset('condo');
    s.engine.saveGym(g);
    return g.id;
  }

  Future<void> _run({required bool fullFlow}) async {
    final gymId = _gymId();
    final plan = s.engine.suggest(
      gymId: gymId,
      muscleIds: const ['chest'],
      minutes: 30,
      seed: 1,
    );
    _log('plan', {'gym': gymId, 'items': plan.items.length});
    if (plan.items.isEmpty) throw StateError('empty plan');
    final c = _controller();
    await c.start(plan);
    _check(c, 'start');
    _log('start', {'uuid': c.snapshot!.workoutUuid, 'rev': c.snapshot!.rev});
    await c.done();
    _check(c, 'set1');
    _log('set1', {'rev': c.snapshot!.rev});
    if (!fullFlow) {
      c.dispose();
      return;
    }
    await _shortRestAndAlert(c);
    await c.done();
    _check(c, 'set2');
    _log('set2', {'rev': c.snapshot!.rev});
    await _finish(c);
  }

  Future<void> _resume() async {
    final r = s.engine.recover(await s.port.readPendingJournal());
    _log('recover', {'action': r.action.name});
    final snap = r.snapshot;
    if (r.action != eng.RecoveryAction.offerResume || snap == null) {
      throw StateError('expected offerResume, got ${r.action.name}');
    }
    final c = _controller();
    await c.resume(snap);
    _check(c, 'resume');
    _log('resume', {'uuid': snap.workoutUuid, 'rev': c.snapshot!.rev});
    await _finish(c);
  }

  /// Cuts the running rest to about 5 s, then waits for the service's
  /// rest_alerts_fired counter to rise.
  Future<void> _shortRestAndAlert(LiveController c) async {
    final before = (await s.port.nativeCounters())['rest_alerts_fired'] ?? 0;
    final rest = c.snapshot!.rest;
    if (rest == null) throw StateError('no rest after set 1');
    final leftS =
        (rest.endsAtWallMs - DateTime.now().millisecondsSinceEpoch) ~/ 1000;
    if (leftS > 5) await c.restDelta(-(leftS - 5));
    _check(c, 'rest');
    _log('rest', {'left_s': 5});
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final now = (await s.port.nativeCounters())['rest_alerts_fired'] ?? 0;
      if (now > before) {
        _log('rest_alert', {'fired': now});
        return;
      }
    }
    throw StateError('rest alert did not fire within 20 s');
  }

  Future<void> _finish(LiveController c) async {
    final uuid = await c.finish();
    _check(c, 'finish');
    if (uuid == null) throw StateError('finish returned no uuid');
    final stored = s.engine.isStored(uuid);
    final top = s.engine.history(limit: 1);
    final journal = await s.port.readPendingJournal();
    _log('finish', {
      'uuid': uuid,
      'stored': stored,
      'history_top': top.isEmpty ? null : top.first.uuid,
      'journal_gone': journal == null,
    });
    if (!stored || journal != null) throw StateError('finish incomplete');
    s.persist();
    c.dispose();
    _log('ok');
  }

  void _check(LiveController c, String step) {
    final e = c.lastError;
    if (e != null) throw StateError('$step: $e');
  }
}
