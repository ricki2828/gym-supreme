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
/// - `discard`: start, log 2 sets, discard (pause then delete the journal):
///   journal gone, nothing stored, a new start accepted (0.2.1 D2).
/// - `ask`: the one-time notification ask (0.1.1).
/// - `history`: list stored workouts and whether a journal is pending
///   (restore drill, 0.2; discard check, 0.2.1).
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
        case 'discard':
          await _discard();
        case 'ask':
          await _ask();
        case 'history':
          await _history();
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

  /// Discard drill (0.2.1 D2): the same path the live screen takes
  /// (LiveController.discard). Afterwards no journal, no new stored workout,
  /// and the service accepts a fresh start (no already_running).
  Future<void> _discard() async {
    final gymId = _gymId();
    final plan = s.engine.suggest(
      gymId: gymId,
      muscleIds: const ['chest'],
      minutes: 30,
      seed: 1,
    );
    if (plan.items.isEmpty) throw StateError('empty plan');
    final before = s.engine.history(limit: 500).length;
    final c = _controller();
    await c.start(plan);
    _check(c, 'start');
    final uuid = c.snapshot!.workoutUuid;
    _log('start', {'uuid': uuid, 'rev': c.snapshot!.rev});
    await c.done();
    _check(c, 'set1');
    await c.done();
    _check(c, 'set2');
    final logged = c.view()!.doneSets;
    _log('set2', {'rev': c.snapshot!.rev, 'done_sets': logged});
    if (logged != 2) throw StateError('expected 2 logged sets, got $logged');
    final ok = await c.discard();
    _check(c, 'discard');
    final journal = await s.port.readPendingJournal();
    final after = s.engine.history(limit: 500).length;
    _log('discard', {
      'uuid': uuid,
      'ok': ok,
      'journal_gone': journal == null,
      'stored': s.engine.isStored(uuid),
      'history_before': before,
      'history_after': after,
    });
    if (!ok || journal != null || after != before) {
      throw StateError('discard incomplete');
    }
    c.dispose();
    // A fresh start must be accepted: a journal or running service left
    // behind would answer already_running / finish_pending.
    final c2 = _controller();
    await c2.start(plan);
    _check(c2, 'restart');
    _log('restart', {'accepted': true, 'uuid': c2.snapshot!.workoutUuid});
    if (!await c2.discard()) throw StateError('second discard failed');
    c2.dispose();
    _log('ok');
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
    var resumed = false;
    for (var i = 0; i < 50 && !resumed; i++) {
      resumed =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      if (!resumed) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    if (!resumed) {
      throw StateError('activity not resumed: the ask would be cancelled');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final allowed = await askNotificationsOnce(n);
    _log('ask', {'allowed': allowed});
    _log('ok');
  }

  /// Lists stored workouts (restore drill: the backup came back intact).
  Future<void> _history() async {
    final pendingJournal = await s.port.readPendingJournal() != null;
    final rows = s.engine.history(limit: 20);
    _log('history', {
      'count': rows.length,
      'pending_journal': pendingJournal,
      'uuids': [for (final r in rows) r.uuid],
      'restore_failed': s.restoreFailed,
      'restore_pending': s.restorePending,
    });
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
