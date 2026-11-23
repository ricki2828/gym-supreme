import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import 'app/db_probe.dart';
import 'app/diagnostics_screen.dart';
import 'app/flavor.dart';
import 'app/services.dart';
import 'screens/flows/flows.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ignore: avoid_print
  print(probeSqlite());
  final services = await bootstrap();
  runApp(GymSupremeApp(services: services));
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
      onHide: widget.services.persist,
      onPause: widget.services.persist,
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
            "Your backed-up workouts didn't load. Close and reopen the app "
            "before you log anything: workouts logged now won't be kept.",
            key: const Key('restore.pending'),
            style: TextStyle(color: Lit.ground),
          ),
        ),
      ),
    );
  }
}
