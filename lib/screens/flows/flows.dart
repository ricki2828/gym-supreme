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
          final uuid = r.snapshot?.workoutUuid;
          if (uuid != null) await port.deleteJournal(uuid);
        case eng.RecoveryAction.offerResume:
          pending = r.snapshot;
        case eng.RecoveryAction.none:
          break;
      }
    } on WorkoutPortException {
      // The journal stays on disk for the next open; nothing is deleted.
    }
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _recovering = false;
      _gymId = _pickGym();
    });
  }

  String? _pickGym() {
    final gyms = _engine.gyms();
    if (gyms.isEmpty) return null;
    final keep = gyms.where((g) => g.id == _gymId);
    return keep.isNotEmpty ? _gymId : gyms.first.id;
  }

  void _refresh() => setState(() => _gymId = _pickGym());

  Future<void> _openPicker() async {
    final gym = _engine.gym(_gymId!)!;
    final plan = await Navigator.of(context).push<eng.SessionPlan>(
      MaterialPageRoute(
        builder: (_) => PickerFlow(deps: widget.deps, gym: gym),
      ),
    );
    if (plan == null || !mounted) return;
    final c = widget.deps.liveController();
    await c.start(plan);
    if (!mounted) return;
    await _runLive(c);
  }

  Future<void> _resume() async {
    final p = _pending;
    if (p == null) return;
    final c = widget.deps.liveController();
    await c.resume(p);
    if (!mounted) return;
    setState(() => _pending = null);
    await _runLive(c);
  }

  Future<void> _runLive(LiveController c) async {
    final uuid = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => LiveFlow(controller: c)));
    final paused = c.active ? c.snapshot : null;
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
  });
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
          if (p != null && pv != null) ...[
            ResumeCard(
              type: workoutTypeOf(p.typeId),
              lift: pv.lift,
              lifts: pv.lifts,
              set: pv.set,
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
  List<int>? _order;

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
    if (order == null || order.length != p.items.length) return p;
    return eng.SessionPlan(
      gymId: p.gymId,
      typeId: p.typeId,
      muscles: p.muscles,
      items: [for (final i in order) p.items[i]],
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

  void _reorder(int from, int to, int n) => setState(() {
    final o = _order ?? List.generate(n, (i) => i);
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
      onReorder: plan == null
          ? null
          : (a, b) => _reorder(a, b, plan.items.length),
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
    if (mounted) setState(() {});
  }

  Future<void> _finish() async {
    final uuid = await c.finish();
    if (mounted && uuid != null) Navigator.of(context).pop(uuid);
  }

  Future<void> _pause() async {
    await c.pause();
    if (mounted) Navigator.of(context).pop();
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
                    'The workout service did not take that (${c.lastError!.code}). '
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
  final VoidCallback onSaved;
  @override
  State<GymFlow> createState() => _GymFlowState();
}

class _GymFlowState extends State<GymFlow> {
  late eng.Gym _gym;

  static final List<int> _dumbbellSteps = [
    ...eng.defaultWeightsG['dumbbell']!,
    for (var g = 27500; g <= 50000; g += 2500) g,
  ];

  @override
  void initState() {
    super.initState();
    _gym = widget.gym ?? widget.deps.engine.gymFromPreset('condo');
  }

  int get _dbMax {
    final w = _gym.kit['dumbbells']?.weightsG ?? const <int>[];
    return w.isEmpty ? 25000 : w.last;
  }

  void _stepDumbbells(int dir) => setState(() {
    final i = _dumbbellSteps.indexOf(_dbMax);
    final j = (i < 0 ? _dumbbellSteps.indexOf(25000) : i) + dir;
    if (j < 0 || j >= _dumbbellSteps.length) return;
    final max = _dumbbellSteps[j];
    _gym = _gym.withWeights('dumbbells', [
      for (final w in _dumbbellSteps)
        if (w <= max) w,
    ]);
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
        _gym = _gym.copyWith(kit: fresh.kit);
      }),
      onDumbbellMax: _stepDumbbells,
      onPickGym: (id) => setState(() {
        _gym = widget.deps.engine.gym(id) ?? _gym;
      }),
      onSave: () {
        widget.deps.engine.saveGym(_gym);
        widget.onSaved();
      },
    );
  }
}
