import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import 'app/app_home.dart';
import 'app/db_probe.dart';

void main() {
  // ignore: avoid_print
  print(probeSqlite());
  runApp(const GymSupremeApp());
}

class GymSupremeApp extends StatelessWidget {
  const GymSupremeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gym Supreme',
      debugShowCheckedModeBanner: false,
      theme: runSoloTheme().copyWith(scaffoldBackgroundColor: Lit.ground),
      home: const AppHome(),
    );
  }
}
