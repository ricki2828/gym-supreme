import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import 'app/db_probe.dart';
import 'app/diagnostics_screen.dart';
import 'app/flavor.dart';
import 'app/services.dart';
import 'app/workout_port.dart';
import 'screens/flows/flows.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ignore: avoid_print
  print(probeSqlite());
  final AppServices services;
  try {
    services = await bootstrap();
  } on Object catch (e, st) {
    // A blank app is the worst outcome: show what broke and how to report it.
    // ignore: avoid_print
    print('GymSupreme/boot failed: $e\n$st');
    runApp(BootErrorApp(error: '$e'));
    return;
  }
  runApp(GymSupremeApp(services: services));
}

/// Shown when the app cannot start (e.g. a database from a newer build, or
/// a full disk). Offers to share the error text; nothing is deleted.
class BootErrorApp extends StatelessWidget {
  const BootErrorApp({super.key, required this.error, this.port});

  final String error;
  final WorkoutPort? port;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: runSoloTheme().copyWith(scaffoldBackgroundColor: Lit.ground),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Gym Supreme couldn't start",
                  key: const Key('boot.error'),
                  style: RunSoloType.title28.copyWith(color: Lit.ink),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Your workouts have not been deleted. Share this error with '
                  'support, then try again after the next update.',
                ),
                const SizedBox(height: 12),
                SelectableText(error, style: TextStyle(color: Lit.inkQuiet)),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => (port ?? PigeonWorkoutPort())
                      .shareFile(
                        'gym-supreme-boot-error.txt',
                        'text/plain',
                        '$buildLabel\n$error',
                      )
                      .catchError((Object _) {}),
                  child: const Text('Share error'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class GymSupremeApp extends StatefulWidget {
  const GymSupremeApp({super.key, required this.services});

  final AppServices services;

  @override
  State<GymSupremeApp> createState() => _GymSupremeAppState();
}

class _GymSupremeAppState extends State<GymSupremeApp> {
  late final AppLifecycleListener _life;
  final _nav = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // WAL checkpoint whenever the app leaves the screen (plan 7, B6).
    _life = AppLifecycleListener(
      // onHide always precedes onPause on Android; one snapshot per backgrounding.
      onHide: widget.services.persist,
    );
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return MaterialApp(
      title: 'Gym Supreme',
      navigatorKey: _nav,
      debugShowCheckedModeBanner: false,
      theme: runSoloTheme().copyWith(scaffoldBackgroundColor: Lit.ground),
      builder: s.restorePending
          ? (context, child) => Column(
              children: [
                const _RestorePendingBanner(),
                Expanded(child: child ?? const SizedBox()),
              ],
            )
          : null,
      home: GymRoot(
        deps: GymDeps(
          engine: s.engine,
          port: s.port,
          catalog: s.catalog,
          appVersion: s.appVersion,
          // Cut 2: history for ghost + rotation (hidden while flags are off).
          store: s.store,
        ),
        onOpenDiagnostics: showDiagnostics
            ? () => _nav.currentState!.push(
                MaterialPageRoute<void>(
                  builder: (_) => DiagnosticsScreen(services: s),
                ),
              )
            : null,
      ),
    );
  }
}

/// Shown when the backup snapshot could not be restored this launch: the app
/// runs on a temporary store, so nothing logged now is kept.
class _RestorePendingBanner extends StatelessWidget {
  const _RestorePendingBanner();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Lit.ink,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            "Your backed-up workouts didn't load. Swipe Gym Supreme away "
            "from Recents and open it again before you log anything: "
            "workouts logged now won't be kept.",
            key: const Key('restore.pending'),
            style: TextStyle(color: Lit.ground),
          ),
        ),
      ),
    );
  }
}
