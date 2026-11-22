import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/main.dart';

void main() {
  testWidgets('empty app renders its title', (tester) async {
    await tester.pumpWidget(const GymSupremeApp());
    expect(find.text('GYM SUPREME'), findsOneWidget);
  });
}
