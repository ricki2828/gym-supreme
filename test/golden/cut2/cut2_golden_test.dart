import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/cut2.dart';
import 'package:gym_supreme/screens/cut2/rotation_screen.dart';
import 'package:gym_supreme/screens/cut2/timer_picker_screen.dart';
import 'package:gym_supreme/widgets/cut2/ghost_lines.dart';
import 'package:gym_supreme/widgets/cut2/rotation_chip.dart';
import 'package:gym_supreme/widgets/cut2/timer_panel.dart';
import 'package:gym_supreme/widgets/lit_widgets.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../../screens/fixtures.dart';

/// Cut-2 goldens (behind Features.*; not in APK 0.1). CI renders the
/// reference PNGs; host renders are for eyeballing only.
const names = {'push': 'Push', 'pull': 'Pull', 'legs': 'Legs', 'core': 'Core'};
const colours = {
  'push': Lit.push,
  'pull': Lit.pull,
  'legs': Lit.legs,
  'core': Lit.core,
};

Future<void> shot(
  WidgetTester tester,
  String name,
  Widget home, {
  double textScale = 1.0,
  bool settle = true,
}) async {
  phone(tester, textScale: textScale);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: runSoloTheme().copyWith(scaffoldBackgroundColor: Lit.ground),
      home: home,
    ),
  );
  // A running TimerPanel ticks forever: pump frames, don't settle.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('../goldens/cut2_$name.png'),
  );
}

/// Panels in the states that matter, stacked on one phone screen.
Widget panels() {
  final emom = TimerBlock.emom(rounds: 20, leadInMs: 10000);
  final tabata = TimerBlock.interval(workMs: 20000, restMs: 10000, rounds: 8);
  final amrap = TimerBlock.amrap(capMs: 12 * 60000);
  Widget p(TimerBlock b, int elapsed, {bool running = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TimerPanel(
      block: b,
      elapsedAt: (_) => elapsed,
      running: running,
      nowMs: () => 0, // fixed clock: a stable frame for the golden
      onStart: () {},
      onRound: () {},
      onFinish: () {},
    ),
  );
  return Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          p(emom, 0),
          p(emom, 10000 + 2 * 60000 + 5000, running: true),
          p(tabata, 25000, running: true),
          p(amrap, amrap.totalMs),
        ],
      ),
    ),
  );
}

/// Ghost lines as they sit under a set, and the session total.
Widget ghosts() => Scaffold(
  body: SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DB BENCH PRESS', style: LitType.display(34)),
          const GhostSetLine(
            perHand: true,
            line: SetGhostLine(
              verdict: GhostVerdict.ahead,
              ghostLoadG: 22500,
              ghostReps: 10,
              loadDeltaG: 2500,
              repsDelta: 0,
            ),
          ),
          const GhostSetLine(
            perHand: true,
            line: SetGhostLine(
              verdict: GhostVerdict.behind,
              ghostLoadG: 22500,
              ghostReps: 8,
              loadDeltaG: -2500,
              repsDelta: 1,
            ),
          ),
          const GhostSetLine(
            line: SetGhostLine(verdict: GhostVerdict.pending, ghostReps: 12),
          ),
          const GhostSetLine(
            line: SetGhostLine(
              verdict: GhostVerdict.level,
              ghostLoadG: 45000,
              ghostReps: 12,
              loadDeltaG: 0,
              repsDelta: 0,
            ),
          ),
          const GhostSetLine(line: SetGhostLine(verdict: GhostVerdict.newSet)),
          const SizedBox(height: 16),
          const GhostTotalLine(
            total: SessionGhostTotal(
              volumeGReps: 2500000,
              ghostSoFarGReps: 2250000,
              ghostFullGReps: 3000000,
              exercisesCompared: 3,
            ),
          ),
          const SizedBox(height: 24),
          DarkSheet(
            child: RotationChip(
              rotation: Rotation(['push', 'pull', 'legs', 'core'], next: 1),
              names: names,
              onTap: () {},
            ),
          ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'timer panels',
    (t) => shot(t, 'timer_panels', panels(), settle: false),
  );

  testWidgets(
    'timer picker',
    (t) => shot(t, 'timer_picker', const TimerPickerScreen()),
  );

  testWidgets(
    'timer picker interval 1.3x',
    (t) => shot(
      t,
      'timer_picker_interval_1_3x',
      TimerPickerScreen(initial: timerPresets[3].block),
      textScale: 1.3,
    ),
  );

  testWidgets(
    'rotation',
    (t) => shot(
      t,
      'rotation',
      RotationScreen(
        rotation: Rotation(['push', 'pull', 'legs', 'core'], next: 1),
        names: names,
        colours: colours,
        onChanged: (_) {},
      ),
    ),
  );

  testWidgets('ghost lines', (t) => shot(t, 'ghost_lines', ghosts()));
}
