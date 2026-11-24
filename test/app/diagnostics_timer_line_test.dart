import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/app/diagnostics_screen.dart';

/// 0.3 cut T1: the Diagnostics screen reads the last timer block's cue log
/// (native counters from android CueLog.kt) as one line.
void main() {
  const pass = {
    'timer_last_block_cues': 21,
    'timer_last_block_fired': 21,
    'timer_last_block_late': 0,
    'timer_last_block_missed': 0,
    'timer_last_block_max_late_ms': 340,
    'timer_last_cue_01_late_ms': 12,
    'rest_alerts_fired': 4,
  };

  test('line reads fired/total, late and max lateness', () {
    expect(
      timerBlockLine(pass),
      'Last timer block: 21/21 cues, 0 late, max 340 ms late',
    );
  });

  test('missed cues are named; no block means no line', () {
    expect(
      timerBlockLine({
        ...pass,
        'timer_last_block_fired': 18,
        'timer_last_block_late': 1,
        'timer_last_block_missed': 3,
        'timer_last_block_max_late_ms': 1450,
      }),
      'Last timer block: 18/21 cues, 1 late, 3 missed, max 1450 ms late',
    );
    expect(timerBlockLine({'rest_alerts_fired': 4}), isNull);
    expect(timerBlockLine(const {}), isNull);
  });

  testWidgets('the line shows when a block ran and is absent otherwise', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TimerBlockLine(native: pass)),
      ),
    );
    expect(
      find.text('Last timer block: 21/21 cues, 0 late, max 340 ms late'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('timer-block-line')), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TimerBlockLine(native: {'rest_alerts_fired': 1})),
      ),
    );
    expect(find.byKey(const Key('timer-block-line')), findsNothing);
  });
}
