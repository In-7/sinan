import 'dart:async' show unawaited;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/pending_saves.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/domain/settings.dart';
import 'package:sinan/src/editor/core/note_document_adapter.dart';
import 'package:sinan/src/editor/widgets/editor_context_menu.dart';
import 'package:sinan/src/notes/note_editor_view_appflowy.dart';
import 'package:sinan/src/notes/services/note_image_preview.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sqlite3/sqlite3.dart' show Database, sqlite3;

/// P0 图片规划：把已写好的全屏灯箱接进当前 AppFlowy 编辑器。
///
/// 接线走 `blockWrapper`（零 vendored 补丁）：图片块双击 → [showNoteImagePreview]。
/// 本测试用真实编辑器 + 真实双击手势，钉三件事：
/// - 双击图片弹出灯箱（Dialog），且不是单击就弹；
/// - 灯箱内容来自被双击那张图的 src；
/// - Esc / 关闭按钮能收起灯箱，回到编辑器。
void main() {
  const String img = 'data:image/png;base64,iVBORw0KGgo=';

  Future<EditorState> pumpEditor(
    WidgetTester tester, {
    String imageSrc = img,
  }) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final String content = NoteDocumentAdapter.storedContentFromDocument(
      Document(
        root: pageNode(children: <Node>[
          paragraphNode(text: '开头'),
          imageNode(url: imageSrc, width: 500, height: 200),
          paragraphNode(text: '图片后面的一段'),
        ]),
      ),
    );
    final Note note = Note(
      id: 'n1',
      kind: NoteKind.note,
      title: '带图的笔记',
      content: content,
      plainText: '开头 图片后面的一段',
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
    addTearDown(container.dispose);
    await container.read(notesProvider.future);

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
          builder: (BuildContext context, Widget? child) =>
              // 灯箱 showDialog 来自官方 flutter/material，必须过桥才能读到
              // 官方 MaterialLocalizations（与 main.dart 同构）。
              // ignore: deprecated_member_use
              MaterialUiCompatibilityBridge(child: child!),
          home: const Scaffold(body: NoteEditorViewAppFlowy(noteId: 'n1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
  }

  testWidgets('单击图片不弹灯箱，双击才弹（Dialog 出现且可关闭）', (tester) async {
    await pumpEditor(tester);

    // 落点沿用图片右键测试的口径：getCenter(语义标签) + tapAt（直接发指针，
    // 绕开 tap() 的命中告警）——拦截器靠 getNodeInOffset 按几何找块，不要求
    // 指针正落在 Image 自身的渲染盒上。
    final Finder imageFinder = find.bySemanticsLabel('图片').first;
    expect(imageFinder, findsOneWidget, reason: '前置：图片块应有语义标签');
    final Offset center = tester.getCenter(imageFinder);
    expect(find.byType(Image), findsWidgets, reason: '前置：图片应已渲染');

    // ⚠️ 断言不能用 find.byType(Dialog)：测试 import 的 material_ui.Dialog 与
    // 灯箱 import 的官方 flutter/material.Dialog 是两套同名不同类型。改用
    // 灯箱工具栏恒定存在的 '100%' 文本（Text 是 widgets 层，跨包同型）。
    // 单击只应选中图片，不弹灯箱。
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsNothing, reason: '单击不该弹灯箱');

    // 双击才弹。
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget, reason: '双击图片应弹全屏灯箱');


    // Esc 收起，回到编辑器。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsNothing, reason: 'Esc 应收起灯箱');
  });

  testWidgets('图片右键菜单有「预览图片」，点它弹同一灯箱', (tester) async {
    final EditorState state = await pumpEditor(tester);
    final Node image = state.document.root.children
        .where((Node n) => n.type == ImageBlockKeys.type)
        .single;
    // 右键菜单的媒体块识别靠当前选区（与 image_context_menu_test 同口径）。
    unawaited(
      state.updateSelectionWithReason(
        Selection.collapsed(Position(path: image.path)),
        reason: SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();

    final Offset center = tester.getCenter(
      find.bySemanticsLabel('图片').first,
    );
    await tester.tapAt(center, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('预览图片'), findsOneWidget,
        reason: '图片右键菜单应有预览入口');
    expect(find.text('删除图片'), findsOneWidget);

    await tester.tap(find.text('预览图片'));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget, reason: '预览图片应弹全屏灯箱');
  });

  testWidgets('灯箱源解析：data: base64 / http / file:// / 纯路径都不抛', (tester) async {
    // 纯函数级覆盖 _decodeDataUri 的兜底（其余分支靠真实双击用例的 data: 路径）。
    // 通过弹出四种源的灯箱、确认不抛异常且 Dialog 恒在即可。
    for (final String source in <String>[
      img,
      'https://example.com/pic.png',
      'file:///D:/photos/pic.png',
      'D:/photos/pic.png',
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            ...GlobalMaterialLocalizations.delegates,
          ],
          // 官方 showDialog 需要官方 MaterialLocalizations（同 main.dart 桥）。
          builder: (BuildContext context, Widget? child) =>
              // ignore: deprecated_member_use
              MaterialUiCompatibilityBridge(child: child!),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => unawaited(showNoteImagePreview(context, source)),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsOneWidget, reason: '源 $source 应能弹灯箱');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
  });

  /// 右键菜单条目判定（本地源显示「复制图片」、网络源不显示）。
  Future<void> expectCopyItem(
    WidgetTester tester,
    String src,
    Matcher matcher,
  ) async {
    final EditorState state = await pumpEditor(tester, imageSrc: src);
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
    await tester.tapAt(
      tester.getCenter(find.bySemanticsLabel('图片').first),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('预览图片'), findsOneWidget);
    expect(find.text('复制图片'), matcher, reason: '源 $src');
  }

  testWidgets('图片右键：本地源有「复制图片」', (tester) async {
    await expectCopyItem(tester, 'D:/photos/pic.png', findsOneWidget);
  });

  test('复制图片：仅本地源出该项（网络图 / base64 都不显示）', () {
    expect(shouldShowCopyImageItem('D:/photos/pic.png'), isTrue);
    expect(shouldShowCopyImageItem('https://example.com/pic.png'), isFalse);
    expect(shouldShowCopyImageItem('data:image/png;base64,AAAA'), isFalse);
    expect(shouldShowCopyImageItem(''), isFalse);
  });

  testWidgets('新插入图片：叠 4s 把手引导后自消，存量图片不弹', (tester) async {
    final EditorState state = await pumpEditor(tester);
    // 存量图片（initState 已登记为已知）不该有引导。
    expect(find.text('拖动两侧把手调整宽度 · 双击放大'), findsNothing);

    // 通过事务插入一张新图 ⇒ 检测新 id ⇒ 弹引导。
    unawaited(
      state.apply(
        state.transaction..insertNode(
          [1],
          imageNode(url: img, width: 300, height: 100),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('拖动两侧把手调整宽度 · 双击放大'),
      findsOneWidget,
      reason: '新插入图片应弹把手引导',
    );

    // 4s 后自动消失。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('拖动两侧把手调整宽度 · 双击放大'), findsNothing);
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
