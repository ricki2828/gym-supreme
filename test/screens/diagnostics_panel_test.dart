import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/diagnostics_panel.dart';

import 'fixtures.dart';

const gate = GateView(
  sessionsTotal: 5,
  sessionsLast14Days: 3,
  dayOfWindow: 9,
  doneSets: 60,
  tapUnchangedSets: 40,
  coldStartSets: 15,
  oneTapRate: 40 / 45,
  oneTapRateInclCold: 40 / 60,
  medianSwapsPerSession: 1.5,
  appVersions: {'0.1.0+12': 5},
);

const native = {
  'journals_lost': 0,
  'journal_torn_tails': 1,
  'rest_alerts_fired': 48,
  'rest_alerts_late': 2,
  'rest_alerts_audio_failed': 0,
  'new_key_from_native': 3,
};

const device = DeviceView(
  model: 'Pixel 8 Pro',
  sdkInt: 35,
  release: '15',
  versionCode: 12,
  notificationsEnabled: false,
  batterySaver: true,
);

void main() {
  Widget app({
    VoidCallback? onSpike,
    VoidCallback? onNotif,
    VoidCallback? onJson,
  }) => MaterialApp(
    home: Scaffold(
      body: DiagnosticsPanel(
        appVersion: '0.1.0+12 (abc1234)',
        gate: gate,
        native: native,
        device: device,
        onOpenSpike: onSpike,
        onOpenNotificationSettings: onNotif,
        onExportJson: onJson,
      ),
    ),
  );

  Future<void> see(WidgetTester t, Finder f) async {
    await t.scrollUntilVisible(f, 200);
    expect(f, findsOneWidget);
  }

  testWidgets('gate numbers with pass/miss marks', (tester) async {
    phone(tester);
    await tester.pumpWidget(app());
    expect(find.text('day 9 of 14'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Sessions, last 14 days, 3 of 4, miss'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('One-tap rate, 89%, ok, cold starts left out'),
      findsOneWidget,
    );
    expect(find.text('67%'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Median swaps per session, 1.5, miss'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Lost workouts, 0, ok'), findsOneWidget);
  });

  testWidgets('every native counter shows, unknown keys raw', (tester) async {
    phone(tester);
    await tester.pumpWidget(app());
    await see(tester, find.text('Rest alerts late (>1 s)'));
    await see(tester, find.text('Torn tails (crash, expected)'));
    await see(tester, find.text('new_key_from_native'));
    await see(tester, find.text('15 (API 35)'));
  });

  testWidgets('notifications off: banner opens settings', (tester) async {
    phone(tester);
    var opened = false;
    await tester.pumpWidget(app(onNotif: () => opened = true));
    expect(find.textContaining('Notifications are off'), findsOneWidget);
    await tester.tap(find.text('Turn on'));
    expect(opened, isTrue);
  });

  testWidgets('spike entry only when given; export fires', (tester) async {
    phone(tester);
    await tester.pumpWidget(app());
    await tester.scrollUntilVisible(find.text('JSON'), 200);
    expect(find.textContaining('checklist'), findsNothing);
    var spike = false;
    var json = false;
    await tester.pumpWidget(
      app(onSpike: () => spike = true, onJson: () => json = true),
    );
    final entry = find.textContaining('checklist');
    await tester.scrollUntilVisible(entry, 200);
    await tester.tap(entry);
    await tester.ensureVisible(find.text('JSON'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JSON'));
    expect(spike && json, isTrue);
  });
}
