import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

/// Set by CI with `--dart-define=BUILD_SHA=<sha>`.
const String kBuildSha = String.fromEnvironment(
  'BUILD_SHA',
  defaultValue: 'local',
);

void main() => runApp(const GymSupremeApp());

class GymSupremeApp extends StatelessWidget {
  const GymSupremeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gym Supreme',
      debugShowCheckedModeBanner: false,
      theme: runSoloTheme().copyWith(scaffoldBackgroundColor: Lit.ground),
      home: const _EmptyHome(),
    );
  }
}

class _EmptyHome extends StatelessWidget {
  const _EmptyHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'GYM SUPREME',
                style: RunSoloType.title28.copyWith(color: Lit.ink),
              ),
              const SizedBox(height: 8),
              Text(
                'build ${kBuildSha.length > 7 ? kBuildSha.substring(0, 7) : kBuildSha}',
                style: TextStyle(color: Lit.inkQuiet),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
