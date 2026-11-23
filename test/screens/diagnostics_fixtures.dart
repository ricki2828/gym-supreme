import 'package:gym_supreme/screens/diagnostics_panel.dart';

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
