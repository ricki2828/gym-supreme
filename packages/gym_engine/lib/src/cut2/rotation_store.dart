/// Rotation persistence (setting key "rotation", t5z) and the finish hook.
library;

import 'dart:convert';

import '../model.dart';
import '../store.dart';
import 'rotation.dart';

/// The stored rotation, or the defaults when none is stored or it is
/// unreadable. Unknown workout types are dropped.
Rotation loadRotation(HistoryStore store) {
  final raw = store.setting(rotationSettingKey);
  Object? j;
  if (raw != null) {
    try {
      j = jsonDecode(raw);
    } on FormatException {
      j = null;
    }
  }
  final r = Rotation.fromJson(j)
      .retainOnly({for (final t in workoutTypes) t.id});
  // Only unknown ids stored (types renamed): fall back rather than leave the
  // chip gone for good. An empty order saved on purpose stays empty.
  final stored = Rotation.tryFromJson(j);
  if (r.isEmpty && stored != null && !stored.isEmpty) {
    return Rotation.defaults();
  }
  return r;
}

void saveRotation(HistoryStore store, Rotation r) =>
    store.saveSetting(rotationSettingKey, jsonEncode(r.toJson()));

/// Call after a workout is stored: advances past [typeId] (null or a type
/// outside the rotation changes nothing, and nothing is written).
Rotation rotationAfterFinish(HistoryStore store, String? typeId) {
  final before = loadRotation(store);
  final after = before.completed(typeId);
  if (after != before) saveRotation(store, after);
  return after;
}
