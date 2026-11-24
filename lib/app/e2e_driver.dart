import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter/widgets.dart';
import 'package:gym_engine/cut2.dart' as c2;
import 'package:gym_engine/gym_engine.dart' as eng;

import '../screens/live_controller.dart';
import '../screens/notification_access.dart';
import 'feature_flags.dart';
import 'screen_awake.dart';
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
/// - `stale_start`: startSession and a paused submit sent back to back with
///   no await between, so the pause reaches the service before its start
///   callback ran. The service must go idle for that start (0.2.1 D2).
/// - `delete`: two quick workouts, the second deleted (0.2.1 D3): it must
///   leave `history` (not `isStored`, which stays true for deleted ones).
/// - `export_check`: the export's workout count and tombstones.
/// - `ask`: the one-time notification ask (0.1.1).
/// - `reorder`: start, log a set, "Do later" on the current exercise (R1,
///   0.3.0); the smoke then kills the app.
/// - `reorder_check`: the journal from `reorder` comes back with the same
///   order, the same current exercise and the logged set still inside its
///   exercise, then it is discarded.
/// - `pick`: opens the import file picker (GymHostApi.pickImportFile); the
///   script backs out of it and checks the native and Dart result (0.3 I1).
/// - `export_dump`: the JSON export, gzip + base64, in numbered `chunk`
///   lines, with the history digest (import drill, 0.3 I1).
/// - `delete_one`: deletes the newest history row (import drill: the
///   re-import must skip it as deleted here).
/// - `import.<base64 gzip export>`: preview + import of that bundle, then
///   persist and log the counts and the history digest (import drill).
/// - `start_weight`: 0.3 S1. Sets a 20 kg starting weight (the call the
///   starting-weights screen makes) on a chest lift with no history, plans,
///   starts a workout and logs the planned and live target load of that
///   lift; then discards the workout and clears the weight, so nothing is
///   stored. The script asserts 20000 g on both.
/// - `history`: list stored workouts and whether a journal is pending
///   (restore drill, 0.2; discard check, 0.2.1).
/// - `health`: Health Connect drill (0.3 H1). Switch on (the script grants
///   WRITE_EXERCISE with `pm grant` first), then finish, edit, delete, undo
///   and backfill one workout, each through [HealthSync]; logs the status
///   and the counts. Kotlin logs one `health_write` / `health_delete` line
///   per call. Without Health Connect it logs the status and stops.
/// - `health_ask`: turns the switch on from scratch, so Health Connect's
///   permission screen opens (the script grants and backs out of it); logs
///   `health_asked` with the status once Kotlin answers.
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
    awake: s.host == null ? null : HostScreenAwake(s.host!),
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
        case 'stale_start':
          await _staleStart();
        case 'delete':
          await _delete();
        case 'export_check':
          _exportCheck();
          _log('ok');
        case 'ask':
          await _ask();
        case 'reorder':
          await _reorder();
        case 'reorder_check':
          await _reorderCheck();
        case 'pick':
          await _pick();
        case 'export_dump':
          _exportDump();
        case 'delete_one':
          _deleteOne();
        case _ when name.startsWith('import.'):
          _import(name.substring('import.'.length));
        case 'start_weight':
          await _startWeight();
        case 'history':
          await _history();
        case 'health':
          await _health();
        case 'health_ask':
          final st = await s.health?.setEnabled(true);
          _log('health_asked', {
            'availability': st?.availability.name,
            'granted': st?.granted,
            'enabled': st?.enabled,
          });
        default:
          _log('unknown', {'command': name});
      }
    } on Object catch (e) {
      // Error first and the command cut short: an import command carries the
      // whole bundle, and logcat truncates long lines.
      _log('error', {
        'error': '$e',
        'command': name.length > 40 ? '${name.substring(0, 40)}...' : name,
      });
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

  /// The service's stale-start path (WorkoutService.onStartCommand): the
  /// start and the paused submit are both on the wire before Kotlin has run
  /// the foreground-service callback the start queued. Dogfood/debug only.
  Future<void> _staleStart() async {
    final gymId = _gymId();
    final plan = s.engine.suggest(
      gymId: gymId,
      muscleIds: const ['chest'],
      minutes: 30,
      seed: 1,
    );
    if (plan.items.isEmpty) throw StateError('empty plan');
    final now = DateTime.now().millisecondsSinceEpoch;
    final started = eng.Session.start(
      plan,
      nowMs: now,
      tzOffsetMin: DateTime.now().timeZoneOffset.inMinutes,
      appVersion: s.appVersion,
    );
    final paused = c2.TimerSession.pause(started, nowMs: now + 1);
    if (identical(paused, started) || paused.rev != started.rev + 1) {
      throw StateError('pause did not advance the rev');
    }
    // No awaits between the two calls.
    final startF = s.port.startSession(started.encode());
    final pauseF = s.port.submitSnapshot(paused.encode(), started.rev);
    await Future.wait([startF, pauseF]);
    _log('stale_start', {'uuid': started.workoutUuid, 'rev': paused.rev});
    // Clean-up only. A delete accepted here is weak evidence: it also passes
    // when the service started and was stopped again in time. The proof that
    // the queued start went idle is in the smoke: start_ignored stale=true,
    // no service_started event, no foreground service left.
    await s.port.deleteJournal(started.workoutUuid);
    final journal = await s.port.readPendingJournal();
    _log('stale_cleanup', {'journal_gone': journal == null});
    if (journal != null) throw StateError('journal left behind');
    _log('ok');
  }

  /// Start, log one set, finish: stored, journal gone. No rest wait.
  Future<void> _health() async {
    final h = s.health;
    if (h == null) {
      _log('health', {'sync': false});
      _log('ok');
      return;
    }
    final st = await h.setEnabled(true);
    _log('health_status', {
      'availability': st?.availability.name,
      'granted': st?.granted,
      'enabled': st?.enabled,
    });
    if (!h.enabled || !(st?.granted ?? false)) {
      _log('ok');
      return;
    }
    final plan = s.engine.suggest(
      gymId: _gymId(),
      muscleIds: const ['chest'],
      minutes: 30,
      seed: 1,
    );
    if (plan.items.isEmpty) throw StateError('empty plan');
    // Finish: the controller's onStored is the hook the app uses.
    Future<void>? stored;
    final c = LiveController(
      engine: s.engine,
      port: s.port,
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
      tzOffsetMin: DateTime.now().timeZoneOffset.inMinutes,
      appVersion: s.appVersion,
      onStored: (u) => stored = h.sync(u),
    );
    await c.start(plan);
    _check(c, 'start');
    await c.done();
    _check(c, 'set');
    final uuid = await c.finish();
    _check(c, 'finish');
    c.dispose();
    if (uuid == null || stored == null) throw StateError('finish not synced');
    await stored;
    _log('health_finish', {'uuid': uuid, 'written': h.written});
    // Edit: a new edited_at_ms, so the rewrite replaces the record.
    final set = s.engine
        .editWorkout(uuid, const [])
        .sets
        .firstWhere(
          (x) => !x.skipped && x.kind == eng.SetKind.reps && x.reps != null,
        );
    s.engine.editWorkout(uuid, [
      eng.WorkoutEdit.setValues(
        set.setId,
        loadG: set.loadG,
        reps: (set.reps ?? 0) + 1,
      ),
    ]);
    await h.sync(uuid);
    _log('health_edit', {'written': h.written});
    if (s.engine.deleteWorkout(uuid) == null) throw StateError('no delete');
    await h.sync(uuid);
    _log('health_delete', {'deleted': h.deleted});
    if (!s.engine.undoDelete(uuid)) throw StateError('no undo');
    await h.sync(uuid);
    _log('health_undo', {'written': h.written});
    // Earlier drills (import's delete_one) leave tombstones: the backfill
    // sends one more delete call for them.
    final tombstones = s.store.deletedWorkoutUuids().length;
    final b = await h.backfill();
    _log('health_backfill', {
      'outcome': b?.outcome.name,
      'count': b?.count,
      'tombstones': tombstones,
      'history': s.engine.history(limit: 500).length,
      'failed': h.failed,
    });
    s.persist();
    _log('ok');
  }

  Future<String> _quickWorkout(eng.SessionPlan plan) async {
    final c = _controller();
    await c.start(plan);
    _check(c, 'start');
    await c.done();
    _check(c, 'set');
    final uuid = await c.finish();
    _check(c, 'finish');
    if (uuid == null) throw StateError('finish returned no uuid');
    c.dispose();
    return uuid;
  }

  /// Delete drill (0.2.1 D3): history is the truth for "visible", never
  /// `isStored` (true for deleted workouts so recovery cannot re-save them).
  Future<void> _delete() async {
    final plan = s.engine.suggest(
      gymId: _gymId(),
      muscleIds: const ['chest'],
      minutes: 30,
      seed: 1,
    );
    if (plan.items.isEmpty) throw StateError('empty plan');
    final kept = await _quickWorkout(plan);
    final gone = await _quickWorkout(plan);
    final d = s.engine.deleteWorkout(gone, rotation: Features.rotation);
    if (d == null) throw StateError('deleteWorkout returned null');
    s.persist();
    final rows = s.engine.history(limit: 500);
    _log('delete', {
      'kept': kept,
      'deleted': gone,
      'in_history': rows.any((r) => r.uuid == gone),
      'kept_in_history': rows.any((r) => r.uuid == kept),
      'is_stored': s.engine.isStored(gone),
      'history_count': rows.length,
    });
    _exportCheck();
    _log('ok');
  }

  /// What history looks like to him: every row and the counters. Equal on
  /// two phones means equal history.
  Map<String, Object?> _digest() {
    final rows = s.engine.history(limit: 1000);
    final c = s.engine.counters();
    final text = jsonEncode([
      for (final r in rows) [r.uuid, r.startedAtMs, r.volumeKg, r.setCount],
      [c.sessionsTotal, c.doneSets, c.tapUnchangedSets, c.coldStartSets],
    ]);
    return {'count': rows.length, 'digest': eng.tieHash(0, text)};
  }

  void _exportDump() {
    final json = s.engine.export(appVersion: s.appVersion).json;
    final b64 = base64.encode(gzip.encode(utf8.encode(json)));
    const size = 600; // well under the logcat line cap
    final n = (b64.length + size - 1) ~/ size;
    _log('export_dump', {..._digest(), 'chunks': n, 'chars': b64.length});
    for (var i = 0; i < n; i++) {
      final end = (i + 1) * size;
      _log('chunk', {
        'i': i,
        'data': b64.substring(i * size, end > b64.length ? b64.length : end),
      });
    }
    _log('ok');
  }

  void _deleteOne() {
    final rows = s.engine.history(limit: 1);
    if (rows.isEmpty) throw StateError('no workout to delete');
    final d = s.engine.deleteWorkout(rows.first.uuid);
    if (d == null) throw StateError('deleteWorkout returned null');
    s.persist();
    _log('delete_one', {'deleted': rows.first.uuid, ..._digest()});
    _log('ok');
  }

  void _import(String b64) {
    final text = utf8.decode(gzip.decode(base64.decode(b64)));
    final p = s.engine.previewImport(text);
    final r = s.engine.importBundle(text);
    s.persist();
    _log('import', {
      ..._digest(),
      'preview_added': p.workoutsAdded,
      'added': r.workoutsAdded,
      'skipped_existing': r.skippedExisting,
      'skipped_deleted': r.skippedDeleted,
      'gyms_added': r.gymsAdded,
      'format': r.exportFormat,
    });
    _log('ok');
  }

  /// Opens the real picker; the script presses BACK, so null is expected.
  Future<void> _pick() async {
    final host = s.host;
    if (host == null) throw StateError('no GymHostApi');
    _log('pick_open');
    final text = await host.pickImportFile();
    _log('pick', {'result': text == null ? 'null' : 'text'});
    _log('ok');
  }

  /// The export's visible workouts and tombstones (export_format 2).
  void _exportCheck() {
    final f = s.engine.export(appVersion: s.appVersion);
    final m = jsonDecode(f.json) as Map<String, Object?>;
    _log('export', {
      'format': m['export_format'],
      'workouts': (m['workouts'] as List).length,
      'workout_uuids': [
        for (final w in m['workouts'] as List) (w as Map)['uuid'],
      ],
      'deleted': m['deleted_workout_uuids'],
    });
  }

  static List<String> _ids(eng.SessionSnapshot s) => [
    for (final e in s.exercises) e.exerciseId,
  ];

  /// Logged sets per exercise, in snapshot order.
  static List<int> _donePer(eng.SessionSnapshot s) => [
    for (final e in s.exercises)
      e.sets.where((x) => x.state == eng.SetState.done).length,
  ];

  static String _currentId(eng.SessionSnapshot s) =>
      s.exercises[s.current!.exercise].exerciseId;

  /// R1: the live reorder survives process death. One set is logged on the
  /// first exercise, which then goes "later" (after the next one).
  Future<void> _reorder() async {
    final plan = s.engine.suggest(
      gymId: _gymId(),
      muscleIds: const ['chest'],
      minutes: 30,
      seed: 1,
    );
    if (plan.items.length < 2) throw StateError('need 2 exercises to reorder');
    final c = _controller();
    await c.start(plan);
    _check(c, 'start');
    await c.done();
    _check(c, 'set1');
    final before = _ids(c.snapshot!);
    await c.doLater();
    _check(c, 'do_later');
    final after = c.snapshot!;
    final expected = [before[1], before[0], ...before.skip(2)];
    if (_ids(after).join(',') != expected.join(',')) {
      throw StateError('order ${_ids(after)} is not $expected');
    }
    _log('reorder', {
      'before': before,
      'order': _ids(after),
      'current': _currentId(after),
      'done_per': _donePer(after),
      'rev': after.rev,
    });
    c.dispose();
  }

  /// After the kill: the journal has the reordered order, the same current
  /// exercise and the logged set where it was logged. Resumes, then discards
  /// (cleans the journal; the discard path itself is its own smoke step).
  Future<void> _reorderCheck() async {
    final r = s.engine.recover(await s.port.readPendingJournal());
    _log('recover', {'action': r.action.name});
    final snap = r.snapshot;
    if (r.action != eng.RecoveryAction.offerResume || snap == null) {
      throw StateError('expected offerResume, got ${r.action.name}');
    }
    final c = _controller();
    await c.resume(snap);
    _check(c, 'resume');
    final now = c.snapshot!;
    _log('reorder_resumed', {
      'order': _ids(now),
      'current': _currentId(now),
      'done_per': _donePer(now),
      'view_exercise': c.view()?.exerciseName,
      'current_name': now.exercises[now.current!.exercise].name,
    });
    if (!await c.discard()) throw StateError('discard failed');
    c.dispose();
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
      'schema_version': s.store.schemaVersion,
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

  /// S1 drill: starting weight -> plan -> live target, nothing stored.
  Future<void> _startWeight() async {
    const loadG = 20000;
    final gymId = _gymId();
    final fresh = {
      for (final l in s.engine.startingWeightLifts(gymId: gymId))
        if (!l.hasHistory) l.exerciseId,
    };
    eng.SessionPlan plan() => s.engine.suggest(
      gymId: gymId,
      muscleIds: const ['chest'],
      minutes: 30,
      seed: 1,
    );
    final pick = plan().items
        .where(
          (i) =>
              (i.unit == eng.LoadUnit.kg || i.unit == eng.LoadUnit.ea) &&
              fresh.contains(i.exerciseId) &&
              s.engine
                  .loadSteps(gymId: gymId, exerciseId: i.exerciseId)
                  .loadsG
                  .contains(loadG),
        )
        .firstOrNull;
    if (pick == null) throw StateError('no loaded chest lift without history');
    final id = pick.exerciseId;
    final before = s.engine.history(limit: 500).length;
    s.engine.setStartingWeight(id, loadG);
    s.persist();
    final item = plan().items.firstWhere((i) => i.exerciseId == id);
    final c = _controller();
    await c.start(plan());
    _check(c, 'start');
    final live = c.snapshot!.exercises.firstWhere((e) => e.exerciseId == id);
    final target = live.sets.first.targetLoadG;
    // One logged set, like the discard drill, so the discard path is the
    // one the live screen takes mid-workout.
    await c.done();
    _check(c, 'set1');
    _log('start_weight', {
      'exercise': id,
      'start_load_g': s.engine.startingLoad(gymId: gymId, exerciseId: id),
      'plan_load_g': item.sets.first.loadG,
      'target_load_g': target,
    });
    final ok = await c.discard();
    _check(c, 'discard');
    c.dispose();
    s.engine.setStartingWeight(id, null);
    s.persist();
    final after = s.engine.history(limit: 500).length;
    _log('start_weight_done', {
      'discarded': ok,
      'cleared': !s.engine.startingWeights().containsKey(id),
      'history_before': before,
      'history_after': after,
    });
    if (!ok || after != before) throw StateError('start_weight left a trace');
    if (item.sets.first.loadG != loadG || target != loadG) {
      throw StateError('starting weight not used: plan/target != $loadG');
    }
    _log('ok');
  }

  void _check(LiveController c, String step) {
    final e = c.lastError;
    if (e != null) throw StateError('$step: $e');
  }
}
