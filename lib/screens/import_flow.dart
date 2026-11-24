import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:gym_engine/gym_engine.dart' as eng;

/// Import from Diagnostics (0.3 I1): pick a file, show what it would add,
/// import on Confirm, then report the result. Every step is injected so the
/// widget tests need no Pigeon or SQLite.
///
/// [pick] returns the file text or null when he backs out (GymHostApi
/// .pickImportFile). [preview] and [apply] are GymApi.previewImport and
/// .importBundle. [afterImport] runs once something was written (persist
/// the backup snapshot, refresh the counters). [blockedReason], when set,
/// is shown instead of picking (the store is temporary this launch).
///
/// Returns the applied counts, or null when nothing was imported.
Future<eng.ImportCounts?> runImport(
  BuildContext context, {
  required Future<String?> Function() pick,
  required eng.ImportCounts Function(String text) preview,
  required eng.ImportCounts Function(String text) apply,
  VoidCallback? afterImport,
  String? blockedReason,
}) async {
  if (blockedReason != null) {
    await _message(context, 'Import is off right now', blockedReason);
    return null;
  }
  final String? text;
  try {
    text = await pick();
  } on PlatformException catch (e) {
    if (!context.mounted) return null;
    await _message(context, 'Could not open the file', switch (e.code) {
      'too_large' => 'That file is over 8 MB, the most an import reads.',
      'already_pending' => 'A file picker is already open.',
      _ => 'The file could not be read. Pick the .json export, not the CSV.',
    });
    return null;
  } on Object {
    if (!context.mounted) return null;
    await _message(
      context,
      'Could not open the file',
      'The file picker did not answer. Try again.',
    );
    return null;
  }
  if (text == null || !context.mounted) return null;

  final eng.ImportCounts p;
  try {
    p = preview(text);
  } on eng.ImportRefused catch (e) {
    await _message(context, 'Nothing imported', e.message);
    return null;
  } on Object catch (e) {
    await _message(context, 'Nothing imported', 'Could not read it ($e).');
    return null;
  }
  if (!context.mounted) return null;
  if (p.isNoOp) {
    await _message(
      context,
      'Nothing new',
      'Everything in this file is already on this phone.\n\n'
          '${importLines(p, applied: false).join('\n')}',
    );
    return null;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Import this export?'),
      content: SingleChildScrollView(
        child: Text(importLines(p, applied: false).join('\n')),
      ),
      actions: [
        TextButton(
          key: const Key('import.cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('import.confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Import'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return null;

  final eng.ImportCounts r;
  try {
    r = apply(text);
  } on eng.ImportRefused catch (e) {
    await _message(context, 'Nothing imported', e.message);
    return null;
  }
  afterImport?.call();
  if (!context.mounted) return r;
  await _message(context, 'Imported', importLines(r, applied: true).join('\n'));
  return r;
}

/// The confirm and result lines. [applied]: past tense for the result.
List<String> importLines(eng.ImportCounts c, {required bool applied}) {
  String n(int x, String one, String many) => '$x ${x == 1 ? one : many}';
  return [
    applied
        ? '${n(c.workoutsAdded, 'workout', 'workouts')} added.'
        : '${n(c.workoutsAdded, 'new workout', 'new workouts')} to add.',
    if (c.skippedExisting > 0)
      '${n(c.skippedExisting, 'workout is', 'workouts are')} already here: '
          'left as they are.',
    if (c.skippedDeleted > 0)
      '${n(c.skippedDeleted, 'workout', 'workouts')} you deleted here: '
          'staying deleted.',
    if (c.gymsAdded > 0)
      '${n(c.gymsAdded, 'gym', 'gyms')} with kit '
          '${applied ? 'added' : 'to add'}.',
    if (c.gymsKept > 0)
      '${n(c.gymsKept, 'gym is', 'gyms are')} already here: yours kept.',
    c.settingsRestored
        ? 'Settings: ${applied ? 'filled in' : 'will be filled in'} from the '
              'file (this phone had the defaults).'
        : 'Settings: yours kept.',
    if (c.hrSamplesAdded > 0)
      'Heart rate: ${n(c.hrSamplesAdded, 'sample', 'samples')}.'
    else
      'Heart rate: not in exports, so not restored.',
    if (c.deletedInFile > 0)
      '${n(c.deletedInFile, 'workout', 'workouts')} deleted on the other '
          'phone: not imported.',
  ];
}

Future<void> _message(BuildContext context, String title, String body) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            key: const Key('import.ok'),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
