import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/app/home_hub.dart';
import 'package:sinan/src/app/providers.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/note_store.dart';
import 'package:sinan/src/data/settings_store.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/focus_ring.dart';
import 'package:sqlite3/sqlite3.dart';

/// 主页骨架的回归（`docs/ui_rewrite_plan.md` §5.6 阶段 2）。
///
/// 钉的是"主页是什么"这四条结构性事实：
/// ① 未选中 = 主页（不是空面板）；② 卡片**都接了焦点环**（§5.2：主页卡片是新出现的
/// 自绘交互件，不能又变成只有鼠标能用）；③ 点卡片 = 走 `locateProvider`（§4 的唯一
/// 跳转通道）；④ **Bento 的主次**（2026-09-22）：大卡跨两列、同行的中卡顶对齐。
/// 内容细节（搜索 / 更多）属于下一步，不在本文件范围。
void main() {
  late Database db;
  late NoteStore notes;
  late SettingsStore settings;

  const String kDataDir = r'C:\Users\test\AppData\Roaming\sinan';

  setUp(() {
    db = sqlite3.openInMemory();
    AppDatabase.migrateForTesting(db);
    notes = NoteStore(db);
    settings = SettingsStore(db);
  });

  tearDown(() => db.close());

  ProviderContainer newContainer() => ProviderContainer(
    overrides: [
      noteStoreProvider.overrideWithValue(notes),
      settingsStoreProvider.overrideWithValue(settings),
      appDataDirProvider.overrideWithValue(kDataDir),
    ],
  );

  /// [noteCount] 条笔记先建好再挂主页（建笔记走 `notesProvider.notifier`，
  /// 与产品路径同源）。
  Future<ProviderContainer> pumpHub(
    WidgetTester tester, {
    int noteCount = 0,
  }) async {
    final ProviderContainer container = newContainer();
    for (int i = 0; i < noteCount; i++) {
      await container.read(notesProvider.notifier).createNote();
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: HomeHub()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('空库：不给空卡片，直接指路', (WidgetTester tester) async {
    await pumpHub(tester);

    expect(find.text('还没有笔记'), findsOneWidget);
    expect(find.text('新建第一条'), findsOneWidget);
    // 没有笔记 ⇒ 不渲染笔记卡片；但**新建入口仍在**（此时它是唯一有意义的事）⇒ 2 张卡。
    expect(
      find.byType(FocusRing),
      findsNWidgets(2),
      reason: '空库时不该有笔记卡片，但两个新建入口必须还在',
    );
  });

  testWidgets('有笔记：上次编辑的大卡 + 最近列表，卡片都接了焦点环', (WidgetTester tester) async {
    await pumpHub(tester, noteCount: 3);

    expect(find.text('上次编辑'), findsOneWidget);
    expect(find.text('最近编辑'), findsOneWidget);
    // 3 篇笔记（1 大卡 + 2 最近）+ 2 个新建入口 = 5 张卡，每张都要能键盘聚焦。
    expect(
      find.byType(FocusRing),
      findsNWidgets(5),
      reason: '主页卡片是新出现的自绘交互件 ⇒ 必须全部接进 Focus 树（§5.2）',
    );
  });

  testWidgets('点卡片进入该笔记：走 locateProvider（唯一跳转通道）', (WidgetTester tester) async {
    final ProviderContainer container = await pumpHub(tester, noteCount: 3);

    expect(container.read(selectedNoteIdProvider), isNull, reason: '主页 = 未选中');

    // 第 3 张卡（下标 2）= 最近列表里的一篇：0 是大卡，1..2 是最近，3/4 是新建。
    await tester.tap(find.byType(FocusRing).at(2));
    await tester.pumpAndSettle();

    final String? selected = container.read(selectedNoteIdProvider);
    expect(selected, isNotNull, reason: '点了卡片却没有选中笔记');
    expect(
      notes.allNotes().map((Note n) => n.id).toList(),
      contains(selected),
      reason: '选中的必须是库里真实存在的一篇',
    );
  });

  /// **Bento 的结构闸门**（2026-09-22）：尺寸有主次才是 Bento，等大小卡片堆不是。
  ///
  /// 钉两条，都是"布局一改就会立刻被抓到"的：
  /// ① 大卡**跨两列**（比中卡宽、也比中卡高）；
  /// ② 同一行的两张中卡**顶对齐**、第二张在**右列**——这条同时兜住"退回单列"
  ///    （`Wrap` 换行规则或被改成 `Column`）与"列宽算错"（间距没扣掉）。
  testWidgets('Bento：大卡跨两列，中卡两列同行顶对齐', (WidgetTester tester) async {
    // 4 篇 ⇒ 大卡 1 + 最近 3 + 新建 2；FocusRing 顺序 = 视觉顺序。
    await pumpHub(tester, noteCount: 4);

    final Rect hero = tester.getRect(find.byType(FocusRing).at(0));
    final Rect first = tester.getRect(find.byType(FocusRing).at(1));
    final Rect second = tester.getRect(find.byType(FocusRing).at(2));

    expect(
      hero.width,
      greaterThan(first.width),
      reason: '大卡没跨两列 ⇒ 退化成"等大小卡片堆"（2026-09-22 明确否决过那种观感）',
    );
    expect(
      hero.height,
      greaterThan(first.height),
      reason: '大卡不比中卡高 ⇒ 主次只剩宽度一条，读起来还是"一排卡片"',
    );
    expect(first.top, second.top, reason: '同一行的两张卡顶没对齐');
    expect(
      second.left,
      greaterThan(first.left),
      reason: '第二张没落到右列 —— 退回单列了，或列宽把间距算漏了',
    );
    expect(first.width, second.width, reason: '同一行的卡应当等宽');
  });

  test('回主页（`locateProvider.goHome`）：清空选中与待消费的跳转请求', () {
    final ProviderContainer container = newContainer();

    container.read(locateProvider.notifier).locate(noteId: 'x');
    expect(container.read(selectedNoteIdProvider), 'x');
    expect(container.read(locateProvider), isNotNull);

    container.read(locateProvider.notifier).goHome();
    expect(container.read(selectedNoteIdProvider), isNull);
    expect(container.read(locateProvider), isNull);
  });
}
