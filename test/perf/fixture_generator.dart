import 'dart:convert';
import 'dart:io';
// 几何/颜色取 `dart:ui`（而不是 flutter/widgets）：后者的 `Row` 与 sqlite3 的
// `Row` 撞名，而这个文件是数据侧工具，不需要任何 widget 类型。
import 'dart:ui' show Color, Offset, Rect;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_camera.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/editor/core/note_document_adapter.dart';
import 'package:sqlite3/sqlite3.dart';

/// **性能夹具生成器**（`docs/perf_baseline.md` §2.1 的缺口）。
///
/// ## 为什么是一个 test 文件而不是 `dart run tool/…`
/// 夹具必须由**应用自己的序列化器**产出（`NoteDocumentAdapter` / 画布内核
/// `toJson`）——手抄一份 schema 写进去，迟早与真实格式漂移，那时夹具就是
/// "能读出来但长得不一样"的假数据，基线的数字全白测。
/// 而这些代码 import 了 Flutter，`dart run` 起不来 ⇒ 放在 `flutter test` 里跑。
///
/// ## 用法（**必须显式开启**，避免误跑污染真实库）
/// ```powershell
/// # 生成（DB 路径省略时自动在 %APPDATA% 里找 sinan.db）
/// flutter test test/perf/fixture_generator.dart `
///   --dart-define=SINAN_FIXTURES=make
///
/// # 指定库（推荐：先指向临时库演练）
/// flutter test test/perf/fixture_generator.dart `
///   --dart-define=SINAN_FIXTURES=make --dart-define=SINAN_DB=C:\path\sinan.db
///
/// # 清理（删掉标题带【性能夹具】的笔记，级联清干净）
/// flutter test test/perf/fixture_generator.dart `
///   --dart-define=SINAN_FIXTURES=clean
/// ```
///
/// ⚠️ 夹具是**真实笔记**（会出现在列表里）：生成后请先记下标题前缀
/// [fixturePrefix]，测完用 `clean` 清掉，别留在正式库里。
void main() {
  const String action = String.fromEnvironment('SINAN_FIXTURES');
  const String dbArg = String.fromEnvironment('SINAN_DB');

  if (action.isEmpty) {
    test('夹具生成器：未启用（不会改动任何数据）', () {
      // 平时 `flutter test` 走到这里什么也不做——夹具生成必须是一次显式动作。
      // ignore: avoid_print
      print(
        '用法：flutter test test/perf/fixture_generator.dart '
        '--dart-define=SINAN_FIXTURES=make '
        '[--dart-define=SINAN_DB=<sinan.db 路径>]',
      );
    });
    return;
  }

  test('夹具生成器：$action', () async {
    final File dbFile = _resolveDb(dbArg);
    // ignore: avoid_print
    print('DB: ${dbFile.path}');
    final Database db = sqlite3.open(dbFile.path);
    addTearDown(db.close);
    // 与应用同口径：外键开，级联才生效（clean 依赖它）。
    db.execute('PRAGMA foreign_keys = ON;');
    AppDatabase.migrateForTesting(db);

    switch (action) {
      case 'make':
        final NoteStore store = NoteStore(db);
        await _clean(store, db);
        final Note doc = store.create(
          kind: NoteKind.note,
          title: '$fixturePrefix大笔记',
          content: _bigNoteContent(),
        );
        final Note canvas = store.create(
          kind: NoteKind.canvas,
          title: '$fixturePrefix大画布',
          content: _bigCanvasContent(),
        );
        // 自检：夹具必须**真的能读回来**（形状写错时宁可在这里炸，
        // 也不要在计时现场才发现测的是一份空文档）。
        _verifyNote(db, doc.id, minPlainText: 4000);
        _verifyCanvas(db, canvas.id, minItems: 400, minStrokes: 5000);
        // ignore: avoid_print
        print('已生成：$fixturePrefix大笔记 / $fixturePrefix大画布');
      case 'clean':
        await _clean(NoteStore(db), db);
        // 自校验：清理必须真的清干净（否则"以为清掉了"会把夹具留在正式库里）。
        expect(
          db.select(
            'SELECT COUNT(*) AS c FROM notes WHERE title LIKE ?',
            <Object?>['$fixturePrefix%'],
          ).single['c'],
          0,
        );
        // ignore: avoid_print
        print('已清理：标题以 $fixturePrefix 开头的笔记');
      default:
        fail('未知 SINAN_FIXTURES=$action（只认 make / clean）');
    }
  });
}

/// 夹具标题前缀：既是**人眼识别标志**，也是 `clean` 的唯一判据。
const String fixturePrefix = '【性能夹具】';

/// 大笔记规模：200 段 × 25 字 ≈ 5000 字（够触发滚动与块高预测的真实路径）。
const int _noteParagraphs = 200;
const int _paragraphChars = 25;

/// 大画布规模：卡片（文本渲染 + LOD）/ 形状（裁剪）/ 笔迹（烤图与重放）。
const int _canvasCards = 200;
const int _canvasShapes = 200;
const int _canvasStrokes = 5000;

/// 解析 DB 路径：显式传入优先；否则在 `%APPDATA%` 里找（选最近改动的那个）。
File _resolveDb(String explicit) {
  if (explicit.isNotEmpty) return File(explicit);
  final String? appData = Platform.environment['APPDATA'];
  if (appData == null) {
    fail('未传 SINAN_DB 且找不到 APPDATA——请显式指定 --dart-define=SINAN_DB=<路径>');
  }
  final List<File> found = <File>[];
  void scan(Directory dir, int depth) {
    if (depth > 3) return;
    for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
      if (e is File && e.uri.pathSegments.last == 'sinan.db') {
        found.add(e);
      } else if (e is Directory) {
        try {
          scan(e, depth + 1);
        } on FileSystemException {
          // 无权限的目录直接跳过（%APPDATA% 下很常见）。
        }
      }
    }
  }

  scan(Directory(appData), 0);
  if (found.isEmpty) {
    fail('在 $appData 里没找到 sinan.db——请用 --dart-define=SINAN_DB 指定');
  }
  found.sort(
    (File a, File b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
  );
  return found.first;
}

/// 大笔记：**块树 JSON**，由真实适配器产出（不手写 JSON）。
String _bigNoteContent() {
  final List<Node> paragraphs = <Node>[
    for (int i = 0; i < _noteParagraphs; i++)
      Node(
        type: ParagraphBlockKeys.type,
        attributes: <String, Object?>{
          // 文本存在 `delta`（appflowy 的通用文本载体）——块树 JSON 里
          // 段落与标题都是这个形状，`NoteDocumentAdapter` 读的也是它。
          ParagraphBlockKeys.delta: <Map<String, Object?>>[
            <String, Object?>{
              'insert':
                  '第${i + 1}段 '
                  '${'性能夹具'.padRight(_paragraphChars, '文')}',
            },
          ],
        },
      ),
  ];
  final Document document = Document(
    root: Node(type: 'page', children: paragraphs),
  );
  return NoteDocumentAdapter.storedContentFromDocument(document);
}

/// 大画布：**走画布内核的 toJson**（相机 + 文档由内核序列化）。
String _bigCanvasContent() {
  final CanvasController controller = CanvasController(camera: CanvasCamera());
  final CanvasDocument doc = controller.document;

  // 卡片：铺成网格，间距留够（视口里能同时看到几十张 ⇒ 触发 LOD 与文本渲染）。
  for (int i = 0; i < _canvasCards; i++) {
    final double x = (i % 20) * 220;
    final double y = (i ~/ 20) * 140;
    doc.addItem(
      CardItem(
        id: 'fixture-card-$i',
        rect: Rect.fromLTWH(x, y, 180, 100),
        blockId: 'fixture-block-$i',
        text: '夹具卡片 ${i + 1}：${'内容' * 6}',
      ),
    );
  }

  // 形状：混在卡片之间（裁剪与粗筛的压力）。
  for (int i = 0; i < _canvasShapes; i++) {
    final double x = (i % 20) * 220 + 40;
    final double y = (i ~/ 20) * 140 + 110;
    doc.addItem(
      ShapeItem(
        rect: Rect.fromLTWH(x, y, 80, 40),
        kind: i.isEven ? CanvasShapeKind.rectangle : CanvasShapeKind.ellipse,
        color: const Color(0xFF3366CC),
        filled: i % 3 == 0,
      ),
    );
  }

  // 笔迹：每条 12 个点（贴近真实手写的一段笔画），打散在卡片区域之上。
  for (int i = 0; i < _canvasStrokes; i++) {
    final double x0 = (i % 50) * 90.0;
    final double y0 = (i ~/ 50) * 60.0;
    doc.addStroke(
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

/// 读回校验：大笔记必须能被适配器解析出足量正文。
void _verifyNote(Database db, String noteId, {required int minPlainText}) {
  final String? content = NoteStore(db).noteById(noteId)?.content;
  final String plain = NoteDocumentAdapter.plainTextOfStoredContent(content);
  expect(
    plain.length,
    greaterThanOrEqualTo(minPlainText),
    reason: '大笔记读回来只剩 ${plain.length} 字：块树形状写错了',
  );
}

/// 读回校验：大画布必须能被内核解析出足量对象。
void _verifyCanvas(
  Database db,
  String noteId, {
  required int minItems,
  required int minStrokes,
}) {
  final String? content = NoteStore(db).noteById(noteId)?.content;
  expect(content, isNotNull);
  final Map<String, dynamic> json =
      jsonDecode(content!) as Map<String, dynamic>;
  final CanvasController restored = CanvasController.fromJson(json);
  addTearDown(restored.dispose);
  expect(
    restored.document.items.length,
    greaterThanOrEqualTo(minItems),
    reason: '大画布读回来只剩 ${restored.document.items.length} 个对象',
  );
  expect(
    restored.document.strokes.length,
    greaterThanOrEqualTo(minStrokes),
    reason: '大画布读回来只剩 ${restored.document.strokes.length} 条笔迹',
  );
}

/// 删除标题带 [fixturePrefix] 的笔记（级联清掉 blocks / canvas_items / 索引行）。
Future<void> _clean(NoteStore store, Database db) async {
  final ResultSet hits = db.select(
    'SELECT id FROM notes WHERE title LIKE ?',
    <Object?>['$fixturePrefix%'],
  );
  for (final Row r in hits) {
    await store.delete(r['id'] as String);
  }
}
