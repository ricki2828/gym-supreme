import 'dart:io';

import 'package:test/test.dart';

/// The same files live in android/core/src/test/fixtures/contract; CI diffs
/// the two directories and fails on any drift or an empty directory.
void main() {
  test('contract fixtures directory has files', () {
    final files = Directory('test/fixtures/contract')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'));
    expect(files, isNotEmpty);
  });
}
