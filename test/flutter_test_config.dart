import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs before every test file. Font loading only: the bundled Saira and
/// Schibsted fonts (pubspec `fonts:`), so goldens render real type instead
/// of the test font's boxes.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manifest = jsonDecode(
    await rootBundle.loadString('FontManifest.json'),
  ) as List<Object?>;
  for (final entry in manifest.cast<Map<String, Object?>>()) {
    final family = (entry['family'] as String).replaceFirst(
      RegExp(r'^packages/[^/]+/'),
      '',
    );
    final loader = FontLoader(family);
    for (final font
        in (entry['fonts'] as List<Object?>).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
  await testMain();
}
