// App-level tests live in test/app/ (app_boot_test.dart, workout_port_test.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/app/flavor.dart';

void main() {
  test('diagnostics are visible in non-release test runs', () {
    expect(showDiagnostics, isTrue);
  });
}
