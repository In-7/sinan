import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **速记（心流）与笔记 / 画布是分离的** —— 这条是产品契约（2026-10-17 用户定），
/// 不是实现细节，所以用测试钉住，而不是写在文档里等下一个改动的人忽略。
///
/// 三件事：
/// 1. 数据层：速记只经 `StreamStore` 读写独立表，**不碰** notes / blocks；
/// 2. 形态：`NoteKind` 里不再有 `stream`（速记不是笔记）；
/// 3. 下游：`kind = 'stream'` 这类特例只允许出现在迁移脚本里（历史数据）。
void main() {
  group('速记隔离', () {
    test('StreamStore 不依赖笔记 / 画布的任何 store', () {
      // 依赖白名单：多一个都要人有意放行。
      const Set<String> allowed = <String>{
        'dart:',
        'package:sqlite3/',
        'package:uuid/',
        '../domain/note.dart',
      };
      final List<String> violations = <String>[];
      for (final String dep in _depsOf(File('lib/src/data/stream_store.dart'))) {
        if (allowed.any(dep.startsWith)) continue;
        violations.add('lib/src/data/stream_store.dart → $dep');
      }
      expect(
        violations,
        isEmpty,
        reason:
            '速记存储越界了。它必须只碰 `stream_items`：\n'
            '  ${violations.join('\n  ')}\n'
            '速记的真相源独立，笔记 / 画布只能经 NoteStore 的导出方法单向取用。',
      );
    });

    test('NoteKind 里没有 stream（速记不是笔记形态）', () {
      final String source = File('lib/src/domain/note.dart').readAsStringSync();
      expect(
        source.contains('NoteKind.stream'),
        isFalse,
        reason: 'v16 起速记在独立表 `stream_items`，`notes.kind` 不再有 stream。',
      );
    });

    test("`kind = 'stream'` 只允许出现在迁移脚本（database.dart）里", () {
      final List<String> offenders = <String>[];
      for (final File file in _dartFilesUnder('lib')) {
        final String rel = _rel(file);
        if (rel == 'lib/src/data/database.dart') continue; // v16 迁移读历史行
        final String text = file.readAsStringSync();
        if (text.contains("kind = 'stream'") ||
            text.contains('kind != \'stream\'')) {
          offenders.add(rel);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            '速记已不在 notes 表，任何地方都不该再为它写特例：\n'
            '  ${offenders.join('\n  ')}',
      );
    });

    test('速记表没有指向 notes / blocks 的外键', () {
      final String source = File('lib/src/data/stream_store.dart').readAsStringSync();
      expect(source.contains('REFERENCES notes'), isFalse);
      expect(source.contains('REFERENCES blocks'), isFalse);
    });
  });
}

List<File> _dartFilesUnder(String dir) =>
    Directory(dir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList();

List<String> _depsOf(File file) {
  final RegExp re = RegExp('''^(?:import|export)\\s+['"]([^'"]+)['"]''');
  final List<String> out = <String>[];
  for (final String line in file.readAsLinesSync()) {
    final RegExpMatch? m = re.firstMatch(line.trimLeft());
    if (m != null) out.add(m.group(1)!);
  }
  return out;
}

String _rel(FileSystemEntity e) => e.path.replaceAll(r'\', '/');
