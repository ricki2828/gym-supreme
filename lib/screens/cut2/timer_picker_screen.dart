import 'package:flutter/material.dart';
import 'package:gym_engine/cut2.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../../widgets/lit_widgets.dart';

/// Pick a timer block: presets first, then adjust (plan 16 Q9). Pops the
/// chosen [TimerBlock]; null on close. Steppers stop at the block limits.
class TimerPickerScreen extends StatefulWidget {
  const TimerPickerScreen({super.key, this.initial});

  /// Preselected block (e.g. last one used); defaults to the first preset.
  final TimerBlock? initial;

  @override
  State<TimerPickerScreen> createState() => _TimerPickerScreenState();
}

class _TimerPickerScreenState extends State<TimerPickerScreen> {
  late TimerBlock _block = widget.initial ?? timerPresets.first.block;

  /// The AMRAP warning he chose; clamped per cap, never lost when the cap
  /// steps down and back up.
  late int _warnMs = _block.type == TimerType.amrap ? _block.warnMs : 60000;

  void _set(TimerBlock Function() make) {
    try {
      setState(() => _block = make());
    } on ArgumentError {
      // Out of range: keep the last valid block (steppers stop at limits).
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _block;
    return Scaffold(
      backgroundColor: Lit.ground,
      appBar: AppBar(
        backgroundColor: Lit.ground,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text('TIMER', style: LitType.display(28)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in timerPresets)
                ChoiceChip(
                  label: Text(p.block.title, style: LitType.body(14)),
                  selected: p.block == b,
                  onSelected: (_) => _set(() {
                    if (p.block.type == TimerType.amrap) {
                      _warnMs = p.block.warnMs;
                    }
                    return p.block;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _TypeRow(
            type: b.type,
            onType: (t) => _set(
              () => switch (t) {
                TimerType.emom => TimerBlock.emom(
                  rounds: 10,
                  leadInMs: b.leadInMs,
                ),
                TimerType.amrap => TimerBlock.amrap(
                  capMs: 12 * 60000,
                  leadInMs: b.leadInMs,
                  warnMs: _warnMs < 12 * 60000 ? _warnMs : 0,
                ),
                TimerType.interval => TimerBlock.interval(
                  workMs: 20000,
                  restMs: 10000,
                  rounds: 8,
                  leadInMs: b.leadInMs,
                ),
              },
            ),
          ),
          const SizedBox(height: 12),
          ...switch (b.type) {
            TimerType.emom => [
              _Stepper(
                label: 'Rounds',
                value: '${b.rounds}',
                onDelta: (d) => _set(
                  () => TimerBlock.emom(
                    rounds: b.rounds + d,
                    periodMs: b.workMs,
                    leadInMs: b.leadInMs,
                  ),
                ),
              ),
              _Stepper(
                label: 'Every',
                value: formatClock(b.workMs),
                onDelta: (d) => _set(
                  () => TimerBlock.emom(
                    rounds: b.rounds,
                    periodMs: b.workMs + d * 15000,
                    leadInMs: b.leadInMs,
                  ),
                ),
              ),
            ],
            TimerType.amrap => [
              _Stepper(
                label: 'Cap',
                value: formatClock(b.capMs),
                onDelta: (d) => _set(
                  () => TimerBlock.amrap(
                    capMs: b.capMs + d * 60000,
                    leadInMs: b.leadInMs,
                    warnMs: _warnMs < b.capMs + d * 60000 ? _warnMs : 0,
                  ),
                ),
              ),
            ],
            TimerType.interval => [
              _Stepper(
                label: 'Rounds',
                value: '${b.rounds}',
                onDelta: (d) => _set(
                  () => TimerBlock.interval(
                    workMs: b.workMs,
                    restMs: b.restMs,
                    rounds: b.rounds + d,
                    leadInMs: b.leadInMs,
                  ),
                ),
              ),
              _Stepper(
                label: 'Work',
                value: formatClock(b.workMs),
                onDelta: (d) => _set(
                  () => TimerBlock.interval(
                    workMs: b.workMs + d * 5000,
                    restMs: b.restMs,
                    rounds: b.rounds,
                    leadInMs: b.leadInMs,
                  ),
                ),
              ),
              _Stepper(
                label: 'Rest',
                value: formatClock(b.restMs),
                onDelta: (d) => _set(
                  () => TimerBlock.interval(
                    workMs: b.workMs,
                    restMs: b.restMs + d * 5000,
                    rounds: b.rounds,
                    leadInMs: b.leadInMs,
                  ),
                ),
              ),
            ],
          },
          const SizedBox(height: 12),
          Text(
            'Total ${formatClock(b.totalMs)}. Buzzes with the screen off.',
            style: LitType.body(14, Lit.inkSecondary, FontWeight.w600),
          ),
          const SizedBox(height: 20),
          BigButton(
            label: 'ADD ${b.type.wire.toUpperCase()}',
            colour: Lit.legs,
            ink: Lit.ink,
            onTap: () => Navigator.of(context).pop(b),
            semanticLabel: 'Add ${b.title}',
          ),
        ],
      ),
    );
  }
}

class _TypeRow extends StatelessWidget {
  const _TypeRow({required this.type, required this.onType});
  final TimerType type;
  final ValueChanged<TimerType> onType;

  @override
  Widget build(BuildContext context) => SegmentedButton<TimerType>(
    segments: const [
      ButtonSegment(value: TimerType.emom, label: Text('EMOM')),
      ButtonSegment(value: TimerType.amrap, label: Text('AMRAP')),
      ButtonSegment(value: TimerType.interval, label: Text('Interval')),
    ],
    selected: {type},
    showSelectedIcon: false,
    onSelectionChanged: (s) => onType(s.first),
  );
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.onDelta,
  });
  final String label;
  final String value;
  final ValueChanged<int> onDelta;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(child: Text(label, style: LitType.body(17))),
        _Round(Icons.remove, 'Less $label', () => onDelta(-1)),
        SizedBox(
          width: 88,
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: LitType.display(30),
          ),
        ),
        _Round(Icons.add, 'More $label', () => onDelta(1)),
      ],
    ),
  );
}

class _Round extends StatelessWidget {
  const _Round(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: Icon(icon),
    tooltip: label,
    iconSize: 24,
    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    style: IconButton.styleFrom(
      side: const BorderSide(color: Lit.ink, width: 1.5),
    ),
    onPressed: onTap,
  );
}
