import '../platform/platform_api.g.dart';
import '../screens/screen_awake.dart';

/// [ScreenAwake] over GymHostApi (native lane): a window flag on the activity.
class HostScreenAwake implements ScreenAwake {
  HostScreenAwake(this.host);

  final GymHostApi host;

  @override
  Future<void> set(bool on) => host.setKeepScreenOn(on);
}
