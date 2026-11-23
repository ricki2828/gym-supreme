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
  // A deleted workout never moves the rotation (recovery of a stale journal
  // on open, 0.2.1 D1 R6).
  if (workoutUuid != null &&
      store.hasWorkout(workoutUuid) &&
      store.workout(workoutUuid) == null) {
    return before;
  }
  final after = before.completed(typeId);
  if (after != before) saveRotation(store, after);
  if (workoutUuid != null) {
    store.saveSetting(rotationLastSettingKey, jsonEncode(workoutUuid));
  }
  return after;
}

/// Call when a workout is deleted (0.2.1 D1), with its [typeId] read before
/// the delete. If it is the last workout the rotation advanced for, its type
/// is in the rotation, and the pointer still sits right after that type (he
/// has not dragged, skipped or tapped since), the pointer goes back to that
/// type so it is suggested again. Otherwise nothing changes.
///
/// Returns the rotation as it was before, for undo ([saveRotation] it back),
/// or null when nothing changed. `rotation_last_uuid` is left as is, so a
/// stale journal of the deleted workout cannot advance it again.
Rotation? rotationAfterDelete(
  HistoryStore store,
  String workoutUuid,
  String? typeId,
) {
  if (typeId == null) return null;
  if (store.setting(rotationLastSettingKey) != jsonEncode(workoutUuid)) {
    return null;
  }
  final before = loadRotation(store);
  final i = before.order.indexOf(typeId);
  if (i < 0 || before.next != (i + 1) % before.order.length) return null;
  final after = before.pointAt(typeId);
  if (after == before) return null; // a one-type rotation: nothing to move
  saveRotation(store, after);
  return before;
}
