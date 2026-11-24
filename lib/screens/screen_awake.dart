/// Keeps the screen on while a workout is being logged (0.3 X1). The app
/// shell (lib/app) implements this over GymHostApi.setKeepScreenOn; tests
/// pass a recorder, and null (play build without the host call) does
/// nothing.
abstract interface class ScreenAwake {
  Future<void> set(bool on);
}
