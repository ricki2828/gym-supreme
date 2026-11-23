import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Undo/skip have one path in the app: TimerSession.undo / .skip. A plain
/// Session.undo on a timed set leaves the redo silent (the service dedups on
/// set_id + run + index, and only TimerSession.undo bumps run).
void main() {
  test('lib/ never calls Session.undo or Session.skip directly', () {
    final bad = <String>[];
    final call = RegExp(r'(?<![A-Za-z_])Session\.(undo|skip)\(');
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (call.hasMatch(lines[i])) bad.add('${f.path}:${i + 1}');
      }
    }
    expect(bad, isEmpty, reason: 'use TimerSession.undo / TimerSession.skip');
  });
}
