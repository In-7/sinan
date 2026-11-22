import 'dart:async' show unawaited;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/pending_saves.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/domain/settings.dart';
import 'package:sinan/src/editor/blocks/custom_block_components.dart';
import 'package:sinan/src/editor/core/note_document_adapter.dart';
import 'package:sinan/src/notes/note_editor_view_appflowy.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// 图片缩放手感（2026-11-22，补丁 26）：
/// - 宽度夹在 [80, 正文列宽] 之间（不再能拖成一条缝、也不能撑破排版）；
/// - 默认宽度用**正文列宽**而不是屏幕宽；
/// - 右键「恢复原始大小」清掉宽/高属性后，画面要真的回退（`didUpdateWidget`）。
void main() {
  const String img = 'data:image/png;base64,iVBORw0KGgo=';

  Future<EditorState> pumpEditor(
    WidgetTester tester, {
    num? width,
    num? height,
  }) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final Map<String, Object> attrs = <String, Object>{
      ImageBlockKeys.url: img,
      ImageBlockKeys.width: ?width,
      ImageBlockKeys.height: ?height,
    };
    final String content = NoteDocumentAdapter.storedContentFromDocument(
      Document(
        root: pageNode(children: <Node>[
          paragraphNode(text: '开头'),
          Node(type: ImageBlockKeys.type, attributes: attrs),
          paragraphNode(text: '结尾'),
        ]),
      ),
    );
    final Note note = Note(
      id: 'n1',
      kind: NoteKind.note,
      title: '缩放',
      content: content,
      plainText: '开头 结尾',
      summary: '',
      contentHash: 'h',
      createdAt: DateTime(2026),
      revisedAt: DateTime(2026),
    );
    final Database db = sqlite3.openInMemory();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);
    final NoteStore store = NoteStore(db);
    await store.restore(note);
    final _FakeNotes notes = _FakeNotes(<Note>[note]);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        notesProvider.overrideWith(() => notes),
        settingsProvider.overrideWith(_FakeSettings.new),
        noteStoreProvider.overrideWithValue(store),
        pendingSavesProvider.overrideWithValue(PendingSaves()),
      ],
    );
    await container.read(notesProvider.future);
    addTearDown(container.dispose);
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            ...GlobalMaterialLocalizations.delegates,
            AppFlowyEditorLocalizations.delegate,
          ],
          supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
          home: const Scaffold(body: NoteEditorViewAppFlowy(noteId: 'n1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
  }

  /// 图片**像素**的实际渲染宽度：`ResizableImage` 里那个 `SizedBox` 的宽度。
  ///
  /// 不能用 `find.byType(Image)`（假图源解码失败会被 errorBuilder 换掉、量到 0），
  /// 也不能用语义节点（它包着撑满整列宽的 `Align`，恒等于列宽）。
  double imageBlockWidth(WidgetTester tester) {
    final Finder box = find
        .descendant(
          of: find.byType(ResizableImage),
          matching: find.byType(SizedBox),
        )
        .first;
    return tester.getSize(box).width;
  }

  testWidgets('IntrinsicWidth 下能布局（块拖拽反馈回归，2026-11-22 真机崩溃）', (
    tester,
  ) async {
    // 块的拖拽反馈（`_buildFeedback`）用 IntrinsicWidth + IntrinsicHeight 重建
    // 整块。图片块内部若用 LayoutBuilder 测量宽度，这里就会抛
    // "LayoutBuilder does not support returning intrinsic dimensions"。
    final List<String> layoutErrors = <String>[];
    final void Function(FlutterErrorDetails)? previous = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      layoutErrors.add(details.exceptionAsString());
    };
    addTearDown(() => FlutterError.onError = previous);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: IntrinsicWidth(
              child: IntrinsicHeight(
                child: ResizableImage(
                  src: img,
                  width: 300,
                  editable: true,
                  alignment: Alignment.center,
                  maxWidth: 600,
                  onResize: (double _) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      layoutErrors.where((String e) => e.contains('intrinsic')),
      isEmpty,
      reason: '图片块不得在 intrinsic 查询路径上抛错（不能用 LayoutBuilder 测量）',
    );
  });

  testWidgets('超宽的已存 width 会被夹回列宽（不再撑破排版）', (tester) async {
    await pumpEditor(tester, width: 5000);
    final double imageWidth = imageBlockWidth(tester);
    final double editorW = tester.getSize(find.byType(AppFlowyEditor)).width;
    expect(imageWidth, greaterThan(0), reason: '前置：图片应已渲染出宽度');
    expect(imageWidth, lessThanOrEqualTo(editorW),
        reason: '5000px 的宽度应被钳制，不能超过编辑器宽度');
  });

  testWidgets('默认（无 width 属性）按正文列宽铺满', (tester) async {
    await pumpEditor(tester);
    final double imageWidth = imageBlockWidth(tester);
    final double editorW = tester.getSize(find.byType(AppFlowyEditor)).width;
    expect(imageWidth, greaterThan(editorW * 0.5),
        reason: '默认宽度应接近列宽（不是 0、也不是屏幕宽溢出）');
    expect(imageWidth, lessThanOrEqualTo(editorW));
  });

  testWidgets('未选中时没有把手；选中后框与把手同时出现', (tester) async {
    final EditorState state = await pumpEditor(tester, width: 300, height: 200);

    Finder resizeHandles() => find.byWidgetPredicate(
      (Widget w) =>
          w is MouseRegion && w.cursor == SystemMouseCursors.resizeLeftRight,
    );

    // 未选中：没有把手（2026-11-23 用户定：把手跟"选中"绑定，说明"可缩放"）。
    expect(resizeHandles(), findsNothing);

    final Node image = state.document.root.children
        .where((Node n) => n.type == ImageBlockKeys.type)
        .single;
    unawaited(
      state.updateSelectionWithReason(
        Selection.collapsed(Position(path: image.path)),
        reason: SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();

    expect(resizeHandles(), findsNWidgets(2), reason: '选中后两侧各一条把手');
    // 选中框：描边贴在图片像素外沿（补丁 25）。
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border != null,
      ),
      findsWidgets,
      reason: '选中时应有描边',
    );
  });

  testWidgets('缩放把手的视觉条是短条（44），热区仍是全高', (tester) async {
    // 指定 height：假图源不会真的解码，不指定的话块高为 0、Stack 塌陷。
    final EditorState state = await pumpEditor(tester, width: 300, height: 200);

    // 把手只在**选中**时出现（2026-11-23 用户定）⇒ 把选区放到图片块上。
    final Node image = state.document.root.children
        .where((Node n) => n.type == ImageBlockKeys.type)
        .single;
    unawaited(
      state.updateSelectionWithReason(
        Selection.collapsed(Position(path: image.path)),
        reason: SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();

    final Finder handles = find.byWidgetPredicate(
      (Widget w) =>
          w is MouseRegion && w.cursor == SystemMouseCursors.resizeLeftRight,
    );
    final Finder bars = find.descendant(
      of: handles,
      matching: find.byType(Container),
    );
    expect(bars, findsNWidgets(2), reason: '两侧各一条视觉条');
    expect(tester.getSize(bars.first).height, 44,
        reason: '视觉条是短条（全高会被读成图片边框，2026-11-23 用户定）');
    // 热区全高：远高于视觉条。
    expect(tester.getSize(handles.first).height, greaterThan(44),
        reason: '热区保持全高（沿边缘任意位置都能抓）');
  });

  testWidgets('缩放把手在图片**外侧**（不压图片、且落在盒子内可命中）', (
    tester,
  ) async {
    final EditorState state = await pumpEditor(tester, width: 300);

    // 把手只在选中时出现 ⇒ 先选中图片。
    final Node image = state.document.root.children
        .where((Node n) => n.type == ImageBlockKeys.type)
        .single;
    unawaited(
      state.updateSelectionWithReason(
        Selection.collapsed(Position(path: image.path)),
        reason: SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();

    final Finder resizeHandles = find.byWidgetPredicate(
      (Widget w) =>
          w is MouseRegion && w.cursor == SystemMouseCursors.resizeLeftRight,
    );
    expect(resizeHandles, findsNWidgets(2), reason: '左右各一条把手');

    // ⚠️ `ResizableImage` 的 rect 是它的根 `Align`（撑满列宽），不是盒子；
    // 盒子是内部那个 `SizedBox`（宽 = 图片宽 + 16）。
    final Rect box = tester.getRect(
      find
          .descendant(
            of: find.byType(ResizableImage),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    final double imageLeft = box.left + 8; // 盒子两侧各留 8 给把手
    final Rect leftHandle = tester.getRect(resizeHandles.first);

    expect(leftHandle.left, closeTo(box.left, 0.5),
        reason: '左手柄贴着盒子左端（= 图片左外侧）');
    expect(leftHandle.right, lessThanOrEqualTo(imageLeft + 0.5),
        reason: '左手柄不得伸进图片像素内');
    expect(leftHandle.width, greaterThan(0), reason: '热区必须有宽度才可命中');
  });

  test('手柄垂直偏移：媒体块固定贴顶，文字块沿用首行对齐值', () {
    // e2e 定位手柄（hover 才挂载、还要量 MenuAnchor）在 widget 树里太脆，
    // 改为直接钉这条纯函数——它是"贴顶 vs 首行对齐"的唯一分叉点。
    expect(
      sinanBlockHandleTop(node: imageNode(url: img), textTop: 123),
      4,
      reason: '图片块（delta == null）必须固定贴顶，不能按块中心/首行算',
    );
    expect(
      sinanBlockHandleTop(node: paragraphNode(text: '正文'), textTop: 123),
      123,
      reason: '文字块仍用首行对齐算出的值',
    );
  });

  testWidgets('右键「恢复原始大小」清掉宽高属性，画面回落到列宽', (tester) async {
    final EditorState state = await pumpEditor(tester, width: 120);
    final Node image = state.document.root.children
        .where((Node n) => n.type == ImageBlockKeys.type)
        .single;
    // 前置：已存 120px（窄图）。
    final double narrow = imageBlockWidth(tester);

    // 选中图片 → 右键 → 点「恢复原始大小」。
    unawaited(
      state.updateSelectionWithReason(
        Selection.collapsed(Position(path: image.path)),
        reason: SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getCenter(find.bySemanticsLabel('图片').first),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('恢复原始大小'), findsOneWidget);

    await tester.tap(find.text('恢复原始大小'));
    await tester.pumpAndSettle();

    expect(image.attributes[ImageBlockKeys.width], isNull,
        reason: 'width 属性应被清成 null（回落默认）');
    final double restored = imageBlockWidth(tester);
    expect(restored, greaterThan(narrow),
        reason: '画面应真的变宽（didUpdateWidget 同步）');
  });
}

class _FakeNotes extends NotesNotifier {
  _FakeNotes(this.notes);
  final List<Note> notes;
  @override
  Future<List<Note>> build() async => notes;
}

class _FakeSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}
