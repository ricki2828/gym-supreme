// Pigeon definitions for the Flutter <-> Kotlin channel contract (plan 6.1).
// Regenerate with: dart run pigeon --input pigeons/platform_api.dart
// Generated files are committed; CI fails if they drift. This file belongs to lane A:
// other lanes send the lines they need.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/platform_api.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/app/src/main/kotlin/app/gymsupreme/platform/PlatformApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.gymsupreme.platform'),
    dartPackageName: 'gym_supreme',
  ),
)
library;

import 'package:pigeon/pigeon.dart';

/// Device facts for the diagnostics page and the spike log.
class HostInfo {
  HostInfo({
    required this.sdkInt,
    required this.model,
    required this.versionCode,
  });

  int sdkInt;
  String model;
  int versionCode;
}

@HostApi()
abstract class GymHostApi {
  HostInfo getHostInfo();
}
