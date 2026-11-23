/// Notifications for the rest alert (plan 6.2; t3x, fix before 0.1). On
/// Android 13+ they are off until the app asks, so a fresh install would
/// show no lock-screen rest notification. The buzz and tone still fire from
/// the service, but the notification is how the rest shows while locked.
///
/// The app shell (lib/app) implements this over GymHostApi
/// (requestNotificationPermission, HostInfo.notificationsEnabled,
/// openNotificationSettings) and a persisted "asked" flag.
abstract interface class NotificationAccess {
  /// Notifications currently allowed.
  Future<bool> enabled();

  /// Shows the system dialog (Android 13+); true when allowed afterwards.
  /// Below Android 13 this returns [enabled] with no dialog.
  Future<bool> request();

  /// Opens the app's notification settings.
  Future<void> openSettings();

  /// Whether the one-time ask already happened on this install.
  Future<bool> askedBefore();
  Future<void> markAsked();
}

/// The one-time ask before the first Start. Returns whether notifications
/// are on afterwards. Never blocks the workout: whatever he chooses, the
/// session starts, and Today keeps a banner while they are off.
///
/// The flag is set before the dialog, so a crash or kill during it never
/// asks twice. The CI e2e driver calls this directly ("ask" command).
Future<bool> askNotificationsOnce(NotificationAccess n) async {
  if (await n.enabled()) return true;
  if (await n.askedBefore()) return false;
  await n.markAsked();
  return n.request();
}
