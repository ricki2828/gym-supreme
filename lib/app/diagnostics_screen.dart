import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../spike/spike_screen.dart';
import 'flavor.dart';

/// Dogfood and debug only. Keeps the phase-0 spike checklist (S1-S4) reachable
/// from 0.1 on (t3x, 23-Nov).
class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Build'),
            subtitle: Text('$kFlavor · $buildLabel'),
          ),
          ListTile(
            key: const Key('diagnostics.spike'),
            title: const Text('Spike checklist (S1-S4)'),
            subtitle: const Text('Rest alert, EMOM, strap, install-over'),
            trailing: Icon(Icons.chevron_right, color: Lit.inkQuiet),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SpikeScreen(buildLabel: buildLabel),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
