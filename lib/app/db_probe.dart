import 'package:sqlite3/sqlite3.dart';

/// C0 proof that the bundled SQLite loads on the device (integration doc
/// ruling 3). Logged once at startup as `GymSupreme/db ok sqlite <version>`;
/// the CI emulator smoke asserts the line. Replaced by the real store open.
String probeSqlite() {
  try {
    final db = sqlite3.openInMemory();
    try {
      final v = db.select('select sqlite_version() as v').first['v'];
      return 'GymSupreme/db ok sqlite $v';
    } finally {
      db.close();
    }
  } catch (e) {
    return 'GymSupreme/db FAILED $e';
  }
}
