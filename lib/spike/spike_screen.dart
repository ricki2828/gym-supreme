import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supreme_ui/supreme_ui.dart';

import 'spike_channel.dart';

/// Phase-0 spike screen (brief section 5). No product UI: it drives the four
/// checks on the runbook card (Link strap, Start all, walk away, Share log) and
/// shows what the service is doing. The service owns everything; this screen
/// polls its status once a second while visible.
class SpikeScreen extends StatefulWidget {
  const SpikeScreen({super.key, required this.buildLabel});

  final String buildLabel;

  @override
  State<SpikeScreen> createState() => _SpikeScreenState();
}

class _SpikeScreenState extends State<SpikeScreen> with WidgetsBindingObserver {
  final SpikeChannel _ch = const SpikeChannel();
  Map<String, Object?> _s = const {};
  Timer? _poll;
  String? _error;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    _refresh();
    _call(_ch.screenWants);
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _call(_ch.screenReleases);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _call(_ch.screenWants);
      _refresh();
    } else if (state == AppLifecycleState.paused) {
      _call(_ch.screenReleases);
    }
  }

  Future<void> _refresh() async {
    try {
      final s = await _ch.status();
      if (mounted) setState(() => _s = s);
    } on MissingPluginException {
      // Widget tests and hosts without the Kotlin side.
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _call(Future<void> Function() f) async {
    try {
      await f();
      if (mounted) setState(() => _error = null);
    } on MissingPluginException {
      // Widget tests.
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message ?? e.code);
    }
    unawaited(_refresh());
  }

  bool _b(String k) => _s[k] == true;
  int? _i(String k) => (_s[k] as num?)?.toInt();
  String? _str(String k) => _s[k] as String?;

  Future<void> _link() async {
    await _call(_ch.requestPermissions);
    if (!_b('btPermissions')) {
      setState(
        () => _error = 'Allow nearby devices, then tap Link strap again.',
      );
      return;
    }
    setState(() => _scanning = true);
    List<Map<String, String?>> found = const [];
    try {
      found = await _ch.scan();
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message ?? e.code);
    } on MissingPluginException {
      // Widget tests.
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    if (!mounted) return;
    if (found.isEmpty) {
      setState(
        () => _error =
            'No heart rate strap found. In the Whoop app, switch on heart '
            'rate broadcast, then try again.',
      );
      return;
    }
    final pick = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Lit.ground,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final f in found)
              ListTile(
                minTileHeight: 56,
                title: Text(f['name'] ?? 'Unnamed strap'),
                subtitle: Text(_tail(f['address'])),
                onTap: () => Navigator.of(ctx).pop(f['address']),
              ),
          ],
        ),
      ),
    );
    if (pick != null) await _call(() => _ch.pair(pick));
  }

  static String _tail(String? a) =>
      a == null || a.length < 5 ? '' : '…${a.substring(a.length - 5)}';

  @override
  Widget build(BuildContext context) {
    final running = _b('running');
    final hrSupported = _s['hrSupported'] != false;
    final sdk = _i('sdk');
    return Scaffold(
      backgroundColor: Lit.ground,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Text(
              'GYM SUPREME',
              style: RunSoloType.title28.copyWith(color: Lit.ink),
            ),
            Text(
              'Test build ${widget.buildLabel}'
              '${sdk == null ? '' : '  ·  Android ${_str('release')} (API $sdk)  ·  ${_str('model')}'}',
              style: RunSoloType.label13.copyWith(color: Lit.inkQuiet),
            ),
            const SizedBox(height: 12),
            if (_s.isNotEmpty && !_b('notificationsOn'))
              _Banner(
                'Notifications are off: rest alerts will only buzz and beep. '
                'Tap Allow below.',
              ),
            if (_b('batterySaver'))
              _Line('Battery saver is on (that is part of the test).'),
            if (_error != null) _Banner(_error!),
            _Card(
              step: '1',
              title: 'Link your Whoop',
              children: [
                if (!hrSupported)
                  _Line('Heart rate needs Android 12 or later on this phone.')
                else ...[
                  _Line(
                    _b('strapLinked')
                        ? '${_str('strapName') ?? 'Strap'}: '
                              '${_b('strapConnected') ? '${_i('hr') ?? '--'} bpm' : 'looking for it…'}'
                        : 'No strap linked.',
                    big: _b('strapConnected'),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _scanning || running ? null : _link,
                        child: Text(_scanning ? 'Looking…' : 'Link strap'),
                      ),
                      if (_b('strapLinked') && !running)
                        TextButton(
                          onPressed: () => _call(_ch.forget),
                          child: const Text('Forget'),
                        ),
                    ],
                  ),
                ],
              ],
            ),
            _Card(
              step: '2',
              title: running ? (_str('title') ?? 'Running') : 'Start all',
              children: [
                if (running) ...[
                  _Line(
                    '${_i('fired') ?? 0} of ${_i('total') ?? 0} cues  ·  '
                    '${_mmss(_i('elapsedS'))} elapsed',
                    big: true,
                  ),
                  if (_str('lastCue') != null)
                    _Line(
                      'Last: ${_str('lastCue')}, ${_i('lastLateMs') ?? 0} ms late',
                    ),
                  _Line(
                    'Service: ${_str('serviceType') ?? '?'}  ·  '
                    'HR samples: ${_i('hrCount') ?? 0}',
                  ),
                  OutlinedButton(
                    onPressed: () => _call(_ch.stop),
                    child: const Text('Stop'),
                  ),
                ] else ...[
                  _Line(
                    '10 rests of 90 s, then a 20 minute every-minute timer, '
                    'tracking the strap throughout. Tap, then lock the phone.',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: () async {
                          await _call(_ch.requestPermissions);
                          await _call(_ch.startAll);
                        },
                        child: const Text('Start all'),
                      ),
                      if (_s.isNotEmpty && !_b('notificationsOn'))
                        TextButton(
                          onPressed: () => _call(_ch.requestPermissions),
                          child: const Text('Allow'),
                        ),
                    ],
                  ),
                ],
              ],
            ),
            _Card(
              step: '3',
              title: 'Share log',
              children: [
                _Line('${_i('logLines') ?? 0} events logged.'),
                FilledButton(
                  onPressed: () => _call(_ch.share),
                  child: const Text('Share log'),
                ),
                for (final l in (_s['tail'] as List?)?.cast<Object?>() ?? [])
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '$l',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Lit.inkSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _mmss(int? s) {
    if (s == null) return '0:00';
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.step,
    required this.title,
    required this.children,
  });

  final String step;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Lit.hair, width: 2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$step  $title',
            style: RunSoloType.body17.copyWith(
              color: Lit.ink,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.text, {this.big = false});

  final String text;
  final bool big;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: (big ? RunSoloType.title28 : RunSoloType.body15).copyWith(
          color: big ? Lit.ink : Lit.inkSecondary,
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Lit.ink,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(text, style: RunSoloType.body15.copyWith(color: Lit.ground)),
    );
  }
}
