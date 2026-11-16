import 'dart:async';
import 'dart:ui' as ui;

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../canvas/canvas_thumbnail.dart';
import '../canvas/kernel/canvas_camera.dart';
import '../canvas/kernel/canvas_painters.dart';
import '../domain/note.dart';
import '../theme/app_custom_icons.dart';
import '../theme/app_icon_button.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/noise_texture.dart';
import '../theme/tokens.dart';
import 'note_display.dart';
import 'providers.dart';
import 'search_provider.dart';

/// 主页顶部的**视图切换**（2026-09-29 用户定，取代 Things 式单列一页纸）。
///
/// 五个视图各答一个问题，浏览时**正交于搜索框**（[searchNotifierProvider]）；
/// 一旦输入查询词，内容区统一切到**全局搜索结果态**（[_SearchResultsView]），
/// 与当前 tab 无关——搜索跨笔记/画布、覆盖日历（2026-09-30 用户定）。
/// - [HomeView.timeline]：**灵感**——按 `revisedAt` 分组的时间流（今天 /
///   昨天 / 本周…），**启动默认视图**且是 tab 行第一枚（2026-10-05 决策 C）。
/// - [HomeView.all]：**全部**——笔记 + 画布跨形态统一池，全局排序
///   （[homeSortProvider]）生效。默认排序就是"最近编辑在前"，看最近改过
///   什么直接看前几张卡即可（2026-09-29 用户定：不单设「最近」视图）。
/// - [HomeView.calendar]：**日记**——按 `createdAt` 回看当天新建的笔记 / 画布
///   （2026-11-14 用户定）。桌面壳是左 [CalendarListColumn]（240 月份网格）
///   + 右格恒为详情；选中日篇目在**左列**（列表行，与日期留白 12）；
///   「写日记」只写今天、只建笔记。
/// - [HomeView.favorites]：收藏（[Note.promotedAt] 非空），跨形态统一。
///
/// 📌 形态与视图的关系（2026-11-09 收口）：**笔记 / 画布自 2026-10-21 起就是
/// 独立视图**（布局同「全部」，见 [kHomeTabs]），在视图层已按 [NoteKind] 收池。
/// 漏斗钮里的「形态」facet 是在其上再筛一遍（笔记页选「画布」得空集），属重复
/// 控件 ⇒ 已撤。灵感 / 全部 / 日历 / 收藏仍不分形态。
///
/// ⚠️ **排序 / 标签都不是页面**：它们是全局控件，合住顶栏右侧一枚
/// 「筛选与排序」漏斗钮（[FilterMenuButton]：一个菜单、两段——排序 / 标签），
/// 对所有视图同时生效。
/// [HomeView] 的**图标**扩展。
///
/// 枚举本体在 `providers.dart`：统一导航历史（[NavHistoryNotifier]）要同时
/// 表达"主页视图"与"某篇笔记页"两种目的地，而它必须与 `locateProvider` 同住
/// （唯一获准写"当前笔记"的文件，见 architecture_test 的源码扫描）。图标要
/// 引用 tabler / [CustomIcons]，不进 DI 层，故留在这里。
extension HomeViewIcon on HomeView {
  /// 最左图标导航轨上的图标（全为 tabler 单色线形）。
  ///
  /// 描边统一用 [Tokens.iconStrokeRail]（1.25，2026-11-07 从全局 1.5 抽出），
  /// 与轨上的回收站 / 设置同粗细；本文件其余 tabler 图标仍用 1.5。
  Widget icon(Color color, {double size = Tokens.iconMdSm}) => switch (this) {
    // 灵感：`tabler.Bulb`（灯泡 = 点子，2026-11-06 用户定，替掉收件箱）。
    // 中间试过其它图标族，都与同排 tabler 的线宽、造型不齐，最终仍回到
    // tabler 家族，只换字形。
    HomeView.timeline => tabler.Bulb(
      height: size,
      width: size,
      strokeWidth: Tokens.iconStrokeRail,
      colorFilter: ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
    ),
    HomeView.all => tabler.LayoutGrid(
      height: size,
      width: size,
      strokeWidth: Tokens.iconStrokeRail,
      colorFilter: ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
    ),
    // 笔记：`tabler.Book2`（书本，2026-11-06 用户定，替掉 FileText）。
    // ⚠️ 搜索结果行 / 附件卡仍用 FileText，那两处是"一篇文档"的语义，不跟着改。
    HomeView.notes => tabler.Book2(
      height: size,
      width: size,
      strokeWidth: Tokens.iconStrokeRail,
      colorFilter: ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
    ),
    // 画布：`tabler.Swipe`（手势划动 = 白板操作，2026-11-06 用户定，替掉 Shape2）。
    // 中间试过其它图标族，均因线宽不齐回到 tabler 家族。
    HomeView.canvas => tabler.Swipe(
      height: size,
      width: size,
      strokeWidth: Tokens.iconStrokeRail,
      colorFilter: ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
    ),
    HomeView.calendar => tabler.Calendar(
      height: size,
      width: size,
      strokeWidth: Tokens.iconStrokeRail,
      colorFilter: ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
    ),
    HomeView.favorites => tabler.Star(
      height: size,
      width: size,
      strokeWidth: Tokens.iconStrokeRail,
      colorFilter: ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
    ),
  };
}

/// 最左图标导航轨的**常驻目的地**：**灵感 | 笔记 | 画布 | 日历**，灵感首位且为
/// 启动默认（与 [NavHistoryNotifier.build] 的默认值一致）。
///
/// 📌 2026-10-21 用户定，两步走：
/// 1. 笔记 / 画布**升为独立视图**（推翻 2026-10-05 决策 E 的"只做筛选"）：与
///    原来的「全部」同布局（主从 + 240 列表列），只是池子按类型收；
/// 2. 同日再定：**「全部」「收藏」撤出图标轨**——笔记 + 画布已覆盖「全部」的
///    内容，轨上不再堆冗余目的地。
///
/// ⚠️ 两枚枚举值本身**保留**：`HomeView.all` 仍是「从编辑器 / 画布页返回主页」
/// 的落点（`search_palette` 的兜底 + 搜索结果空态文案在用）；「收藏」页暂留
/// 代码（[Note.promotedAt] 语义未变），但**当前没有 UI 入口**。
const List<HomeView> kHomeTabs = <HomeView>[
  HomeView.timeline,
  HomeView.notes,
  HomeView.canvas,
  HomeView.calendar,
];

/// 卡片网格的**排序方案**（2026-09-29 用户定，在「更多」视图里选）。
///
/// 一旦选定，对**全部 / 笔记 / 画布 / 更多**四个视图同时生效（进编辑器再
/// 回来也
/// 保留，所以放 provider 而非 widget state）；收藏视图坚持按收藏时间倒序
/// （"最近收藏的排前面"是收藏视图自身的语义，不该被这里覆盖）。
enum NoteSort {
  /// 最近修改（默认）：`revisedAt` 倒序——最常回看的是"刚碰过的"。
  revised('最近编辑'),

  /// 最近创建：`createdAt` 倒序——日历之外的线性"新写的在前"。
  created('最近创建'),

  /// 标题 A–Z：按显示标题升序（空标题按「无标题」参与排序）。
  title('标题 A–Z');

  const NoteSort(this.label);

  /// 「更多」视图里排序 chip 的文字（测试锚点）。
  final String label;

  /// 比较器：返回传给 `List.sort` 的顺序（`true` = 升序语义）。
  Comparator<Note> get comparator => switch (this) {
    NoteSort.revised => (Note a, Note b) => b.revisedAt.compareTo(a.revisedAt),
    NoteSort.created => (Note a, Note b) => b.createdAt.compareTo(a.createdAt),
    // 统一转小写：英文标题不被大小写劈开；中文不受影响（按码点稳定排序）。
    NoteSort.title => (Note a, Note b) => _titleOf(
      a,
    ).toLowerCase().compareTo(_titleOf(b).toLowerCase()),
  };
}

/// 主页当前的排序方案。默认 [NoteSort.revised]。
final homeSortProvider = NotifierProvider<HomeSortNotifier, NoteSort>(
  HomeSortNotifier.new,
);

class HomeSortNotifier extends Notifier<NoteSort> {
  @override
  NoteSort build() => NoteSort.revised;

  void select(NoteSort sort) => state = sort;
}

// ── 日历「日记」视图的选择与数据口径（2026-11-14 布局改造） ──────────────

/// 日历浏览态：显示哪一月、选中哪一天。
///
/// 2026-11-14 从 [_CalendarPageState] 的私有 State 提为 provider：日期面板
/// 移到左侧列表列后，「左列点日期」与「右内容显示篇目」成了两棵独立子树，
/// 必须共享同一份选择，否则点左边右边不动。
///
/// **不落盘**（沿用原「纯浏览节奏」语义）：重启回今天、切走再回来也回今天。
final calendarSelectionProvider =
    NotifierProvider<CalendarSelectionNotifier, CalendarSelection>(
      CalendarSelectionNotifier.new,
    );

typedef CalendarSelection = ({DateTime month, DateTime selected});

class CalendarSelectionNotifier extends Notifier<CalendarSelection> {
  @override
  CalendarSelection build() {
    final DateTime now = DateTime.now();
    return (
      month: DateTime(now.year, now.month),
      selected: DateTime(now.year, now.month, now.day),
    );
  }

  /// 切月：**选中日跟着移到新月的同一天**（clamp 到月末）。
  /// 标题现在是「M月D日」，不能只换月份却留着上个月的选中日，否则标题、
  /// 网格选中格、右内容区三者会脱节（2026-11-14 用户定标题带日期）。
  void pickMonth(DateTime m) {
    final int daysInMonth = DateTime(m.year, m.month + 1, 0).day;
    final int day = state.selected.day > daysInMonth
        ? daysInMonth
        : state.selected.day;
    state = (
      month: DateTime(m.year, m.month),
      selected: DateTime(m.year, m.month, day),
    );
  }

  void pickDay(DateTime d) =>
      state = (month: DateTime(d.year, d.month), selected: _calDayKey(d));

  /// 月份头「回到今天」：月份与选中日一起回今天。
  void goToday() {
    final DateTime now = DateTime.now();
    state = (
      month: DateTime(now.year, now.month),
      selected: DateTime(now.year, now.month, now.day),
    );
  }
}

/// 日历的**唯一数据口径**：按 `createdAt`（新建日期）归组，组内新建倒序。
///
/// 笔记与画布**混排、不过滤 kind** —— 日历是「日记」，只问"这天新建了什么"，
/// 不问"后来改没改"（2026-11-14 用户定）。左列的篇数小圆点与右内容的篇目卡
/// 都从这里取，口径单点，不会左右漂移。
///
/// ⚠️ 不要改成 `revisedAt`，也不要接 [homeSortProvider] / `activeTag`：
/// 那会把日记变成"最近编辑"，用户明确否掉了。
final calendarDaysProvider = Provider<Map<DateTime, List<Note>>>((Ref ref) {
  final List<Note> all = ref.watch(notesProvider).value ?? const <Note>[];
  final Map<DateTime, List<Note>> byDay = <DateTime, List<Note>>{};
  for (final Note n in all) {
    byDay.putIfAbsent(_calDayKey(n.createdAt), () => <Note>[]).add(n);
  }
  for (final List<Note> list in byDay.values) {
    list.sort((Note a, Note b) => b.createdAt.compareTo(a.createdAt));
  }
  return byDay;
});

/// 日期归一化键（去时间，本地时区）。日历列与归组都用它。
DateTime _calDayKey(DateTime d) => DateTime(d.year, d.month, d.day);

/// [homeItemsProvider] 的入参（record：结构相等即命中缓存）。
///
/// 2026-11-09 撤掉 `kind`：形态由 [HomeView.notes] / [HomeView.canvas]
/// 在视图层收池，再带一个恒为 all 的 facet 只是死参数。
typedef HomeItemsArgs = ({HomeView view, String? tag});

/// 主页卡片网格的取数：**视图范围 + 标签过滤 + 排序**（2026-09-30 从
/// `_HomeBody._itemsFor` 抽出）。
///
/// 为什么做成 provider 而不是 build 里现算：这是**记忆化**的结果——只有
/// 笔记快照 / 排序方案 / 视图 / 标签四者之一变化才重算；窗口 resize、
/// 胶囊 hover 等无关 rebuild 再触发 build，`ref.watch` 拿回的是**同一个
/// List 实例**，不再每次 O(n log n) 全量重排。family 参数用 record，
/// 结构相等自动复用；autoDispose 让每个条目随最后一个监听者释放。
///
/// 收藏视图不读全局排序，坚持"最近收藏在前"（收藏视图自身的语义）。
final homeItemsProvider = Provider.autoDispose
    .family<List<Note>, HomeItemsArgs>((Ref ref, HomeItemsArgs args) {
      final List<Note> all = ref.watch(notesProvider).value ?? const <Note>[];
      final Comparator<Note> order = ref.watch(homeSortProvider).comparator;
      final List<Note> scope = switch (args.view) {
        // 灵感**不读笔记池**：它是独立表 `stream_items`，由
        // `StreamView` 自行渲染。这里给空列表是"此视图没有笔记项"的诚实回答——
        // 绝不能让谁把文库里的笔记塞进灵感页（单向契约）。
        HomeView.timeline => const <Note>[],
        // 全部：跨形态统一池，跟随全局排序。
        HomeView.all => all.toList()..sort(order),
        // 笔记 / 画布（2026-10-21 用户定升为视图）：在**视图层**就按类型收池，
        // 全局排序照走。形态不再另设 facet（2026-11-09 撤）。
        HomeView.notes =>
          all.where((Note n) => n.kind != NoteKind.canvas).toList()
            ..sort(order),
        HomeView.canvas =>
          all.where((Note n) => n.kind == NoteKind.canvas).toList()
            ..sort(order),
        // 收藏不读全局排序：最近收藏的排前面。
        HomeView.favorites => <Note>[
          ...all.where((Note n) => n.promotedAt != null),
        ]..sort((Note a, Note b) => b.promotedAt!.compareTo(a.promotedAt!)),
        HomeView.calendar => const <Note>[],
      };
      // 标签筛选是顶栏全局控件 ⇒ 对当前视图生效；未选标签时原样返回。
      // 有搜索词时不走这里（搜索态由 _SearchResultsView 跨形态渲染）。
      return args.tag == null
          ? scope
          : scope.where((Note n) => n.tags.contains(args.tag)).toList();
    });

/// 超过该体积的画布 content 才把解析丢到后台 Isolate（[compute]）。
///
/// 画布 JSON 内联**全部笔迹点**（一页几千条笔迹时 content 可达数 MB），整串
/// jsonDecode 会在 UI 线程阻塞数帧；但轻画布（绝大多数）解析是亚毫秒级，
/// Isolate 往返反而更慢。故按字节数分档：阈值取 128KB（约合 1–2 万点）。
const int _kThumbnailIsolateBytes = 128 * 1024;

/// 单篇画布的**缩略图快照**（懒取 + autoDispose 缓存，键 = noteId）。
///
/// 列表快照刻意不背画布正文（JSON 可能很大）；网格里每张可见的画布卡各取
/// 一次，划走即释放。监听该笔记的 `contentHash`：保存后哈希一变，本 family
/// 条目自动作废重取，无需手动失效。
///
/// ## 两条取数路径（2026-10-01）
/// 1. **关系表快路径**（闸门通过时）：直接从 `canvas_items` 逆投影取几何，
///    不读 MB 级 `notes.content`（笔迹点全在里面）、不做全文 jsonDecode、
///    不需要 Isolate——纯笔迹重画布（0 个 item）也命中、直接落水印。
/// 2. **降落伞**（闸门缺失 / 哈希不符 / 行数不符）：读 content 全文解析；
///    超过 128KB 走后台 Isolate。任何行落后于 content 的状态都单向退回旧路径，
///    缩略图正确性不因影子表而回退。
final canvasThumbnailProvider = FutureProvider.autoDispose
    .family<CanvasThumbnail?, String>((Ref ref, String noteId) async {
      // 依赖锚点：该笔记 contentHash 变化（保存 / 撤销）即自动作废重取；
      // select 只锚这一条，其余笔记变动不重建本卡。快路径也正是拿这个哈希
      // 与 srcfp 闸门比对。
      ref.watch(
        notesProvider.select((AsyncValue<List<Note>> v) {
          for (final Note n in v.value ?? const <Note>[]) {
            if (n.id == noteId) return n.contentHash;
          }
          return null;
        }),
      );
      // 类型留作推断：home_hub 不经白名单不能直接 import data/（架构边界），
      // 具体 store 类型经 app/providers 的 noteStoreProvider 传入即可。
      final noteStore = ref.read(noteStoreProvider);

      // ① 关系表快路径：行 ⇄ content 由 srcfp 闸门（hash + item 行数）担保。
      final List<Map<String, dynamic>>? rowItems = noteStore
          .canvasThumbnailItemJson(noteId);
      if (rowItems != null) {
        final CanvasThumbnail? thumb = thumbnailFromItemJson(rowItems);
        if (thumb != null) ref.onDispose(thumb.dispose);
        return thumb;
      }

      // ② 降落伞：读 content 全文。重画布（笔迹点多）后台解析，避免 jsonDecode
      // 卡住 UI 帧；轻画布同步解析。产物是纯数据对象图（fromJson 不解码图片、
      // 不建 TextPainter），可安全跨 Isolate 回传。
      final String content = noteStore.canvasContentOf(noteId);
      final CanvasThumbnail? thumb = content.length > _kThumbnailIsolateBytes
          ? await compute(parseCanvasThumbnail, content)
          : parseCanvasThumbnail(content);
      if (thumb != null) ref.onDispose(thumb.dispose);
      return thumb;
    });

/// **日历页**（原名 `HomeHub`，2026-10-17 改名）。
///
/// ## 现在的职责（2026-11-14 收口）
/// **桌面外壳不再挂载本页**：日历已并入主从布局（左 [CalendarListColumn] +
/// 右格恒为详情），由 [HomeScreen] 直接分发。
///
/// 本页保留为**独立挂载 / 测试用**的整卡形态（月份卡在上、选中日篇目在下），
/// 不带筛选与搜索。内容区按 `view` 分发的网格兜底同理，桌面壳不走它们。
///
/// ## 三条结构事实
/// 1. **顶栏**：只剩一枚靠右的漏斗钮 [FilterMenuButton]（排序 / 标签合住）。
///    视图切换 + 新建胶囊在最左 **60 图标轨** [AppIconRail]；上一步 / 下一步在
///    标题栏左簇（与全局键 `Alt+←/→` 同走命令层）。
/// 2. **内容区按视图 + 搜索词解析**（[homeItemsProvider]）：搜索词在**当前
///    视图范围内**过滤（日历视图忽略搜索）；命中渲染成 [_CardsGrid]。
/// 3. **卡片** [_NoteCard] 用现成卡片三件套（[AppTheme.cardFill] / [cardStroke] /
///    [cardFillHover]）——静止态**有底色**（与列表行的"显式透明"相反：卡片本就
///    该是一块浮起的板子）。每张接 [FocusRing]（§5.2 键盘可达）。
/// 日历「写日记」**只落今天、只新建笔记**（2026-11-14 用户定）。
/// 画布不走这个入口，但日记页会照常显示当天新建的画布结果。
void _createDiaryToday(WidgetRef ref) {
  unawaited(() async {
    final Note n = await ref.read(notesProvider.notifier).createNote();
    ref.read(locateProvider.notifier).locate(noteId: n.id, focus: true);
  }());
}

/// **日历左列**（240 宽，2026-11-14 用户定）：日期面板搬到笔记列表列的位置，
/// 同样尺寸、同样可折叠，但内容是月份网格而不是笔记行。
///
/// 不复用 [NoteListColumn]——它写死了搜索 / 筛选 / 新建分半钮与笔记行数据源，
/// 而日历页「筛选和搜索都不需要」。这里只复用日历自己的单元格与写日记入口。
///
/// **骨架与 [NoteListColumn] 同构**（2026-11-14 用户定）：① 工具行留 36 高
/// 给悬浮折叠钮让位 ② 标题行（「M月D日」+ 回到今天 + 切月）与「笔记 12」同位
/// ③ 发丝 ④ 内容区（月份网格 + 12 留白 + 选中日篇目）。
/// 📌 **整列同底**（2026-11-16 用户定，回退 11-14 的「内容区另铺 surface」）：
/// 颜色与标题头统一，左列读作一张卡；不再卡中卡挤窄 7 列。
/// padding 12 ⇒ 216 可用宽，每格 ≈30.9。
class CalendarListColumn extends ConsumerWidget {
  const CalendarListColumn({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final CalendarSelection sel = ref.watch(calendarSelectionProvider);
    final Map<DateTime, List<Note>> byDay = ref.watch(calendarDaysProvider);
    final List<Note> dayNotes =
        byDay[_calDayKey(sel.selected)] ?? const <Note>[];
    final DateTime today = _calDayKey(DateTime.now());

    final DateTime first = DateTime(sel.month.year, sel.month.month);
    final int daysInMonth = DateTime(
      sel.month.year,
      sel.month.month + 1,
      0,
    ).day;
    final int leading = (first.weekday + 6) % 7; // 周一起始
    final int rowCount = ((leading + daysInMonth) / 7).ceil();

    final List<Widget> grid = <Widget>[];
    int day = 1 - leading;
    for (int r = 0; r < rowCount; r++) {
      final List<Widget> cells = <Widget>[];
      for (int c = 0; c < 7; c++, day++) {
        final DateTime d = DateTime(sel.month.year, sel.month.month, day);
        final bool inMonth = d.month == sel.month.month;
        cells.add(
          Expanded(
            child: _CalCell(
              date: d,
              inMonth: inMonth,
              isToday: d == today,
              isSelected: d == _calDayKey(sel.selected),
              hasEntry: inMonth && (byDay[_calDayKey(d)]?.isNotEmpty ?? false),
              onTap: inMonth
                  ? () =>
                        ref.read(calendarSelectionProvider.notifier).pickDay(d)
                  : null,
            ),
          ),
        );
      }
      grid.add(SizedBox(height: 36, child: Row(children: cells)));
    }

    // ⚠️ 标题行**不放篇数**（2026-11-14 用户实报「10 月 54」被读成日期）。
    // 本月新建数在网格绿点 + 右内容区「新建 N 篇」里已经表达，标题只写月份。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // ① 工具行：日历没有工具钮，但**必须把悬浮折叠钮的位置空出来**
        //   （[NoteListColumn] 同高 36 = 上 4 + 热区 28 + 下 4）。
        const SizedBox(height: 36),
        // ② 标题行：与 [NoteListColumn] 第二行**同位**（左 12、行高 20）
        //   ⇒ 月份文字和「笔记 12」落在同一条基线上。
        // 📌 bottom = [Tokens.spaceSm](8)，与 [NoteListColumn] 第二行同值
        //（2026-11-15 加回，当时为容纳热区 28 临时减到 0）。
        // padding 必须在 [SizedBox] **外面**：否则 20 高会被 8 的内距压成 12，
        // 文字挤变形。加在行外 ⇒ 标题文字的 y 不动。
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Tokens.spaceMd,
            0,
            Tokens.spaceSm,
            Tokens.spaceSm,
          ),
          child: SizedBox(
            height: 20,
            child: _CompactMonthHeader(
              month: sel.month,
              today: today,
              selected: sel.selected,
            ),
          ),
        ),
        // ③ 头部 ↔ 内容区发丝：与笔记列同款结构线（2026-11-16 起淡一档）。
        Container(height: 1, color: Bauhaus.dividerSoft(theme.brightness)),
        // ④ 内容区**与标题头同底**（2026-11-16 用户定，回退 11-14 的底色区分）：
        //   不再铺 [Bauhaus.surface]，左列整列读作一张卡，颜色和标题头统一。
        //   通栏 padding 12 ⇒ 网格仍占 216 可用宽（每格 ≈30.9）。
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(Tokens.spaceMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    for (final String s in const <String>[
                      '一',
                      '二',
                      '三',
                      '四',
                      '五',
                      '六',
                      '日',
                    ])
                      Expanded(
                        child: Center(
                          child: Text(
                            s,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Bauhaus.inkMuted(scheme.brightness),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: Tokens.spaceXs),
                AnimatedSwitcher(
                  duration: Tokens.durationFast,
                  child: KeyedSubtree(
                    key: ValueKey<DateTime>(first),
                    child: SizedBox(
                      width: double.infinity,
                      height: 36 * 6,
                      child: Column(children: grid),
                    ),
                  ),
                ),
                Container(
                  height: 1,
                  color: Bauhaus.dividerSoft(theme.brightness),
                ),
                const SizedBox(height: Tokens.spaceXs),
                _DiaryEntryButton(
                  day: today,
                  onTap: () => _createDiaryToday(ref),
                  compact: true,
                ),
                // ⑤ 日期 ↔ 篇目**留白 12**（2026-11-14 用户定）：不加发丝、
                //    也不放「新建 N 篇」小标题——列表本身就是确数，用户不需要
                //    再读一遍数字。只用空白把两段分开。
                const SizedBox(height: Tokens.spaceMd),
                // ⑥ 选中日篇目：从右格搬进左列，外观与笔记列表行一致。
                //    笔记 / 画布混排，点开走唯一跳转通道。
                Expanded(
                  child: dayNotes.isEmpty
                      ? Align(
                          alignment: Alignment.topLeft,
                          child: Text(
                            '这天没有新建内容',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Bauhaus.inkMuted(theme.brightness),
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: dayNotes.length,
                          itemBuilder: (BuildContext _, int i) => Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: CalendarDayRow(
                              note: dayNotes[i],
                              onTap: () => ref
                                  .read(locateProvider.notifier)
                                  .locate(noteId: dayNotes[i].id),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 日历列**标题行**专用的紧凑月份头（高 20，与 [NoteListColumn] 第二行同位）。
/// 左：**「M月D日」**（2026-11-14 用户定，跟随当前显示的月份与选中日）；
/// 右：「回到今天」（只要不在今天就出现）+ 切月两枚 20 方钮。
///
/// 复用不了 28 圆的 [_CalNavButton]——标题行只有 20 高，会把行撑高、把标题
/// 从「笔记 12」那条基线上挤下去。
class _CompactMonthHeader extends ConsumerWidget {
  const _CompactMonthHeader({
    required this.month,
    required this.today,
    required this.selected,
  });

  final DateTime month;
  final DateTime today;
  final DateTime selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.colorScheme.brightness;
    final bool atCurrentMonth =
        month.year == today.year && month.month == today.month;
    // 「回到今天」显示条件：**不在今天就显示**（2026-11-14 用户定）。
    // 旧条件只看月份 ⇒ 本月里点了别的一天，按钮就消失，想回今天只能手动
    // 再点一次日期。goToday() 同时拨回月份与选中日，入口该随时可用。
    final bool showGoToday = !atCurrentMonth || _calDayKey(selected) != today;
    final CalendarSelectionNotifier notifier = ref.read(
      calendarSelectionProvider.notifier,
    );

    Widget chevron(Widget icon, String tip, int delta) => _CalTinyButton(
      icon: icon,
      tooltip: tip,
      onTap: () =>
          notifier.pickMonth(DateTime(month.year, month.month + delta)),
    );
    ui.ColorFilter inkFilter() =>
        ui.ColorFilter.mode(Bauhaus.inkMuted(b), ui.BlendMode.srcIn);

    return Row(
      children: <Widget>[
        Text(
          '${month.month}月${selected.day}日',
          style: theme.textTheme.titleSmall?.copyWith(color: Bauhaus.ink(b)),
        ),
        const Spacer(),
        if (showGoToday) ...<Widget>[
          _CalTinyButton(label: '回到今天', onTap: notifier.goToday),
          const SizedBox(width: Tokens.spaceXs),
        ],
        chevron(
          tabler.ChevronLeft(
            height: Tokens.iconXs + 4,
            width: Tokens.iconXs + 4,
            strokeWidth: Tokens.iconStroke,
            colorFilter: inkFilter(),
          ),
          '上个月',
          -1,
        ),
        const SizedBox(width: Tokens.spaceXs),
        chevron(
          tabler.ChevronRight(
            height: Tokens.iconXs + 4,
            width: Tokens.iconXs + 4,
            strokeWidth: Tokens.iconStroke,
            colorFilter: inkFilter(),
          ),
          '下个月',
          1,
        ),
      ],
    );
  }
}

/// 日历标题行的小按钮（切月 ‹ › / 回到今天）：圆角方形，**静止透明**。
///
/// 2026-11-16 用户定（两步走完）：先加常驻底求"一眼可点"，实机又觉得重，
/// 最终收敛为**边框常显 + 背景色只在悬浮时出现**——1px [Bauhaus.hairline]
/// 边框给可点提示，hover 叠 [AppTheme.hoverOverlay]、按下再深一档；无投影。
///
/// 📌 圆角 [Tokens.radiusXxs](4)：20×20 里用 10（[radiusSm]）是**半宽 = 正圆**，
/// 读不出"方形"。项目 tokens 分了档——4px 是「<24px 的方件」，10px 属 ≥24 控件。
class _CalTinyButton extends StatefulWidget {
  const _CalTinyButton({
    this.icon,
    this.label,
    this.tooltip,
    required this.onTap,
  });

  /// 图标钮（20×20）与文字钮（自适应宽）二选一。
  final Widget? icon;
  final String? label;
  final String? tooltip;
  final VoidCallback onTap;

  @override
  State<_CalTinyButton> createState() => _CalTinyButtonState();
}

class _CalTinyButtonState extends State<_CalTinyButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    final bool isIcon = widget.icon != null;

    Widget button = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (mounted) setState(() => _hover = true);
      },
      onExit: (_) {
        if (mounted) setState(() => _hover = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          if (mounted) setState(() => _pressed = true);
        },
        onTapUp: (_) {
          if (mounted) setState(() => _pressed = false);
        },
        onTapCancel: () {
          if (mounted) setState(() => _pressed = false);
        },
        onTap: widget.onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            // 2026-11-16 用户定：**常态底色去掉**，只留悬浮触发。
            // hairline 边框保留作可点提示（它是边框不是背景色）。
            color: Colors.transparent,
            border: Bauhaus.hairline(b),
            borderRadius: BorderRadius.circular(Tokens.radiusXxs),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _pressed
                  ? theme.colorScheme.onSurface.withValues(alpha: 0.10)
                  : _hover
                  ? AppTheme.hoverOverlay(b)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(Tokens.radiusXxs),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isIcon ? 0 : Tokens.spaceXs,
              ),
              child: Center(
                child: isIcon
                    ? widget.icon
                    : Text(
                        widget.label!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Bauhaus.inkMuted(b),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }
    return button;
  }
}

/// 日历左列「选中日篇目」的**列表行**（2026-11-14 用户定）。
///
/// 外观**照抄 [NoteListColumn] 的 `_NoteRow`**：内缩 4 的圆角块、内距 8/12、
/// 标题 `bodyMedium w600` + 摘要 `bodySmall` 两行、hover 叠 `hoverOverlay`、
/// 行首不放 kind 图标（项目 2026-10-21 定）。画布只在标题**末尾**补一枚小角标，
/// 因为日历是笔记 / 画布混排，需要一点点辨识度，且不占行首、不动左缘。
class CalendarDayRow extends StatefulWidget {
  const CalendarDayRow({super.key, required this.note, required this.onTap});

  final Note note;
  final VoidCallback onTap;

  @override
  State<CalendarDayRow> createState() => _CalendarDayRowState();
}

class _CalendarDayRowState extends State<CalendarDayRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    final Note n = widget.note;
    final bool isCanvas = n.kind == NoteKind.canvas;
    final String title = noteDisplayTitle(n);
    final String summary = n.summary.trim();
    final TextStyle titleStyle =
        theme.textTheme.bodyMedium?.copyWith(
          color: Bauhaus.ink(b),
          fontWeight: FontWeight.w600,
        ) ??
        const TextStyle();
    final TextStyle summaryStyle =
        theme.textTheme.bodySmall?.copyWith(color: Bauhaus.inkMuted(b)) ??
        const TextStyle();

    return MouseRegion(
      onEnter: (_) {
        if (mounted) setState(() => _hover = true);
      },
      onExit: (_) {
        if (mounted) setState(() => _hover = false);
      },
      child: Semantics(
        button: true,
        label: title,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: Tokens.spaceXs),
            padding: const EdgeInsets.symmetric(
              horizontal: Tokens.spaceMd - Tokens.spaceXs,
              vertical: Tokens.spaceMd,
            ),
            decoration: BoxDecoration(
              color: _hover ? AppTheme.hoverOverlay(b) : Colors.transparent,
              borderRadius: Bauhaus.radius,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: titleStyle,
                            ),
                          ),
                          if (isCanvas) ...<Widget>[
                            const SizedBox(width: Tokens.spaceXs),
                            CustomIcons.canvas(size: Tokens.iconXs + 4),
                          ],
                        ],
                      ),
                      if (summary.isNotEmpty) ...<Widget>[
                        const SizedBox(height: Tokens.spaceXxs),
                        Text(
                          summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: summaryStyle,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

/// 2026-11-14 起桌面壳不再走本页：日历已并入主从布局（左 [CalendarListColumn]
/// + 右格恒为详情）。本页保留为**独立挂载 / 测试用**的整卡形态
/// （月份卡在上、选中日篇目在下），不再带顶栏漏斗、也不吃全局搜索态——
/// 日历页「筛选和搜索都不需要」（用户定），且漏斗管的排序 / 标签对按
/// `createdAt` 归组的日记本来就不生效，是个假控件。
class _CalendarPageState extends ConsumerState<CalendarPage> {
  @override
  Widget build(BuildContext context) {
    final HomeView view = ref.watch(navHistoryProvider).view;
    final CalendarSelection sel = ref.watch(calendarSelectionProvider);
    final CalendarSelectionNotifier notifier = ref.read(
      calendarSelectionProvider.notifier,
    );

    return _HomeBody(
      view: view,
      calMonth: sel.month,
      calSelected: sel.selected,
      onPickMonth: notifier.pickMonth,
      onPickDay: notifier.pickDay,
    );
  }
}

/// 「最近」不单设视图（2026-09-29 用户定）：「全部」默认按最近编辑排序，
/// 看最近动过什么直接看前几张卡即可。
///
/// 内容区：按 [view] 分发——日历走网格，其余走卡片网格（取数口径见
/// [homeItemsProvider]）。
class _HomeBody extends ConsumerWidget {
  const _HomeBody({
    required this.view,
    required this.calMonth,
    required this.calSelected,
    required this.onPickMonth,
    required this.onPickDay,
  });

  final HomeView view;
  final DateTime calMonth;
  final DateTime calSelected;
  final ValueChanged<DateTime> onPickMonth;
  final ValueChanged<DateTime> onPickDay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 2026-11-14 撤掉「全局搜索态覆盖日历」：日历是日记界面，不需要搜索；
    // Ctrl+K 全局搜索浮层是独立 Overlay，不走这里。这里只留 activeTag 给
    // 独立挂载时的「全部 / 收藏」兜底空态用。
    final SearchState search = ref.watch(searchNotifierProvider);

    // ⚠️ 灵感**不由本页渲染**：它是独立的一页纸时间流，由外壳
    // `HomeScreen` 直接挂 `StreamView`（2026-10-17 修：此前挂在这里，而桌面壳
    // 改走主从布局后这条分支再也没被走到 —— 表现为"改了界面没变化"）。
    // 本页在桌面上只承担「日历」（以及单独挂载时的网格 / 搜索兜底）。

    // 日历视图：日历卡片 + 卡片外下方的选中日篇目。
    if (view == HomeView.calendar) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          Tokens.spaceLg,
          0,
          Tokens.spaceLg,
          Tokens.spaceLg,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: _CalendarView(
              month: calMonth,
              selected: calSelected,
              onPickMonth: onPickMonth,
              onPickDay: onPickDay,
              onOpenNote: (Note n) =>
                  ref.read(locateProvider.notifier).locate(noteId: n.id),
              onCreateToday: () => _createDiaryToday(ref),
            ),
          ),
        ),
      );
    }

    // 其余视图：卡片网格。取数走 [homeItemsProvider]（记忆化：无关 rebuild
    // 不重排；语义见 provider 文档）。
    final List<Note> items = ref.watch(
      homeItemsProvider((view: view, tag: search.activeTag)),
    );

    if (items.isEmpty) {
      return Column(
        children: <Widget>[
          Expanded(
            child: _EmptyView(
              view: view,
              hasQuery: false,
              query: '',
              activeTag: search.activeTag,
            ),
          ),
        ],
      );
    }

    return Column(
      children: <Widget>[
        Expanded(
          child: _CardsGrid(
            items: items,
            onOpen: (Note n) =>
                ref.read(locateProvider.notifier).locate(noteId: n.id),
            onUnfavorite: view == HomeView.favorites
                ? (Note n) => ref.read(notesProvider.notifier).togglePromoted(n)
                : null,
          ),
        ),
      ],
    );
  }
}

/// **全局搜索结果态**（2026-09-30 用户定）：顶栏一输入，内容区统一切到这里——
/// 与当前 tab 无关（**跨笔记/画布、覆盖日历**），命中顺序就是检索相关度
/// （[SearchNotifier] 已按"标题命中置顶 → RRF 分"排好）。
///
/// 卡片拿到了检索产出的 **snippet**（命中块文本）：摘要位显示它并高亮查询
/// 词，而不是默认的正文前三行——全局检索最贵的产出不再被渲染层丢掉。
/// 📌 2026-11-14 桌面壳不再内联渲染搜索结果（日历不要搜索、`Ctrl+K` 走独立
/// Overlay 浮层）。保留此 public 组件给将来的独立挂载 / 兜底复用。
class SearchResultsView extends ConsumerWidget {
  const SearchResultsView({super.key, required this.search});

  final SearchState search;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<SearchHit> hits = search.hits;
    final String query = search.query.trim();
    final bool keywordOnly = search.vectorFallbackReason != null;

    // 空结果分两种：检索还在途（去抖/语义路 HTTP）⇒ 转圈；已完成 ⇒ 空态文案。
    if (hits.isEmpty) {
      return Column(
        children: <Widget>[
          _SearchResultBar(
            count: 0,
            searching: search.searching,
            keywordOnly: keywordOnly,
          ),
          Expanded(
            child: search.searching
                ? const Center(
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _EmptyView(
                    view: HomeView.all,
                    hasQuery: true,
                    query: query,
                    activeTag: null,
                  ),
          ),
        ],
      );
    }

    final Map<String, SearchHit> hitOf = <String, SearchHit>{
      for (final SearchHit h in hits) h.note.id: h,
    };
    return Column(
      children: <Widget>[
        _SearchResultBar(
          count: hits.length,
          searching: search.searching,
          keywordOnly: keywordOnly,
        ),
        Expanded(
          child: _CardsGrid(
            items: <Note>[for (final SearchHit h in hits) h.note],
            onOpen: (Note n) =>
                ref.read(locateProvider.notifier).locate(noteId: n.id),
            hitsById: hitOf,
            highlightQuery: query,
          ),
        ),
      ],
    );
  }
}

/// 搜索结果上方的一条**状态细栏**：左侧计数（在途 ⇒ "正在搜索…"），右侧在
/// 语义路缺席时弱提示"关键词检索"（6.4：降级是提示不是错误）。
class _SearchResultBar extends StatelessWidget {
  const _SearchResultBar({
    required this.count,
    required this.searching,
    required this.keywordOnly,
  });

  final int count;
  final bool searching;
  final bool keywordOnly;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.spaceLg,
        Tokens.spaceXs,
        Tokens.spaceLg,
        0,
      ),
      child: Row(
        children: <Widget>[
          Text(
            searching ? '正在搜索…' : '$count 条结果',
            style: theme.textTheme.labelMedium?.copyWith(
              color: Bauhaus.inkMuted(scheme.brightness),
            ),
          ),
          const Spacer(),
          if (keywordOnly)
            Text(
              '关键词检索',
              style: theme.textTheme.labelSmall?.copyWith(
                color: Bauhaus.inkMuted(scheme.brightness)
                    .withValues(alpha: 0.65),
              ),
            ),
        ],
      ),
    );
  }
}

/// 顶栏**筛选器**控件钮（2026-09-30 用户定）：排序方案（[homeSortProvider]）
/// 与标签筛选（[SearchState.activeTag]）同属"整理当前池子"的元操作，合住一枚
/// 漏斗钮、一个菜单——上半段排序、下半段标签。对 [kHomeTabs]
/// 所有视图全局生效（收藏的排序语义除外，见 [_CalendarPageState]）。
///
/// 2026-11-09 撤掉「形态」段：笔记 / 画布已是独立视图、在取数层按类型收池，
/// 面板里再选一次是重复控件（选错还得空集）。
///
/// 标签段在全库无标签时**整段消失**，但钮本身常驻（排序永远可用，
/// 2026-09-30 之前排序 / 标签是两枚钮，无标签时只剩排序，用户找不到入口）。
///
/// 2026-10-26 用户定**功能钮零状态**：点击直接开菜单，图标恒定色、任何
/// 交互态不变色——"列表正被筛着"由菜单内勾选（`tabler.Check`）表达，
/// 不再图标转蓝（顺带回归 monochrome 定稿：唯一蓝只在焦点环）。
///
/// 同日：宿主改为 [AppIconButton]（与列表头三枚同一件），图标统一 Fluent 漏斗
/// ⇒ **字形与色源单点**，那条"默认 tabler 不吃 Material IconTheme、要走
/// AppIconTheme 桥"的旁路随之消失。
///
/// 📌 2026-11-14 日历页不再带漏斗 ⇒ 生产调用点只剩列表栏第二行（`size: 20`）；
/// 默认 28 供独立挂载 / 测试壳使用。
class FilterMenuButton extends ConsumerStatefulWidget {
  const FilterMenuButton({super.key, this.size = Tokens.headerActionSize});

  /// 热区边长。默认 28（独立挂载 / 测试壳）；日历页顶栏漏斗 2026-11-14 已撤。
  ///
  /// 列表栏「视图名 + 篇数」行传 **20**：那行的行高由本钮决定，28 会把标题行
  /// 撑高、文字垂直居中下沉 5px（2026-11-09 用户实报"折叠钮与笔记的间距变大"）。
  final double size;

  @override
  ConsumerState<FilterMenuButton> createState() => _FilterMenuButtonState();
}

class _FilterMenuButtonState extends ConsumerState<FilterMenuButton> {
  /// 菜单锚点（GlobalKey）：不挂的话 position 落 Offset.zero ⇒ 菜单弹到
  /// 屏幕左上角（全仓统一教训）。
  final GlobalKey _key = GlobalKey();

  Future<void> _openMenu() async {
    final NoteSort currentSort = ref.read(homeSortProvider);
    final List<(String, int)> tags = ref.read(allTagsProvider);
    final String? activeTag = ref.read(searchNotifierProvider).activeTag;

    // **锚点矩形**（Flutter 官方 PopupMenu 口径，别再手算零宽度点）：
    // 此前用 `RelativeRect.fromLTRB(dx, dy, dx, dy)`（锚点 = 按钮左下角的
    // 零宽度矩形）⇒ 菜单只从按钮左缘**向右**展开；按钮靠近窗口右缘时会被
    // 框架"吸"到屏幕边缘，菜单整体甩到按钮右边很远（用户实测"面板离搜索
    // 按钮很远"）。改成按钮相对屏幕的**四边缘矩形**后，框架按 left/right
    // 哪边空间大自动决定展开方向——2026-11-09 工具行重排后漏斗钮在右簇中段
    // （新建在最右），左右余量由框架自行判断，同样成立。
    //
    // ⚠️ 坐标必须用**全局坐标**（plain localToGlobal，不传 ancestor）：
    // 本应用菜单走 material_ui 的 Navigator，其 overlay renderBox 不是这个
    // 按钮的祖先，传 `localToGlobal(ancestor: overlay)` 会做跨坐标系换算，
    // 实测得到 8~40px 的垃圾偏移；而 overlay 全屏铺在 (0,0)，全局坐标即
    // overlay 坐标（项目内其他 showMenu 也全是这个口径）。
    final RenderBox? box =
        _key.currentContext?.findRenderObject() as RenderBox?;
    final Size screen = MediaQuery.sizeOf(context);
    RelativeRect position = RelativeRect.fill;
    if (box != null) {
      final Offset topLeftGlobal = box.localToGlobal(Offset.zero);
      final Offset bottomRightGlobal = box.localToGlobal(
        box.size.bottomRight(Offset.zero),
      );
      position = RelativeRect.fromLTRB(
        topLeftGlobal.dx,
        bottomRightGlobal.dy,
        screen.width - bottomRightGlobal.dx,
        screen.height - bottomRightGlobal.dy,
      );
    }

    await showMenu<void>(
      context: context,
      position: position,
      // 2026-11-09：形态段已撤——笔记 / 画布本身已是独立视图，再筛一遍重复。
      items: <PopupMenuEntry<void>>[
        _menuHeader('排序'),
        for (final NoteSort s in NoteSort.values)
          PopupMenuItem<void>(
            onTap: () => ref.read(homeSortProvider.notifier).select(s),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(s.label),
                if (s == currentSort) ...<Widget>[
                  const SizedBox(width: Tokens.spaceSm),
                  const tabler.Check(
                    height: Tokens.iconMdSm,
                    width: Tokens.iconMdSm,
                    strokeWidth: Tokens.iconStroke,
                  ),
                ],
              ],
            ),
          ),
        if (tags.isNotEmpty) ...<PopupMenuEntry<void>>[
          const PopupMenuDivider(),
          _menuHeader('标签'),
          // 有选中标签时先给一枚显式的"清除"（否则只能再点同一枚取消）。
          if (activeTag != null)
            PopupMenuItem<void>(
              onTap: () =>
                  ref.read(searchNotifierProvider.notifier).selectTag(null),
              child: const Text('全部标签（清除筛选）'),
            ),
          for (final (String tag, int count) in tags)
            PopupMenuItem<void>(
              // 点已选中的标签 = 取消（沿用旧 chips 的 toggle 语义）。
              onTap: () => ref
                  .read(searchNotifierProvider.notifier)
                  .selectTag(tag == activeTag ? null : tag),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(tag),
                  const SizedBox(width: Tokens.spaceXs),
                  Text('$count', style: Theme.of(context).textTheme.labelSmall),
                  if (tag == activeTag) ...<Widget>[
                    const SizedBox(width: Tokens.spaceSm),
                    const tabler.Check(
                      height: Tokens.iconMdSm,
                      width: Tokens.iconMdSm,
                      strokeWidth: Tokens.iconStroke,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ],
    );
  }

  /// 菜单里的**分段标题**（不可点、不响应 hover）：PopupMenuItem 没有
  /// header 变体，用 `enabled: false` 落一个弱化的 labelSmall。
  PopupMenuEntry<void> _menuHeader(String text) => PopupMenuItem<void>(
    enabled: false,
    height: 28,
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Bauhaus.inkMuted(Theme.of(context).colorScheme.brightness),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // ⚠️ 锚点 key 挂在 **32×32 外壳**上，不能挂 IconButton：material_ui 的
    // M3 IconButton 外层包了 48×48 的点击热区（_InputPadding），元素根
    // RenderBox 是热区而非可视按钮（实测落在按钮左下方，菜单因此整体
    // 错位 8~40px）。外壳尺寸与位置就是可视按钮的真实矩形。
    return SizedBox(
      key: _key,
      // 尺寸由调用点给（见 [FilterMenuButton.size]）：列表栏 20、hub 顶栏 28。
      //
      // ⚠️ 20 是热区下限：`AppIconButton` 的圆角是 `radiusButton`(10)，宽 20 时
      // 半径 = 半宽 ⇒ hover 底由"圆角方块"变**正圆**。漏斗图形实测只占 12.4px，
      // 不会被圆角切到；但若实机觉得圆底与第一行钮形态不一致，改 24（沉 3px）
      // 即可，圆角方块会回来。
      width: widget.size,
      height: widget.size,
      child: AppIconButton(
        size: widget.size,
        // 两处调用点同一枚 Fluent 漏斗；色由 [AppIconButton] 单点下发
        // ——不再有"默认 tabler 走另一条取色链路"的旁支。
        //
        // 2026-11-09 **光学补偿**：漏斗是宽扁形，bbox 只占 24 画板的 68.75%，
        // 18 框下视觉仅 ≈12.4px（搜索 ≈14.1 / 新建 ≈15.5），实机显小。提到
        // [Tokens.iconMdSm](20) ⇒ 视觉 ≈13.8px，与同排基本齐；代价是线宽
        // 1.125→1.25px（+11%，肉眼几乎无感）。⚠️ 别改用 Transform / FittedBox
        // 缩放：那是缩放已栅格化层，会糊。
        icon: CustomIcons.filter(size: Tokens.iconMdSm),
        tooltip: '筛选与排序',
        onPressed: _openMenu,
      ),
    );
  }
}

/// 卡片网格：随窗口宽度自动增删列（[SliverGridDelegateWithMaxCrossAxisExtent]，
/// 无写死列数）。
///
/// 两种用法：`Expanded` 里自己滚（主页各视图，默认）；`shrinkWrap: true`
/// 收缩成内容高、交给外层滚动体（日历选中日的篇目，2026-09-29 用户定：
/// 篇目也从列表行改成卡片，与其余视图同语言）。
class _CardsGrid extends StatelessWidget {
  const _CardsGrid({
    required this.items,
    required this.onOpen,
    this.onUnfavorite,
    this.hitsById,
    this.highlightQuery,
    this.shrinkWrap = false,
    this.padding = const EdgeInsets.fromLTRB(
      Tokens.spaceLg,
      Tokens.spaceXs,
      Tokens.spaceLg,
      Tokens.spaceLg,
    ),
  });

  final List<Note> items;
  final ValueChanged<Note> onOpen;

  /// 收藏视图传入：卡片右上出一枚实心星，点它就地取消收藏。其余视图传 `null`。
  final ValueChanged<Note>? onUnfavorite;

  /// 搜索结果态传入：noteId → 命中信息（含 snippet）。卡片摘要位改用命中
  /// 片段，标题/片段高亮 [highlightQuery]。浏览态传 `null`。
  final Map<String, SearchHit>? hitsById;

  /// 搜索结果态的查询词（用于高亮）；浏览态为 `null`。
  final String? highlightQuery;

  /// `true` = 高度收到内容（嵌在外层滚动体里用），并把滚动让给外层。
  final bool shrinkWrap;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: padding,
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        // 2026-10-01 用户定：每行 **5** 个、加大留白（取代 2026-09-30 的
        // 每行 6 个/间距 12——6 块白砖阵列在空白卡多时显挤）。列数公式仍是
        // ceil((可用宽−间距)/(extent+间距))，264/间距 20 按默认 1340 窗宽
        // （网格可用 ≈1302）反解：ceil((1302−20)/284) = 5、每块 ≈244×203；
        // 逻辑窗宽到 ≈1440 才自动升 6 列，720 最小窗宽仍降 3 列（≈216×180），
        // 更大显示器才会到 6–7 列——**列数随窗宽自适应，绝不硬挤**。
        // （256/20 是错档：升 6 列临界只有 ≈1400，默认窗稍拖宽就破 5 列。）
        maxCrossAxisExtent: 264,
        // 2026-10-01 用户定：**6:5 矮卡**（宽/高 = 1.2）取代正方形——5 列后
        // 248 见方偏高、纵向信息密度低；244×203 与最小窗 216×180 都仍高于
        // 卡内容下限（标题+4 行摘要+底行 ≈145），摘要行数不变，空白变少。
        childAspectRatio: 1.2,
        // 间距收编为 [Tokens.cardGridSpacing]（8pt 网格化后 = 24）。
        crossAxisSpacing: Tokens.cardGridSpacing,
        mainAxisSpacing: Tokens.cardGridSpacing,
      ),
      itemCount: items.length,
      itemBuilder: (BuildContext _, int i) => _NoteCard(
        // key 钉在 noteId：搜索过滤 / 切视图时列表内容变，Element 复用会让
        // 卡片的 hover 态串到别的卡上（无 key 的 GridView 经典坑）。
        key: ValueKey<String>('note-card-${items[i].id}'),
        note: items[i],
        onOpen: () => onOpen(items[i]),
        onUnfavorite: onUnfavorite == null
            ? null
            : () => onUnfavorite!(items[i]),
        hit: hitsById?[items[i].id],
        highlightQuery: highlightQuery,
      ),
    );
  }
}

/// 一张**笔记卡片**（2026-10-01 起为 6:5 矮卡，默认窗宽每行 5 个）。
/// 两种形态同尺寸、同标题/底行语言，中段不同：
/// - 笔记：标题 + 摘要（≤3 行）+ 标签 + 相对时间；
/// - 画布：**几何缩略图**（[_CanvasThumbnail]，真实 item 几何 fit 绘制）
///   + 标题 + 标签 + 相对时间，标题仍带 [CustomIcons.canvas] 角标。
///
/// 用现成卡片三件套（[AppTheme.cardFill] / [cardStroke] / [cardFillHover]）——
/// 静止态**有底色**（与列表行"显式透明"相反：卡片是一块浮起的板子，透明就没了
/// 卡片的样子）。
class _NoteCard extends StatefulWidget {
  const _NoteCard({
    super.key,
    required this.note,
    required this.onOpen,
    this.onUnfavorite,
    this.hit,
    this.highlightQuery,
  });

  final Note note;
  final VoidCallback onOpen;
  final VoidCallback? onUnfavorite;

  /// 搜索结果态的命中信息（null = 浏览态）：非空时摘要位优先显示
  /// [SearchHit.snippet]（命中块文本）。
  final SearchHit? hit;

  /// 查询词；非空时标题与摘要里的命中词披主题色（搜索结果态）。
  final String? highlightQuery;

  @override
  State<_NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends State<_NoteCard> {
  final FocusNode _focus = FocusNode();
  bool _hover = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Brightness brightness = theme.brightness;
    final BorderRadius radius = BorderRadius.circular(Tokens.radiusMd);
    final Note n = widget.note;
    final bool isCanvas = n.kind == NoteKind.canvas;

    final String title = noteDisplayTitle(n);
    final String? summary = _cardSummaryOf(n);
    // 标题是不是借来的（无标题但正文非空）：借了且没余行 ⇒ 中段留白即可；
    // 不是借的又没摘要（真空白 / 有标题无正文）⇒「（空白）」兜底。
    final bool borrowedTitle = n.title.trim().isEmpty && title != '无标题';
    final List<String> tags = n.tags;

    // 搜索结果态：摘要位优先放**命中块片段**（压空白，同 answer_service 的
    // 口径）；仅标题命中（snippet 空）时退回普通摘要。浏览态 hit 为 null，
    // 一切照旧。
    final String? rawSnippet = widget.hit?.snippet?.trim();
    final String? snippet = (rawSnippet == null || rawSnippet.isEmpty)
        ? null
        : rawSnippet.replaceAll(RegExp(r'\s+'), ' ').trim();
    final String? displaySummary = snippet ?? summary;
    final String? highlight = widget.highlightQuery;

    return FocusRing(
      focusNode: _focus,
      borderRadius: radius,
      child: Material(
        // 包豪斯扁平卡：白面 + 1.5px 墨硬边；hover = 墨 6% 浅覆（单色——唯一蓝只给
        // 「新建」胶囊描边，卡片不再用蓝）。
        color: _hover
            ? Color.alphaBlend(
                Bauhaus.hover(brightness),
                Bauhaus.surface(brightness),
              )
            : Bauhaus.surface(brightness),
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          focusNode: _focus,
          borderRadius: radius,
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          onHover: (bool v) => setState(() => _hover = v),
          onTap: widget.onOpen,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Bauhaus.cardBorder(brightness),
            ),
            padding: const EdgeInsets.all(Tokens.spaceMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (isCanvas) ...<Widget>[
                  // 画布卡：**上图下文**——缩略图吃余高，下方标题 + meta 行，
                  // 与笔记卡同尺寸、同标题/底行语言，只是中段从文字换成画面。
                  Expanded(child: _CanvasThumbnail(noteId: n.id)),
                  const SizedBox(height: Tokens.spaceSm),
                  _titleRow(
                    context,
                    theme,
                    scheme,
                    isCanvas: true,
                    title: title,
                    highlight: highlight,
                  ),
                  const SizedBox(height: Tokens.spaceSm),
                  _metaRow(theme, scheme, n, tags),
                ] else ...<Widget>[
                  _titleRow(
                    context,
                    theme,
                    scheme,
                    isCanvas: false,
                    title: title,
                    highlight: highlight,
                  ),
                  const SizedBox(height: Tokens.spaceSm),
                  // 摘要：搜索态 = 命中块片段（命中词高亮）；浏览态 = ≤3 行
                  // 真实正文（无标题笔记的标题借走了首行，摘要从余下行起，不
                  // 重复）。6:5 矮卡（默认 203 高）下 3 行 + Expanded 吃余高，
                  // 短笔记的空白落在摘要与底行之间，像便签留白而非坏版。
                  // 标题不是借的又没有正文时才落「（空白）」；借了标题但没余行的，
                  // 中段留白即可——假斜体填充比空白更吵。
                  Expanded(
                    child: displaySummary != null
                        ? _matchRich(
                            displaySummary,
                            query: highlight,
                            base:
                                theme.textTheme.bodySmall?.copyWith(
                                  color: Bauhaus.inkMuted(scheme.brightness),
                                ) ??
                                const TextStyle(),
                            matchColor: Bauhaus.blue(scheme.brightness),
                            maxLines: 3,
                          )
                        : borrowedTitle
                        ? const SizedBox.shrink()
                        : Text(
                            '（空白）',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Bauhaus.inkMuted(scheme.brightness)
                                  .withValues(alpha: 0.6),
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                  ),
                  const SizedBox(height: Tokens.spaceSm),
                  _metaRow(theme, scheme, n, tags),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 标题行：左 = 形态角标（仅画布）+ 标题，右 = 取消收藏星（仅收藏视图）。
  /// 笔记卡与画布卡共用，保证两种形态标题语言一致。
  Widget _titleRow(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme, {
    required bool isCanvas,
    required String title,
    required String? highlight,
  }) {
    return Row(
      children: <Widget>[
        if (isCanvas) ...<Widget>[
          CustomIcons.canvas(size: Tokens.iconXs + 4),
          const SizedBox(width: Tokens.spaceXs),
        ],
        Expanded(
          child: _matchRich(
            title,
            query: highlight,
            base:
                theme.textTheme.titleSmall?.copyWith(
                  color: Bauhaus.ink(scheme.brightness),
                  fontWeight: FontWeight.w600,
                ) ??
                const TextStyle(),
            matchColor: Bauhaus.blue(scheme.brightness),
            maxLines: 1,
          ),
        ),
        if (widget.onUnfavorite != null) ...<Widget>[
          const SizedBox(width: Tokens.spaceXs),
          SizedBox(
            width: 24,
            height: 24,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: '取消收藏',
              icon: tabler.StarFilled(
                height: Tokens.iconSm,
                width: Tokens.iconSm,
                strokeWidth: Tokens.iconStroke,
                colorFilter: ui.ColorFilter.mode(
                  Bauhaus.inkMuted(scheme.brightness),
                  ui.BlendMode.srcIn,
                ),
              ),
              onPressed: widget.onUnfavorite,
            ),
          ),
        ],
      ],
    );
  }

  /// 底行：标签（最多 3 枚 + `+n`）+ 右对齐相对时间。
  Widget _metaRow(
    ThemeData theme,
    ColorScheme scheme,
    Note n,
    List<String> tags,
  ) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Wrap(
            spacing: Tokens.spaceXs,
            runSpacing: Tokens.spaceXs,
            children: <Widget>[
              for (final String t in tags.take(3)) _CardTag(label: t),
              if (tags.length > 3) _CardTag(label: '+${tags.length - 3}'),
            ],
          ),
        ),
        const SizedBox(width: Tokens.spaceSm),
        Text(
          relativeTime(n.revisedAt),
          style: theme.textTheme.labelSmall?.copyWith(
            color: Bauhaus.inkMuted(scheme.brightness),
          ),
        ),
      ],
    );
  }
}

/// 画布卡的**几何缩略图**：懒读 [canvasThumbnailProvider]，用内核现成的
/// [ItemPainter] + 一台 fit 到内容包围盒的相机绘制（不画笔迹、不解码图片）。
///
/// 三态：解析中 / 空画布 ⇒ 淡形状图标水印居中（卡片永远不留白成"坏卡"）；
/// 有 item ⇒ 全量 item 几何 fit 绘制。
class _CanvasThumbnail extends ConsumerWidget {
  const _CanvasThumbnail({required this.noteId});

  final String noteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final CanvasThumbnail? thumb = ref
        .watch(canvasThumbnailProvider(noteId))
        .value;

    // 衬编辑器同源纸面色（AppTheme.contentCanvas）：缩略图是"画布的俯视
    // 小图"而非卡面上的裸线条——暗色主题下用户画的黑墨在深纸面上才可见，
    // 也与笔记卡文字区形成材质区分。圆角 Sm 收在卡片 padding 内。
    final BorderRadius previewRadius = BorderRadius.circular(Tokens.radiusSm);
    final Widget watermark = Center(
      child: tabler.Shape2(
        height: Tokens.iconXl,
        width: Tokens.iconXl,
        strokeWidth: Tokens.iconStroke,
        colorFilter: ui.ColorFilter.mode(
          Bauhaus.inkMuted(scheme.brightness).withValues(alpha: 0.28),
          ui.BlendMode.srcIn,
        ),
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.contentCanvas(theme.brightness),
        borderRadius: previewRadius,
      ),
      child: ClipRRect(
        borderRadius: previewRadius,
        child: thumb == null
            ? watermark
            // 每帧按当前尺寸现造相机：缩略图不响应交互，没有相机状态要维护，
            // fit 是纯算术，比监听 resize 存状态更省。
            : LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final CanvasCamera camera = CanvasCamera()
                    ..fit(thumb.bounds, constraints.biggest, padding: 6);
                  return CustomPaint(
                    size: constraints.biggest,
                    painter: ItemPainter(
                      camera: camera,
                      items: thumb.items,
                      inkColor: AppTheme.canvasInk(theme.brightness),
                      // 缩略图专用：屏幕短边 <20px 的卡片/导图退化成单色块，
                      // 跳过文本排版与图片采样（缩到这个尺寸字早已不可辨）。
                      // 形状不参与代理（单次 drawRect，且空心变实心会改语义）。
                      lod: true,
                      lodScale: camera.scale,
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// 卡片底部的一枚小标签记号（极淡描边，非交互——只是标注）。
class _CardTag extends StatelessWidget {
  const _CardTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Tokens.spaceXs + 2,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Tokens.radiusMd),
        border: Bauhaus.cardBorder(theme.brightness),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: Bauhaus.inkMuted(theme.colorScheme.brightness),
        ),
      ),
    );
  }
}

/// 某视图没有内容时的空态（各视图说各的话，别一律"还没有笔记"）。
class _EmptyView extends ConsumerWidget {
  const _EmptyView({
    required this.view,
    required this.hasQuery,
    required this.query,
    required this.activeTag,
  });

  final HomeView view;
  final bool hasQuery;
  final String query;
  final String? activeTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final String text;
    if (hasQuery) {
      text = '没有与「$query」匹配的结果';
    } else if (activeTag != null) {
      // 标签筛选是**全局控件**（顶栏 [FilterMenuButton]）⇒ 任何视图都可能因它
      // 而空，先答这一条，再答各视图自己的空态（2026-09-29 定）。
      text = '「$activeTag」标签下还没有内容';
    } else {
      text = switch (view) {
        HomeView.timeline => '还没有笔记或画布',
        HomeView.all => '还没有笔记或画布',
        HomeView.notes => '还没有笔记',
        HomeView.canvas => '还没有画布',
        HomeView.favorites => '还没有收藏',
        HomeView.calendar => '', // 不会走到。
      };
    }
    return Center(
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: Bauhaus.inkMuted(theme.colorScheme.brightness),
        ),
      ),
    );
  }
}

// ─────────────────────────── 公共小料 ───────────────────────────

String _titleOf(Note note) => note.title.isEmpty ? '无标题' : note.title;

/// 卡片**显示摘要**：自己写了标题 ⇒ 摘要 = 全部正文；标题是借的 ⇒ 摘要从
/// 余下行起（首行已经站在标题位上，不重复展示）。没有可显示的 ⇒ `null`
/// （调用方留白，不放假填充）。
///
/// 读的是 [Note.summary]（列表快照的 160 字投影，v13），不是整篇 plainText。
String? _cardSummaryOf(Note note) {
  final List<String> lines = <String>[
    for (final String line in note.summary.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (note.title.trim().isNotEmpty) {
    return lines.isEmpty ? null : lines.join('\n');
  }
  return lines.length <= 1 ? null : lines.skip(1).join('\n');
}

/// 构造**命中词高亮**文本（搜索结果态卡片用）：[query] 按空白拆成多个
/// token，大小写不敏感地把命中段染成 [matchColor] 并加粗；query 为空 /
/// 无命中时退化为普通 Text（浏览态零成本）。中文无空格 ⇒ 整个词当一个
/// 子串 token。
Widget _matchRich(
  String text, {
  required String? query,
  required TextStyle base,
  required Color matchColor,
  int? maxLines,
}) {
  final String q = (query ?? '').trim();
  if (q.isEmpty || text.isEmpty) {
    return Text(
      text,
      style: base,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
  final List<String> tokens = q
      .split(RegExp(r'\s+'))
      .where((String t) => t.isNotEmpty)
      .map(_escapeRegExp)
      .toList(growable: false);
  if (tokens.isEmpty) {
    return Text(
      text,
      style: base,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }

  final RegExp pattern = RegExp('(${tokens.join('|')})', caseSensitive: false);
  final List<TextSpan> spans = <TextSpan>[];
  int last = 0;
  for (final RegExpMatch m in pattern.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }
    spans.add(
      TextSpan(
        text: m.group(0),
        style: base.copyWith(color: matchColor, fontWeight: FontWeight.w700),
      ),
    );
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));

  return Text.rich(
    TextSpan(style: base, children: spans),
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
  );
}

/// 转义正则元字符（Dart 没有内置 RegExp.escape 可用时的手写版）。
/// 字符类用 raw（`${` 在普通字符串里会被当插值开头）；替换值用普通
/// 字符串 `'\\'`（raw 的 `r'\'` 反斜杠贴引号不合法）。
String _escapeRegExp(String s) => s.replaceAllMapped(
  RegExp(r'[.*+?^${}()|[\]\\]'),
  (Match m) => '\\${m.group(0)}',
);

// ─────────────────────────── 日历分区 ───────────────────────────

/// 日历分区（2026-09-26）：按**新建日期**（`createdAt`）回看一个月。
///
/// 不跟修改日期走——它回答"我什么时候写过什么"。语言延续主页排版风：无格线、
/// 文字网格、语义色状态。
///
/// 2026-09-26 用户定：周一起始；标记 = 日期下小圆点（≥3 篇两枚，不显数字）；
/// 今天 = 细描边圈（不填充）；选中 = 玻璃 tint 填充。
///
/// 2026-09-29 用户定：日历网格独占**一张卡片**（自有底色 / 颗粒 / 阴影），
/// 卡片底部常驻「写日记」入口（**只写今天**，点完直接打字；2026-09-29 再定：
/// 点选日只管回看，不改变落笔日期）；选中日的篇目列表挪到**卡片之外、下方
/// 的页面背景上**——卡片与结果背景分开——且篇目本身也用**卡片网格**呈现
/// （同日再定：列表行不直观，与其余视图统一成 [_NoteCard]）。
class _CalendarView extends ConsumerWidget {
  const _CalendarView({
    required this.month,
    required this.selected,
    required this.onPickMonth,
    required this.onPickDay,
    required this.onOpenNote,
    required this.onCreateToday,
  });

  /// 当前显示月份（传任意一天即可，内部只看年月）。
  final DateTime month;
  final DateTime selected;
  final ValueChanged<DateTime> onPickMonth;
  final ValueChanged<DateTime> onPickDay;

  /// 打开某篇（父层走 `locateProvider`，主页不直接导航）。
  final ValueChanged<Note> onOpenNote;

  /// **写今天的日记**（父层建笔记并定位聚焦；与点选日无关）。
  final VoidCallback onCreateToday;

  /// 日期归一化键（去时间，本地时区）。
  static DateTime _dayKey(DateTime d) => DateTime(d.year, d.month, d.day);

  /// 网格行高。总高恒按**最多 6 行**预留（2026-09-26 用户定：不压缩行高）——
  /// 周一起始下最挤的月份（1 号是周日 + 31 天月）恰需 6 行；5 行的月份
  /// 下方空一行，总高恒定 ⇒ 切月不跳动。
  static const double _calRowHeight = 36;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    // 日记口径单点：左列与右内容同读 [calendarDaysProvider]（按 createdAt
    // 归组、笔记与画布混排）。这里不再本地重算，避免左右口径漂移。
    final Map<DateTime, List<Note>> byDay = ref.watch(calendarDaysProvider);

    final DateTime first = DateTime(month.year, month.month);
    final int daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // 周一起始：周一 = 0 … 周日 = 6。
    final int leading = (first.weekday + 6) % 7;
    final int rowCount = ((leading + daysInMonth) / 7).ceil();
    final DateTime today = _dayKey(DateTime.now());

    // 网格：动态行数（5/6 行），首尾用相邻月日期补位（淡化、不可点）。
    // DateTime 构造自带溢出规范化（day = 0 自动借位到上月）。
    final List<Widget> grid = <Widget>[];
    int day = 1 - leading;
    for (int r = 0; r < rowCount; r++) {
      final List<Widget> cells = <Widget>[];
      for (int c = 0; c < 7; c++, day++) {
        final DateTime d = DateTime(month.year, month.month, day);
        final bool inMonth = d.month == month.month;
        cells.add(
          Expanded(
            child: _CalCell(
              date: d,
              inMonth: inMonth,
              isToday: d == today,
              isSelected: d == _dayKey(selected),
              hasEntry: inMonth && (byDay[_dayKey(d)]?.isNotEmpty ?? false),
              onTap: inMonth ? () => onPickDay(d) : null,
            ),
          ),
        );
      }
      grid.add(
        SizedBox(
          height: _calRowHeight,
          child: Row(children: cells),
        ),
      );
    }

    // 选中日的列表（日历正下方，单列叙事不出右栏）。
    final List<Note> dayNotes = byDay[_dayKey(selected)] ?? const <Note>[];

    // 包豪斯扁平（2026-10-12）：白面 + 1px 发丝边 + 4px 硬边，无 bevel / 投影；
    // 与主区卡片、内容浮面卡同一套扁平语言。日历组浮在工作区浮面卡上。
    final Color panel = Bauhaus.surface(theme.brightness);

    // 日历**卡片**：只装月份头 / 星期 / 网格 / 底部「写日记」。选中日的篇目
    // 列表挪到卡片之外（见本方法 return 的第二段），两种背景分开。
    final Widget card = DecoratedBox(
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(Tokens.radiusMd),
        border: Bauhaus.hairline(theme.brightness),
      ),
      // 面板上挂同款纸面颗粒（paperNoiseAlpha）：颗粒铺在底色上、内容之下。
      // ⚠️ 噪点层必须铺满**整个面板**：padding 不能放在 Container 上——Stack
      // 会被内缩 ⇒ 颗粒只铺内容区，面板边缘留一圈无颗粒的纯色、看起来
      // "颜色不一致"（2026-09-26 用户截图反馈）。改为内容自带 padding。
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: NoiseTexture(
              intensity: AppTheme.paperNoiseAlpha(theme.brightness),
              grain: AppTheme.windowNoiseGrain(theme.brightness),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Tokens.spaceLg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _monthHeader(theme, scheme, today),
                const SizedBox(height: Tokens.spaceSm),
                // 星期表头：与网格同构（7 列），只提供"列名"，不是交互件。
                Row(
                  children: <Widget>[
                    for (final String s in const <String>[
                      '一',
                      '二',
                      '三',
                      '四',
                      '五',
                      '六',
                      '日',
                    ])
                      Expanded(
                        child: Center(
                          child: Text(
                            s,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Bauhaus.inkMuted(scheme.brightness),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: Tokens.spaceXs),
                // 切月动效：150ms 淡入（克制，不滑动不缩放）。
                AnimatedSwitcher(
                  duration: Tokens.durationFast,
                  child: KeyedSubtree(
                    key: ValueKey<DateTime>(first),
                    child: SizedBox(
                      width: double.infinity,
                      // 恒定总高 = 最多 6 行 × 行高（预留，不压缩）。
                      height: _calRowHeight * 6,
                      child: Column(children: grid),
                    ),
                  ),
                ),
                const SizedBox(height: Tokens.spaceSm),
                // 卡片底部：一条发丝分隔 + 常驻「写日记」入口（像日记本每页
                // 底下留白的那一行）。**只写今天**，点完直接打字。
                Container(height: 1, color: Bauhaus.line(theme.brightness)),
                const SizedBox(height: Tokens.spaceXs),
                _DiaryEntryButton(day: today, onTap: onCreateToday),
              ],
            ),
          ),
        ],
      ),
    );

    // 卡片**之外**（页面背景上）：选中日的篇目——日期圆片与日历选中格同款，
    // 建立「下面这些卡 = 上面圈住的那天」的视觉呼应；背景与卡片分开。
    // 2026-09-29 用户定：篇目从列表行改成**卡片网格**（与其余视图同语言，
    // 一眼读出标题 / 摘要 / 标签），列表行不直观。
    final Widget daySection = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              SizedBox(
                width: 30,
                height: 30,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // 「当前项」统一读法：强调色药丸（2026-10-08 全局换装）。
                    // 2026-11-14 与日历格同改圆角方形，圆形语言从日历退场。
                    color: AppTheme.selectedPill(scheme),
                    borderRadius: BorderRadius.circular(Tokens.radiusSm),
                  ),
                  child: Center(
                    child: Text(
                      '${selected.day}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Bauhaus.ink(scheme.brightness),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Tokens.spaceSm),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      TextSpan(
                        text: '${selected.month} 月',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Bauhaus.ink(scheme.brightness),
                        ),
                      ),
                      TextSpan(
                        text: '  ·  新建 ${dayNotes.length} 篇',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Bauhaus.inkMuted(scheme.brightness),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Tokens.spaceXs),
          if (dayNotes.isEmpty)
            Text(
              '这天没有新建内容',
              style: theme.textTheme.labelSmall?.copyWith(
                color: Bauhaus.inkMuted(scheme.brightness),
              ),
            )
          else
            // shrinkWrap：高度收到内容，滚动交给日历页的外层滚动体；左右
            // 不加内边距——与上方日期圆片对齐。
            _CardsGrid(
              items: dayNotes,
              onOpen: onOpenNote,
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: Tokens.spaceXs),
            ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        card,
        const SizedBox(height: Tokens.spaceMd),
        daySection,
      ],
    );
  }

  /// 月份头：`titleLarge` 月份 + 右侧切月 ghost 圆钮（+ 非本月时的「回到今天」）。
  Widget _monthHeader(ThemeData theme, ColorScheme scheme, DateTime today) {
    final bool atCurrentMonth =
        month.year == today.year && month.month == today.month;
    return Row(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
          child: Text(
            '${month.year} 年 ${month.month} 月',
            style: theme.textTheme.titleLarge?.copyWith(
              color: Bauhaus.ink(scheme.brightness),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const Spacer(),
        if (!atCurrentMonth) ...<Widget>[
          _CalGhostButton(label: '回到今天', onTap: () => onPickDay(today)),
          const SizedBox(width: Tokens.spaceXs),
        ],
        _CalNavButton(
          tooltip: '上个月',
          icon: tabler.ChevronLeft(
            height: Tokens.iconSm,
            width: Tokens.iconSm,
            strokeWidth: Tokens.iconStroke,
            colorFilter: ui.ColorFilter.mode(
              Bauhaus.inkMuted(scheme.brightness),
              ui.BlendMode.srcIn,
            ),
          ),
          onTap: () => onPickMonth(DateTime(month.year, month.month - 1)),
        ),
        const SizedBox(width: Tokens.spaceXs),
        _CalNavButton(
          tooltip: '下个月',
          icon: tabler.ChevronRight(
            height: Tokens.iconSm,
            width: Tokens.iconSm,
            strokeWidth: Tokens.iconStroke,
            colorFilter: ui.ColorFilter.mode(
              Bauhaus.inkMuted(scheme.brightness),
              ui.BlendMode.srcIn,
            ),
          ),
          onTap: () => onPickMonth(DateTime(month.year, month.month + 1)),
        ),
      ],
    );
  }
}

/// 日历卡片底部的「写日记」入口（2026-09-29 用户定）：**只写今天**——
/// 点选日只管回看，落笔日期永远是今天。全宽一条（发丝分隔之下），静止透明、
/// hover 叠一档；左侧 PencilPlus +「写日记」，右侧灰字给出今天的日期（含周几）。
class _DiaryEntryButton extends StatefulWidget {
  const _DiaryEntryButton({
    required this.day,
    required this.onTap,
    this.compact = false,
  });

  /// 恒为今天（由日历宿主传入，本地时区零点）。
  final DateTime day;
  final VoidCallback onTap;

  /// 240 宽左列专用：藏掉右侧的「11 月 14 日 · 周六」，否则 216 可用宽里
  /// 一行放不下（实测溢出 27px）。整卡形态仍显示完整日期。
  final bool compact;

  @override
  State<_DiaryEntryButton> createState() => _DiaryEntryButtonState();
}

class _DiaryEntryButtonState extends State<_DiaryEntryButton> {
  final FocusNode _focus = FocusNode();
  bool _hover = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final BorderRadius radius = BorderRadius.circular(Tokens.radiusMd);
    const List<String> weekdays = <String>['一', '二', '三', '四', '五', '六', '日'];
    return Tooltip(
      message: '为今天写一篇日记',
      child: FocusRing(
        focusNode: _focus,
        borderRadius: radius,
        child: Material(
          color: _hover
              ? AppTheme.hoverOverlay(theme.brightness)
              : Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            focusNode: _focus,
            borderRadius: radius,
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            onHover: (bool v) => setState(() => _hover = v),
            onTap: widget.onTap,
            child: SizedBox(
              height: 36,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceSm),
                child: Row(
                  children: <Widget>[
                    tabler.PencilPlus(
                      height: Tokens.iconSm,
                      width: Tokens.iconSm,
                      strokeWidth: Tokens.iconStroke,
                      colorFilter: ui.ColorFilter.mode(
                        Bauhaus.inkMuted(scheme.brightness),
                        ui.BlendMode.srcIn,
                      ),
                    ),
                    const SizedBox(width: Tokens.spaceSm),
                    Text(
                      '写日记',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Bauhaus.ink(scheme.brightness),
                      ),
                    ),
                    const Spacer(),
                    if (!widget.compact)
                      Text(
                        '${widget.day.month} 月 ${widget.day.day} 日 · 周${weekdays[widget.day.weekday - 1]}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Bauhaus.inkMuted(scheme.brightness),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 日历单元格：36 高、数字居中、**圆角方形**状态底（2026-11-14 由圆形改方形）。
/// 有新建的那天铺 [AppTheme.calendarEntryFill] 浅绿底（二元标记，不编码篇数），
/// 选中 / 今天描边 / hover 都叠在它上面。无格线——文字网格。
class _CalCell extends StatefulWidget {
  const _CalCell({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.hasEntry,
    this.onTap,
  });

  final DateTime date;
  final bool inMonth;
  final bool isToday;
  final bool isSelected;

  /// 当天**有没有新建**（二元，不编码篇数；2026-11-14 用户定）。
  final bool hasEntry;

  /// `null` = 非本月补位，不可点。
  final VoidCallback? onTap;

  @override
  State<_CalCell> createState() => _CalCellState();
}

class _CalCellState extends State<_CalCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool dim = !widget.inMonth;
    // 状态底：选中 = [AppTheme.selectedPill]（2026-10-11 起透明无底色，与导航选中
    // 同语言）；hover = 再叠一档。选中格靠文字 onSurface + w600 区分（见下）。
    final Color? fill = widget.isSelected
        ? AppTheme.selectedPill(scheme)
        : (_hover && widget.onTap != null)
        ? AppTheme.hoverOverlay(theme.brightness)
        : null;
    final Color textColor = dim
        ? Bauhaus.ink(scheme.brightness).withValues(alpha: 0.3)
        : Bauhaus.inkMuted(scheme.brightness);
    // 文字色优先级 **今天 > 选中 > 常态**（2026-11-14 用户定）：今天是更强的
    // 时间事实，不该被选中态的 ink 覆盖。旧版今天只有 w600，且默认态
    //（选中 = 今天）连描边都被排除 ⇒ 用户实报「加粗不明显，看不出来」。
    final Color dayInk = widget.isToday
        ? AppTheme.calendarTodayInk(theme.brightness)
        : widget.isSelected
        ? Bauhaus.ink(scheme.brightness)
        : textColor;
    final FontWeight? dayWeight = (widget.isToday || widget.isSelected)
        ? FontWeight.w600
        : null;

    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) {
        if (mounted) setState(() => _hover = true);
      },
      onExit: (_) {
        if (mounted) setState(() => _hover = false);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Center(
          child: SizedBox(
            width: 30,
            height: 30,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                // ① 有新建 ⇒ **浅绿圆角方底**（2026-11-14 用户定）。
                // 二元标记：只回答"这天写没写"，不编码篇数；点开右内容区看确数。
                // 放在最底层，选中 / 今天描边 / hover 都能叠在它上面读出来。
                if (widget.hasEntry)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppTheme.calendarEntryFill(theme.brightness),
                        borderRadius: BorderRadius.circular(Tokens.radiusSm),
                      ),
                    ),
                  ),
                // ② 选中 / hover 底：**圆角方形**（2026-11-14 由圆形改方形）。
                if (fill != null)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(Tokens.radiusSm),
                      ),
                    ),
                  ),
                // ③ 今天：**不论是否选中**都画纯绿圆角方形描边（2026-11-14 修）。
                // 旧条件 `isToday && !isSelected` 让默认态（选中 = 今天）的今天
                // 标识整个消失，只剩 w600 ⇒ 实机认不出。不填充，压在浅绿底上。
                if (widget.isToday)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(Tokens.radiusSm),
                        border: Border.all(
                          color: AppTheme.calendarTodayInk(theme.brightness),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                // ④ 日期数字：始终居中，不被任何标记顶上去。
                Text(
                  '${widget.date.day}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: dayInk,
                    fontWeight: dayWeight,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 切月 ghost 圆钮：28 圆，静止透明，hover 叠一档（"再叠一档"同语言）。
class _CalNavButton extends StatefulWidget {
  const _CalNavButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_CalNavButton> createState() => _CalNavButtonState();
}

class _CalNavButtonState extends State<_CalNavButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) {
          if (mounted) setState(() => _hover = true);
        },
        onExit: (_) {
          if (mounted) setState(() => _hover = false);
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: SizedBox(
            width: 28,
            height: 28,
            child: Material(
              color: _hover
                  ? AppTheme.hoverOverlay(brightness)
                  : Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: Center(child: widget.icon),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「回到今天」ghost 文字钮：小灰字，hover 淡底圆角。
class _CalGhostButton extends StatefulWidget {
  const _CalGhostButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_CalGhostButton> createState() => _CalGhostButtonState();
}

class _CalGhostButtonState extends State<_CalGhostButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return MouseRegion(
      onEnter: (_) {
        if (mounted) setState(() => _hover = true);
      },
      onExit: (_) {
        if (mounted) setState(() => _hover = false);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Material(
          color: _hover
              ? AppTheme.hoverOverlay(theme.brightness)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(Tokens.radiusSm),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Tokens.spaceSm,
              vertical: Tokens.spaceXs,
            ),
            child: Text(
              widget.label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: Bauhaus.inkMuted(scheme.brightness),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
