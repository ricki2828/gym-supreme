import 'package:flutter/material.dart';
import 'package:gym_engine/gym_engine.dart' as eng;

import '../screens/diagnostics_panel.dart';
import '../screens/engine_adapter.dart';
import '../screens/import_flow.dart';
import '../spike/spike_screen.dart';
import 'flavor.dart';
import 'services.dart';

/// The last timer block's cue log in one readable line (0.3 cut T1), from
/// the native counters (`timer_last_block_*`, android CueLog.kt), or null when
/// no block has run. Ricki reads the 20/20 screen-off result off the screen.
String? timerBlockLine(Map<String, int> native) {
  final cues = native['timer_last_block_cues'];
  if (cues == null) return null;
  final fired = native['timer_last_block_fired'] ?? 0;
  final late = native['timer_last_block_late'] ?? 0;
  final missed = native['timer_last_block_missed'] ?? 0;
  final max = native['timer_last_block_max_late_ms'] ?? 0;
  final miss = missed > 0 ? ', $missed missed' : '';
  return 'Last timer block: $fired/$cues cues, $late late$miss, '
      'max $max ms late';
}

/// [timerBlockLine] above the panel; nothing when no block has run.
class TimerBlockLine extends StatelessWidget {
  const TimerBlockLine({super.key, required this.native});

  final Map<String, int> native;

  @override
  Widget build(BuildContext context) {
    final line = timerBlockLine(native);
    if (line == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Text(
        line,
        key: const Key('timer-block-line'),
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    );
  }
}

/// Hosts the UI lane's DiagnosticsPanel: gate counters, native counters,
/// device facts, export, and (dogfood/debug only) the spike checklist.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  Map<String, int> _native = const {};
  DeviceView? _device;

  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Map<String, int> native = const {};
    DeviceView? device;
    try {
      native = s.withAppCounters(await s.port.nativeCounters());
    } on Object {
      // The panel still renders the gate rows.
      native = s.withAppCounters(const {});
    }
    final host = s.host;
    if (host != null) {
      try {
        final h = await host.getHostInfo();
        device = DeviceView(
          model: h.model,
          sdkInt: h.sdkInt,
          release: h.release,
          versionCode: h.versionCode,
          notificationsEnabled: h.notificationsEnabled,
          batterySaver: h.batterySaver,
        );
      } on Object {
        device = null;
      }
    }
    if (mounted) {
      setState(() {
        _native = native;
        _device = device;
      });
    }
  }

  Future<void> _export({required bool csv}) async {
    s.persist(); // never throws; export must work even if the backup is broken
    final messenger = ScaffoldMessenger.of(context);
    try {
      final files = s.engine.export(
        appVersion: s.appVersion,
        native: s.withAppCounters(_native),
      );
      final stamp = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      await s.port.shareFile(
        'gym-supreme-$stamp.${csv ? 'csv' : 'json'}',
        csv ? eng.ExportFiles.csvMime : eng.ExportFiles.jsonMime,
        csv ? files.csv : files.json,
      );
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  /// Import (0.3 I1): picker -> counts -> confirm -> one transaction ->
  /// backup snapshot.
  Future<void> _import() async {
    final host = s.host;
    if (host == null) return;
    await runImport(
      context,
      pick: host.pickImportFile,
      preview: s.engine.previewImport,
      apply: s.engine.importBundle,
      blockedReason: s.restorePending
          ? 'Your backup could not be restored yet, so this launch runs on '
                'a temporary store and an import would be lost. Restart the '
                'app and try again.'
          : null,
      afterImport: () {
        s.persist(); // the backup snapshot holds the imported history
        if (mounted) setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: Column(
        children: [
          TimerBlockLine(native: _native),
          Expanded(child: _panel()),
        ],
      ),
    );
  }

  Widget _panel() {
    final host = s.host;
    return DiagnosticsPanel(
      appVersion: s.appVersion,
      gate: gateViewOf(
        s.engine.counters(),
        nowMs: DateTime.now().millisecondsSinceEpoch,
      ),
      native: _native,
      device: _device,
      onExportJson: () => _export(csv: false),
      onExportCsv: () => _export(csv: true),
      onImport: host == null ? null : _import,
      onOpenNotificationSettings: host == null
          ? null
          : () => host.openNotificationSettings(),
      onOpenSpike: showDiagnostics
          ? () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SpikeScreen(buildLabel: buildLabel),
              ),
            )
          : null,
    );
  }
}
