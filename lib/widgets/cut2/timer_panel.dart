import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:gym_engine/cut2.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../lit_widgets.dart';

/// The running timer block on the live screen (R4). Display only: the cues
/// sound from WorkoutService. The countdown is derived on every frame from
/// [elapsedAt] (the session's anchor), never from an accumulating timer, so
/// it cannot drift from what the service fires.
class TimerPanel extends StatefulWidget {
  const TimerPanel({
    super.key,
    required this.block,
    required this.elapsedAt,
    required this.running,
    this.nowMs = _wallNow,
    this.onStart,
    this.onRound,
    this.onFinish,
    this.ink = Lit.ink,
    this.accent = Lit.legs,
  });

  final TimerBlock block;

  /// Block time (lead-in included) at a wall-clock instant, e.g.
  /// `(now) => TimerSession.elapsedMs(snapshot, setId, now)`.
  final int Function(int nowMs) elapsedAt;

  /// True while the block clock runs; the panel ticks only then.
  final bool running;

  /// Injectable for tests and goldens.
  final int Function() nowMs;

  final VoidCallback? onStart;

  /// "Round done" tap (marks).
  final VoidCallback? onRound;

  /// Stop early, or log the block at the end.
  final VoidCallback? onFinish;
  final Color ink;
  final Color accent;

  @override
  State<TimerPanel> createState() => _TimerPanelState();
}

int _wallNow() => DateTime.now().millisecondsSinceEpoch;

class _TimerPanelState extends State<TimerPanel>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  int _shownSecond = -1;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(TimerPanel old) {
    super.didUpdateWidget(old);
    _sync();
  }

  bool get _done =>
      widget.block.stateAt(widget.elapsedAt(widget.nowMs())).phase ==
      TimerPhase.done;

  void _sync() {
    if (widget.running && !_done) {
      _ticker ??= createTicker(_onTick);
      if (!_ticker!.isActive) _ticker!.start();
    } else {
      _ticker?.stop();
    }
  }

  void _onTick(Duration _) {
    // Rebuild once per displayed second, not every frame.
    final e = widget.elapsedAt(widget.nowMs());
    // Stop at the end: the anchor stays set until LOG IT, but nothing moves.
    if (widget.block.stateAt(e).phase == TimerPhase.done) _ticker?.stop();
    final s = e ~/ 1000;
    if (s != _shownSecond) setState(() => _shownSecond = s);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    final elapsed = widget.elapsedAt(widget.nowMs());
    final st = b.stateAt(elapsed);
    final started = widget.running || elapsed > 0;
    final done = st.phase == TimerPhase.done;
    final big = formatClock(
      st.phase == TimerPhase.done ? 0 : st.phaseRemainingMs,
    );
    final ink = widget.ink;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: Lit.ink.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: widget.accent, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(timerPhaseText(b, st), style: LitType.cap(13, ink)),
          const SizedBox(height: 4),
          // The clock is a plain label (read on focus). Only phase and round
          // changes are announced, never every second.
          Semantics(
            label: '${timerPhaseText(b, st)}, $big left',
            excludeSemantics: true,
            child: Text(big, style: LitType.display(72, ink)),
          ),
          const SizedBox(height: 4),
          Semantics(
            liveRegion: started,
            label: started
                ? '${timerPhaseText(b, st)}. ${_roundOnly(b, st)}'
                : b.title,
            excludeSemantics: true,
            child: Text(
              started ? timerRoundText(b, st) : b.title,
              style: LitType.body(14, ink, FontWeight.w600),
            ),
          ),
          const SizedBox(height: 14),
          if (!started)
            BigButton(
              label: 'START',
              colour: widget.accent,
              ink: Lit.ink,
              onTap: widget.onStart,
              semanticLabel: 'Start ${b.title}',
            )
          else
            Row(
              children: [
                // Hidden while paused: BigButton has no disabled look.
                if (!done && widget.running && widget.onRound != null) ...[
                  Expanded(
                    child: BigButton(
                      label: 'ROUND',
                      colour: widget.accent,
                      ink: Lit.ink,
                      fontSize: 24,
                      onTap: widget.onRound,
                      semanticLabel: 'Round done',
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: BigButton(
                    label: done ? 'LOG IT' : 'STOP',
                    colour: done ? widget.accent : Lit.ink,
                    ink: done ? Lit.ink : Colors.white,
                    fontSize: 24,
                    onTap: widget.onFinish,
                    semanticLabel: done ? 'Log this block' : 'Stop the block',
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Round and phase only, without the seconds: a live region must change at
/// most once per round, or TalkBack reads the clock every second.
String _roundOnly(TimerBlock b, TimerState s) => switch (s.phase) {
  TimerPhase.done || TimerPhase.leadIn => b.title,
  _ when b.type == TimerType.amrap => b.title,
  _ => 'Round ${s.round} of ${s.rounds}',
};
