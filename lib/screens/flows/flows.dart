import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:supreme_ui/supreme_ui.dart';

import '../../app/workout_port.dart';
import '../body_screen.dart';
import '../engine_adapter.dart';
import '../gym_setup_screen.dart';
import '../history_screen.dart';
import '../live_controller.dart';
import '../live_screen.dart';
import '../picker_screen.dart';
import '../post_workout_screen.dart';
import '../view_models.dart';
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
  }) : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       tzOffsetMin =
           tzOffsetMin ?? (() => DateTime.now().timeZoneOffset.inMinutes);

  final eng.GymApi engine;
  final WorkoutPort port;
  final eng.Catalog catalog;
  final String appVersion;
  final int Function() nowMs;
  final int Function() tzOffsetMin;

  LiveController liveController() => LiveController(
    engine: engine,
    port: port,
    nowMs: nowMs,
    tzOffsetMin: tzOffsetMin(),
    appVersion: appVersion,
  );
}

/// The app's root: journal recovery on open (plan 7, B1), first run, then
/// Today / Body / Gyms. The shell sets this as `home`.
class GymRoot extends StatefulWidget {
  const GymRoot({super.key, required this.deps, this.onOpenDiagnostics});
  final GymDeps deps;

  /// Dogfood/debug only; null hides the entry.
  final VoidCallback? onOpenDiagnostics;

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

  @override
  void initState() {
    super.initState();
    _recover();
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
    final c = widget.deps.liveController();
    try {
      await c.start(plan);
    } on Object catch (e) {
      // e.g. finish_pending / already_running: a journal is still on disk.
      c.dispose();
      _say('Could not start: ${_reason(e)}. Reopen the app to recover it.');
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

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _runLive(LiveController c) async {
    final uuid = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => LiveFlow(controller: c)));
    // Anything not stored stays offered as Resume (paused, or a finish that
    // failed half way: its journal is still on disk).
    final paused = c.finishedUuid == null ? c.snapshot : null;
    c.dispose();
    if (!mounted) return;
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
        onOpenDiagnostics: widget.onOpenDiagnostics,
        recoveryError: _recoveryError,
      ),
      _BodyTab(deps: widget.deps, gymId: gym.id),
      GymFlow(
        key: ValueKey(gym.id),
        deps: widget.deps,
        gym: gym,
        onSaved: _refresh,
      ),
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
    this.onOpenDiagnostics,
    this.recoveryError,
  });

  /// The last open could not read or store a journal; it is kept on disk.
  final Object? recoveryError;
  final GymDeps deps;
  final eng.Gym gym;
  final eng.SessionSnapshot? pending;
  final VoidCallback onStart;
  final VoidCallback onResume;
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
          if (rows.isEmpty)
            Text(
              'Nothing logged yet. Your first session shows up here when '
              'you finish it.',
              style: LitType.body(15, Lit.inkSecondary),
            )
          else
            for (final r in rows) HistoryRowTile(row: r),
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

  eng.GymApi get _engine => widget.deps.engine;

  /// The type whose default muscles hold every pick (most overlap wins);
  /// null for a mixed pick, which then uses ink.
  String? _typeId() {
    if (_picked.isEmpty) return null;
    String? best;
    var bestOverlap = 0;
    for (final t in eng.workoutTypes) {
      if (!_picked.every(t.muscles.contains)) continue;
      final overlap = t.muscles.where(_picked.contains).length;
      if (overlap > bestOverlap) {
        best = t.id;
        bestOverlap = overlap;
      }
    }
    return best;
  }

  eng.SessionPlan? _plan() {
    if (_picked.isEmpty) return null;
    final p = _engine.suggest(
      gymId: widget.gym.id,
      muscleIds: _picked,
      typeId: _typeId(),
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
    );
  }
}

/// The live screen over a [LiveController]. Pops with the workout uuid on
/// finish, or null when paused.
class LiveFlow extends StatefulWidget {
  const LiveFlow({super.key, required this.controller});
  final LiveController controller;
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

  void _leave([String? uuid]) {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
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

  Future<void> _pause() async {
    if (_leaving) return;
    _leaving = true;
    if (await c.pause()) {
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
            onDone: c.done,
            onSkipSet: c.skipSet,
            onRestDelta: c.restDelta,
            onSkipRest: c.skipRest,
            onReorder: c.reorderUpNext,
            onPause: _pause,
            onFinish: _finish,
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
    final row = rows.firstWhere((r) => r.uuid == uuid);
    final units = {
      for (final x in deps.catalog.exercises) x.id: unitOfKind(x.load),
    };
    final tz = deps.tzOffsetMin();
    return PostWorkoutScreen(
      view: postWorkoutViewOf(
        e.summary(uuid),
        row: row,
        weekTypes: weekTypesOf(rows, localOf(deps.nowMs(), tz)),
        unitByExercise: units,
      ),
      onDone: () => Navigator.of(context).pop(),
    );
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

  /// Max candidates when the gym has not told us its pairs: a 2.5 kg grid.
  static final List<int> _grid = [for (var g = 2500; g <= 50000; g += 2500) g];

  /// His pairs as the screen opened, so stepping down then up gives them
  /// back instead of grid values.
  /// Reset whenever the working gym is replaced (pick, add, preset), so one
  /// gym's pairs never leak into another.
  List<int> _own = const [];

  void _use(eng.Gym g) {
    _gym = g;
    _own = [...?g.kit['dumbbells']?.weightsG];
  }

  @override
  void initState() {
    super.initState();
    _use(widget.gym ?? widget.deps.engine.gymFromPreset('condo'));
  }

  /// The gym's own pairs, or the engine's fallback list until it has some.
  List<int> get _dbWeights {
    final w = _gym.kit['dumbbells']?.weightsG ?? const <int>[];
    return w.isNotEmpty ? w : eng.defaultWeightsG['dumbbell']!;
  }

  int get _dbMax => _dbWeights.last;

  /// Moves only the heaviest pair, 2.5 kg at a time. Lighter pairs the gym
  /// already has are kept as they are (never replaced by defaults); a new
  /// top adds just that pair.
  void _stepDumbbells(int dir) => setState(() {
    final cur = _dbMax;
    final own = {..._own, ..._dbWeights};
    // Within his range, his own pairs; above his own top, a 2.5 kg grid.
    final top = own.reduce((a, b) => a > b ? a : b);
    final candidates = ({...own, ..._grid.where((g) => g > top)}.toList()
      ..sort());
    final next = dir > 0
        ? candidates.where((g) => g > cur).firstOrNull
        : candidates.where((g) => g < cur).lastOrNull;
    if (next == null) return;
    final keep = [
      for (final w in own)
        if (w <= next) w,
      if (!own.contains(next)) next,
    ]..sort();
    _gym = _gym.withWeights('dumbbells', keep);
  });

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
      dumbbellMaxG: _dbMax,
      firstRun: widget.firstRun,
      onToggle: (id) => setState(() => _gym = _gym.toggle(id)),
      onPreset: (id) => setState(() {
        final fresh = widget.deps.engine.gymFromPreset(id);
        _use(_gym.copyWith(kit: fresh.kit));
      }),
      onDumbbellMax: _stepDumbbells,
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

/// A short reason for a banner: the port's refusal code, else the type.
String _reason(Object e) =>
    e is WorkoutPortException ? e.code : e.runtimeType.toString();
