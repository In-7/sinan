import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugPrint, debugPrintSynchronously;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/canvas/canvas_note_view.dart';
import 'package:sinan/src/canvas/kernel/canvas_view.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/notes/note_editor_view_appflowy.dart';
import 'package:sinan/src/notes/note_list_view.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/window/app_title_bar.dart';
import 'package:sqlite3/sqlite3.dart';

/// 无障碍（a11y）：**能守住的就设门槛，守不住的记在账上**。
///
/// 背景与判据见 `docs/a11y.md`。三类断言的分工（别混用）：
///
/// | 类别 | 形态 | 含义 |
/// |---|---|---|
/// | **硬门槛** | `expect(..., isTrue)` | 现在就是绿的，**不许退回去**（列表标签、四界面对比度、桌面 24×24） |
/// | **账本** | `skip:` + 说明 | 已知欠账：**可见、不假装绿**、也不拦 CI；修好只需删掉 `skip` |
/// | **盲区守卫** | `expect(画布语义规模, 0)` | 画布**零语义节点** ⇒ 三个检查器在它身上全绿是**假阴性**（没节点可查）。这条防的就是"把假绿读成合格" |
///
/// ## 官方三个检查器（已核实）
/// - 标签判据是 `label.isEmpty && tooltip.isEmpty`（`accessibility.dart` 第 264 行）
///   ⇒ **`tooltip` 也算合格标签**；
/// - 官方**只有** android 48×48 / iOS 44×44 预设，**没有 Windows**；桌面按
///   WCAG 2.2 SC 2.5.8 取 **24×24**（`MinimumTapTargetGuideline(size:, link:)`）；
/// - `evaluate()` 直接读 `semanticsOwner.rootSemanticsNode` ⇒ 必须先
///   `tester.ensureSemantics()`。
///
/// ## ⚠️ 两条"不能当真"的边界
/// 1. **生产底色不可完全复现**：测试进程没有平台窗口合成，只能用主题令牌近似
///    ⇒ 对比度结果**只有参考价值**，最终要人眼复核；
/// 2. 断言跑在**桌面口径**（24×24），不是移动端的 48 —— 我们最小窗宽 720，属高密度桌面 UI。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 默认 `debugPrint` 是节流版，盘点报告可能被丢/延迟；这里要"一次看全"。
  setUpAll(() => debugPrint = debugPrintSynchronously);

  late Database db;
  late NoteStore store;
  late SettingsStore settings;
  late Directory tempDir;

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    store = NoteStore(db);
    settings = SettingsStore(db);
    tempDir = Directory.systemTemp.createTempSync('sinan_a11y');

    // 标题栏在 initState 里向 `window_manager` 查窗口状态（`isFocused` /
    // `isMaximized`，见 `app_title_bar.dart` 三处 `_sync`）——测试进程没有原生
    // 实现，不桩掉就是 `MissingPluginException`。桩成"未聚焦、未最大化"的中性态
    // 即可：本文件要的是**语义树**，不是窗口真相。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'),
            (MethodCall call) async {
      if (call.method == 'isMaximized' ||
          call.method == 'isFocused' ||
          call.method == 'isFullScreen') {
        return false;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  tearDownAll(() => debugPrint(_summary()));

  for (final Brightness b in Brightness.values) {
    final String mode = b == Brightness.light ? '浅色' : '深色';

    testWidgets('笔记列表：三件套必须保持全过 · $mode', (WidgetTester tester) async {
      final Note note = store.create();
      final handle = tester.ensureSemantics();
      final _Audit a = await _audit(
        tester,
        store: store,
        settings: settings,
        dataDir: tempDir.path,
        brightness: b,
        // 生产里列表浮在窗口底上（不可复现，见文件头 ⚠️）。
        background: AppTheme.windowBackground(b),
        child: NoteListView(selectedId: note.id, onPick: (String _) {}),
        surface: '笔记列表[ $mode ]',
        settle: true,
      );
      handle.dispose();

      expect(
        a.labeled,
        isTrue,
        reason: '列表项是读屏用户进入应用的第一站，标签不许丢',
      );
      expect(a.contrast, isTrue, reason: '列表文字对比度退化');
      expect(a.tap, isTrue, reason: '列表可点目标小于桌面 24×24');
    });

    testWidgets('自绘标题栏（真实形态）：三件套必须保持全过 · $mode', (
      WidgetTester tester,
    ) async {
      final handle = tester.ensureSemantics();
      final _Audit a = await _audit(
        tester,
        store: store,
        settings: settings,
        dataDir: tempDir.path,
        brightness: b,
        background: AppTheme.windowBackground(b),
        // 照 `HomeScreen` 的真实形态复刻：标题栏 `trailing` 含问笔记 + 设置钮（导航已
        // 搬到工作区左侧 [AppIconRail]），全部走 `IconButton(tooltip:)`，
        // **不要**在外层包 Tooltip（见 a11y 文档）。
        child: Column(
          children: <Widget>[
            WindowStrip(
              trailing: <Widget>[
                IconButton(
                  icon: const Icon(Icons.menu),
                  tooltip: '菜单',
                  onPressed: () {},
                ),
              ],
            ),
          ],
        ),
        surface: '自绘标题栏[ $mode ]',
      );
      handle.dispose();

      expect(a.labeled, isTrue, reason: '自绘窗控/动作按钮丢了标签');
      expect(a.contrast, isTrue, reason: '标题栏文字对比度退化');
      expect(a.tap, isTrue, reason: '窗控按钮小于桌面 24×24');
    });

    testWidgets('画布：可断言的两项必须过；语义是**已知盲区** · $mode', (
      WidgetTester tester,
    ) async {
      final Note note = store.create(kind: NoteKind.canvas);
      final handle = tester.ensureSemantics();
      final _Audit a = await _audit(
        tester,
        store: store,
        settings: settings,
        dataDir: tempDir.path,
        brightness: b,
        background: AppTheme.contentCanvas(b),
        child: CanvasNoteView(noteId: note.id),
        surface: '画布[ $mode ]',
      );
      handle.dispose();

      expect(a.contrast, isTrue, reason: '画布浮层文字对比度退化');
      expect(a.tap, isTrue, reason: '画布可点目标小于桌面 24×24');

      // ⚠️ 下面是**盲区守卫**，不是"画布合格"的证明：画布**内容**全是
      // `CustomPaint`，不产出任何语义节点 ⇒ 三个检查器在内容上必然全绿
      // （没东西可查）。
      //
      // 守卫的**范围是内容子树**（`CanvasView`），不是整页。2026-09-18 修正：
      // 工具栏加了缩放百分比按钮（真正的交互件，本该有语义与 tooltip），
      // 拿"整页总数 == 0"当守卫就会因为它而红 —— 而真正要盯的事实
      // （**内容**零语义）反而没人守。
      final Finder contentSemantics = find.descendant(
        of: find.byType(CanvasView),
        matching: find.bySemanticsLabel(RegExp(r'.+')),
      );
      expect(
        contentSemantics,
        findsNothing,
        reason: '画布**内容**当前零语义节点——检查器给它的 ✅ 是**假阴性**。一旦这里'
            '变成非空，说明有人开始给画布内容补语义了：请把本断言改成 findsWidgets，'
            '并同步更新 docs/a11y.md 的"已知盲区"条目。',
      );
      expect(
        find.descendant(
          of: find.byType(CanvasView),
          matching: find.byType(Text),
        ),
        findsNothing,
        reason: '画布内容文字走 TextPainter 自绘，不该出现 Text 部件',
      );
    });

    testWidgets('块编辑器：对比度与点击目标必须过 · $mode', (WidgetTester tester) async {
      final Note note = store.create();
      final handle = tester.ensureSemantics();
      final _Audit a = await _audit(
        tester,
        store: store,
        settings: settings,
        dataDir: tempDir.path,
        brightness: b,
        background: AppTheme.contentCanvas(b),
        child: NoteEditorViewAppFlowy(noteId: note.id),
        surface: '块编辑器[ $mode ]',
        settle: true,
      );
      handle.dispose();

      expect(a.contrast, isTrue, reason: '正文/元信息行对比度退化');
      expect(a.tap, isTrue, reason: '编辑器内可点目标小于桌面 24×24');
      // ⚠️ 标签这一项**不在这里断言**：编辑器还剩已知欠账（vendored 的视口与
      // 正文节点），见下面那条 `skip` 的用例与 docs/a11y.md。
    });
  }

  // ⚠️ `testWidgets` 的 `skip` 只收 bool（不像 `test` 能吃理由字符串），
  // 所以理由写进**用例名**——它在输出里以 skipped 出现，看得见，不是假装绿。
  // 编辑器已清账（2026-09-17）：选择手势层走补丁 17，"点末尾空白"那块无名可点区
  // 走应用侧 `excludeFromSemantics`。于是这条从"账本"转正成**棘轮**（回归即红）。
  testWidgets('块编辑器的可点目标都有标签', (WidgetTester tester) async {
    final Note note = store.create();
    final handle = tester.ensureSemantics();
    final _Audit a = await _audit(
      tester,
      store: store,
      settings: settings,
      dataDir: tempDir.path,
      brightness: Brightness.light,
      background: AppTheme.contentCanvas(Brightness.light),
      child: NoteEditorViewAppFlowy(noteId: note.id),
      surface: '块编辑器[ 浅色 · 棘轮待激活 ]',
      settle: true,
    );
    handle.dispose();

    expect(a.labeled, isTrue, reason: '编辑器里仍有无标签的可点目标');
  });
}

// ─── 盘点执行 ──────────────────────────────────────────────────────────────

/// 桌面口径的点击目标（官方无 Windows 预设，见文件头）。
const Size _desktopTapTarget = Size(24, 24);

/// 一次盘点的结论：三条检查器是否通过 + 语义规模（后者专门用来暴露假阴性）。
class _Audit {
  const _Audit({
    required this.labeled,
    required this.contrast,
    required this.tap,
    required this.labeledWidgets,
    required this.textWidgets,
  });

  /// `labeledTapTargetGuideline`：可点目标都有 label 或 tooltip。
  final bool labeled;

  /// `textContrastGuideline`：文字对比度达 WCAG。
  final bool contrast;

  /// `MinimumTapTargetGuideline(24×24)`：可点目标够大。
  final bool tap;

  /// 能匹配到语义标签的部件数（近似指标）。
  final int labeledWidgets;

  /// `Text` 部件数——自绘文字（`TextPainter`）不计，故画布应为 0。
  final int textWidgets;
}

final List<String> _failures = <String>[];

/// 挂载一个界面 → 跑三个检查器 → 打印报告 → 返回结论。
Future<_Audit> _audit(
  WidgetTester tester, {
  required NoteStore store,
  required SettingsStore settings,
  required String dataDir,
  required Brightness brightness,
  required Color background,
  required Widget child,
  required String surface,
  bool settle = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        noteStoreProvider.overrideWithValue(store),
        settingsStoreProvider.overrideWithValue(settings),
        appDataDirProvider.overrideWithValue(dataDir),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
        home: Scaffold(backgroundColor: background, body: child),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // 画布/标题栏有防抖定时器与自绘层，`pumpAndSettle` 可能等不到静止。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  final Object? mountError = tester.takeException();
  final List<String> lines = <String>['\n──── a11y 盘点 · $surface ────'];
  if (mountError != null) {
    lines.add('  ⚠️ 挂载期间有异常（结论可能不完整）：$mountError');
  }
  final int labeledWidgets =
      find.bySemanticsLabel(RegExp(r'.+')).evaluate().length;
  final int textWidgets = find.byType(Text).evaluate().length;
  lines.add('  ℹ️ 有标签部件 $labeledWidgets 个 · Text 部件 $textWidgets 个');

  final Map<String, bool> passed = <String, bool>{};
  for (final (String key, AccessibilityGuideline g) in <(
    String,
    AccessibilityGuideline,
  )>[
    ('labeled', labeledTapTargetGuideline),
    ('contrast', textContrastGuideline),
    ('tap', const MinimumTapTargetGuideline(
      size: _desktopTapTarget,
      link: 'WCAG 2.2 SC 2.5.8 Target Size (Minimum)',
    )),
  ]) {
    try {
      final Evaluation r = await g.evaluate(tester);
      passed[key] = r.passed;
      if (r.passed) {
        lines.add('  ✅ ${g.description}');
      } else {
        _failures.add('$surface · ${g.description}');
        lines.add('  ❌ ${g.description}\n      ${_clip(r.reason ?? '（无说明）')}');
      }
    } on Object catch (e) {
      // 检查器自己炸了（如某控件无法离屏渲染）——也算一条信息，不是 UI 结论。
      passed[key] = false;
      lines.add('  ⚠️ ${g.description} — 检查器自身失败：$e');
    }
  }
  debugPrint(lines.join('\n'));

  return _Audit(
    labeled: passed['labeled'] ?? false,
    contrast: passed['contrast'] ?? false,
    tap: passed['tap'] ?? false,
    labeledWidgets: labeledWidgets,
    textWidgets: textWidgets,
  );
}

/// 违规清单可能很长（逐节点列出），截断到可读长度。
String _clip(String text, {int maxLines = 12, int maxChars = 1000}) {
  final List<String> lines = text.split('\n');
  final String head = lines.take(maxLines).join('\n');
  final String out =
      head.length > maxChars ? '${head.substring(0, maxChars)}…' : head;
  return lines.length > maxLines || head.length > maxChars
      ? '$out\n      ……（原文共 ${lines.length} 行，此处截断）'
      : out;
}

String _summary() {
  final StringBuffer b = StringBuffer('\n════ a11y 盘点汇总 ════');
  if (_failures.isEmpty) {
    b.write('\n  无违规（注意：画布的"通过"是假阴性，见 docs/a11y.md）');
  } else {
    b.write('\n  仍红 ${_failures.length} 条：');
    for (final String f in _failures) {
      b.write('\n  · $f');
    }
  }
  b.write('\n（硬门槛 = 断言；欠账 = skip 标记；盲区 = 语义规模守卫）\n');
  return b.toString();
}
