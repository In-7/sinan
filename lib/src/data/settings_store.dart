import 'package:sqlite3/sqlite3.dart';

/// 应用设置的持久化（settings 表的 key-value 读写）。
///
/// 与 [NoteStore] 同层：只在 SQLite 之上做薄封装，不碰业务语义
/// （含义与默认值归 models/settings.dart 的 [AppSettings]）。
/// 读写都是本地同步的——SQLite 文件在用户数据目录，无网络/异步开销，
/// 因此 Riverpod 的 Notifier 可以**同步**读取初值，无需 AsyncNotifier。
class SettingsStore {
  SettingsStore(this.db);

  final Database db;

  /// 读取设置值；未设置过返回 null（调用方回落到默认值）。
  String? get(String key) {
    final ResultSet rows = db.select(
      'SELECT value FROM settings WHERE key = ?;',
      <Object?>[key],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// 写入设置值（不存在则插入，已存在则覆盖）。
  void set(String key, String value) {
    db.execute(
      'INSERT INTO settings (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value;',
      <Object?>[key, value],
    );
  }
}
