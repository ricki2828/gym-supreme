import 'package:flutter/material.dart';
import 'package:gym_engine/gym_engine.dart' as eng;

import '../screens/diagnostics_panel.dart';
import '../screens/engine_adapter.dart';
import '../screens/import_flow.dart';
import '../spike/spike_screen.dart';
import 'flavor.dart';
import 'services.dart';

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
    final host = s.host;
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: DiagnosticsPanel(
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
      ),
    );
  }
}
