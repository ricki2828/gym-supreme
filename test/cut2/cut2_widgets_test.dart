import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/cut2.dart';
import 'package:gym_supreme/screens/cut2/rotation_screen.dart';
import 'package:gym_supreme/screens/cut2/timer_picker_screen.dart';
import 'package:gym_supreme/widgets/cut2/ghost_lines.dart';
import 'package:gym_supreme/widgets/cut2/rotation_chip.dart';
import 'package:gym_supreme/widgets/cut2/timer_panel.dart';

const names = {'push': 'Push', 'pull': 'Pull', 'legs': 'Legs'};

Widget app(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('GhostSetLine / GhostTotalLine', () {
    testWidgets('hidden with no ghost', (t) async {
      await t.pumpWidget(app(const GhostSetLine(line: null)));
      expect(find.byType(Text), findsNothing);
      await t.pumpWidget(app(const GhostTotalLine(total: null)));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('ahead shows text, up icon and a spoken label', (t) async {
      const l = SetGhostLine(
        verdict: GhostVerdict.ahead,
        ghostLoadG: 20000,
        ghostReps: 10,
        loadDeltaG: 2500,
        repsDelta: 0,
      );
      await t.pumpWidget(app(const GhostSetLine(line: l, perHand: true)));
      expect(find.text('Last time 20 ea × 10 · +2.5 kg'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_drop_up), findsOneWidget);
      expect(
        find.bySemanticsLabel('Ahead of last time, 20 kilos for 10 reps'),
        findsOneWidget,
      );
    });
  });

  testWidgets('RotationChip text and tap', (t) async {
    var taps = 0;
    await t.pumpWidget(
      app(
        RotationChip(
          rotation: Rotation.defaults(),
          names: names,
          dark: false,
          onTap: () => taps++,
        ),
      ),
    );
    expect(find.text('Next: Push · then Pull, Legs'), findsOneWidget);
    await t.tap(find.byType(RotationChip));
    expect(taps, 1);
  });

  group('RotationScreen', () {
    Future<List<Rotation>> pump(WidgetTester t, Rotation r) async {
      final out = <Rotation>[];
      await t.pumpWidget(
        MaterialApp(
          home: RotationScreen(rotation: r, names: names, onChanged: out.add),
        ),
      );
      return out;
    }

    testWidgets('tap a row makes it next; skip advances', (t) async {
      final out = await pump(t, Rotation.defaults());
      await t.tap(find.text('Legs'));
      expect(out.single.nextId, 'legs');
      await t.tap(find.text('SKIP PUSH'));
      expect(out.last.nextId, 'pull');
    });

    testWidgets('drag reorders and keeps next', (t) async {
      final out = await pump(t, Rotation.defaults());
      final handle = find.byIcon(Icons.drag_handle).first;
      final g = await t.startGesture(t.getCenter(handle));
      await t.pump();
      for (var i = 0; i < 12; i++) {
        await g.moveBy(const Offset(0, 10));
        await t.pump();
      }
      await g.up();
      await t.pumpAndSettle();
      expect(out, isNotEmpty);
      expect(out.last.order.first, isNot('push'));
      expect(out.last.nextId, 'push');
    });
  });

  group('TimerPickerScreen', () {
    Future<TimerBlock?> pick(
      WidgetTester t,
      Future<void> Function() act,
    ) async {
      TimerBlock? got;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () async => got = await Navigator.of(c).push(
                MaterialPageRoute<TimerBlock>(
                  builder: (_) => const TimerPickerScreen(),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await act();
      await t.pumpAndSettle();
      return got;
    }

    testWidgets('default preset, add', (t) async {
      final b = await pick(t, () async {
        await t.tap(find.text('ADD EMOM'));
      });
      expect(b, timerPresets.first.block);
    });

    testWidgets('stepper changes rounds; close returns null', (t) async {
      final b = await pick(t, () async {
        await t.tap(find.byTooltip('More Rounds'));
        await t.pump();
        await t.tap(find.text('ADD EMOM'));
      });
      expect(b!.rounds, timerPresets.first.block.rounds + 1);
      final none = await pick(t, () async {
        await t.tap(find.byTooltip('Close'));
      });
      expect(none, isNull);
    });

    testWidgets('AMRAP warning survives cap down and up', (t) async {
      final b = await pick(t, () async {
        await t.tap(find.text('AMRAP 12:00'));
        await t.pump();
        for (var i = 0; i < 11; i++) {
          await t.tap(find.byTooltip('Less Cap'));
          await t.pump();
        }
        await t.tap(find.byTooltip('More Cap'));
        await t.pump();
        await t.tap(find.text('ADD AMRAP'));
      });
      expect(b!.capMs, 120000);
      expect(b.warnMs, 60000);
    });

    testWidgets('switch to AMRAP', (t) async {
      final b = await pick(t, () async {
        await t.tap(find.text('AMRAP').last);
        await t.pump();
        await t.tap(find.text('ADD AMRAP'));
      });
      expect(b!.type, TimerType.amrap);
    });
  });

  group('TimerPanel', () {
    final emom = TimerBlock.emom(rounds: 3, leadInMs: 10000);

    testWidgets('not started: title + START', (t) async {
      var started = 0;
      await t.pumpWidget(
        app(
          TimerPanel(
            block: emom,
            elapsedAt: (_) => 0,
            running: false,
            onStart: () => started++,
          ),
        ),
      );
      expect(find.text('START'), findsOneWidget);
      await t.tap(find.text('START'));
      expect(started, 1);
    });

    testWidgets('running: derives from the anchor, ticks per second', (
      t,
    ) async {
      var now = 1000;
      await t.pumpWidget(
        app(
          TimerPanel(
            block: emom,
            elapsedAt: (n) => n - 1000,
            running: true,
            nowMs: () => now,
            onRound: () {},
            onFinish: () {},
          ),
        ),
      );
      expect(find.text('GET READY'), findsOneWidget);
      now = 1000 + 10000 + 5000;
      await t.pump(const Duration(milliseconds: 20));
      expect(find.text('EMOM'), findsOneWidget);
      expect(find.text('0:55'), findsOneWidget);
      expect(find.text('Round 1 of 3 · 2:55 left'), findsOneWidget);
      expect(find.text('STOP'), findsOneWidget);
      expect(find.text('ROUND'), findsOneWidget);
    });

    testWidgets('paused mid-block: no ROUND, no ticking', (t) async {
      await t.pumpWidget(
        app(
          TimerPanel(
            block: emom,
            elapsedAt: (_) => 40000,
            running: false,
            onRound: () {},
            onFinish: () {},
          ),
        ),
      );
      expect(find.text('ROUND'), findsNothing);
      expect(find.text('STOP'), findsOneWidget);
      // Settles: a ticking panel would never settle (timeout).
      await t.pumpAndSettle();
    });

    testWidgets('ticker stops once the block is done', (t) async {
      var now = 0;
      await t.pumpWidget(
        app(
          TimerPanel(
            block: emom,
            elapsedAt: (n) => n,
            running: true,
            nowMs: () => now,
            onFinish: () {},
          ),
        ),
      );
      now = emom.totalMs + 10;
      await t.pump(const Duration(milliseconds: 20));
      await t.pump(const Duration(milliseconds: 20));
      expect(find.text('LOG IT'), findsOneWidget);
      await t.pumpAndSettle(); // would time out if it kept ticking
    });

    testWidgets('live region changes per round, not per second', (t) async {
      var now = 10000 + 5000;
      await t.pumpWidget(
        app(
          TimerPanel(
            block: emom,
            elapsedAt: (n) => n,
            running: true,
            nowMs: () => now,
          ),
        ),
      );
      final h = t.ensureSemantics();
      expect(find.bySemanticsLabel('EMOM. Round 1 of 3'), findsOneWidget);
      now += 3000;
      await t.pump(const Duration(milliseconds: 20));
      expect(find.bySemanticsLabel('EMOM. Round 1 of 3'), findsOneWidget);
      h.dispose();
    });

    testWidgets('done: LOG IT', (t) async {
      await t.pumpWidget(
        app(
          TimerPanel(
            block: emom,
            elapsedAt: (_) => emom.totalMs,
            running: false,
            onFinish: () {},
          ),
        ),
      );
      expect(find.text('DONE'), findsOneWidget);
      expect(find.text('LOG IT'), findsOneWidget);
      expect(find.text('ROUND'), findsNothing);
    });
  });
}
