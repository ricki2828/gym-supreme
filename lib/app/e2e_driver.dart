import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:gym_engine/gym_engine.dart' as eng;

import '../screens/live_controller.dart';
import '../screens/notification_access.dart';
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
/// - `ask`: the one-time notification ask (0.1.1).
class E2eDriver {
  E2eDriver(this.s, {void Function(String line)? out}) : _out = out ?? print;

  final AppServices s;
  final void Function(String line) _out;

  String _nonce = '';

  void _log(String step, [Map<String, Object?> extra = const {}]) => _out(
    'GymSupreme/e2e ${jsonEncode({'step': step, 'nonce': _nonce, ...extra})}',
  );

  /// Name of the only gym the driver ever uses. It refuses to run on a phone
  /// that has any other gym, so an app sending gym_e2e to a real dogfood
  /// install cannot put fake workouts into his history.
  static const gymName = 'E2E';

  LiveController _controller() => LiveController(
    engine: s.engine,
    port: s.port,
    nowMs: () => DateTime.now().millisecondsSinceEpoch,
    tzOffsetMin: DateTime.now().timeZoneOffset.inMinutes,
    appVersion: s.appVersion,
  );

  /// [command] is `<name>:<nonce>`; the nonce is echoed in every line so the
  /// smoke script never matches a stale line.
  Future<void> run(String command) async {
    final i = command.indexOf(':');
    _nonce = i < 0 ? '' : command.substring(i + 1);
    final name = i < 0 ? command : command.substring(0, i);
    if (s.engine.gyms().any((g) => g.name != gymName)) {
      _log('refused', {'reason': 'a real gym exists on this phone'});
      return;
    }
    try {
      switch (name) {
        case 'run':
          await _run(fullFlow: true);
        case 'start_only':
          await _run(fullFlow: false);
        case 'resume':
          await _resume();
        case 'ask':
          await _ask();
        default:
          _log('unknown', {'command': name});
      }
    } on Object catch (e) {
      _log('error', {'command': name, 'error': '$e'});
    }
  }

  String _gymId() {
    final gyms = s.engine.gyms();
    if (gyms.isNotEmpty) return gyms.first.id;
    final g = s.engine.gymFromPreset('condo', name: gymName);
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

  /// The one-time notification ask exactly as the app runs it before the
  /// first Start; the smoke checks the system dialog it raises (API 33+).
  Future<void> _ask() async {
    final n = s.notifications;
    if (n == null) throw StateError('no NotificationAccess');
    // The request only shows a dialog while the activity is resumed (t5v).
    for (var i = 0; i < 50; i++) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final allowed = await askNotificationsOnce(n);
    _log('ask', {'allowed': allowed});
    _log('ok');
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
