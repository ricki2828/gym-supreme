import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import 'diagnostics_screen.dart';
import 'flavor.dart';

/// Placeholder home until the UI lane's first-run / picker screens land.
class AppHome extends StatelessWidget {
  const AppHome({super.key});

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
              Text('build $buildLabel', style: TextStyle(color: Lit.inkQuiet)),
              if (showDiagnostics) ...[
                const SizedBox(height: 24),
                TextButton(
                  key: const Key('home.diagnostics'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DiagnosticsScreen(),
                    ),
                  ),
                  child: const Text('Diagnostics'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
