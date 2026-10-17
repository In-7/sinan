import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// Markdown 镜像的**接线**（设置开关 → 保存 / 改名 / 删除 / 撤销）。
///
/// 引擎本身的规则（幂等、撞名、消毒、引用 → wikilink）钉在
/// `test/data/md_mirror_test.dart`；这里只钉"应用什么时候会去调它"：
/// 关着不动、开着跟着保存走、改名搬文件、删除清文件、撤销补回来。
void main() {
  late Database db;
  late NoteStore store;
  late ProviderContainer container;
  late Directory tmp;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
    tmp = Directory.systemTemp.createTempSync('sinan_mirror_wiring_');
    container = ProviderContainer(
      overrides: [
        noteStoreProvider.overrideWithValue(store),
        settingsStoreProvider.overrideWithValue(SettingsStore(db)),
        appDataDirProvider.overrideWithValue(tmp.path),
        databaseProvider.overrideWithValue(db),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// v2 块树（`saveContent` 会双写 `blocks`，镜像读的就是它）。
  String docWith(String text) => jsonEncode(<String, Object?>{
    'v': 2,
    'format': 'blocks',
    'document': <String, Object?>{
      'id': 'root',
      'type': 'page',
      'children': <Object?>[
        <String, Object?>{
          'id': 'b1',
          'type': 'paragraph',
          'data': <String, Object?>{
            'delta': <Object?>[
              <String, Object?>{'insert': text},
            ],
          },
        },
      ],
    },
  });

  /// 默认导出目录（应用数据目录下的 `markdown-mirror`）。
  String mirrorPath(String name) => p.join(tmp.path, 'markdown-mirror', name);

  Future<void> save(String id, String text) =>
      container.read(notesProvider.notifier).saveContent(
        id,
        docWith(text),
        plainText: text,
      );

  test('开关关着：保存不产生任何文件（默认不碰磁盘）', () async {
    final Note n = store.create(title: '甲');
    await save(n.id, '正文');
    expect(Directory(p.join(tmp.path, 'markdown-mirror')).existsSync(), isFalse);
  });

  test('开关打开：保存正文 ⇒ 该篇落到默认目录', () async {
    final Note n = store.create(title: '甲');
    container.read(settingsProvider.notifier).setMarkdownMirrorEnabled(true);
    await save(n.id, '第一版');

    final File f = File(mirrorPath('甲.md'));
    expect(f.existsSync(), isTrue);
    expect(f.readAsStringSync(), contains('第一版'));

    await save(n.id, '第二版');
    expect(f.readAsStringSync(), contains('第二版'));
  });

  test('设置里选了目录 ⇒ 文件写到那里（不是默认目录）', () async {
    final String custom = p.join(tmp.path, 'vault');
    container.read(settingsProvider.notifier)
      ..setMarkdownMirrorEnabled(true)
      ..setMarkdownMirrorDir(custom);

    final Note n = store.create(title: '乙');
    await save(n.id, '正文');

    expect(File(p.join(custom, '乙.md')).existsSync(), isTrue);
    expect(Directory(p.join(tmp.path, 'markdown-mirror')).existsSync(), isFalse);
  });

  test('改标题 ⇒ 旧文件删、新文件在（保存标题就搬家）', () async {
    final Note n = store.create(title: '旧名');
    container.read(settingsProvider.notifier).setMarkdownMirrorEnabled(true);
    await save(n.id, '正文');
    expect(File(mirrorPath('旧名.md')).existsSync(), isTrue);

    await container.read(notesProvider.notifier).saveTitle(n.id, '新名');
    expect(File(mirrorPath('旧名.md')).existsSync(), isFalse);
    expect(File(mirrorPath('新名.md')).existsSync(), isTrue);
  });

  test('删笔记 ⇒ 镜像文件跟着删；撤销删除 ⇒ 补回来', () async {
    final Note n = store.create(title: '要删的');
    container.read(settingsProvider.notifier).setMarkdownMirrorEnabled(true);
    await save(n.id, '正文');
    expect(File(mirrorPath('要删的.md')).existsSync(), isTrue);

    final Note? removed = await container
        .read(notesProvider.notifier)
        .deleteNote(n.id);
    expect(removed, isNotNull);
    expect(File(mirrorPath('要删的.md')).existsSync(), isFalse);

    await container.read(notesProvider.notifier).restoreNote(removed!);
    expect(File(mirrorPath('要删的.md')).existsSync(), isTrue);
  });

  test('立即导出：关着开关 ⇒ 恒 0（不解析目录、不抛）', () async {
    store.create(title: '甲');
    final int n = await container.read(markdownMirrorExportProvider)();
    expect(n, 0);
    expect(Directory(p.join(tmp.path, 'markdown-mirror')).existsSync(), isFalse);
  });

  test('镜像目录的单一来源：显示与写盘同一条路径', () {
    container.read(settingsProvider.notifier).setMarkdownMirrorDir('  ');
    expect(
      container.read(markdownMirrorDirProvider),
      p.join(tmp.path, 'markdown-mirror'),
      reason: '空白覆盖视同没填',
    );

    final String custom = p.join(tmp.path, 'vault');
    container.read(settingsProvider.notifier).setMarkdownMirrorDir(custom);
    expect(container.read(markdownMirrorDirProvider), custom);
  });
}
