import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import 'spike/spike_screen.dart';

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
      // Phase-0 spike build (lane B); phase 1 replaces this with the app.
      home: SpikeScreen(
        buildLabel: kBuildSha.length > 7
            ? kBuildSha.substring(0, 7)
            : kBuildSha,
      ),
    );
  }
}
