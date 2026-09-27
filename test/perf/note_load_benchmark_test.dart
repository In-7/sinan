// 笔记加载路径微基准：把「打开一篇笔记」拆成 SQLite 读取 / jsonDecode /
// Document 构建三段，回答"后台 isolate 到底能省下哪一段"。
//
// 跑法：flutter test test/perf/note_load_benchmark_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/editor/core/note_document_adapter.dart';
import 'package:sqlite3/sqlite3.dart';

/// 中文语料池：生成贴近真实的正文（避免"重复一个字"导致断行/整形失真）。
const String _kCorpus =
    '写作是一种把思考外化的方式，当你把想法写下来，它才真正属于你。'
    '本地优先意味着数据永远留在你自己的设备上，不依赖任何云端服务。'
    '块编辑器让每一段都能独立移动、引用与重组，这是流式写作的基础。';

/// 每段字数（贴近真实段落长度；万字笔记 ≈ 110 段）。
const int _kParagraphChars = 90;

String _textOf(int length) {
  final StringBuffer sb = StringBuffer();
  while (sb.length < length) {
    sb.write(_kCorpus);
  }
  return sb.toString().substring(0, length);
}

/// 生成 v2 块树 JSON（结构与 `NoteDocumentAdapter` 注释中的格式一致）。
String _generateStoredContent(int totalChars) {
  final List<Object?> children = <Object?>[];
  int remaining = totalChars;
  int i = 0;
  while (remaining > 0) {
    final int take = remaining < _kParagraphChars ? remaining : _kParagraphChars;
    final String text = _textOf(take);
    final bool isHeading = i > 0 && i % 17 == 0;
    children.add(<String, Object?>{
      'id': 'b$i',
      'type': isHeading ? 'heading' : 'paragraph',
      'data': isHeading
          ? <String, Object?>{
              'level': 2,
              'delta': <Object?>[<String, Object?>{'insert': text}],
            }
          : <String, Object?>{
              'delta': <Object?>[<String, Object?>{'insert': text}],
            },
    });
    remaining -= take;
    i++;
  }
  return jsonEncode(<String, Object?>{
    'v': 2,
    'format': 'blocks',
    'document': <String, Object?>{
      'id': 'root01',
      'type': 'page',
      'children': children,
    },
  });
}

int _blockCountOf(int totalChars) =>
    (totalChars / _kParagraphChars).ceil();

/// 取中位数：微基准降噪（首次含惰性初始化，取中位数比均值稳）。
int _median(List<int> samples) {
  final List<int> sorted = List<int>.of(samples)..sort();
  return sorted[sorted.length ~/ 2];
}

int _measureUs(void Function() body, {int runs = 7}) {
  final List<int> samples = <int>[];
  for (int i = 0; i < runs; i++) {
    final Stopwatch sw = Stopwatch()..start();
    body();
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  return _median(samples);
}

void main() {
  test('解析拆分：jsonDecode vs Document 构建', () {
    final StringBuffer report = StringBuffer();
    report.writeln();
    report.writeln('  chars   json KB   blocks |  decode ms | docTotal ms | build ms');
    report.writeln('  ${'-' * 66}');

    for (final int chars in <int>[1000, 5000, 10000, 50000]) {
      final String content = _generateStoredContent(chars);
      final int bytes = utf8.encode(content).length;

      // ① 纯 jsonDecode（isolate 唯一能搬走的一段）
      final int decodeUs = _measureUs(() {
        jsonDecode(content);
      });
      // ② documentFromStoredContent = decode + Document 构建
      final int totalUs = _measureUs(() {
        NoteDocumentAdapter.documentFromStoredContent(content);
      });
      final int buildUs = totalUs - decodeUs;

      report.writeln(
        '  ${chars.toString().padLeft(5)}  ${(bytes / 1024).toStringAsFixed(1).padLeft(7)}'
        '  ${_blockCountOf(chars).toString().padLeft(7)} |'
        ' ${(decodeUs / 1000).toStringAsFixed(2).padLeft(10)} |'
        ' ${(totalUs / 1000).toStringAsFixed(2).padLeft(11)} |'
        ' ${(buildUs / 1000).toStringAsFixed(2).padLeft(9)}',
      );
    }
    // ignore: avoid_print
    print(report.toString());
  });

  test('SQLite 读取（本机可加载 sqlite3 时才有效）', () {
    Database? db;
    try {
      db = sqlite3.openInMemory();
    } on Object catch (error) {
      // ignore: avoid_print
      print('\n  [跳过] sqlite3 在测试环境不可用：$error');
      return;
    }
    db.execute('CREATE TABLE notes (id TEXT PRIMARY KEY, content TEXT, '
        'title TEXT, plain_text TEXT)');

    final String wanzi = _generateStoredContent(10000);
    db.execute('INSERT INTO notes VALUES (?, ?, ?, ?)',
        <Object?>['n1', wanzi, '标题', _textOf(10000)]);
    // 再塞 199 篇：正文 400 字、plain_text 同尺寸（贴近真实语料）
    for (int i = 0; i < 199; i++) {
      db.execute('INSERT INTO notes VALUES (?, ?, ?, ?)',
          <Object?>[
        's$i',
        _generateStoredContent(400),
        't$i',
        _textOf(400),
      ]);
    }

    final int oneNoteUs = _measureUs(() {
      db!.select('SELECT content FROM notes WHERE id = ?', <Object?>['n1']);
    });
    // 现状：列表查询带 plain_text（NoteStore.allNotes 的真实形状）
    final int listWithUs = _measureUs(() {
      db!.select('SELECT id, title, plain_text FROM notes');
    });
    // 对照：不带 plain_text
    final int listWithoutUs = _measureUs(() {
      db!.select('SELECT id, title FROM notes');
    });

    // ignore: avoid_print
    print('\n  SQLite: 单篇取正文(万字) ${(oneNoteUs / 1000).toStringAsFixed(3)} ms'
        '\n          200 篇列表 带 plain_text ${(listWithUs / 1000).toStringAsFixed(3)} ms'
        '\n          200 篇列表 无 plain_text ${(listWithoutUs / 1000).toStringAsFixed(3)} ms\n');
    db.close();
  });
}
