import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color, Offset;

import 'package:flutter/foundation.dart'
    show kDebugMode, kProfileMode, kReleaseMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_camera.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';
import 'package:sinan/src/data/chunker.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/fingerprint.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sqlite3/sqlite3.dart';

/// **AOT 校准微基准**（阶段 B 遗留项，2026-10-04）。
///
/// `test/perf/db_isolate_threshold_probe_test.dart` 只有 **JIT** 数字（`flutter
/// test` 不支持 release/profile，`--profile` 会以 exit 64 拒绝）。而发布是 AOT，
/// 判断"某路径是否越过一帧预算"必须用 AOT 数字，否则会把 JIT 的高估当真。
///
/// 这里直接**调用真实 store**（不是复刻），在 Windows 桌面以 profile 模式跑：
/// ```powershell
/// flutter test integration_test/db_bench_test.dart --profile -d windows
/// ```
/// 于是同时得到真实代码 + 真实 AOT，且**不需要夹具**（内存库自建）。
///
/// 测项与 JIT 探针一一对应，便于算 JIT→AOT 倍数：
/// ① 读侧：FTS `MATCH + bm25`（高频/独有）、`allNotes()`（含裸查拆段）；
/// ② 写侧：大画布整篇保存 `updateContent`（指纹 + decode + 增量投影）。
///
/// 规模可覆盖：`--dart-define=SINAN_NOTES=N` / `SINAN_STROKES=N`（默认中等规模）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const int notesScale = int.fromEnvironment(
    'SINAN_NOTES',
    defaultValue: 10000,
  );
  const int strokesScale = int.fromEnvironment(
    'SINAN_STROKES',
    defaultValue: 5000,
  );
  // ⚠️ 读侧与写侧务必**分进程跑**：同进程里读侧先灌 1 万笔记，膨胀的老年代堆会让
  // 写侧的 GC 进入病态——实测同一 debug 模式下写侧数字在 87ms↔480ms 间乱跳，
  // 只有分进程（读 / 写各一次调用）才拿得到稳定值。这正是 JIT 探针踩过的同一个坑。
  const String benchMode = String.fromEnvironment(
    'SINAN_BENCH',
    defaultValue: 'all',
  );
  const bool runRead = benchMode == 'all' || benchMode == 'read';
  const bool runWrite = benchMode == 'all' || benchMode == 'write';

  final Map<String, Object?> out = <String, Object?>{};
  final StringBuffer log = StringBuffer();

  testWidgets('AOT 微基准：读侧（FTS / allNotes）', (WidgetTester tester) async {
    final Database db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');

    final Stopwatch setup = Stopwatch()..start();
    _bulkIndex(db, notesScale);
    setup.stop();

    final int commonUs = _medianUs(() {
      db.select(
        'SELECT block_id, note_id, chunk_text, bm25(chunks_fts) AS rank '
        'FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT 32',
        <Object?>[_keywordMatch('写作')],
      );
    });
    final int rareUs = _medianUs(() {
      db.select(
        'SELECT block_id, note_id, chunk_text, bm25(chunks_fts) AS rank '
        'FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT 32',
        <Object?>[_keywordMatch(_uniquePair(42))],
      );
    });
    final NoteStore store = NoteStore(db);
    final int listUs = _medianUs(store.allNotes, runs: 5);
    final int rawUs = _medianUs(
      () => db.select(
        'SELECT id, kind, title, content_hash, tags, summary, '
        'created_at, revised_at, promoted_at FROM notes '
        'ORDER BY (promoted_at IS NULL) ASC, promoted_at DESC, '
        'revised_at DESC, created_at DESC, id ASC',
      ),
      runs: 5,
    );
    db.close();

    out['env'] = _envLabel();
    out['notes'] = notesScale;
    out['index_ms'] = setup.elapsedMilliseconds;
    out['match_common_ms'] = commonUs / 1000;
    out['match_rare_ms'] = rareUs / 1000;
    out['allnotes_ms'] = listUs / 1000;
    out['allnotes_raw_ms'] = rawUs / 1000;

    log
      ..writeln()
      ..writeln(
        '  [${_envLabel()}] 笔记数 $notesScale（建索引 ${setup.elapsedMilliseconds}ms）',
      )
      ..writeln('        高频MATCH  ${(commonUs / 1000).toStringAsFixed(3)} ms')
      ..writeln('        独有词MATCH ${(rareUs / 1000).toStringAsFixed(3)} ms')
      ..writeln(
        '        allNotes    ${(listUs / 1000).toStringAsFixed(3)} ms'
        '（裸查 ${(rawUs / 1000).toStringAsFixed(3)}）',
      );
  }, skip: !runRead);

  testWidgets('AOT 微基准：写侧（大画布整篇保存）', (WidgetTester tester) async {
    final Database db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    final NoteStore store = NoteStore(db);
    final Note canvas = store.create(kind: NoteKind.canvas);

    // 造一次拿尺寸；真测时每轮换 jitter 穿过哈希判变闸门（否则第 2 次起 0 写入）。
    final String sample = _canvasContent(strokesScale, jitter: 0);
    final int bytes = utf8.encode(sample).length;
    final int decodeUs = _medianUs(() => jsonDecode(sample), runs: 5);
    final int fpUs = _medianUs(() => contentFingerprint(sample), runs: 5);

    final List<int> saveSamples = <int>[];
    for (int run = 0; run < 5; run++) {
      final String content = _canvasContent(strokesScale, jitter: run);
      final Stopwatch sw = Stopwatch()..start();
      await store.updateContent(canvas.id, content, plainText: '');
      sw.stop();
      saveSamples.add(sw.elapsedMicroseconds);
    }
    final int saveUs = _median(saveSamples);
    db.close();

    out['env'] = _envLabel();
    out['strokes'] = strokesScale;
    out['content_kb'] = bytes ~/ 1024;
    out['fingerprint_ms'] = fpUs / 1000;
    out['decode_ms'] = decodeUs / 1000;
    out['save_ms'] = saveUs / 1000;

    log
      ..writeln()
      ..writeln(
        '  [${_envLabel()}] 笔迹数 $strokesScale（content ${bytes ~/ 1024} KB）',
      )
      ..writeln('        指纹     ${(fpUs / 1000).toStringAsFixed(3)} ms')
      ..writeln('        decode   ${(decodeUs / 1000).toStringAsFixed(3)} ms')
      ..writeln('        整篇保存 ${(saveUs / 1000).toStringAsFixed(3)} ms');
  }, skip: !runWrite);

  tearDownAll(() {
    final Directory dir = Directory('build/perf')..createSync(recursive: true);
    File('${dir.path}/aot_db_bench.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
    // ignore: avoid_print
    print(log.toString());
    // ignore: avoid_print
    print('AOT_DB_BENCH ${jsonEncode(out)}');
  });
}

String _envLabel() => kReleaseMode
    ? 'release/AOT'
    : kProfileMode
    ? 'profile/AOT'
    : kDebugMode
    ? 'debug/JIT'
    : 'unknown';

int _median(List<int> samples) {
  final List<int> s = List<int>.of(samples)..sort();
  return s[s.length ~/ 2];
}

int _medianUs(void Function() body, {int runs = 11}) {
  final List<int> samples = <int>[];
  for (int i = 0; i < runs; i++) {
    final Stopwatch sw = Stopwatch()..start();
    body();
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  return _median(samples);
}

/// 与 JIT 探针逐字一致：bigram OR 组合（见 retriever._keywordRanked）。
String _keywordMatch(String query) {
  final List<String> tokens = bigram(query).split(' ');
  return tokens.map((String t) => '"${t.replaceAll('"', '""')}"').join(' OR ');
}

String _uniquePair(int i) {
  const int base = 250;
  final int a = 0x4e00 + i % base;
  final int b = 0x4e00 + (i ~/ base) % base;
  return String.fromCharCode(a) + String.fromCharCode(b);
}

const String _kCorpus =
    '写作是一种把思考外化的方式，当你把想法写下来，它才真正属于你。'
    '本地优先意味着数据永远留在你自己的设备上，不依赖任何云端服务。'
    '块编辑器让每一段都能独立移动、引用与重组，这是流式写作的基础。';

/// 造 n 篇已索引笔记（notes + blocks + chunks_fts），单事务灌完。
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
      final String text =
          '$_kCorpus${_kCorpus.substring(0, 60)}锚${_uniquePair(i)}记';
      insNote.execute(<Object?>[id, 'note', 't$i', '', 'fp1:1:$i', text, 1, 1]);
      final String blockId = 'b$i';
      insBlock.execute(<Object?>[
        blockId,
        id,
        'paragraph',
        jsonEncode(<String, Object?>{
          'delta': <Map<String, Object?>>[
            <String, Object?>{'insert': text},
          ],
        }),
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

/// 走画布内核 toJson 造大画布；[jitter] 让每轮 content 不同以穿过判变闸门。
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
