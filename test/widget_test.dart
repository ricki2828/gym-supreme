import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/app/diagnostics_screen.dart';
import 'package:gym_supreme/main.dart';

void main() {
  testWidgets('home renders its title', (tester) async {
    await tester.pumpWidget(const GymSupremeApp());
    expect(find.text('GYM SUPREME'), findsOneWidget);
  });

  testWidgets('diagnostics (non-play flavours) reaches the spike checklist', (
    tester,
  ) async {
    await tester.pumpWidget(const GymSupremeApp());
    await tester.tap(find.byKey(const Key('home.diagnostics')));
    await tester.pumpAndSettle();
    expect(find.byType(DiagnosticsScreen), findsOneWidget);
    expect(find.byKey(const Key('diagnostics.spike')), findsOneWidget);
  });
}
