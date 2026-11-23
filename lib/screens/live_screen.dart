import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../widgets/lit_widgets.dart';
import 'view_models.dart';

enum SetTile { done, current, pending, skipped }

/// Everything the live screen shows. Built from the session snapshot plus
/// the screen's draft (the +/- before Done) by the live controller.
class LiveView {
  const LiveView({
    required this.type,
    required this.exerciseName,
    required this.lift,
    required this.lifts,
    required this.set,
    required this.sets,
    required this.rail,
    required this.reps,
    required this.loadG,
    required this.unit,
    required this.targetReps,
    required this.targetLoadG,
    required this.restS,
    required this.upNext,
    required this.elapsedS,
    this.lastTime,
    this.canLoadUp = true,
    this.canLoadDown = true,
    this.restLeftS,
    this.paused = false,
    this.allDone = false,
    this.timerBlock = false,
    this.setId,
    this.blockTitle,
    this.undoLabel,
    this.canSwap = false,
    this.doneSets = 0,
    this.leftSets = 0,
  });

  final WorkoutType? type;
  final String exerciseName;

  /// 1-based.
  final int lift, lifts, set, sets;

  /// Sets of the current exercise, first to last.
  final List<SetTile> rail;

  /// What Done will log.
  final int reps;
  final int? loadG;
  final LoadUnit unit;

  /// The plan for this set; null load = cold start (first time here).
  final int? targetReps;
  final int? targetLoadG;

  /// "Last time 3 × 10 · 22 kg ea", or null.
  final String? lastTime;
  final bool canLoadUp, canLoadDown;

  /// Rest after this set, seconds.
  final int restS;

  /// Exercises after the current one, in order (drag to reorder).
  final List<PlanItem> upNext;

  /// Seconds left in the running rest; null = not resting.
  final int? restLeftS;
  final int elapsedS;
  final bool paused;

  /// Every set is logged or skipped: only Finish is left.
  final bool allDone;

  /// The current set is a cut-2 timer block (EMOM, AMRAP, intervals). Its
  /// controls come from the caller's setExtra (the timer panel), so the
  /// reps/load steppers, last-time line, DONE and the rest panel are hidden.
  final bool timerBlock;

  /// The current set's id, so a typed value lands on the set the number pad
  /// was opened on, never the next one.
  final String? setId;

  /// The block's own name ("EMOM 20 × 1:00"); null when not a block or
  /// unreadable. Shown wherever a set would show "reps × load".
  final String? blockTitle;

  /// The last logged set, e.g. "Dumbbell bench press 10 × 22 kg ea"; null
  /// when nothing is logged yet (no Undo).
  final String? undoLabel;

  /// The current exercise has nothing logged yet, so it can be swapped.
  final bool canSwap;

  /// For the Finish confirm: sets logged, and sets still pending (dropped).
  final int doneSets;
  final int leftSets;

  bool get coldStart =>
      targetLoadG == null && (unit == LoadUnit.kg || unit == LoadUnit.kgEach);

  bool get asPlanned => reps == targetReps && loadG == targetLoadG;
}

/// Live logging (plan item 4; b-live.png): prefill from last time, one-tap
/// Done, +/- on the gym's real weights, auto rest, drag to reorder.
class LiveScreen extends StatelessWidget {
  const LiveScreen({
    super.key,
    required this.view,
    this.onReps,
    this.onLoad,
    this.onTypeReps,
    this.onTypeLoad,
    this.onDone,
    this.onSkipSet,
    this.onRestDelta,
    this.onSkipRest,
    this.onReorder,
    this.onPause,
    this.onFinish,
    this.onUndo,
    this.onSwap,
    this.onAddSet,
    this.setExtra,
    this.actions = const [],
  });

  final LiveView view;

  /// Cut-2 slot under the last-time line (ghost line for the current set).
  final Widget? setExtra;

  /// Cut-2 slot: extra actions above Pause/Finish (e.g. "Add timer block").
  final List<Widget> actions;

  /// +1 / -1 rep.
  final ValueChanged<int>? onReps;

  /// +1 / -1 step along the gym's weight list.
  final ValueChanged<int>? onLoad;

  /// A typed rep count (seconds on a timed set), with the set id it was
  /// typed for.
  final void Function(int value, String? setId)? onTypeReps;

  /// A typed load in grams (any value, on the gym's list or not).
  final void Function(int grams, String? setId)? onTypeLoad;
  final VoidCallback? onDone;
  final VoidCallback? onSkipSet;

  /// ±15 s on the planned or running rest.
  final ValueChanged<int>? onRestDelta;
  final VoidCallback? onSkipRest;

  /// Indexes within [LiveView.upNext].
  final void Function(int from, int to)? onReorder;
  final VoidCallback? onPause;

  /// Called after he confirms (with sets left) or straight away (all done).
  final VoidCallback? onFinish;

  /// Undo the last logged set (P1-6).
  final VoidCallback? onUndo;

  /// Swap the current exercise (only offered while nothing of it is logged).
  final VoidCallback? onSwap;

  /// One more set on the current exercise.
  final VoidCallback? onAddSet;

  /// Finish with sets still pending asks first (P1-6: Finish used to sit
  /// beside Pause and end the workout in one tap).
  Future<void> _confirmFinish(BuildContext context) async {
    final f = onFinish;
    if (f == null) return;
    if (view.leftSets == 0) return f();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Finish this workout?'),
        content: Text(
          '${view.doneSets} ${view.doneSets == 1 ? 'set' : 'sets'} logged. '
          '${view.leftSets} not done ${view.leftSets == 1 ? 'is' : 'are'} '
          'dropped.',
        ),
        actions: [
          TextButton(
            key: const Key('finish.keep'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep going'),
          ),
          TextButton(
            key: const Key('finish.confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Finish'),
          ),
        ],
      ),
    );
    if (ok == true) f();
  }

  /// Finish, pinned to the bottom of every live screen so it never needs a
  /// scroll; Pause lives in the header, away from it.
  Widget _finishBar(BuildContext context, Color ink, Color bg) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
      child: OutlinedButton(
        key: const Key('live.finish'),
        onPressed: onFinish == null ? null : () => _confirmFinish(context),
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          backgroundColor: bg,
          minimumSize: const Size.fromHeight(52),
          side: BorderSide(color: ink, width: 2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Text(
          'Finish workout',
          style: LitType.body(17, ink, FontWeight.w800),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (view.allDone) {
      return _AllDone(view: view, onFinish: onFinish, onUndo: onUndo);
    }
    if (view.restLeftS != null) {
      return _RestScreen(
        view: view,
        onRestDelta: onRestDelta,
        onSkipRest: onSkipRest,
        onReorder: onReorder,
        onUndo: onUndo,
        finishBar: _finishBar(context, Lit.ink, Lit.pull),
      );
    }
    final bg = view.type?.colour ?? Lit.ground;
    final ink = view.type?.onColour ?? Lit.ink;
    // Hand the set to the timer panel only when one is given: a block opened
    // in a build without it falls back to the normal set controls.
    final blockUi = view.timerBlock && setExtra != null;
    return Scaffold(
      backgroundColor: bg,
      bottomNavigationBar: _finishBar(context, ink, bg),
      body: SafeArea(
        bottom: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 16, 20),
                children: [
                  _Header(view: view, ink: ink, onPause: onPause),
                  const SizedBox(height: 6),
                  Text(
                    view.exerciseName.toUpperCase(),
                    style: LitType.display(
                      view.exerciseName.length > 18 ? 44 : 60,
                      ink,
                    ),
                    semanticsLabel: view.exerciseName,
                  ),
                  if (!blockUi) ...[
                    const SizedBox(height: 14),
                    _Stepper(
                      value: view.unit == LoadUnit.timed
                          ? clock(view.reps)
                          : '${view.reps}',
                      unit: view.unit == LoadUnit.timed ? 'SEC' : 'REPS',
                      size: 96,
                      ink: ink,
                      bg: bg,
                      label: view.unit == LoadUnit.timed ? 'seconds' : 'reps',
                      onMinus: onReps == null || view.reps <= 1
                          ? null
                          : () => onReps!(-1),
                      onPlus: onReps == null ? null : () => onReps!(1),
                      onEdit: onTypeReps == null
                          ? null
                          : () async {
                              final timed = view.unit == LoadUnit.timed;
                              final forSet = view.setId;
                              final v = await askNumber(
                                context,
                                title: timed ? 'Seconds' : 'Reps',
                                unit: timed ? 'sec' : 'reps',
                                initial: view.reps,
                                max: timed ? 3600 : 200,
                              );
                              if (v != null && v >= 1) {
                                onTypeReps!(v.round(), forSet);
                              }
                            },
                    ),
                    if (view.unit == LoadUnit.kg ||
                        view.unit == LoadUnit.kgEach) ...[
                      const SizedBox(height: 8),
                      _Stepper(
                        value: view.loadG == null ? '–' : kg(view.loadG!),
                        unit: view.unit == LoadUnit.kgEach ? 'KG EA' : 'KG',
                        size: 150,
                        ink: ink,
                        bg: bg,
                        label: 'kilograms',
                        onMinus: onLoad == null || !view.canLoadDown
                            ? null
                            : () => onLoad!(-1),
                        onPlus: onLoad == null || !view.canLoadUp
                            ? null
                            : () => onLoad!(1),
                        onEdit: onTypeLoad == null
                            ? null
                            : () async {
                                final forSet = view.setId;
                                final v = await askNumber(
                                  context,
                                  title: view.unit == LoadUnit.kgEach
                                      ? 'Kilograms, each'
                                      : 'Kilograms',
                                  unit: 'kg',
                                  initial: view.loadG == null
                                      ? null
                                      : view.loadG! / 1000,
                                  decimals: true,
                                );
                                if (v != null) {
                                  onTypeLoad!((v * 1000).round(), forSet);
                                }
                              },
                      ),
                    ],
                    const SizedBox(height: 10),
                    Text(
                      view.coldStart
                          ? 'First time here. Pick a starting weight; '
                                'the app remembers it.'
                          : (view.lastTime ?? 'No history at this gym yet.'),
                      style: LitType.body(17, ink, FontWeight.w600),
                    ),
                  ],
                  ?setExtra,
                  if (!blockUi) ...[
                    const SizedBox(height: 18),
                    BigButton(
                      label: 'DONE',
                      sub: _doneSub(),
                      colour: Lit.ink,
                      ink: Colors.white,
                      subColour: view.type?.colour ?? Colors.white,
                      height: 150,
                      fontSize: 110,
                      radius: 28,
                      onTap: view.coldStart && view.loadG == null
                          ? null
                          : onDone,
                    ),
                    const SizedBox(height: 12),
                    _RestPanel(
                      seconds: view.restS,
                      ink: ink,
                      onDelta: onRestDelta,
                    ),
                  ],
                  _SetLinks(
                    ink: ink,
                    undoLabel: view.undoLabel,
                    onUndo: onUndo,
                    onSwap: view.canSwap ? onSwap : null,
                    onAddSet: onAddSet,
                    onSkipSet: onSkipSet,
                  ),
                  if (view.upNext.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      'NEXT UP · DRAG TO REORDER',
                      style: LitType.cap(13, ink),
                    ),
                    const SizedBox(height: 8),
                    PlanList(
                      items: view.upNext,
                      onReorder: onReorder,
                      ruleColour: ink.withValues(alpha: 0.25),
                    ),
                  ],
                  for (final a in actions) ...[const SizedBox(height: 12), a],
                  const SizedBox(height: 18),
                ],
              ),
            ),
            _SetRail(rail: view.rail, accent: bg),
          ],
        ),
      ),
    );
  }

  String _doneSub() {
    if (view.blockTitle != null) return view.blockTitle!;
    final load = loadLabel(view.loadG, view.unit);
    final work = view.unit == LoadUnit.timed
        ? clock(view.reps)
        : '${view.reps}';
    final what = view.unit == LoadUnit.timed
        ? work
        : (load.isEmpty ? '$work reps' : '$work × $load');
    if (view.coldStart) {
      return view.loadG == null ? 'Set a weight first' : '$what, first time';
    }
    return view.asPlanned ? '$what, as planned' : '$what, changed';
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.view, required this.ink, this.onPause});
  final LiveView view;
  final Color ink;
  final VoidCallback? onPause;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          'LIFT ${view.lift} OF ${view.lifts} · SET ${view.set} OF ${view.sets}',
          style: LitType.cap(14, ink),
        ),
      ),
      Text(
        clock(view.elapsedS),
        style: LitType.cap(14, ink),
        semanticsLabel: '${view.elapsedS ~/ 60} minutes in',
      ),
      if (onPause != null) ...[
        const SizedBox(width: 4),
        TextButton.icon(
          key: const Key('live.pause'),
          onPressed: onPause,
          style: TextButton.styleFrom(
            foregroundColor: ink,
            minimumSize: const Size(48, 48),
          ),
          icon: const Icon(Icons.pause, size: 20),
          label: Text('Pause', style: LitType.body(14, ink, FontWeight.w700)),
        ),
      ],
    ],
  );
}

/// The small actions under the set: Undo the last set, Swap this exercise,
/// Add a set, Skip this set. Each 48 dp.
class _SetLinks extends StatelessWidget {
  const _SetLinks({
    required this.ink,
    this.undoLabel,
    this.onUndo,
    this.onSwap,
    this.onAddSet,
    this.onSkipSet,
  });
  final Color ink;
  final String? undoLabel;
  final VoidCallback? onUndo;
  final VoidCallback? onSwap;
  final VoidCallback? onAddSet;
  final VoidCallback? onSkipSet;

  Widget _link(
    String text,
    IconData icon,
    VoidCallback onTap, {
    Key? key,
    String? semantic,
  }) => Semantics(
    button: true,
    label: semantic ?? text,
    excludeSemantics: true,
    child: TextButton.icon(
      key: key,
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size(48, 48),
      ),
      icon: Icon(icon, size: 18),
      label: Text(text, style: LitType.body(14, ink, FontWeight.w700)),
    ),
  );

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    children: [
      if (undoLabel != null && onUndo != null)
        _link(
          'Undo last set',
          Icons.undo,
          onUndo!,
          key: const Key('live.undo'),
          semantic: 'Undo last set: $undoLabel',
        ),
      if (onSwap != null)
        _link(
          'Swap',
          Icons.swap_horiz,
          onSwap!,
          key: const Key('live.swap'),
          semantic: 'Swap this exercise',
        ),
      if (onAddSet != null)
        _link(
          'Add a set',
          Icons.add,
          onAddSet!,
          key: const Key('live.add_set'),
        ),
      if (onSkipSet != null)
        _link('Skip this set', Icons.skip_next, onSkipSet!),
    ],
  );
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.value,
    required this.unit,
    required this.size,
    required this.ink,
    required this.bg,
    required this.label,
    this.onMinus,
    this.onPlus,
    this.onEdit,
  });
  final String value;
  final String unit;
  final double size;
  final Color ink;
  final Color bg;
  final String label;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  /// Tap the number to type it (P1-1).
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _Round(icon: Icons.remove, tip: 'Less $label', bg: bg, onTap: onMinus),
      Expanded(
        child: Semantics(
          button: onEdit != null,
          label: '$value $label',
          onTapHint: onEdit == null ? null : 'type a value',
          excludeSemantics: true,
          onTap: onEdit,
          child: InkWell(
            onTap: onEdit,
            borderRadius: BorderRadius.circular(16),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(value, style: LitType.display(size, ink)),
                  const SizedBox(width: 8),
                  Text(unit, style: LitType.display(size * 0.42, ink)),
                ],
              ),
            ),
          ),
        ),
      ),
      _Round(icon: Icons.add, tip: 'More $label', bg: bg, onTap: onPlus),
    ],
  );
}

/// A 60 dp round +/- button. Hold it to repeat (P1-1): after the long-press
/// delay, one step and then about 8 a second until released or the end of
/// the range.
class _Round extends StatefulWidget {
  const _Round({
    required this.icon,
    required this.tip,
    required this.bg,
    this.onTap,
  });
  final IconData icon;
  final String tip;
  final Color bg;
  final VoidCallback? onTap;

  @override
  State<_Round> createState() => _RoundState();
}

class _RoundState extends State<_Round> {
  Timer? _repeat;

  void _start() {
    _stop(); // a second finger must not leave the first timer running
    final tap = widget.onTap;
    if (tap == null) return;
    tap();
    _repeat = Timer.periodic(const Duration(milliseconds: 120), (_) {
      final t = widget.onTap;
      if (t == null) {
        _stop();
      } else {
        t();
      }
    });
  }

  void _stop() {
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: widget.onTap != null,
    label: widget.tip,
    excludeSemantics: true,
    onTap: widget.onTap,
    child: GestureDetector(
      onLongPressStart: (_) => _start(),
      onLongPressEnd: (_) => _stop(),
      onLongPressCancel: _stop,
      child: Material(
        color: widget.onTap == null ? Lit.ink.withValues(alpha: 0.35) : Lit.ink,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.onTap,
          child: SizedBox(
            width: 60,
            height: 60,
            child: Icon(widget.icon, size: 30, color: widget.bg),
          ),
        ),
      ),
    ),
  );
}

/// The number pad for a typed value. Null on cancel or a value out of range.
Future<num?> askNumber(
  BuildContext context, {
  required String title,
  required String unit,
  num? initial,
  bool decimals = false,
  num max = 500,
}) {
  final text = TextEditingController(
    text: initial == null
        ? ''
        : (decimals ? _trimNum(initial.toDouble()) : '${initial.round()}'),
  );
  num? parse() {
    final v = num.tryParse(text.text.trim().replaceAll(',', '.'));
    if (v == null || !v.isFinite || v < 0 || v > max) return null;
    return decimals ? v : v.round();
  }

  return showDialog<num>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        key: const Key('live.keypad'),
        controller: text,
        autofocus: true,
        keyboardType: TextInputType.numberWithOptions(decimal: decimals),
        style: LitType.display(48),
        decoration: InputDecoration(suffixText: unit),
        onSubmitted: (_) {
          final v = parse();
          if (v != null) Navigator.of(ctx).pop(v);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('live.keypad.set'),
          onPressed: () {
            final v = parse();
            if (v != null) Navigator.of(ctx).pop(v);
          },
          child: const Text('Set'),
        ),
      ],
    ),
  );
}

String _trimNum(double v) => v == v.roundToDouble()
    ? v.toStringAsFixed(0)
    : v
          .toStringAsFixed(3)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');

class _RestPanel extends StatelessWidget {
  const _RestPanel({required this.seconds, required this.ink, this.onDelta});
  final int seconds;
  final Color ink;
  final ValueChanged<int>? onDelta;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
    decoration: BoxDecoration(
      color: Lit.ink.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'THEN REST ${clock(seconds)}',
                style: LitType.display(34, ink),
              ),
              const SizedBox(height: 2),
              Text(
                'Starts itself. Buzzes when it ends.',
                style: LitType.body(13, ink, FontWeight.w600),
              ),
            ],
          ),
        ),
        _Pill('−15', ink, onDelta == null ? null : () => onDelta!(-15)),
        const SizedBox(width: 6),
        _Pill('+15', ink, onDelta == null ? null : () => onDelta!(15)),
      ],
    ),
  );
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, this.ink, this.onTap);
  final String label;
  final Color ink;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label.startsWith('+')
        ? '15 seconds more rest'
        : '15 seconds less rest',
    excludeSemantics: true,
    onTap: onTap,
    child: InkWell(
      onTap: onTap,
      customBorder: const StadiumBorder(),
      child: Container(
        constraints: const BoxConstraints(minWidth: 52, minHeight: 48),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: ShapeDecoration(
          shape: StadiumBorder(side: BorderSide(color: ink, width: 1.5)),
        ),
        child: Text(label, style: LitType.body(15, ink, FontWeight.w700)),
      ),
    ),
  );
}

/// The set strip on the right edge (b-live): last set on top.
class _SetRail extends StatelessWidget {
  const _SetRail({required this.rail, required this.accent});
  final List<SetTile> rail;
  final Color accent;
  @override
  Widget build(BuildContext context) {
    final n = rail.length;
    return ExcludeSemantics(
      child: SizedBox(
        width: 46,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 36),
          child: Column(
            children: [
              for (var i = n - 1; i >= 0; i--)
                Expanded(
                  flex: rail[i] == SetTile.current ? 3 : 2,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _tile(i + 1, rail[i]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(int number, SetTile t) {
    final (Color fill, Color border, Color text) = switch (t) {
      SetTile.done => (Lit.ink, Lit.ink, accent),
      SetTile.current => (Colors.white, Lit.ink, Lit.ink),
      SetTile.pending => (
        Colors.transparent,
        Lit.ink.withValues(alpha: 0.4),
        Lit.ink,
      ),
      SetTile.skipped => (
        Colors.transparent,
        Lit.ink.withValues(alpha: 0.4),
        Lit.inkQuiet,
      ),
    };
    return Container(
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: border, width: 2.5),
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)),
      ),
      alignment: Alignment.center,
      child: Text(
        t == SetTile.skipped ? '–' : '$number',
        style: LitType.body(15, text, FontWeight.w800),
      ),
    );
  }
}

/// Rest running: the screen turns blue (b-live's promise; b-timer's Rest).
class _RestScreen extends StatelessWidget {
  const _RestScreen({
    required this.view,
    this.onRestDelta,
    this.onSkipRest,
    this.onReorder,
    this.onUndo,
    this.finishBar,
  });
  final LiveView view;
  final ValueChanged<int>? onRestDelta;
  final VoidCallback? onSkipRest;
  final void Function(int from, int to)? onReorder;
  final VoidCallback? onUndo;
  final Widget? finishBar;

  @override
  Widget build(BuildContext context) {
    const bg = Lit.pull;
    const ink = Lit.ink;
    final left = view.restLeftS!;
    final load = loadLabel(view.loadG, view.unit);
    final next =
        view.blockTitle ??
        (view.unit == LoadUnit.timed
            ? clock(view.reps)
            : (load.isEmpty ? '${view.reps} reps' : '${view.reps} × $load'));
    return Scaffold(
      backgroundColor: bg,
      bottomNavigationBar: finishBar,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          children: [
            Row(
              children: [
                Expanded(child: Text('REST', style: LitType.cap(14))),
                Text(clock(view.elapsedS), style: LitType.cap(14)),
              ],
            ),
            Semantics(
              liveRegion: true,
              label: '${clock(left)} rest left',
              excludeSemantics: true,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(clock(left), style: LitType.display(220, ink)),
              ),
            ),
            Text(
              'left. Buzz and a tone when it ends, even locked.',
              style: LitType.body(17, ink, FontWeight.w600),
            ),
            const SizedBox(height: 24),
            Text(
              'NEXT · SET ${view.set} OF ${view.sets}',
              style: LitType.cap(14, ink),
            ),
            const SizedBox(height: 4),
            Text(
              view.exerciseName.toUpperCase(),
              style: LitType.display(40, ink),
            ),
            Text(next.toUpperCase(), style: LitType.display(40, ink)),
            const SizedBox(height: 20),
            Row(
              children: [
                _Pill(
                  '−15',
                  ink,
                  onRestDelta == null ? null : () => onRestDelta!(-15),
                ),
                const SizedBox(width: 8),
                _Pill(
                  '+15',
                  ink,
                  onRestDelta == null ? null : () => onRestDelta!(15),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: BigButton(
                    label: 'SKIP REST',
                    colour: Lit.ink,
                    ink: Colors.white,
                    fontSize: 28,
                    onTap: onSkipRest,
                  ),
                ),
              ],
            ),
            if (view.undoLabel != null && onUndo != null)
              Align(
                alignment: Alignment.centerLeft,
                child: _SetLinks(
                  ink: ink,
                  undoLabel: view.undoLabel,
                  onUndo: onUndo,
                ),
              ),
            if (view.upNext.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('THEN · DRAG TO REORDER', style: LitType.cap(13, ink)),
              const SizedBox(height: 8),
              PlanList(
                items: view.upNext,
                onReorder: onReorder,
                ruleColour: ink.withValues(alpha: 0.25),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AllDone extends StatelessWidget {
  const _AllDone({required this.view, this.onFinish, this.onUndo});
  final LiveView view;
  final VoidCallback? onFinish;
  final VoidCallback? onUndo;
  @override
  Widget build(BuildContext context) {
    final bg = view.type?.colour ?? Lit.ground;
    final ink = view.type?.onColour ?? Lit.ink;
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(clock(view.elapsedS), style: LitType.cap(14, ink)),
              const Spacer(),
              Text('EVERY SET LOGGED', style: LitType.display(64, ink)),
              const SizedBox(height: 8),
              Text(
                'Finish to save it and see what lit up.',
                style: LitType.body(17, ink, FontWeight.w600),
              ),
              const SizedBox(height: 24),
              BigButton(
                label: 'FINISH',
                colour: Lit.ink,
                ink: Colors.white,
                height: 96,
                fontSize: 64,
                radius: 28,
                onTap: onFinish,
              ),
              if (view.undoLabel != null && onUndo != null)
                _SetLinks(ink: ink, undoLabel: view.undoLabel, onUndo: onUndo),
            ],
          ),
        ),
      ),
    );
  }
}
