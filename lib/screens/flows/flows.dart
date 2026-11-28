import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gym_engine/cut2.dart' as c2;
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:supreme_ui/supreme_ui.dart';

import '../../app/feature_flags.dart';
import '../../app/health_sync.dart';
import '../../app/workout_port.dart';
import '../../widgets/cut2/amrap_entry.dart';
import '../../widgets/cut2/ghost_lines.dart';
import '../../widgets/cut2/rotation_chip.dart';
import '../../widgets/cut2/timer_panel.dart';
import '../cut2/rotation_screen.dart';
import '../cut2/timer_picker_screen.dart';
import '../body_screen.dart';
import '../engine_adapter.dart';
import '../gym_setup_screen.dart';
import '../history_screen.dart';
import '../live_controller.dart';
import '../live_screen.dart';
import '../notification_access.dart';
import '../picker_screen.dart';
import '../post_workout_screen.dart';
import '../progress_model.dart';
import '../progress_screen.dart';
import '../screen_awake.dart';
import '../settings_profile.dart';
import '../starting_weights_screen.dart';
import '../view_models.dart';
import '../weight_list_screen.dart';
import '../workout_detail_screen.dart';
import '../../widgets/lit_widgets.dart';

/// What every flow needs. Built once by the app shell (lib/app, t5t).
class GymDeps {
  GymDeps({
    required this.engine,
    required this.port,
    required this.catalog,
    this.appVersion = '',
    int Function()? nowMs,
    int Function()? tzOffsetMin,
    this.store,
    this.notifications,
    this.persist,
    this.health,
    this.screenAwake,
  }) : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       tzOffsetMin =
           tzOffsetMin ?? (() => DateTime.now().timeZoneOffset.inMinutes);

  final eng.GymApi engine;
  final WorkoutPort port;
  final eng.Catalog catalog;
  final String appVersion;
  final int Function() nowMs;
  final int Function() tzOffsetMin;

  /// History for the cut-2 ghost and rotation (lib/app passes the same
  /// store as the engine's). Null hides both even with their flags on.
  final eng.HistoryStore? store;

  /// Notification permission for the rest alert; null (tests, play build
  /// without the host call) skips the ask and the banner.
  final NotificationAccess? notifications;

  /// Keeps the screen on during a session (0.3 X1); null in tests.
  final ScreenAwake? screenAwake;

  /// Writes the backup snapshot (AppServices.persist). Called after a delete,
  /// an undo and every edit, so the backup matches the history. Null in tests
  /// that do not care.
  final VoidCallback? persist;

  /// Health Connect write (0.3 H1); null unless the `health` flag is on and
  /// the store is real (and in tests that do not care).
  final HealthSync? health;

  /// Fire and forget: brings [uuid]'s Health Connect session in line with
  /// history after a finish, edit, delete or undo. Never blocks or throws.
  void healthSync(String uuid) {
    final h = health;
    if (h != null) unawaited(h.sync(uuid));
  }

  LiveController liveController() => LiveController(
    awake: screenAwake,
    plateMath: Features.plateMath,
    store: store,
    engine: engine,
    port: port,
    nowMs: nowMs,
    tzOffsetMin: tzOffsetMin(),
    appVersion: appVersion,
    onStored: health == null ? null : healthSync,
  );
}

/// The app's root: journal recovery on open (plan 7, B1), first run, then
/// Today / Body / Gyms. The shell sets this as `home`.
class GymRoot extends StatefulWidget {
  const GymRoot({super.key, required this.deps, this.onOpenDiagnostics});
  final GymDeps deps;

  /// Dogfood/debug only; null hides the entry.
  /// Opens Diagnostics and completes when he comes back. Today rebuilds
  /// then: an import there may have added workouts and gyms (0.3 I1).
  final Future<void> Function()? onOpenDiagnostics;

  @override
  State<GymRoot> createState() => _GymRootState();
}

class _GymRootState extends State<GymRoot> {
  eng.GymApi get _engine => widget.deps.engine;
  String? _gymId;
  eng.SessionSnapshot? _pending;
  bool _recovering = true;
  Object? _recoveryError;
  int _tab = 0;
  bool _notificationsOff = false;
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    _recover();
    _checkNotifications();
    // Back from the settings page: drop the banner once they are on.
    _life = AppLifecycleListener(onResume: _checkNotifications);
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  Future<void> _checkNotifications() async {
    final n = widget.deps.notifications;
    if (n == null) return;
    bool off;
    try {
      off = !await n.enabled();
    } on Object {
      return; // unknown: no banner rather than a wrong one
    }
    if (mounted && off != _notificationsOff) {
      setState(() => _notificationsOff = off);
    }
  }

  /// The one-time ask, just before the first Start. Never blocks the start.
  Future<void> _askNotifications() async {
    final n = widget.deps.notifications;
    if (n == null) return;
    try {
      final on = await askNotificationsOnce(n);
      if (mounted) setState(() => _notificationsOff = !on);
    } on Object {
      // The workout starts anyway; the banner check runs again on resume.
    }
  }

  /// A journal on open is either already stored (delete it), finished but
  /// not stored (the engine saves it, then delete), or unfinished (offer
  /// Resume). Delete only after the engine has the workout.
  Future<void> _recover() async {
    final port = widget.deps.port;
    eng.SessionSnapshot? pending;
    try {
      final text = await port.readPendingJournal();
      final r = _engine.recover(text);
      switch (r.action) {
        case eng.RecoveryAction.deleteJournal:
        case eng.RecoveryAction.savedThenDelete:
          // The workout is stored either way; a failed delete only leaves a
          // journal that the next open deletes. Not a restore failure.
          final uuid = r.snapshot?.workoutUuid;
          // Cut 2: a workout finished while the app was dead (lock screen)
          // still moves the rotation; idempotent per workout uuid.
          final st = widget.deps.store;
          final snap = r.snapshot;
          if (Features.rotation &&
              st != null &&
              snap != null &&
              snap.finished) {
            try {
              c2.rotationAfterFinish(st, snap.typeId, workoutUuid: uuid);
            } on Object {
              // Cosmetic: the pointer stays one step behind; he can tap a row in
              // the rotation editor to correct it.
            }
          }
          // H1: a workout finished while the app was dead goes to Health
          // Connect now; an already-stored one is a no-op (same version).
          if (uuid != null && snap != null && snap.finished) {
            widget.deps.healthSync(uuid);
          }
          if (uuid != null) {
            try {
              await port.deleteJournal(uuid);
            } on Object {
              // Retried on the next open.
            }
          }
        case eng.RecoveryAction.offerResume:
          pending = r.snapshot;
        case eng.RecoveryAction.none:
          break;
      }
    } on Object catch (e) {
      // Port refusal, storage error, a catalog that no longer knows an
      // exercise: the journal stays on disk untouched for the next open, and
      // the app still opens.
      _recoveryError = e;
    } finally {
      if (mounted) {
        setState(() {
          _pending = pending;
          _recovering = false;
          _gymId = _pickGym();
        });
      }
    }
  }

  String? _pickGym() {
    final gyms = _engine.gyms();
    if (gyms.isEmpty) return null;
    final keep = gyms.where((g) => g.id == _gymId);
    return keep.isNotEmpty ? _gymId : gyms.first.id;
  }

  /// After a save, the saved gym becomes the current one.
  void _refresh([String? gymId]) => setState(() {
    _gymId = gymId;
    _gymId = _pickGym();
  });

  Future<void> _openPicker() async {
    final gym = _engine.gym(_gymId!)!;
    final plan = await Navigator.of(context).push<eng.SessionPlan>(
      MaterialPageRoute(
        builder: (_) => PickerFlow(deps: widget.deps, gym: gym),
      ),
    );
    if (plan == null || !mounted) return;
    await _askNotifications();
    if (!mounted) return;
    final c = widget.deps.liveController();
    try {
      await c.start(plan);
    } on Object catch (e) {
      // e.g. finish_pending / already_running: a journal is still on disk.
      c.dispose();
      _say(
        _reason(e) == 'finish_pending' || _reason(e) == 'already_running'
            ? 'A workout is still waiting to be saved. Close and reopen the '
                  'app; if this keeps happening, see Diagnostics.'
            : 'Could not start: ${_reason(e)}. Reopen the app to recover it.',
      );
      return;
    }
    if (!mounted) {
      c.dispose();
      return;
    }
    await _runLive(c);
  }

  Future<void> _resume() async {
    final p = _pending;
    if (p == null) return;
    final c = widget.deps.liveController();
    try {
      await c.resume(p);
    } on Object catch (e) {
      c.dispose();
      _say('Could not resume: ${_reason(e)}. Your sets are still saved.');
      return;
    }
    if (!mounted) {
      c.dispose();
      return;
    }
    setState(() => _pending = null);
    await _runLive(c);
  }

  /// Resume card: throw the paused workout away. Confirm first; the card
  /// stays if the journal cannot be deleted. Nothing is written to SQLite
  /// and the rotation does not move.
  Future<void> _discardPending() async {
    final p = _pending;
    if (p == null || p.finished) return;
    final sets = [
      for (final e in p.exercises)
        for (final s in e.sets)
          if (s.state == eng.SetState.done) s,
    ].length;
    if (!await askDiscard(context, sets) || !mounted) return;
    try {
      await widget.deps.port.deleteJournal(p.workoutUuid);
    } on Object catch (e) {
      _say('Could not discard: ${_reason(e)}. The workout is still paused.');
      return;
    }
    if (!mounted) return;
    setState(() => _pending = null);
    _say('Workout discarded.');
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _runLive(LiveController c) async {
    final uuid = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => LiveFlow(controller: c, catalog: widget.deps.catalog),
      ),
    );
    // Anything not stored stays offered as Resume (paused, or a finish that
    // failed half way: its journal is still on disk).
    final paused = c.finishedUuid == null ? c.snapshot : null;
    final discardFailed =
        c.discardFailed && c.snapshot?.state == eng.SessionState.paused
        ? c.lastError
        : null;
    c.dispose();
    if (!mounted) return;
    if (discardFailed != null) {
      _say(
        'Could not discard: ${_reason(discardFailed)}. The workout is '
        'paused; discard it from the Resume card.',
      );
    }
    if (uuid != null) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => PostWorkoutFlow(deps: widget.deps, uuid: uuid),
        ),
      );
    }
    if (!mounted) return;
    setState(() => _pending = paused);
  }

  @override
  Widget build(BuildContext context) {
    if (_recovering) {
      return const Scaffold(backgroundColor: Lit.ground, body: SizedBox());
    }
    if (_gymId == null) {
      return GymFlow(deps: widget.deps, firstRun: true, onSaved: _refresh);
    }
    final gym = _engine.gym(_gymId!)!;
    final tabs = [
      _Today(
        deps: widget.deps,
        gym: gym,
        pending: _pending,
        onStart: _openPicker,
        onResume: _resume,
        onDiscard: _discardPending,
        onHistoryChanged: () {
          if (mounted) setState(() {});
        },
        onOpenDiagnostics: widget.onOpenDiagnostics == null
            ? null
            : () async {
                await widget.onOpenDiagnostics!();
                if (mounted) setState(() {});
              },
        recoveryError: _recoveryError,
        notificationsOff: _notificationsOff,
        onOpenNotificationSettings: widget.deps.notifications == null
            ? null
            : () => widget.deps.notifications!.openSettings(),
      ),
      _BodyTab(deps: widget.deps, gymId: gym.id),
      GymFlow(
        key: ValueKey(gym.id),
        deps: widget.deps,
        gym: gym,
        onSaved: _refresh,
      ),
      ProgressTab(deps: widget.deps),
    ];
    return Scaffold(
      backgroundColor: Lit.ground,
      body: tabs[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        backgroundColor: Colors.white,
        indicatorColor: Lit.hair,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today), label: 'Today'),
          NavigationDestination(
            icon: Icon(Icons.accessibility_new),
            label: 'Body',
          ),
          NavigationDestination(
            icon: Icon(Icons.fitness_center),
            label: 'Gyms',
          ),
          NavigationDestination(
            icon: Icon(Icons.show_chart),
            label: 'Progress',
          ),
        ],
      ),
    );
  }
}

/// Today: Resume if a session is waiting, start a new one, history below.
class _Today extends StatelessWidget {
  const _Today({
    required this.deps,
    required this.gym,
    required this.pending,
    required this.onStart,
    required this.onResume,
    this.onDiscard,
    this.onHistoryChanged,
    this.onOpenDiagnostics,
    this.recoveryError,
    this.notificationsOff = false,
    this.onOpenNotificationSettings,
  });

  /// The last open could not read or store a journal; it is kept on disk.
  final Object? recoveryError;

  /// Plan 6.2: a standing banner while notifications are denied.
  final bool notificationsOff;
  final VoidCallback? onOpenNotificationSettings;
  final GymDeps deps;
  final eng.Gym gym;
  final eng.SessionSnapshot? pending;
  final VoidCallback onStart;
  final VoidCallback onResume;
  final VoidCallback? onDiscard;

  /// A workout was deleted, restored or edited: rebuild Today's list.
  final VoidCallback? onHistoryChanged;
  final VoidCallback? onOpenDiagnostics;

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final r in deps.engine.history(limit: 50)) historyRowOf(r),
    ];
    final p = pending;
    final pv = p == null ? null : liveViewOf(p, nowMs: deps.nowMs());
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        children: [
          Row(
            children: [
              Expanded(child: Text('GYM SUPREME', style: LitType.display(40))),
              GymChip(name: gym.name),
            ],
          ),
          const SizedBox(height: 16),
          if (notificationsOff) ...[
            Container(
              key: const Key('today.notifications_off'),
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              decoration: BoxDecoration(
                color: Lit.ink,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      // t5v: the alert uses Vibrator + ToneGenerator directly,
                      // not the channel; untested with notifications denied.
                      'Notifications are off, so the rest timer won\'t show '
                      'on the lock screen. You should still get the buzz '
                      'and tone.',
                      style: LitType.body(14, Colors.white, FontWeight.w600),
                    ),
                  ),
                  if (onOpenNotificationSettings != null)
                    TextButton(
                      onPressed: onOpenNotificationSettings,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        minimumSize: const Size(48, 48),
                      ),
                      child: Text(
                        'Turn on',
                        style: LitType.body(15, Colors.white, FontWeight.w800)
                            .copyWith(
                              decoration: TextDecoration.underline,
                              decorationColor: Colors.white,
                            ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (recoveryError != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Lit.ink,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'A workout in progress could not be restored '
                '(${_reason(recoveryError!)}). It is kept on the phone; '
                'export from Diagnostics to keep a copy.',
                style: LitType.body(14, Colors.white, FontWeight.w600),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (p != null && pv != null) ...[
            ResumeCard(
              type: workoutTypeOf(p.typeId),
              lift: pv.lift,
              lifts: pv.lifts,
              set: pv.set,
              finishedUnsaved: p.finished,
              pausedWhen: _when(p.pausedAtMs ?? p.startedAtMs, deps.nowMs()),
              onResume: onResume,
              // A finished journal is saved by Resume, not thrown away.
              onDiscard: p.finished ? null : onDiscard,
            ),
            const SizedBox(height: 16),
          ],
          BigButton(
            label: 'LIGHT SOMETHING UP',
            colour: Lit.ink,
            ink: Colors.white,
            height: 72,
            fontSize: 36,
            radius: 20,
            onTap: p == null ? onStart : null,
            semanticLabel: p == null
                ? 'Pick muscles and start a session'
                : 'Finish or resume the paused session first',
          ),
          const SizedBox(height: 24),
          Text('HISTORY', style: LitType.display(32)),
          const SizedBox(height: 8),
          if (rows.isEmpty) ...[
            Text(
              'Nothing logged yet. Your first session shows up here when '
              'you finish it.',
              style: LitType.body(15, Lit.inkSecondary),
            ),
            const SizedBox(height: 12),
            // 0.3 S1: no history to start from, so offer starting weights.
            OutlinedButton.icon(
              key: const Key('today.starting_weights'),
              onPressed: () async {
                await openStartingWeights(context, deps, gym.id);
                onHistoryChanged?.call();
              },
              icon: const Icon(Icons.edit),
              label: Text(
                deps.engine.startingWeights().isEmpty
                    ? 'Set starting weights'
                    : 'Starting weights: '
                          '${deps.engine.startingWeights().length} set',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Lit.ink,
                minimumSize: const Size(48, 48),
              ),
            ),
          ] else
            for (final r in rows)
              HistoryRowTile(
                row: r,
                // Opens the workout's lifts and sets (review P2). Needs the
                // store; without it the row stays read-only.
                onOpen: deps.store == null
                    ? null
                    : (uuid) => _openDetail(context, uuid),
                onDelete: deps.store == null
                    ? null
                    : (uuid) => _confirmDelete(context, uuid),
              ),
          if (onOpenDiagnostics != null) ...[
            const SizedBox(height: 24),
            Center(
              child: TextButton(
                key: const Key('home.diagnostics'),
                onPressed: onOpenDiagnostics,
                child: Text(
                  'Diagnostics',
                  style: LitType.body(14, Lit.inkSecondary, FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _openDetail(BuildContext context, String uuid) {
    final w = deps.store!.workout(uuid);
    if (w == null) return;
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => WorkoutDetailFlow(
              deps: deps,
              uuid: uuid,
              onChanged: onHistoryChanged,
            ),
          ),
        )
        .then((_) => onHistoryChanged?.call());
  }

  /// Long-press a history row: confirm, delete, offer Undo.
  Future<void> _confirmDelete(BuildContext context, String uuid) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await askDeleteWorkout(context)) return;
    deleteWorkoutWithUndo(deps, messenger, uuid, onHistoryChanged);
  }

  static String _when(int atMs, int nowMs) {
    final mins = (nowMs - atMs) ~/ 60000;
    if (mins < 60) return mins <= 1 ? 'just now' : '$mins minutes ago';
    final at = DateTime.fromMillisecondsSinceEpoch(atMs);
    final now = DateTime.fromMillisecondsSinceEpoch(nowMs);
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(at.year, at.month, at.day)).inDays;
    if (days == 0) return 'today';
    if (days == 1) return 'yesterday';
    if (days < 7) return 'on ${shortDate(at).split(' ').first}';
    return 'on ${shortDate(at)}';
  }
}

/// The Progress tab over the engine: reads finished workouts once per open
/// (and after a profile or confirm change), never inside `build`.
class ProgressTab extends StatefulWidget {
  const ProgressTab({super.key, required this.deps});
  final GymDeps deps;
  @override
  State<ProgressTab> createState() => _ProgressTabState();
}

class _ProgressTabState extends State<ProgressTab> {
  ProgressView? _view;
  bool _failed = false;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// Reads the stored workouts here (the database lives on this isolate),
  /// then runs the analysis off the UI thread. A late result from an older
  /// reload is dropped.
  Future<void> _reload() async {
    final d = widget.deps;
    final st = d.store;
    final gen = ++_gen;
    try {
      final input = ProgressInput(
        workouts: st == null ? const [] : st.workouts(),
        catalog: d.catalog,
        gymNames: {for (final g in d.engine.gyms()) g.id: g.name},
        profile: Profile.load(st),
        nowMs: d.nowMs(),
        tzOffsetMin: d.tzOffsetMin(),
        legacyBodyweightG: d.engine.settings().bodyweightG,
        confirmed: loadConfirmed(st),
      );
      final v = await progressRunner(input);
      if (mounted && gen == _gen) {
        setState(() {
          _view = v;
          _failed = false;
        });
      }
    } on Object {
      if (mounted && gen == _gen) setState(() => _failed = true);
    }
  }

  void _say(String t) =>
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(t)));

  void _confirm(IgnoredSet set) {
    final st = widget.deps.store;
    final c = set.confirmation;
    if (st == null || c == null) return;
    try {
      saveConfirmed(st, [
        for (final x in loadConfirmed(st))
          if (x.setId != c.setId) x,
        c,
      ]);
    } on Object {
      _say('Could not save that. Try again.');
      return;
    }
    widget.deps.persist?.call();
    _reload();
  }

  Future<void> _openProfile() async {
    final st = widget.deps.store;
    if (st == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SettingsProfileScreen(
          initial: Profile.load(st),
          today: todayIso(widget.deps.nowMs(), widget.deps.tzOffsetMin()),
          onSave: (p) {
            try {
              p.save(st);
            } on Object {
              return false;
            }
            widget.deps.persist?.call();
            return true;
          },
        ),
      ),
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final v = _view;
    if (v == null && _failed) {
      return Scaffold(
        backgroundColor: Lit.ground,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('PROGRESS', style: LitType.display(44)),
                const SizedBox(height: 12),
                Text(
                  'Could not load progress',
                  key: const Key('progress.error'),
                  style: LitType.body(16, Lit.ink, FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  'Your workouts are safe. Try again.',
                  style: LitType.body(14, Lit.inkSecondary),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton(
                      key: const Key('progress.retry'),
                      onPressed: () {
                        setState(() => _failed = false);
                        _reload();
                      },
                      child: const Text('Retry'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      key: const Key('progress.profile'),
                      onPressed: _openProfile,
                      child: const Text('Profile'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (v == null) {
      return const Scaffold(
        backgroundColor: Lit.ground,
        body: Center(child: CircularProgressIndicator(color: Lit.ink)),
      );
    }
    return ProgressScreen(
      view: v,
      onOpenProfile: _openProfile,
      onOpenLift: (c) => showLiftSheet(
        context,
        card: c,
        onConfirm: (s) {
          Navigator.of(context).pop();
          _confirm(s);
        },
      ),
      onConfirm: _confirm,
    );
  }
}

class _BodyTab extends StatelessWidget {
  const _BodyTab({required this.deps, required this.gymId});
  final GymDeps deps;
  final String gymId;
  @override
  Widget build(BuildContext context) {
    final status = deps.engine.muscleStatus(gymId: gymId);
    // Colour = the workout type that owns the muscle by default (plan 4.2).
    WorkoutType? home(String m) {
      for (final t in eng.workoutTypes) {
        if (t.muscles.contains(m)) return workoutTypeOf(t.id);
      }
      return null;
    }

    return BodyScreen(
      muscles: bodyMusclesOf(deps.catalog.muscles, status, lastTypeOf: home),
    );
  }
}

/// Muscle picker over the engine: selection order (first = lead muscle),
/// suggestion on every change, local reorder before Start.
class PickerFlow extends StatefulWidget {
  const PickerFlow({super.key, required this.deps, required this.gym});
  final GymDeps deps;
  final eng.Gym gym;
  @override
  State<PickerFlow> createState() => _PickerFlowState();
}

class _PickerFlowState extends State<PickerFlow> {
  final List<String> _picked = [];

  /// Exercise ids in the order he dragged them; null = engine order.
  List<String>? _order;

  /// Time budget; starts at his default (settings), 45 unless changed.
  late int _minutes = _nearestBudget(_engine.settings().defaultMinutes);

  /// The chip closest to his default, so one is always selected.
  static int _nearestBudget(int m) => const [
    30,
    45,
    60,
  ].reduce((a, b) => (a - m).abs() <= (b - m).abs() ? a : b);

  /// Variety seed (t61, item 4): the stored workout count + 1, fixed while
  /// this picker is open so the list never reshuffles on a tap. It only
  /// breaks ties between lifts with no history and rotates one slot.
  late final int _seed = _engine.counters().sessionsTotal + 1;

  eng.GymApi get _engine => widget.deps.engine;

  /// Session type of the pick, by picker rows: the engine's majority rule
  /// (review P1-3).
  String? _typeId() => eng.typeForGroups([
    for (final g in MuscleGroup.picker) g.muscleIds.where(_picked.contains),
  ]);

  eng.SessionPlan? _plan() {
    if (_picked.isEmpty) return null;
    final p = _engine.suggest(
      gymId: widget.gym.id,
      muscleIds: _picked,
      typeId: _typeId(),
      minutes: _minutes,
      seed: _seed,
    );
    final order = _order;
    if (order == null) return p;
    // Dragged lifts first in his order, anything new after in engine order.
    final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
    int key(int i) => rank[p.items[i].exerciseId] ?? order.length + i;
    final idx = List.generate(p.items.length, (i) => i)
      ..sort((a, b) => key(a).compareTo(key(b)));
    final items = [for (final i in idx) p.items[i]];
    return eng.SessionPlan(
      gymId: p.gymId,
      typeId: p.typeId,
      muscles: p.muscles,
      items: items,
      uncovered: p.uncovered,
      estimatedMinutes: p.estimatedMinutes,
    );
  }

  void _toggle(MuscleGroup g) => setState(() {
    final on = g.muscleIds.every(_picked.contains);
    if (on) {
      _picked.removeWhere(g.muscleIds.contains);
    } else {
      for (final m in g.muscleIds) {
        if (!_picked.contains(m)) _picked.add(m);
      }
    }
    _order = null;
  });

  void _reorder(int from, int to, List<eng.PlannedItem> shown) => setState(() {
    final o = [for (final i in shown) i.exerciseId];
    o.insert(to, o.removeAt(from));
    _order = o;
  });

  @override
  Widget build(BuildContext context) {
    final status = _engine.muscleStatus(gymId: widget.gym.id);
    final plan = _plan();
    final names = {for (final m in widget.deps.catalog.muscles) m.id: m.name};
    final legs = ['quads', 'hamstrings', 'glutes', 'calves'];
    final legsResting = legs.every((m) => status[m]?.resting ?? false);
    return PickerScreen(
      gym: GymView(
        id: widget.gym.id,
        name: widget.gym.name,
        kit: widget.gym.equipmentIds,
      ),
      days: muscleDaysOf(status),
      selected: _picked.toSet(),
      plan: plan == null
          ? null
          : planViewOf(
              plan,
              muscleNames: [for (final m in plan.uncovered) names[m] ?? m],
            ),
      restNote: legsResting ? 'Legs are still resting.' : null,
      onToggleGroup: _toggle,
      onReorder: plan == null ? null : (a, b) => _reorder(a, b, plan.items),
      onStart: plan == null || plan.items.isEmpty
          ? null
          : () => Navigator.of(context).pop(plan),
      onClose: () => Navigator.of(context).pop(),
      minutes: _minutes,
      // A new budget is a new plan: his drag order no longer applies.
      onMinutes: (m) => setState(() {
        _minutes = m;
        _order = null;
      }),
      sheetExtra: _rotationChip(),
    );
  }

  // ---- cut 2: rotation (Features.rotation) ----------------------------------

  static final Map<String, String> _typeNames = {
    for (final t in eng.workoutTypes) t.id: t.name,
  };
  static const Map<String, Color> _typeColours = {
    'push': Lit.push,
    'pull': Lit.pull,
    'legs': Lit.legs,
    'core': Lit.core,
    'engine': Lit.engine,
  };

  Widget? _rotationChip() {
    final st = widget.deps.store;
    if (!Features.rotation || st == null) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: RotationChip(
        rotation: c2.loadRotation(st),
        names: _typeNames,
        onTap: () => _editRotation(st),
      ),
    );
  }

  Future<void> _editRotation(eng.HistoryStore st) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StatefulBuilder(
          // Re-read from the store on every change: never a stale copy.
          builder: (context, setLocal) => RotationScreen(
            rotation: c2.loadRotation(st),
            names: _typeNames,
            colours: _typeColours,
            onChanged: (r) => setLocal(() => c2.saveRotation(st, r)),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }
}

/// The live screen over a [LiveController]. Pops with the workout uuid on
/// finish, or null when paused.
class LiveFlow extends StatefulWidget {
  const LiveFlow({super.key, required this.controller, required this.catalog});
  final LiveController controller;
  final eng.Catalog catalog;
  @override
  State<LiveFlow> createState() => _LiveFlowState();
}

class _LiveFlowState extends State<LiveFlow> {
  LiveController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    // Completed elsewhere (cut 2: lock-screen Finish, picked up on resync):
    // leave with the uuid so post-workout shows.
    final done = c.finishedUuid;
    if (done != null && !_leaving) {
      _leaving = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _leave(done));
    }
    setState(() {});
  }

  /// One exit only: a second Back/Pause/Finish during the first one's await
  /// or exit animation would pop GymRoot itself.
  bool _leaving = false;

  bool _left = false;
  int _leaveTries = 0;

  void _leave([String? uuid]) {
    if (!mounted || _left) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (!route.isCurrent) {
      // A sheet or dialog is over the live screen (a lock-screen Finish landed
      // under it): close down to this route, then leave on the next frame.
      if (_leaveTries++ > 5) return;
      Navigator.of(context).popUntil((r) => r == route);
      WidgetsBinding.instance.addPostFrameCallback((_) => _leave(uuid));
      return;
    }
    _left = true;
    Navigator.of(context).pop(uuid);
  }

  Future<void> _finish() async {
    if (_leaving) return;
    _leaving = true;
    final uuid = await c.finish();
    if (uuid != null) {
      _leave(uuid);
    } else {
      _leaving = false; // failed: stay, banner shows, Finish can retry
    }
  }

  // ---- cut 2 (each entry gated by its Features flag) ----------------------

  /// Under the current set: the timer panel on a timer block, else the
  /// ghost line. Null when both features are off.
  Widget? _setExtra() {
    final block = c.currentTimer;
    if (Features.timers && block != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TimerPanel(
          block: block,
          elapsedAt: c.timerElapsedMs,
          running: c.timerRunning,
          nowMs: c.nowMs,
          onStart: c.startTimer,
          onRound: c.markRound,
          onFinish: () => _finishTimer(block),
        ),
      );
    }
    if (Features.ghost) {
      final g = c.currentGhost();
      if (g != null) return GhostSetLine(line: g, perHand: c.currentPerHand);
    }
    return null;
  }

  /// DONE on a timer set: start an armed block, else log it (AMRAP asks for
  /// rounds). Any other set: a plain Done.
  Future<void> _onDone() async {
    final block = c.currentTimer;
    if (block == null) return c.done();
    if (!c.timerRunning && c.timerElapsedMs(c.nowMs()) == 0) {
      return c.startTimer();
    }
    return _finishTimer(block);
  }

  Future<void> _addTimer() async {
    if (_leaving) return;
    final block = await Navigator.of(context).push(
      MaterialPageRoute<c2.TimerBlock>(
        builder: (_) => const TimerPickerScreen(),
      ),
    );
    if (block != null && mounted && !_leaving) await c.addTimer(block);
  }

  Future<void> _finishTimer(c2.TimerBlock block) async {
    if (_leaving) return;
    if (block.type == c2.TimerType.amrap) {
      final r = await askAmrapResult(context);
      if (r == null || !mounted || _leaving) return;
      await c.finishTimer(amrapRounds: r.rounds, amrapExtraReps: r.extraReps);
    } else {
      await c.finishTimer();
    }
  }

  /// Swap the current exercise for one that trains the same muscles with
  /// this gym's kit (P1-5).
  Future<void> _swap() async {
    final s = c.snapshot;
    final cur = s?.current;
    if (s == null || cur == null || _leaving) return;
    final ex = s.exercises[cur.exercise];
    final kit = c.engine.gym(s.gymId)?.equipmentIds ?? const <String>{};
    final options = swapCandidates(widget.catalog, s, ex.exerciseId, kit);
    final picked = await showModalBottomSheet<eng.Exercise>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'SWAP ${ex.name.toUpperCase()}',
                style: LitType.display(26),
              ),
            ),
            if (options.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('Nothing else here trains those muscles.'),
              ),
            for (final o in options)
              ListTile(
                minTileHeight: 56,
                title: Text(o.name),
                subtitle: Text(o.primary.join(', ')),
                onTap: () => Navigator.of(ctx).pop(o),
              ),
          ],
        ),
      ),
    );
    // A workout finished elsewhere while the sheet was up: leave now (its
    // first _leave found the sheet, not this route, on top).
    final done = c.finishedUuid;
    if (done != null && mounted) {
      _leave(done);
      return;
    }
    if (picked == null || !mounted || _leaving) return;
    final last = c.engine.lastTime(gymId: s.gymId, exerciseId: picked.id);
    final result = await c.swapCurrent(
      swapItem(
        picked,
        ex,
        last: last,
        // S1: no history anywhere, but a starting weight he typed.
        startLoadG: c.engine.startingLoad(
          gymId: s.gymId,
          exerciseId: picked.id,
        ),
        // The prefill must be a load this gym has (as progression snaps).
        steps: c.engine.loadSteps(gymId: s.gymId, exerciseId: picked.id),
      ),
      replacingId: ex.exerciseId,
    );
    if (result == SwapResult.moved && mounted) {
      // A save failure ([SwapResult.failed]) shows the error banner instead;
      // this is the case where the session moved on under the sheet.
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Not swapped: that exercise has a set logged now.'),
        ),
      );
    }
  }

  /// "Up next · Change order": the reorder sheet over the live screen. It
  /// reads the controller again on every change, so a move shows at once.
  Future<void> _changeOrder() => showReorderSheet(
    context,
    listenable: c,
    view: c.view,
    onMove: c.reorderQueue,
    onMoveItem: c.moveQueueItem,
  );

  /// Pause, then delete the journal; leaves with no uuid (nothing to
  /// summarise). If the delete fails the workout stays paused and Today
  /// offers it as Resume (the failure is said there).
  Future<void> _discard() async {
    if (_leaving) return;
    _leaving = true;
    await c.discard();
    // A lock-screen finish that landed mid-discard stored the workout: show
    // its summary, as _changed would have (it skips while _leaving).
    final done = c.finishedUuid;
    if (done != null) {
      _leave(done);
      return;
    }
    // Leave when the journal is gone, or when it is safely paused and only
    // the delete failed (Today then offers Resume and says so). A refused
    // pause leaves the workout running: stay, the error banner shows.
    final paused = c.snapshot?.state == eng.SessionState.paused;
    if (c.discardedUuid != null || (c.discardFailed && paused)) {
      _leave();
    } else {
      _leaving = false;
    }
  }

  Future<void> _pause() async {
    if (_leaving) return;
    _leaving = true;
    final paused = await c.pause();
    final done = c.finishedUuid;
    if (done != null) {
      _leave(done);
    } else if (paused) {
      _leave();
    } else {
      _leaving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = c.view();
    if (v == null) {
      return const Scaffold(backgroundColor: Lit.ground, body: SizedBox());
    }
    return PopScope(
      // Back = pause, so a stray back gesture never loses the session.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_pause());
      },
      child: Stack(
        children: [
          LiveScreen(
            view: v,
            onReps: c.reps,
            onLoad: c.load,
            onTypeReps: (v, id) => c.setReps(v, setId: id),
            onTypeLoad: (g, id) => c.setLoad(g, setId: id),
            onDone: _onDone,
            onSkipSet: c.skipSet,
            onRestDelta: c.restDelta,
            onSkipRest: c.skipRest,
            onReorder: c.reorderQueue,
            onDoLater: c.doLater,
            onPickNext: c.pickNow,
            onMoveItem: c.moveQueueItem,
            onChangeOrder: _changeOrder,
            onPause: _pause,
            onFinish: _finish,
            onDiscard: c.active ? _discard : null,
            onUndo: c.undoLast,
            onSwap: _swap,
            onAddSet: c.addSet,
            setExtra: _setExtra(),
            actions: [
              if (Features.timers &&
                  c.active &&
                  c.snapshot?.currentSet != null &&
                  c.currentTimer == null)
                BigButton(
                  label: 'ADD TIMER',
                  colour: Lit.ink.withValues(alpha: 0.12),
                  ink: Lit.ink,
                  fontSize: 22,
                  height: 52,
                  onTap: _addTimer,
                  semanticLabel: 'Add a timer block to this exercise',
                ),
            ],
          ),
          if (c.lastError != null && c.lastError is! StaleRevException)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Material(
                color: Lit.ink,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'That did not go through (${_reason(c.lastError!)}). '
                    'Your sets so far are safe; try again.',
                    style: LitType.body(14, Colors.white, FontWeight.w600),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class PostWorkoutFlow extends StatelessWidget {
  const PostWorkoutFlow({super.key, required this.deps, required this.uuid});
  final GymDeps deps;
  final String uuid;
  @override
  Widget build(BuildContext context) {
    final e = deps.engine;
    final rows = e.history(limit: 60);
    // Deleted (or older than the list) while this route was up: no summary.
    final row = rows.where((r) => r.uuid == uuid).firstOrNull;
    final summary = e.summaryOrNull(uuid);
    if (row == null || summary == null) {
      return Scaffold(
        backgroundColor: Lit.ground,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'This workout is no longer in your history.',
                    textAlign: TextAlign.center,
                    style: LitType.body(17, Lit.ink, FontWeight.w700),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    key: const Key('post.gone.back'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Back'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final units = {
      for (final x in deps.catalog.exercises) x.id: unitOfKind(x.load),
    };
    final tz = deps.tzOffsetMin();
    return PostWorkoutScreen(
      view: postWorkoutViewOf(
        summary,
        row: row,
        weekTypes: weekTypesOf(rows, localOf(deps.nowMs(), tz)),
        unitByExercise: units,
      ),
      totalExtra: _ghostTotal(),
      onDone: () => Navigator.of(context).pop(),
    );
  }

  /// Cut 2 (Features.ghost): this workout against last time. Null hides it.
  Widget? _ghostTotal() {
    final st = deps.store;
    if (!Features.ghost || st == null) return null;
    final all = st.workouts();
    final mine = [
      for (final w in all)
        if (w.uuid == uuid) w,
    ];
    if (mine.isEmpty) return null;
    final t = c2.ghostTotalForRecord(mine.first, all);
    return t == null ? null : GhostTotalLine(total: t);
  }
}

/// Gym setup over the engine: a working copy, saved on Save. First run
/// starts from the condo preset (plan 4.3, Q14).
class GymFlow extends StatefulWidget {
  const GymFlow({
    super.key,
    required this.deps,
    this.gym,
    this.firstRun = false,
    required this.onSaved,
  });
  final GymDeps deps;
  final eng.Gym? gym;
  final bool firstRun;

  /// The saved gym's id; the root makes it the current gym.
  final ValueChanged<String> onSaved;
  @override
  State<GymFlow> createState() => _GymFlowState();
}

class _GymFlowState extends State<GymFlow> {
  late eng.Gym _gym;

  void _use(eng.Gym g) => _gym = g;

  @override
  void initState() {
    super.initState();
    _use(widget.gym ?? widget.deps.engine.gymFromPreset('condo'));
  }

  /// Loads with a weight list he can edit (P1-2), by catalog load kind.
  static const _listed = {'dumbbell', 'stack'};

  /// Equipment some exercise actually loads (a stack nothing uses, like the
  /// condo's bench with overhead cable today, gets no weights row).
  late final Set<String> _loaded = {
    for (final x in widget.deps.catalog.exercises)
      for (final set in x.equipmentSets)
        for (final id in set) id,
  };

  List<WeightRow> _weightRows() {
    final cat = widget.deps.catalog;
    return [
      for (final e in cat.equipment)
        if (_listed.contains(e.load) &&
            _gym.has(e.id) &&
            _loaded.contains(e.id))
          () {
            final own = _gym.kit[e.id]?.weightsG ?? const <int>[];
            return WeightRow(
              id: e.id,
              name: e.name,
              weightsG: own.isNotEmpty
                  ? own
                  : (eng.defaultWeightsG[e.load] ?? const <int>[]),
              // Pairs only for dumbbells; a wall ball or kettlebell is one.
              perHand: e.id == 'dumbbells',
              fromDefaults: own.isEmpty,
            );
          }(),
    ];
  }

  Future<void> _editWeights(String id) async {
    final row = _weightRows().firstWhere((r) => r.id == id);
    final list = await Navigator.of(context).push<List<int>>(
      MaterialPageRoute(builder: (_) => WeightListScreen(row: row)),
    );
    if (list == null || list.isEmpty || !mounted) return;
    // The editor's Save keeps: a gym already stored gets the list at once
    // (review of #39: leaving via Today or another gym lost it). A new gym
    // (first run) is stored by its own Save, with the list in it.
    final stored = widget.deps.engine.gym(_gym.id);
    // Only for kit already stored: an unsaved tick waits for the floor Save.
    if (stored != null && stored.has(id)) {
      widget.deps.engine.saveGym(stored.withWeights(id, list));
    }
    setState(() => _gym = _gym.withWeights(id, list));
  }

  /// The saved copy of the gym being edited, or null (first run, new gym).
  eng.Gym? get _stored => widget.deps.engine.gym(_gym.id);

  /// Rename now, for a saved gym: only the name is written (an unsaved kit
  /// tick waits for the floor Save), so history shows the new name at once.
  Future<void> _rename() async {
    final text = TextEditingController(text: _gym.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename gym'),
        content: TextField(
          key: const Key('gym.rename.field'),
          controller: text,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('gym.rename.save'),
            onPressed: () => Navigator.of(ctx).pop(text.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    // Not disposed here: the dialog is still animating out (as askNumber).
    final next = name?.trim();
    if (next == null || next.isEmpty || next == _gym.name || !mounted) return;
    final stored = _stored;
    if (stored != null) {
      widget.deps.engine.saveGym(stored.copyWith(name: next));
      widget.deps.persist?.call();
    }
    setState(() => _gym = _gym.copyWith(name: next));
  }

  /// Delete a saved gym after a confirm. Its workouts stay in history (with
  /// "Deleted gym" where its name was). Never the last gym.
  Future<void> _delete() async {
    final stored = _stored;
    final others = [
      for (final g in widget.deps.engine.gyms())
        if (g.id != _gym.id) g,
    ];
    if (stored == null || others.isEmpty) return;
    // A paused (or unfinished) workout still points at this gym and would
    // resume onto a gym that is gone: finish or discard it first.
    String? blocked;
    try {
      final text = await widget.deps.port.readPendingJournal();
      final head = text == null ? null : eng.readJournal(text).last;
      if (head != null && head.gymId == stored.id) {
        blocked = 'Finish or discard the paused workout first';
      }
    } on Object {
      blocked = 'Could not check for a paused workout. Try again';
    }
    if (!mounted) return;
    if (blocked != null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Can\u2019t delete ${stored.name} yet'),
          content: Text('$blocked.'),
          actions: [
            TextButton(
              key: const Key('gym.delete.blocked'),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${stored.name}?'),
        content: const Text(
          'Its kit list and weights go. Workouts you logged here stay in '
          'your history.',
        ),
        actions: [
          TextButton(
            key: const Key('gym.delete.keep'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            key: const Key('gym.delete.confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFB3261E),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    widget.deps.engine.deleteGym(stored.id);
    widget.deps.persist?.call();
    // Back to the gym the tab opened on if it is still there.
    final next = others.firstWhere(
      (g) => g.id == widget.gym?.id,
      orElse: () => others.first,
    );
    setState(() => _use(next));
    widget.onSaved(next.id);
  }

  /// Bar weight and plate pairs rows (0.3 P1), only with the flag on and the
  /// kit ticked: a bar shows its weight, the plates their pairs.
  List<PlateRow> _plateRows() {
    if (!Features.plateMath) return const [];
    final cat = widget.deps.catalog;
    return [
      for (final e in cat.equipment)
        if (_gym.has(e.id) && (e.load == 'barbell' || e.id == 'plates'))
          () {
            final own = _gym.kit[e.id]?.weightsG ?? const <int>[];
            if (e.id == 'plates') {
              return PlateRow(
                id: e.id,
                name: e.name,
                summary: platePairsSummary(own),
                fromDefaults: own.isEmpty,
              );
            }
            final bar = own.isNotEmpty && own.first > 0
                ? own.first
                : c2.standardBarG;
            return PlateRow(
              id: e.id,
              name: '${e.name} bar',
              summary: '${kg(bar)} kg',
              fromDefaults: own.isEmpty,
            );
          }(),
    ];
  }

  Future<void> _editPlates(String id) async {
    final own = _gym.kit[id]?.weightsG ?? const <int>[];
    List<int>? list;
    if (id == 'plates') {
      list = await Navigator.of(context).push<List<int>>(
        MaterialPageRoute(builder: (_) => PlatePairsScreen(pairsG: own)),
      );
    } else {
      final v = await askNumber(
        context,
        title: 'Bar weight',
        unit: 'kg',
        decimals: true,
        initial: (own.isNotEmpty ? own.first : c2.standardBarG) / 1000,
        max: 60,
      );
      if (v != null && v > 0) list = [(v * 1000).round()];
    }
    final chosen = list;
    if (chosen == null || !mounted) return;
    // Saved at once for a stored gym, as for the weight lists.
    final stored = widget.deps.engine.gym(_gym.id);
    if (stored != null && stored.has(id)) {
      widget.deps.engine.saveGym(stored.withWeights(id, chosen));
    }
    setState(() => _gym = _gym.withWeights(id, chosen));
  }

  @override
  Widget build(BuildContext context) {
    final cat = widget.deps.catalog;
    final gyms = widget.deps.engine.gyms();
    return GymSetupScreen(
      gyms: [
        for (final g in gyms.where((g) => g.id != _gym.id))
          GymView(id: g.id, name: g.name, kit: g.equipmentIds),
        GymView(id: _gym.id, name: _gym.name, kit: _gym.equipmentIds),
      ],
      currentGymId: _gym.id,
      kit: _gym.equipmentIds,
      equipment: [
        for (final e in cat.equipment)
          if (e.id != eng.bodyweight) KitItem(e.id, e.name),
      ],
      presets: [for (final p in cat.presets) PresetView(p.id, p.name)],
      weights: _weightRows(),
      plateRows: _plateRows(),
      onEditPlates: _editPlates,
      firstRun: widget.firstRun,
      onToggle: (id) => setState(() => _gym = _gym.toggle(id)),
      // A preset only pre-ticks (plan 4.3): it adds its kit, and everything
      // he already set (ticks, dumbbell pairs, stack weights) is kept.
      onPreset: (id) => setState(() {
        final fresh = widget.deps.engine.gymFromPreset(id);
        _use(_gym.copyWith(kit: {...fresh.kit, ..._gym.kit}));
      }),
      onEditWeights: _editWeights,
      // 0.3 S1: only for a gym already saved (its kit decides the lifts).
      onStartingWeights:
          widget.firstRun || widget.deps.engine.gym(_gym.id) == null
          ? null
          : () => openStartingWeights(context, widget.deps, _gym.id),
      onRename: _stored == null ? null : _rename,
      onDelete: _stored == null || gyms.length < 2 ? null : _delete,
      onPickGym: (id) => setState(() {
        _use(widget.deps.engine.gym(id) ?? _gym);
      }),
      // A new gym starts from the condo preset; he fixes what differs.
      onAddGym: () => setState(() {
        _use(
          widget.deps.engine.gymFromPreset(
            'condo',
            name: 'Gym ${gyms.length + 1}',
          ),
        );
      }),
      onSave: () {
        widget.deps.engine.saveGym(_gym);
        widget.onSaved(_gym.id);
      },
    );
  }
}

/// Opens the starting weights for [gymId] (0.3 S1); every change persists
/// the backup snapshot.
Future<void> openStartingWeights(
  BuildContext context,
  GymDeps deps,
  String gymId,
) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => StartingWeightsFlow(
      engine: deps.engine,
      gymId: gymId,
      persist: deps.persist,
    ),
  ),
);

/// A short reason for a banner: the port's refusal code, else the type.
String _reason(Object e) =>
    e is WorkoutPortException ? e.code : e.runtimeType.toString();

/// Deletes [uuid] from history and offers Undo for 10 seconds on the ROOT
/// ScaffoldMessenger [messenger] (captured before any pop, so the snackbar
/// outlives the route that asked). Returns false when nothing was deleted.
/// Rotation moves back only when the flag is on; UNDO hands the engine the
/// rotation it returned. Every change persists the backup snapshot.
bool deleteWorkoutWithUndo(
  GymDeps deps,
  ScaffoldMessengerState messenger,
  String uuid,
  VoidCallback? onChanged,
) {
  final eng.DeletedWorkout? d;
  try {
    d = deps.engine.deleteWorkout(uuid, rotation: Features.rotation);
  } on Object catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not delete: ${_reason(e)}.')),
    );
    return false;
  }
  if (d == null) return false;
  deps.persist?.call();
  deps.healthSync(uuid);
  onChanged?.call();
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: const Text('Workout deleted'),
        duration: const Duration(seconds: 10),
        // An action keeps a snackbar up until dismissed unless told not to.
        persist: false,
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () {
            try {
              final ok = deps.engine.undoDelete(
                uuid,
                rotationBefore: d!.rotationBefore,
              );
              deps.persist?.call();
              if (ok) deps.healthSync(uuid);
              onChanged?.call();
              if (!ok) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('Nothing to undo.')),
                );
              }
            } on Object catch (e) {
              messenger.showSnackBar(
                SnackBar(content: Text('Could not undo: ${_reason(e)}.')),
              );
            }
          },
        ),
      ),
    );
  return true;
}

/// One stored workout: its sets (tap one to change reps or load, or remove
/// it) and Delete. Every save is one engine.editWorkout; the totals are read
/// back from the store, so they cannot drift from what was saved.
class WorkoutDetailFlow extends StatefulWidget {
  const WorkoutDetailFlow({
    super.key,
    required this.deps,
    required this.uuid,
    this.onChanged,
  });
  final GymDeps deps;
  final String uuid;

  /// Called after a delete, undo or edit (Today rebuilds its list).
  final VoidCallback? onChanged;

  @override
  State<WorkoutDetailFlow> createState() => _WorkoutDetailFlowState();
}

class _WorkoutDetailFlowState extends State<WorkoutDetailFlow> {
  GymDeps get _deps => widget.deps;

  void _saved() {
    _deps.persist?.call();
    _deps.healthSync(widget.uuid);
    widget.onChanged?.call();
    if (mounted) setState(() {});
  }

  void _say(String text) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  void _edit(String setId, int? loadG, int reps) {
    try {
      _deps.engine.editWorkout(widget.uuid, [
        eng.WorkoutEdit.setValues(setId, loadG: loadG, reps: reps),
      ]);
      _saved();
    } on Object catch (e) {
      _say('Could not save: ${_failure(e)}.');
    }
  }

  void _remove(String setId) {
    try {
      _deps.engine.editWorkout(widget.uuid, [eng.WorkoutEdit.removeSet(setId)]);
      _saved();
    } on Object catch (e) {
      _say('Could not remove: ${_failure(e)}.');
    }
  }

  static String _failure(Object e) =>
      e is ArgumentError ? '${e.message}' : _reason(e);

  void _delete() {
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    if (deleteWorkoutWithUndo(
      _deps,
      messenger,
      widget.uuid,
      widget.onChanged,
    )) {
      nav.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = _deps.store?.workout(widget.uuid);
    if (w == null) {
      // Deleted or unknown: nothing to show (a delete pops this route).
      return const Scaffold(backgroundColor: Lit.ground, body: SizedBox());
    }
    final gymName = _deps.engine.gym(w.gymId)?.name ?? '';
    return WorkoutDetailScreen(
      view: workoutDetailOf(w, gymName: gymName, catalog: _deps.catalog),
      onDelete: _delete,
      onEditSet: _edit,
      onRemoveSet: _remove,
    );
  }
}
