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
    this.queue = const [],
    this.canDoLater = false,
    this.atExerciseEnd = false,
    required this.elapsedS,
    this.lastTime,
    this.startingWeightG,
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
    this.plateLine,
  });

  /// Per-side plates for the current barbell load ("Per side 20 + 1.25"), or
  /// null: not a barbell lift, or plate math is off (0.3 P1).
  final String? plateLine;

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

  /// The starting weight he typed for this lift (0.3 S1) when it seeded
  /// this session: no history anywhere. Still a cold start for the one-tap
  /// metric, but the screen says where the load came from instead of
  /// "first time".
  final int? startingWeightG;
  final bool canLoadUp, canLoadDown;

  /// Rest after this set, seconds.
  final int restS;

  /// Exercises after the current one that still have sets to do, in order.
  final List<PlanItem> upNext;

  /// Every exercise with sets to do, the current one first: the drag-to-
  /// reorder list. Logged sets stay with their exercise.
  final List<PlanItem> queue;

  /// "Do later" is offered: another exercise is waiting, and the current set
  /// is not a timer block (a block in progress cannot move).
  final bool canDoLater;

  /// The last set of an exercise was just logged and the current exercise has
  /// nothing logged yet, with others still waiting: "WHAT'S NEXT?" is offered.
  /// Picking uses the same rule (and block lock) as [canDoLater].
  final bool atExerciseEnd;

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

enum _FinishChoice { keep, finish, discard }

const _destructive = Color(0xFFB3261E);

/// "Discard this workout? N sets will be lost." True when he confirms. One
/// copy for the live screen and the Resume card on Today.
Future<bool> askDiscard(BuildContext context, int doneSets) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Discard this workout?'),
      content: Text(
        doneSets == 0
            ? 'Nothing has been logged.'
            : '$doneSets ${doneSets == 1 ? 'set' : 'sets'} will be lost.',
      ),
      actions: [
        TextButton(
          key: const Key('discard.keep'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Keep it'),
        ),
        TextButton(
          key: const Key('discard.confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          style: TextButton.styleFrom(foregroundColor: _destructive),
          child: const Text('Discard'),
        ),
      ],
    ),
  );
  return ok == true;
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
    this.onDoLater,
    this.onPickNext,
    this.onChangeOrder,
    this.onPause,
    this.onFinish,
    this.onDiscard,
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

  /// Indexes within [LiveView.queue] (the current exercise is index 0).
  final void Function(int from, int to)? onReorder;

  /// Move the current exercise to just after the next one.
  final VoidCallback? onDoLater;

  /// "What's next?": do the exercise at this [LiveView.queue] index now. It
  /// becomes the first pending one; the others keep their order.
  final ValueChanged<int>? onPickNext;

  /// Opens the reorder sheet (see [showReorderSheet]).
  final VoidCallback? onChangeOrder;
  final VoidCallback? onPause;

  /// Called after he confirms (with sets left) or straight away (all done).
  final VoidCallback? onFinish;

  /// Throw the whole workout away (journal deleted, nothing saved). Offered
  /// inside the Finish confirm, after a second "are you sure".
  final VoidCallback? onDiscard;

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
    final d = onDiscard;
    if (view.doneSets == 0 && d != null) {
      // Nothing logged: storing an empty workout helps nobody.
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Nothing logged'),
          content: const Text('Discard this workout?'),
          actions: [
            TextButton(
              key: const Key('finish.keep'),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Keep going'),
            ),
            TextButton(
              key: const Key('finish.nothing_discard'),
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(foregroundColor: _destructive),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (discard == true) d();
      return;
    }
    if (view.leftSets == 0) return f();
    final choice = await showDialog<_FinishChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Finish this workout?'),
        content: Text(
          '${view.doneSets} ${view.doneSets == 1 ? 'set' : 'sets'} logged. '
          '${view.leftSets} not done ${view.leftSets == 1 ? 'is' : 'are'} '
          'dropped.',
        ),
        actions: [
          if (d != null)
            TextButton(
              key: const Key('finish.discard'),
              onPressed: () => Navigator.of(ctx).pop(_FinishChoice.discard),
              style: TextButton.styleFrom(foregroundColor: _destructive),
              child: const Text('Discard workout'),
            ),
          TextButton(
            key: const Key('finish.keep'),
            onPressed: () => Navigator.of(ctx).pop(_FinishChoice.keep),
            child: const Text('Keep going'),
          ),
          TextButton(
            key: const Key('finish.confirm'),
            onPressed: () => Navigator.of(ctx).pop(_FinishChoice.finish),
            child: const Text('Finish'),
          ),
        ],
      ),
    );
    if (choice == _FinishChoice.finish) f();
    if (choice == _FinishChoice.discard && d != null && context.mounted) {
      if (await askDiscard(context, view.doneSets)) d();
    }
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
      return _AllDone(
        view: view,
        onFinish: onFinish == null ? null : () => _confirmFinish(context),
        onUndo: onUndo,
      );
    }
    if (view.restLeftS != null) {
      return _RestScreen(
        view: view,
        onRestDelta: onRestDelta,
        onSkipRest: onSkipRest,
        onReorder: onReorder,
        onDoLater: view.canDoLater ? onDoLater : null,
        onPickNext: onPickNext,
        onChangeOrder: onChangeOrder,
        onUndo: onUndo,
        // Edit the next set while resting (X1): the current set is the next
        // one, so the same steppers apply. Not for a timer block.
        nextEdit: view.timerBlock || (onReps == null && onLoad == null)
            ? null
            : Column(
                children: [
                  const SizedBox(height: 10),
                  _repsStepper(context, ink: Lit.ink, bg: Lit.rest, size: 56),
                  if (view.unit == LoadUnit.kg ||
                      view.unit == LoadUnit.kgEach) ...[
                    const SizedBox(height: 6),
                    _loadStepper(context, ink: Lit.ink, bg: Lit.rest, size: 56),
                  ],
                ],
              ),
        finishBar: _finishBar(context, Lit.ink, Lit.rest),
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
                  if (view.queue.length > 1 && onChangeOrder != null) ...[
                    const SizedBox(height: 8),
                    _UpNextEntry(view: view, ink: ink, onTap: onChangeOrder!),
                  ],
                  if (!blockUi) ...[
                    const SizedBox(height: 14),
                    _repsStepper(context, ink: ink, bg: bg, size: 96),
                    if (view.unit == LoadUnit.kg ||
                        view.unit == LoadUnit.kgEach) ...[
                      const SizedBox(height: 8),
                      _loadStepper(context, ink: ink, bg: bg, size: 150),
                      if (view.plateLine != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          view.plateLine!,
                          key: const Key('live.plates'),
                          style: LitType.body(18, ink, FontWeight.w800),
                        ),
                      ],
                    ],
                    const SizedBox(height: 10),
                    Text(
                      view.coldStart && view.startingWeightG != null
                          ? 'Starting weight you set: '
                                '${loadLabel(view.startingWeightG, view.unit)}.'
                          : view.coldStart
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
                  if (view.atExerciseEnd && onPickNext != null) ...[
                    const SizedBox(height: 18),
                    _WhatsNext(view: view, ink: ink, onPick: onPickNext),
                  ],
                  _SetLinks(
                    ink: ink,
                    undoLabel: view.undoLabel,
                    onUndo: onUndo,
                    onSwap: view.canSwap ? onSwap : null,
                    onAddSet: onAddSet,
                    onSkipSet: onSkipSet,
                  ),
                  if (view.canDoLater && onDoLater != null) ...[
                    const SizedBox(height: 6),
                    _DoLaterButton(ink: ink, onTap: onDoLater!),
                  ],
                  if (view.queue.length > 1) ...[
                    const SizedBox(height: 14),
                    Text(
                      'ORDER · HOLD A ROW TO DRAG, OR USE ITS MENU',
                      style: LitType.cap(13, ink),
                    ),
                    const SizedBox(height: 8),
                    PlanList(
                      items: view.queue,
                      markFirst: true,
                      lockFirst: view.timerBlock,
                      moveMenu: true,
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

  /// The reps (or seconds) stepper for the current set: the set screen at 96,
  /// and under NEXT on the rest screen (the next set is the current one).
  Widget _repsStepper(
    BuildContext context, {
    required Color ink,
    required Color bg,
    required double size,
  }) => _Stepper(
    value: view.unit == LoadUnit.timed ? clock(view.reps) : '${view.reps}',
    unit: view.unit == LoadUnit.timed ? 'SEC' : 'REPS',
    size: size,
    ink: ink,
    bg: bg,
    label: view.unit == LoadUnit.timed ? 'seconds' : 'reps',
    onMinus: onReps == null || view.reps <= 1 ? null : () => onReps!(-1),
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
  );

  /// The load stepper for the current set (kg or kg each).
  Widget _loadStepper(
    BuildContext context, {
    required Color ink,
    required Color bg,
    required double size,
  }) => _Stepper(
    value: view.loadG == null ? '–' : kg(view.loadG!),
    unit: view.unit == LoadUnit.kgEach ? 'KG EA' : 'KG',
    size: size,
    ink: ink,
    bg: bg,
    label: 'kilograms',
    onMinus: onLoad == null || !view.canLoadDown ? null : () => onLoad!(-1),
    onPlus: onLoad == null || !view.canLoadUp ? null : () => onLoad!(1),
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
              initial: view.loadG == null ? null : view.loadG! / 1000,
              decimals: true,
            );
            if (v != null) {
              onTypeLoad!((v * 1000).round(), forSet);
            }
          },
  );

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
      if (view.loadG == null) return 'Set a weight first';
      // "starting weight" only while the load is still it; once he has
      // changed the load it is a first time at a new weight.
      return view.startingWeightG != null && view.loadG == view.startingWeightG
          ? '$what, starting weight'
          : '$what, first time';
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
        // One line, shrinking at large text rather than wrapping; the gap
        // keeps it from running into the clock ("OF 312:40").
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            // Narrow phones keep the set count, which he needs mid-set, at a
            // readable size rather than shrinking the whole line.
            _narrowHeader(context)
                ? 'SET ${view.set} OF ${view.sets}'
                : 'LIFT ${view.lift} OF ${view.lifts} · SET ${view.set} OF ${view.sets}',
            semanticsLabel:
                'Lift ${view.lift} of ${view.lifts}, set ${view.set} of ${view.sets}',
            style: LitType.cap(14, ink),
          ),
        ),
      ),
      const SizedBox(width: 10),
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
    onTap: onTap,
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
          semantic: undoLabel!.startsWith('skip: ')
              ? 'Undo ${undoLabel!}'
              : 'Undo last set: $undoLabel',
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

/// "Up next · Change order": a whole-row button under the exercise name that
/// opens the reorder sheet. 56 dp, so it is findable and hard to miss.
class _UpNextEntry extends StatelessWidget {
  const _UpNextEntry({
    required this.view,
    required this.ink,
    required this.onTap,
  });
  final LiveView view;
  final Color ink;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final next = view.queue[1].name;
    return Semantics(
      button: true,
      label: 'Up next: $next. Change order',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: ink.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: const Key('live.change_order'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('UP NEXT', style: LitType.cap(11, ink)),
                        Text(
                          next,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: LitType.body(15, ink, FontWeight.w800),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.swap_vert, color: ink, size: 22),
                  const SizedBox(width: 4),
                  Text(
                    'Change order',
                    style: LitType.body(14, ink, FontWeight.w800),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Do later": a real button, at least 48 dp tall.
class _DoLaterButton extends StatelessWidget {
  const _DoLaterButton({required this.ink, required this.onTap});
  final Color ink;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Do this exercise later: move it after the next one',
    excludeSemantics: true,
    onTap: onTap,
    child: OutlinedButton.icon(
      key: const Key('live.do_later'),
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size.fromHeight(52),
        side: BorderSide(color: ink.withValues(alpha: 0.6), width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon: const Icon(Icons.arrow_downward, size: 18),
      label: Text('Do later', style: LitType.body(15, ink, FontWeight.w800)),
    ),
  );
}

/// "WHAT'S NEXT?": after an exercise's last set. On the rest screen
/// the default is a big card that starts by itself when the
/// rest ends, with Start now; on the set screen the current exercise is
/// already the default, so only the alternatives show. Each row, tapped, makes
/// that exercise the current one (the others keep their order).
class _WhatsNext extends StatelessWidget {
  const _WhatsNext({
    required this.view,
    required this.ink,
    this.onRest = false,
    this.card = true,
    this.rows = true,
    this.onPick,
    this.onStartNow,
  });
  final LiveView view;
  final Color ink;

  /// Drawn on the rest screen, in two parts: the big default [card] where the
  /// NEXT block was, and the [rows] below Skip rest. On the set screen
  /// ([onRest] false) the current exercise is already the default, so a hint
  /// and the rows are all there is.
  final bool onRest;
  final bool card;
  final bool rows;
  final ValueChanged<int>? onPick;
  final VoidCallback? onStartNow;

  @override
  Widget build(BuildContext context) {
    final def = view.queue.first;
    final canPick = view.canDoLater && onPick != null;
    final showCard = onRest && card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showCard || !onRest) ...[
          Text(
            "WHAT'S NEXT?",
            key: const Key('whatsnext.title'),
            style: LitType.cap(14, ink),
          ),
          const SizedBox(height: 8),
        ],
        if (showCard)
          Container(
            key: const Key('whatsnext.default'),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            decoration: BoxDecoration(
              color: Lit.ink,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'STARTS WHEN THE REST ENDS',
                  style: LitType.cap(12, Colors.white),
                ),
                const SizedBox(height: 4),
                Text(
                  def.name.toUpperCase(),
                  style: LitType.display(36, Colors.white),
                  semanticsLabel: def.name,
                ),
                Text(
                  prescription(def),
                  style: LitType.body(15, Colors.white, FontWeight.w600),
                ),
                const SizedBox(height: 12),
                BigButton(
                  key: const Key('whatsnext.start'),
                  label: 'START NOW',
                  colour: Colors.white,
                  ink: Lit.ink,
                  height: 56,
                  fontSize: 26,
                  onTap: onStartNow,
                  semanticLabel: 'Start ${def.name} now',
                ),
              ],
            ),
          )
        else if (!onRest)
          Text(
            'Machine taken? Start one of these now instead.',
            style: LitType.body(15, ink, FontWeight.w600),
          ),
        if (rows && view.queue.length > 1) ...[
          SizedBox(height: onRest ? 0 : 12),
          Text(
            onRest ? 'OR DO ONE OF THESE NOW' : 'DO ONE OF THESE NOW',
            style: LitType.cap(12, ink),
          ),
          const SizedBox(height: 4),
          for (var i = 1; i < view.queue.length; i++)
            _PickRow(
              key: Key('whatsnext.pick.$i'),
              item: view.queue[i],
              ink: ink,
              onTap: canPick ? () => onPick!(i) : null,
            ),
          if (!view.canDoLater && view.timerBlock)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'A timer block is next and cannot be moved.',
                style: LitType.body(14, ink, FontWeight.w600),
              ),
            ),
        ],
      ],
    );
  }
}

class _PickRow extends StatelessWidget {
  const _PickRow({
    super.key,
    required this.item,
    required this.ink,
    required this.onTap,
  });
  final PlanItem item;
  final Color ink;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = onTap == null ? ink.withValues(alpha: 0.45) : ink;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: 'Do ${item.name} now, ${prescription(item)}',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: ink.withValues(alpha: 0.25))),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.name,
                      style: LitType.body(15, c, FontWeight.w800),
                    ),
                    Text(
                      prescription(item),
                      style: LitType.body(13, c, FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text('DO NOW', style: LitType.cap(12, c)),
              Icon(Icons.chevron_right, color: c),
            ],
          ),
        ),
      ),
    );
  }
}

/// The reorder sheet: every exercise still to do, the current one tagged
/// NOW. Live: [view] is read again on every change of [listenable], so moves
/// show at once (a builder that captured the view at open time went stale).
Future<void> showReorderSheet(
  BuildContext context, {
  required Listenable listenable,
  required LiveView? Function() view,
  required void Function(int from, int to) onMove,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Lit.ground,
  builder: (ctx) => ListenableBuilder(
    listenable: listenable,
    builder: (ctx, _) => ReorderSheet(view: view(), onMove: onMove),
  ),
);

class ReorderSheet extends StatelessWidget {
  const ReorderSheet({super.key, required this.view, required this.onMove});
  final LiveView? view;
  final void Function(int from, int to) onMove;

  @override
  Widget build(BuildContext context) {
    final v = view;
    final h = MediaQuery.sizeOf(context).height;
    // Header + hint + padding take about 150 dp; the list scrolls in the rest.
    final listH = (h * 0.75 - 150).clamp(120.0, 600.0);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'CHANGE ORDER',
                    style: LitType.display(30, Lit.ink),
                  ),
                ),
                TextButton(
                  key: const Key('order.close'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  style: TextButton.styleFrom(
                    foregroundColor: Lit.ink,
                    minimumSize: const Size(64, 48),
                  ),
                  child: Text(
                    'Done',
                    style: LitType.body(16, Lit.ink, FontWeight.w800),
                  ),
                ),
              ],
            ),
            Text(
              'Hold a row and drag it, or open its menu to move it up or down. '
              'NOW is the exercise on screen.',
              style: LitType.body(14, Lit.ink, FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (v == null || v.queue.length < 2)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Nothing else to reorder.',
                  style: LitType.body(15, Lit.ink, FontWeight.w700),
                ),
              )
            else
              PlanList(
                items: v.queue,
                markFirst: true,
                lockFirst: v.timerBlock,
                moveMenu: true,
                maxHeight: listH,
                onReorder: onMove,
                ruleColour: Lit.ink.withValues(alpha: 0.25),
              ),
          ],
        ),
      ),
    );
  }
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
    this.onDoLater,
    this.onPickNext,
    this.onChangeOrder,
    this.onUndo,
    this.finishBar,
    this.nextEdit,
  });

  /// Steppers for the next set's reps and load; null hides them.
  final Widget? nextEdit;
  final LiveView view;
  final ValueChanged<int>? onRestDelta;
  final VoidCallback? onSkipRest;
  final void Function(int from, int to)? onReorder;
  final VoidCallback? onDoLater;
  final ValueChanged<int>? onPickNext;
  final VoidCallback? onChangeOrder;
  final VoidCallback? onUndo;
  final Widget? finishBar;

  @override
  Widget build(BuildContext context) {
    const bg = Lit.rest;
    const ink = Lit.ink;
    final left = view.restLeftS!;
    final choose = view.atExerciseEnd && onPickNext != null;
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
            if (choose)
              // Zero extra taps: this card is the default, and it starts by
              // itself when the rest ends (Start now = Skip rest).
              _WhatsNext(
                view: view,
                ink: ink,
                onRest: true,
                rows: false,
                onStartNow: onSkipRest,
              )
            else ...[
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
            ],
            if (view.plateLine != null) ...[
              const SizedBox(height: 4),
              Text(
                view.plateLine!,
                key: const Key('rest.plates'),
                style: LitType.body(18, ink, FontWeight.w800),
              ),
            ],
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
            if (choose) ...[
              const SizedBox(height: 18),
              _WhatsNext(
                view: view,
                ink: ink,
                onRest: true,
                card: false,
                onPick: onPickNext,
              ),
            ],
            // Below Skip rest, so editing the next set never pushes it off a
            // small screen (the UI e2e looks for it).
            if (nextEdit != null) ...[
              const SizedBox(height: 14),
              Text('CHANGE THE NEXT SET', style: LitType.cap(13, ink)),
              nextEdit!,
            ],
            if (view.undoLabel != null && onUndo != null)
              Align(
                alignment: Alignment.centerLeft,
                child: _SetLinks(
                  ink: ink,
                  undoLabel: view.undoLabel,
                  onUndo: onUndo,
                ),
              ),
            if (view.queue.length > 1 && onChangeOrder != null) ...[
              const SizedBox(height: 14),
              _UpNextEntry(view: view, ink: ink, onTap: onChangeOrder!),
            ],
            if (!choose && onDoLater != null) ...[
              const SizedBox(height: 8),
              _DoLaterButton(ink: ink, onTap: onDoLater!),
            ],
            if (view.queue.length > 1 && !choose) ...[
              const SizedBox(height: 24),
              Text(
                'ORDER · HOLD A ROW TO DRAG, OR USE ITS MENU',
                style: LitType.cap(13, ink),
              ),
              const SizedBox(height: 8),
              PlanList(
                items: view.queue,
                markFirst: true,
                lockFirst: view.timerBlock,
                moveMenu: true,
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

/// Short live header: narrow phones (320 dp) at any text size, and 360 dp
/// phones at large text, where the full line would shrink to ~0.6x.
bool _narrowHeader(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  return w < 360 || w / MediaQuery.textScalerOf(context).scale(1) < 300;
}
