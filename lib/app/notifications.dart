import 'dart:io';

import '../platform/platform_api.g.dart';
import '../screens/notification_access.dart';

/// NotificationAccess over GymHostApi (native lane) with the one-time-ask flag
/// as a file under files/ (not backed up, like the restore counters).
class HostNotificationAccess implements NotificationAccess {
  HostNotificationAccess(this.host, this.supportDir);

  final GymHostApi host;
  final String supportDir;

  File get _flag => File('$supportDir/notif_asked');

  @override
  Future<bool> enabled() async =>
      (await host.getHostInfo().timeout(const Duration(seconds: 2)))
          .notificationsEnabled;

  @override
  Future<bool> request() => host.requestNotificationPermission();

  @override
  Future<void> openSettings() => host.openNotificationSettings();

  @override
  Future<bool> askedBefore() async => _flag.existsSync();

  @override
  Future<void> markAsked() async => _flag.writeAsStringSync('1\n', flush: true);
}
