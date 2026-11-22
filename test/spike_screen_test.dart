import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:gym_supreme/spike/spike_screen.dart';

void main() {
  const ch = MethodChannel('app.gymsupreme/spike');
  final calls = <String>[];

  Future<void> pump(WidgetTester tester, Map<String, Object?> status) async {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async {
          calls.add(call.method);
          return call.method == 'status' ? status : null;
        });
    await tester.pumpWidget(
      const MaterialApp(home: SpikeScreen(buildLabel: 'abc1234')),
    );
    await tester.pump();
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null);
  });

  testWidgets('idle: card steps, Start all starts the service', (tester) async {
    await pump(tester, {
      'sdk': 35,
      'release': '15',
      'model': 'Google Pixel 8 Pro',
      'notificationsOn': true,
      'hrSupported': true,
      'btPermissions': true,
      'strapLinked': false,
      'running': false,
      'logLines': 3,
      'tail': <String>[],
    });
    expect(find.text('GYM SUPREME'), findsOneWidget);
    expect(find.text('No strap linked.'), findsOneWidget);
    expect(find.text('3 events logged.'), findsOneWidget);
    expect(calls, contains('screenWants'));
    await tester.tap(find.text('Start all'));
    await tester.pump();
    expect(calls, containsAllInOrder(['requestPermissions', 'startAll']));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('running: progress, strap HR and the notifications banner', (
    tester,
  ) async {
    await pump(tester, {
      'sdk': 35,
      'notificationsOn': false,
      'hrSupported': true,
      'strapLinked': true,
      'strapConnected': true,
      'strapName': 'WHOOP 4A0934',
      'hr': 128,
      'running': true,
      'title': 'Rest 4 of 10',
      'fired': 3,
      'total': 31,
      'elapsedS': 275,
      'lastCue': 'rest 3 of 10',
      'lastLateMs': 12,
      'serviceType': 'specialUse|connectedDevice',
      'hrCount': 270,
    });
    expect(find.textContaining('Notifications are off'), findsOneWidget);
    expect(find.text('WHOOP 4A0934: 128 bpm'), findsOneWidget);
    expect(find.textContaining('Rest 4 of 10'), findsOneWidget);
    expect(find.text('3 of 31 cues  ·  4:35 elapsed'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(calls, contains('stop'));
    await tester.pumpWidget(const SizedBox());
  });
}
