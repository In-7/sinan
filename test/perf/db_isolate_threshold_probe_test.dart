// 阶段 B「DB 全面后台 isolate 化」触发阈值探针（2026-10-04）。
//
// 回答的是一个**判据问题**，不是性能优化：主 isolate 上的同步 SQLite 调用，
// 在个人规模（千篇）与极端规模（五万篇）下，到底有没有持续越过一帧预算
// （120Hz 半帧 ≈ 4ms、整帧 ≈ 8ms）？没有实测数据前，阶段 B 是拿地基级重构
// 赌一个推测出来的瓶颈——本文件把推测换成数字。
//
// 两个测项：
//  ① 读侧：chunks_fts MATCH+bm25（全局搜索真实查询形状，候选 32 条）高频词 /
//     独有词两档，外加主页 allNotes() 全表快照；
//  ② 写侧：大画布整篇保存 updateContent（指纹 + 笔迹分片 + 多表投影），
//     1k / 5k / 10k 条笔迹三档。
//
// 跑法：
//   flutter test test/perf/db_isolate_threshold_probe_test.dart           # 轻量档
//   flutter test test/perf/db_isolate_threshold_probe_test.dart `
//     --dart-define=SINAN_PROBE=full                                       # 万/五万档
//
// 全内存库：数据不落盘、跑完即弃；WAL/磁盘抖动不污染读数（测量目标是 CPU 侧
// 的同步执行耗时，这恰好也是"主 isolate 被卡住"的那段）。
import 'dart:convert';
import 'dart:ui' show Color, Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_camera.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';
import 'package:sinan/src/data/chunker.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/fingerprint.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// 全量档才跑万/五万（50k 行 FTS 建索引本身要数十秒，不该拖慢日常测试）。
const String _kMode = String.fromEnvironment('SINAN_PROBE');
const bool _full = _kMode == 'full';

/// 单规模覆盖：**每个规模必须用独立 VM 进程跑**（`--dart-define=SINAN_NOTES=N`
/// / `SINAN_STROKES=N`）。同一 VM 里先造 5 万笔记再测 1 千笔迹保存，膨胀的
/// 老年代堆会让 GC 进入病态、把无关测项污染 6 倍以上（2026-10-04 实测踩过）。
const String _kNotesArg = String.fromEnvironment('SINAN_NOTES');
const String _kStrokesArg = String.fromEnvironment('SINAN_STROKES');

/// 与笔记基准同一份语料：高频词「写作」在每一篇里都出现（最坏排名工况）。
const String _kCorpus =
    '写作是一种把思考外化的方式，当你把想法写下来，它才真正属于你。'
    '本地优先意味着数据永远留在你自己的设备上，不依赖任何云端服务。'
    '块编辑器让每一段都能独立移动、引用与重组，这是流式写作的基础。';

/// 生产检索的候选上限：retriever 默认 limit 8 × candidateFactor 4 = 32。
const int _kCandidateLimit = 32;

int _median(List<int> samples) {
  final List<int> sorted = List<int>.of(samples)..sort();
  return sorted[sorted.length ~/ 2];
}

int _measureUs(void Function() body, {int runs = 11}) {
  final List<int> samples = <int>[];
  for (int i = 0; i < runs; i++) {
    final Stopwatch sw = Stopwatch()..start();
    body();
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  return _median(samples);
}

/// 复刻 retriever._keywordRanked 的 bigram OR 组合（私有方法不能直接引，
/// 形状必须逐字一致，否则测的不是同一条查询）。
String _keywordMatch(String query) {
  final List<String> tokens = bigram(query).split(' ');
  return tokens.map((String t) => '"${t.replaceAll('"', '""')}"').join(' OR ');
}

void main() {
  test('读侧探针：FTS MATCH / 全表快照 vs 帧预算', () {
    final List<int> scales = _kNotesArg.isNotEmpty
        ? <int>[int.parse(_kNotesArg)]
        : _full
        ? <int>[1000, 3000, 10000, 50000]
        : <int>[1000];
    final StringBuffer report = StringBuffer();
    report.writeln();
    report.writeln('  笔记数 | 建索引 s | 高频MATCH ms | 独有词 ms | allNotes ms');
    report.writeln('  ${'-' * 66}');

    for (final int n in scales) {
      final Database db = sqlite3.openInMemory();
      AppDatabase.migrateForTesting(db);
      db.execute('PRAGMA foreign_keys = ON;');

      final Stopwatch setup = Stopwatch()..start();
      _bulkIndex(db, n);
      setup.stop();

      // 高频词：每篇都有「写作」，posting list ≈ 全表，bm25 全排——最坏工况。
      final int commonUs = _measureUs(() {
        db.select(
          'SELECT block_id, note_id, chunk_text, bm25(chunks_fts) AS rank '
          'FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?',
          <Object?>[_keywordMatch('写作'), _kCandidateLimit],
        );
      });

      // 独有词：只有第 42 篇含这对字（2 字 ⇒ 单个 bigram ⇒ posting list = 1）。
      final String rarePair = _uniquePair(42);
      final int rareUs = _measureUs(() {
        db.select(
          'SELECT block_id, note_id, chunk_text, bm25(chunks_fts) AS rank '
          'FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?',
          <Object?>[_keywordMatch(rarePair), _kCandidateLimit],
        );
      });

      final NoteStore store = NoteStore(db);
      final int listUs = _measureUs(store.allNotes, runs: 5);
      // 拆段：同一条快照 SQL 的**裸查询**（C 执行 + FFI 行读取，无对象映射），
      // 与 allNotes 的差值才是 JIT/AOT 会变的那段（Row → Note 分配）。
      final int listRawUs = _measureUs(
        () => db.select(
          'SELECT id, kind, title, content_hash, tags, summary, '
          'created_at, revised_at, promoted_at FROM notes '
          'ORDER BY (promoted_at IS NULL) ASC, promoted_at DESC, '
          'revised_at DESC, created_at DESC, id ASC',
        ),
        runs: 5,
      );

      report.writeln(
        '  ${n.toString().padLeft(6)} | ${(setup.elapsedMilliseconds / 1000).toStringAsFixed(1).padLeft(8)} |'
        ' ${(commonUs / 1000).toStringAsFixed(3).padLeft(12)} |'
        ' ${(rareUs / 1000).toStringAsFixed(3).padLeft(9)} |'
        ' ${(listUs / 1000).toStringAsFixed(3).padLeft(8)}'
        ' (裸查${(listRawUs / 1000).toStringAsFixed(1)})',
      );
      db.close();
    }
    report.writeln(
      '  注：裸查=SQLite C+FFI（JIT/AOT 不变）；allNotes 超出裸查的部分=对象映射（AOT 更快）',
    );
    report.writeln(
      '  阈值参考：120Hz 整帧 8.3ms / 半帧 4.2ms（${_full ? 'full' : '轻量档'}，flutter test=JIT 上界）',
    );
    // ignore: avoid_print
    print(report.toString());
  });

  test('写侧探针：大画布整篇保存 updateContent（指纹+投影+笔迹分片）', () async {
    final List<int> strokeScales = _kStrokesArg.isNotEmpty
        ? <int>[int.parse(_kStrokesArg)]
        : _full
        ? <int>[1000, 5000, 10000]
        : <int>[1000];
    final Database db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    final NoteStore store = NoteStore(db);
    final Note canvas = store.create(kind: NoteKind.canvas);

    final StringBuffer report = StringBuffer();
    report.writeln();
    report.writeln('  笔迹数 | content KB | 指纹 ms | decode ms | 整篇保存 ms（5 次中位数）');
    report.writeln('  ${'-' * 72}');

    for (final int strokes in strokeScales) {
      // 每次跑造**不同** content（多一条偏移笔迹）：保存有哈希判变闸门，
      // 相同 content 第二次起直接 0 写入，会把测值刷成假的 0。
      final List<int> saveSamples = <int>[];
      int fpUs = 0;
      int decodeUs = 0;
      late int bytes;
      for (int run = 0; run < 5; run++) {
        final String content = _canvasContent(strokes, jitter: run);
        bytes = utf8.encode(content).length;
        if (run == 2) {
          fpUs = _measureUs(() => contentFingerprint(content), runs: 5);
          // 投影内部第一步就是 jsonDecode——拆出来看保存耗时的构成
          // （decode 是纯 Dart，投影插入走 FFI）。
          decodeUs = _measureUs(() => jsonDecode(content), runs: 5);
        }
        final Stopwatch sw = Stopwatch()..start();
        // updateContent 签名 async 但内部全是同步工作，await 不引入调度。
        await store.updateContent(canvas.id, content, plainText: '');
        sw.stop();
        saveSamples.add(sw.elapsedMicroseconds);
      }
      final int saveUs = _median(saveSamples);
      report.writeln(
        '  ${strokes.toString().padLeft(6)} | ${(bytes / 1024).toStringAsFixed(0).padLeft(10)} |'
        ' ${(fpUs / 1000).toStringAsFixed(3).padLeft(7)} |'
        ' ${(decodeUs / 1000).toStringAsFixed(3).padLeft(9)} |'
        ' ${(saveUs / 1000).toStringAsFixed(3).padLeft(8)}',
      );
    }
    report.writeln(
      '  阈值参考：120Hz 整帧 8.3ms（${_full ? 'full' : '轻量档'}，flutter test=JIT 上界；FFI 写与解码 AOT 仅小幅变快）',
    );
    // ignore: avoid_print
    print(report.toString());
    db.close();
  });
}

// ── 读侧夹具 ──────────────────────────────────────────────────────

/// 从约 250 个汉字的方阵里取唯一二字组（6.2 万种，够 5 万篇各拿一个）。
String _uniquePair(int i) {
  const int base = 250;
  final int a = 0x4e00 + i % base;
  final int b = 0x4e00 + (i ~/ base) % base;
  return String.fromCharCode(a) + String.fromCharCode(b);
}

/// 批量造 n 篇"已索引"笔记：notes + blocks + chunks_fts，一条事务灌完。
/// 形状与生产双写一致（块文本在 data.delta、FTS 走 [chunkBlock] 的 bigram）。
void _bulkIndex(Database db, int n) {
  final PreparedStatement insNote = db.prepare(
    'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
    'created_at, revised_at) VALUES (?,?,?,?,?,?,?,?)',
  );
  final PreparedStatement insBlock = db.prepare(
    'INSERT INTO blocks (id, note_id, type, props_json, ord, created_at, '
    'updated_at, fingerprint) VALUES (?,?,?,?,?,?,?,?)',
  );
  final PreparedStatement insFts = db.prepare(
    'INSERT INTO chunks_fts (search_text, block_id, note_id, chunk_text) '
    'VALUES (?,?,?,?)',
  );

  db.execute('BEGIN');
  try {
    for (int i = 0; i < n; i++) {
      final String id = 'n$i';
      // 每篇一段约 150 字：语料高频词 + 一个本篇独有的二字组（做独有词查询）。
      final String text =
          '$_kCorpus${_kCorpus.substring(0, 60)}锚${_uniquePair(i)}记';
      insNote.execute(<Object?>[id, 'note', 't$i', '', 'fp1:1:$i', text, 1, 1]);

      final String blockId = 'b$i';
      final String props = jsonEncode(<String, Object?>{
        'delta': <Map<String, Object?>>[
          <String, Object?>{'insert': text},
        ],
      });
      insBlock.execute(<Object?>[
        blockId,
        id,
        'paragraph',
        props,
        0,
        1,
        1,
        'fp1:1:$blockId',
      ]);

      for (final Chunk c in chunkBlock(text)) {
        insFts.execute(<Object?>[c.searchText, blockId, id, c.text]);
      }
    }
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    insNote.close();
    insBlock.close();
    insFts.close();
  }
}

// ── 写侧夹具 ──────────────────────────────────────────────────────

/// 走画布内核 toJson 造大画布（与 perf fixture 同路径），[jitter] 让每篇
/// content 不同以穿过保存的哈希判变闸门。
String _canvasContent(int strokes, {required int jitter}) {
  final CanvasController controller = CanvasController(camera: CanvasCamera());
  for (int i = 0; i < strokes; i++) {
    final double x0 = (i % 50) * 90.0 + jitter;
    final double y0 = (i ~/ 50) * 60.0;
    controller.document.addStroke(
      InkStroke(
        color: const Color(0xFF1F1F1F),
        baseWidth: 2.5,
        points: <InkPoint>[
          for (int k = 0; k < 12; k++)
            InkPoint(Offset(x0 + k * 5, y0 + (k % 4) * 3), 0.5),
        ],
      ),
    );
  }
  return jsonEncode(controller.toJson());
}
