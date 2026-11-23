import 'package:flutter/material.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../widgets/lit_widgets.dart';

/// Core-gate numbers (plan 3, B4) from the engine's Counters.
class GateView {
  const GateView({
    required this.sessionsTotal,
    required this.sessionsLast14Days,
    required this.dayOfWindow,
    required this.doneSets,
    required this.tapUnchangedSets,
    required this.coldStartSets,
    required this.oneTapRate,
    required this.oneTapRateInclCold,
    required this.medianSwapsPerSession,
    this.appVersions = const {},
  });
  final int sessionsTotal;
  final int sessionsLast14Days;

  /// 1-based day of the 14-day window since the first session; null before.
  final int? dayOfWindow;
  final int doneSets;
  final int tapUnchangedSets;
  final int coldStartSets;

  /// 0..1, cold starts left out.
  final double oneTapRate;
  final double oneTapRateInclCold;
  final double? medianSwapsPerSession;
  final Map<String, int> appVersions;
}

/// HostInfo facts (t5v, via Pigeon).
class DeviceView {
  const DeviceView({
    required this.model,
    required this.sdkInt,
    required this.release,
    required this.versionCode,
    required this.notificationsEnabled,
    required this.batterySaver,
  });
  final String model;
  final int sdkInt;
  final String release;
  final int versionCode;
  final bool notificationsEnabled;
  final bool batterySaver;
}

/// Labels for the native counters (WorkoutPort.nativeCounters keys).
/// Unknown keys still show, under their raw name, so nothing is hidden.
const Map<String, String> nativeCounterLabels = {
  'journals_lost': 'Journals lost',
  'journal_corrupt_lines': 'Corrupt journal lines',
  'journal_torn_tails': 'Torn tails (crash, expected)',
  'rest_alerts_fired': 'Rest alerts fired',
  'rest_alerts_late': 'Rest alerts late (>1 s)',
  'rest_alerts_missed': 'Rest alerts missed (app dead)',
  'rest_alert_max_late_ms': 'Latest rest alert, ms',
  'rest_alerts_audio_failed': 'Tone failed (buzz may have worked)',
};

/// The body of the Diagnostics page (t5t hosts it in lib/app, dogfood
/// only). Gate counters, native counters, device facts, export, spike.
class DiagnosticsPanel extends StatelessWidget {
  const DiagnosticsPanel({
    super.key,
    required this.appVersion,
    required this.gate,
    required this.native,
    this.device,
    this.onExportJson,
    this.onExportCsv,
    this.onOpenNotificationSettings,
    this.onOpenSpike,
  });
  final String appVersion;
  final GateView gate;
  final Map<String, int> native;
  final DeviceView? device;
  final VoidCallback? onExportJson;
  final VoidCallback? onExportCsv;
  final VoidCallback? onOpenNotificationSettings;

  /// The phase-0 spike checklist; null hides the entry.
  final VoidCallback? onOpenSpike;

  @override
  Widget build(BuildContext context) {
    final lost = native['journals_lost'] ?? 0;
    final d = device;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      children: [
        Text('DIAGNOSTICS', style: LitType.display(44)),
        Text(appVersion, style: LitType.body(14, Lit.inkSecondary)),
        if (d != null && !d.notificationsEnabled) ...[
          const SizedBox(height: 14),
          _Banner(
            text:
                'Notifications are off, so the rest alert cannot show when '
                'the phone is locked.',
            action: 'Turn on',
            onTap: onOpenNotificationSettings,
          ),
        ],
        const SizedBox(height: 18),
        _Section('Core gate'),
        _Row(
          'Window',
          gate.dayOfWindow == null
              ? 'starts at the first session'
              : 'day ${gate.dayOfWindow} of 14',
        ),
        _Row(
          'Sessions, last 14 days',
          '${gate.sessionsLast14Days} of 4',
          ok: gate.sessionsLast14Days >= 4,
        ),
        _Row(
          'One-tap rate',
          _pct(gate.oneTapRate),
          ok: gate.oneTapRate >= 0.7,
          note: 'cold starts left out',
        ),
        _Row('One-tap rate incl. cold starts', _pct(gate.oneTapRateInclCold)),
        _Row(
          'Median swaps per session',
          gate.medianSwapsPerSession == null
              ? '–'
              : _num(gate.medianSwapsPerSession!),
          ok: gate.medianSwapsPerSession == null
              ? null
              : gate.medianSwapsPerSession! <= 1,
        ),
        _Row('Lost workouts', '$lost', ok: lost == 0),
        const SizedBox(height: 18),
        _Section('Sets'),
        _Row('Sessions, all time', '${gate.sessionsTotal}'),
        _Row('Sets done', '${gate.doneSets}'),
        _Row('One tap, unchanged', '${gate.tapUnchangedSets}'),
        _Row('Cold start', '${gate.coldStartSets}'),
        for (final v in gate.appVersions.entries)
          _Row('Sessions on ${v.key}', '${v.value}'),
        const SizedBox(height: 18),
        _Section('Service and journal'),
        for (final k in [
          ...nativeCounterLabels.keys.where(native.containsKey),
          ...native.keys.where((k) => !nativeCounterLabels.containsKey(k)),
        ])
          _Row(
            nativeCounterLabels[k] ?? k,
            '${native[k]}',
            ok: switch (k) {
              'journals_lost' ||
              'journal_corrupt_lines' ||
              'rest_alerts_missed' ||
              'rest_alerts_audio_failed' => native[k] == 0,
              _ => null,
            },
          ),
        if (native.isEmpty) _Row('Native counters', 'none reported yet'),
        if (d != null) ...[
          const SizedBox(height: 18),
          _Section('Device'),
          _Row('Model', d.model),
          _Row('Android', '${d.release} (API ${d.sdkInt})'),
          _Row('Build', '${d.versionCode}'),
          _Row(
            'Notifications',
            d.notificationsEnabled ? 'on' : 'off',
            ok: d.notificationsEnabled,
          ),
          _Row('Battery saver', d.batterySaver ? 'on' : 'off'),
        ],
        const SizedBox(height: 22),
        _Section('Export'),
        Text(
          'Export is the backup that counts (plan 7). It holds every '
          'workout, gym and counter. Nothing leaves the phone unless you '
          'share it.',
          style: LitType.body(14, Lit.inkSecondary),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: BigButton(
                label: 'JSON',
                colour: Lit.ink,
                ink: Colors.white,
                onTap: onExportJson,
                semanticLabel: 'Export everything as JSON',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: BigButton(
                label: 'CSV',
                colour: Lit.ink,
                ink: Colors.white,
                onTap: onExportCsv,
                semanticLabel: 'Export sets as CSV',
              ),
            ),
          ],
        ),
        if (onOpenSpike != null) ...[
          const SizedBox(height: 22),
          _Section('Phone checks'),
          OutlinedButton(
            onPressed: onOpenSpike,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              side: const BorderSide(color: Lit.ink, width: 2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(
              'Rest alert and strap checklist (S1-S4)',
              style: LitType.body(16, Lit.ink, FontWeight.w700),
            ),
          ),
        ],
      ],
    );
  }
}

/// "89%"; a 0/0 rate before any sets is "–", not a crash.
String _pct(double r) => r.isFinite ? '${(r * 100).round()}%' : '–';
String _num(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(title.toUpperCase(), style: LitType.display(26)),
  );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.ok, this.note});
  final String label;
  final String value;

  /// Gate pass (true), miss (false) or no target (null).
  final bool? ok;
  final String? note;
  @override
  Widget build(BuildContext context) {
    final mark = switch (ok) {
      true => 'ok',
      false => 'miss',
      null => null,
    };
    return Semantics(
      label: [label, value, ?mark, ?note].join(', '),
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Lit.hair)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: LitType.body(15, Lit.ink)),
                  if (note != null)
                    Text(note!, style: LitType.body(12, Lit.inkQuiet)),
                ],
              ),
            ),
            if (ok != null) ...[
              Icon(
                ok! ? Icons.check_circle : Icons.error,
                size: 18,
                color: ok! ? const Color(0xFF1F9D57) : const Color(0xFFD7263D),
              ),
              const SizedBox(width: 6),
            ],
            Text(value, style: LitType.body(15, Lit.ink, FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.action, this.onTap});
  final String text;
  final String action;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
    decoration: BoxDecoration(
      color: Lit.ink,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: LitType.body(14, Colors.white, FontWeight.w600),
          ),
        ),
        TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            minimumSize: const Size(48, 48),
          ),
          child: Text(
            action,
            style: LitType.body(15, Colors.white, FontWeight.w800).copyWith(
              decoration: TextDecoration.underline,
              decorationColor: Colors.white,
            ),
          ),
        ),
      ],
    ),
  );
}
