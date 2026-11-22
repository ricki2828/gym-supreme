import 'package:flutter/services.dart';

/// The spike's channel to the Kotlin workout service (lane A agreed: a plain
/// MethodChannel confined to `lib/spike`; whatever outlives the spike moves to
/// Pigeon in phase 1).
class SpikeChannel {
  const SpikeChannel();

  static const MethodChannel _ch = MethodChannel('app.gymsupreme/spike');

  Future<Map<String, Object?>> status() async {
    final m = await _ch.invokeMapMethod<String, Object?>('status');
    return m ?? const {};
  }

  Future<void> requestPermissions() => _ch.invokeMethod('requestPermissions');
  Future<void> startAll() => _ch.invokeMethod('startAll');
  Future<void> stop() => _ch.invokeMethod('stop');
  Future<void> pair(String address) =>
      _ch.invokeMethod('pair', {'address': address});
  Future<void> forget() => _ch.invokeMethod('forget');
  Future<void> screenWants() => _ch.invokeMethod('screenWants');
  Future<void> screenReleases() => _ch.invokeMethod('screenReleases');
  Future<void> share() => _ch.invokeMethod('share');

  /// HR straps seen by a 10 s scan: `{address, name}` each.
  Future<List<Map<String, String?>>> scan() async {
    final l = await _ch.invokeListMethod<Object?>('scan') ?? const [];
    return [
      for (final e in l)
        if (e is Map)
          {'address': e['address'] as String?, 'name': e['name'] as String?},
    ];
  }
}
