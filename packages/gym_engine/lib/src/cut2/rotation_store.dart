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

/// Setting key holding the uuid of the last workout the rotation advanced
/// for, so a retry (recovery on open, a second finish call) never advances
/// twice.
const String rotationLastSettingKey = 'rotation_last_uuid';

/// Call after a workout is stored: advances past [typeId] (null or a type
/// outside the rotation changes nothing, and nothing is written). With
/// [workoutUuid], idempotent per workout.
Rotation rotationAfterFinish(
  HistoryStore store,
  String? typeId, {
  String? workoutUuid,
}) {
  final before = loadRotation(store);
  if (workoutUuid != null &&
      store.setting(rotationLastSettingKey) == jsonEncode(workoutUuid)) {
    return before;
  }
  final after = before.completed(typeId);
  if (after != before) saveRotation(store, after);
  if (workoutUuid != null) {
    store.saveSetting(rotationLastSettingKey, jsonEncode(workoutUuid));
  }
  return after;
}
