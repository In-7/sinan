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
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/noise_texture.dart';
import '../theme/tokens.dart';
import 'note_display.dart';
import 'providers.dart';
import 'search_provider.dart';
import 'stream_view.dart';

/// 主页顶部的**视图切换**（2026-09-29 用户定，取代 Things 式单列一页纸）。
///
/// 五个视图各答一个问题，浏览时**正交于搜索框**（[searchNotifierProvider]）；
/// 一旦输入查询词，内容区统一切到**全局搜索结果态**（[_SearchResultsView]），
/// 与当前 tab 无关——搜索跨笔记/画布、覆盖日历（2026-09-30 用户定）。
/// - [HomeView.timeline]：**心流**——按 `revisedAt` 分组的时间流（今天 /
///   昨天 / 本周…），**启动默认视图**且是 tab 行第一枚（2026-10-05 决策 C）。
/// - [HomeView.all]：**全部**——笔记 + 画布跨形态统一池，全局排序
///   （[homeSortProvider]）生效。默认排序就是"最近编辑在前"，看最近改过
///   什么直接看前几张卡即可（2026-09-29 用户定：不单设「最近」视图）。
/// - [HomeView.calendar]：按新建日期回看（日历网格成一张卡片，卡片底部
///   「写日记」**只写今天**——点选日只管回看；选中日的篇目列在卡片**之外**
///   的页面背景上）。
/// - [HomeView.favorites]：收藏（[Note.promotedAt] 非空），跨形态统一。
///
/// ⚠️ **四个视图都不分笔记与画布**（用户 2026-09-29 明确）：形态是**筛选
/// 维度**而不是视图（2026-10-05 决策 E）⇒ 走顶栏漏斗钮里的「形态」facet
/// （[NoteKindFacet]），不再占用 tab 位，三点溢出菜单随之退役。
///
/// ⚠️ **排序 / 标签 / 形态都不是页面**：它们是全局控件，合住顶栏右侧一枚
/// 「筛选与排序」漏斗钮（[_FilterMenuButton]：一个菜单、三段——形态 / 排序 /
/// 标签），对所有视图同时生效。
/// [HomeView] 的**图标**扩展。
///
/// 枚举本体在 `providers.dart`：统一导航历史（[NavHistoryNotifier]）要同时
/// 表达"主页视图"与"某篇笔记页"两种目的地，而它必须与 `locateProvider` 同住
/// （唯一获准写"当前笔记"的文件，见 architecture_test 的源码扫描）。图标要
/// 引用 tabler / [CustomIcons]，不进 DI 层，故留在这里。
extension HomeViewIcon on HomeView {
  /// 最左图标导航轨上的图标（tabler 单色线形；形态 facet 里的「画布」才用
  /// `CustomIcons.canvas` 彩色插画）。
  Widget icon(Color color) => switch (this) {
    // 心流 = 时间流 ⇒ 时钟（分组键是 `revisedAt`）。
    HomeView.timeline => tabler.Clock(
      height: Tokens.iconMdSm,
      width: Tokens.iconMdSm,
      strokeWidth: Tokens.iconStroke,
      colorFilter: ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
    ),
    HomeView.all => tabler.LayoutGrid(
      height: Tokens.iconMdSm,
      width: Tokens.iconMdSm,
      strokeWidth: Tokens.iconStroke,
      colorFilter: ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
    ),
    HomeView.calendar => tabler.Calendar(
      height: Tokens.iconMdSm,
      width: Tokens.iconMdSm,
      strokeWidth: Tokens.iconStroke,
      colorFilter: ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
    ),
    HomeView.favorites => tabler.Star(
      height: Tokens.iconMdSm,
      width: Tokens.iconMdSm,
      strokeWidth: Tokens.iconStroke,
      colorFilter: ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
    ),
  };
}

/// 最左图标导航轨的**四个常驻目的地**（2026-10-09 用户定外移；此前是 HomeHub
/// 顶栏横排 tab）：**心流 | 全部 | 日历 | 收藏**，心流首位且为启动默认
///（与 [NavHistoryNotifier.build] 的默认值一致）。
///
/// ⚠️ 笔记 / 画布**不在这里**（决策 E）——它们是形态筛选，走漏斗钮的
/// [NoteKindFacet]；三点溢出菜单已随之退役。
const List<HomeView> kHomeTabs = <HomeView>[
  HomeView.timeline,
  HomeView.all,
  HomeView.calendar,
  HomeView.favorites,
];

/// **形态筛选 facet**（2026-10-05 决策 E 新增）：全部 / 笔记 / 画布。
///
/// ## 为什么它不是 [HomeView] 的值
/// 视图答的是"我怎么看"（投影：心流 / 全部 / 日历 / 收藏），形态答的是
/// "它是什么"（类型：文档类 spark+note / 画布 canvas）。两个维度塞进一排
/// tab 就是类别错误——本项目上一次是以"空间切换器"的形式解决它的（只过滤
/// 列表、不切主区），这里沿用同一个结论：**只做筛选，不做视图**。
///
/// ## 为什么它不入统一导航历史
/// 切形态只是"换个看法"，不是"去了一个地方" ⇒ 不写 [navHistoryProvider]，
/// 上一步 / 下一步不该被它打断（否则在列表里筛一下就毁掉前进栈）。
enum NoteKindFacet {
  all('全部'),
  docs('笔记'),
  canvas('画布');

  const NoteKindFacet(this.label);

  /// 菜单里显示的名字（也是测试 find 的锚点）。
  final String label;

  /// 该形态是否收下这篇（文档类 = 非画布）。
  bool matches(NoteKind kind) => switch (this) {
    NoteKindFacet.all => true,
    NoteKindFacet.docs => kind != NoteKind.canvas && kind != NoteKind.stream,
    NoteKindFacet.canvas => kind == NoteKind.canvas,
  };
}

/// 当前形态筛选（顶栏漏斗钮的「形态」段）。默认 [NoteKindFacet.all]。
final homeKindFacetProvider = NotifierProvider<HomeKindFacet, NoteKindFacet>(
  HomeKindFacet.new,
);

class HomeKindFacet extends Notifier<NoteKindFacet> {
  @override
  NoteKindFacet build() => NoteKindFacet.all;

  void select(NoteKindFacet facet) => state = facet;
}

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

/// [homeItemsProvider] 的入参（record：结构相等即命中缓存）。
///
/// `kind` 是 2026-10-05 决策 E 加的**形态 facet**（笔记 / 画布不再是视图）。
typedef HomeItemsArgs = ({HomeView view, String? tag, NoteKindFacet kind});

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
        // 心流与"全部"同为跨形态统一池、跟随全局排序（心流的时间分组在
        // stream_view 里按 revisedAt 做，这里仍给一份排好序的全集）。
        HomeView.timeline => all.toList()..sort(order),
        // 全部：跨形态统一池，跟随全局排序。
        HomeView.all => all.toList()..sort(order),
        // 收藏不读全局排序：最近收藏的排前面。
        HomeView.favorites => <Note>[
          ...all.where((Note n) => n.promotedAt != null),
        ]..sort((Note a, Note b) => b.promotedAt!.compareTo(a.promotedAt!)),
        HomeView.calendar => const <Note>[],
      };
      // 形态筛选（决策 E）：先按类型收一遍，再按标签收一遍——两者都是顶栏
      // 全局控件 ⇒ 对当前视图生效。
      final List<Note> byKind = args.kind == NoteKindFacet.all
          ? scope
          : scope.where((Note n) => args.kind.matches(n.kind)).toList();
      // 标签筛选是顶栏全局控件 ⇒ 对当前视图生效；未选标签时原样返回。
      // 有搜索词时不走这里（搜索态由 _SearchResultsView 跨形态渲染）。
      return args.tag == null
          ? byKind
          : byKind.where((Note n) => n.tags.contains(args.tag)).toList();
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

/// **主页**：顶栏（筛选）+ 内容区（心流 / 卡片网格 / 日历 / 收藏）。
///
/// ## 为什么从"单列一页纸"改成这个（2026-09-29 用户定）
/// 旧的 Things 式一页纸把日历 / 收藏 / 继续 / 最近 / 新建**串成一列**，一次只能
/// 从上往下扫；用户要的是**空间切换**范式（对标 Craft / Bear）：目的地切换
/// 点哪个看哪个，内容统一用**小卡片**（带 2–3 行摘要，一眼知道大概内容）。
///
/// ## 三条结构事实
/// 1. **顶栏**：只剩一枚靠右的漏斗钮 [_FilterMenuButton]（形态 / 排序 / 标签合住）。
///    视图切换 + 新建胶囊 2026-10-12 移到工作区**左侧扁平导航** [HomeSidebar]（无面板、
///    贴窗口底）；本内容区本身才是浮面卡。上一步 / 下一步 2026-10-15 加回**标题栏左簇**
///    （左缘与内容卡对齐，功能与全局键 `Alt+←/→` 同走命令层）。常驻捕获输入框
///    （OmniBar）2026-10-09 撤除（用户："这个输入方式不好用"）。
/// 2. **内容区按视图 + 搜索词解析**（[homeItemsProvider]）：搜索词在**当前
///    视图范围内**过滤（日历视图忽略搜索）；命中渲染成 [_CardsGrid]。
/// 3. **卡片** [_NoteCard] 用现成卡片三件套（[AppTheme.cardFill] / [cardStroke] /
///    [cardFillHover]）——静止态**有底色**（与列表行的"显式透明"相反：卡片本就
///    该是一块浮起的板子）。每张接 [FocusRing]（§5.2 键盘可达）。
///
/// ## 页面模型（不变）
/// 未选中笔记 = 主页；选中 = 笔记 / 画布页。同一个 `selectedNoteIdProvider` 驱动。
class HomeHub extends ConsumerStatefulWidget {
  const HomeHub({super.key});

  @override
  ConsumerState<HomeHub> createState() => _HomeHubState();
}

class _HomeHubState extends ConsumerState<HomeHub> {
  /// 日历视图的浏览态：显示月份与选中日。只放本地 State（纯浏览节奏，
  /// 不进 provider 不落盘，重启回今天）。
  DateTime _calMonth = _todayMonth();
  DateTime _calSelected = _today();

  static DateTime _today() {
    final DateTime n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static DateTime _todayMonth() {
    final DateTime n = DateTime.now();
    return DateTime(n.year, n.month);
  }

  @override
  Widget build(BuildContext context) {
    final HomeView view = ref.watch(navHistoryProvider).view;
    final SearchState s = ref.watch(searchNotifierProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 顶栏：只剩一枚靠右的「筛选与排序」漏斗钮（形态 / 排序 / 标签合住）。
        // 视图切换 + 新建胶囊 2026-10-12 移到工作区左侧扁平导航（[HomeSidebar]），
        // 不再占内容区顶栏。问笔记（AI）是工作区右角折叠钮（见 [HomeScreen]
        // 工作区 [_RightRailToggleButton]），开合两态坐标不变。
        const Padding(
          padding: EdgeInsets.fromLTRB(
            Tokens.spaceLg,
            // 顶部带中心线（Tokens.headerBandCenter = 20）：32 高的钮取
            // top = 20 − 16 = 4，与编辑器耳朵（top 5、高 30）同中心线。
            Tokens.headerBandCenter - Tokens.toolbarButtonSize / 2,
            // 右内缩让开工作区右角的 AI 折叠钮（_RightRailToggleButton，占据右起
            // spaceXs + toolbarButtonSize = 36px），再留 spaceSm 间隙——否则两者重叠
            // （2026-10-11 用户修）。
            Tokens.spaceXs + Tokens.toolbarButtonSize + Tokens.spaceSm,
            Tokens.spaceSm,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              _FilterMenuButton(),
            ],
          ),
        ),
        Expanded(
          child: _HomeBody(
            view: view,
            search: s,
            calMonth: _calMonth,
            calSelected: _calSelected,
            onPickMonth: (DateTime m) => setState(() => _calMonth = m),
            onPickDay: (DateTime d) => setState(() {
              _calSelected = d;
              _calMonth = DateTime(d.year, d.month);
            }),
          ),
        ),
      ],
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
    required this.search,
    required this.calMonth,
    required this.calSelected,
    required this.onPickMonth,
    required this.onPickDay,
  });

  final HomeView view;
  final SearchState search;
  final DateTime calMonth;
  final DateTime calSelected;
  final ValueChanged<DateTime> onPickMonth;
  final ValueChanged<DateTime> onPickDay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Note> all = ref.watch(notesProvider).value ?? const <Note>[];

    // 有查询词 ⇒ **全局搜索结果态**（2026-09-30 用户定"搜索跨形态"）：
    // 浏览与搜索是两种意图——tab 只管"逛哪个池子"，搜索永远是"去全库找
    // 东西"。所以搜索态跨笔记/画布、**覆盖任何 tab（含日历）**；撤词后
    // 回到原视图（查询词在 provider 里，视图状态从没被动过）。
    if (search.query.trim().isNotEmpty) {
      return _SearchResultsView(search: search);
    }

    // 心流视图：按 `revisedAt` 分组的时间流（2026-10-06，阶段 1 ②A）。
    // 与卡片网格**同一池子**（同一 homeItemsProvider 入参，形态 / 标签 facet
    // 同样生效）、同一种显示口径，只是换了一种排布。
    if (view == HomeView.timeline) {
      return StreamView(tag: search.activeTag);
    }

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
              notes: all,
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
      homeItemsProvider((
        view: view,
        tag: search.activeTag,
        kind: ref.watch(homeKindFacetProvider),
      )),
    );

    if (items.isEmpty) {
      return Column(
        children: <Widget>[
          Expanded(
            child: _EmptyView(
              view: view,
              hasQuery: search.query.trim().isNotEmpty,
              query: search.query.trim(),
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

  /// 日历的「写日记」**只落今天**（2026-09-29 用户定：点选哪天只管回看，
  /// 不改变落笔日期）：新建一篇，建好即定位聚焦——点完直接打字。
  void _createDiaryToday(WidgetRef ref) {
    unawaited(() async {
      final Note n = await ref.read(notesProvider.notifier).createNote();
      ref.read(locateProvider.notifier).locate(noteId: n.id, focus: true);
    }());
  }
}

/// **全局搜索结果态**（2026-09-30 用户定）：顶栏一输入，内容区统一切到这里——
/// 与当前 tab 无关（**跨笔记/画布、覆盖日历**），命中顺序就是检索相关度
/// （[SearchNotifier] 已按"标题命中置顶 → RRF 分"排好）。
///
/// 卡片拿到了检索产出的 **snippet**（命中块文本）：摘要位显示它并高亮查询
/// 词，而不是默认的正文前三行——全局检索最贵的产出不再被渲染层丢掉。
class _SearchResultsView extends ConsumerWidget {
  const _SearchResultsView({required this.search});

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
                color: Bauhaus.inkMuted(scheme.brightness).withValues(alpha: 0.65),
              ),
            ),
        ],
      ),
    );
  }
}

/// 顶栏**筛选器**控件钮（2026-09-30 用户定）：排序方案（[homeSortProvider]）
/// 与标签筛选（[SearchState.activeTag]）同属"整理当前池子"的元操作，合住一枚
/// 漏斗钮、一个菜单——上半段排序、下半段标签。对 [kHomeTabs] /
/// [kHomeTabs] 所有视图全局生效（收藏的排序语义除外，见 [_HomeHubState]）。
///
/// 标签段在全库无标签时**整段消失**，但钮本身常驻（排序永远可用，
/// 2026-09-30 之前排序 / 标签是两枚钮，无标签时只剩排序，用户找不到入口）。
///
/// 有**任何**非默认条件生效（排序非默认 / 选中了标签）⇒ 图标披主题色，
/// 一眼能看到"列表正被筛着"。
class _FilterMenuButton extends ConsumerStatefulWidget {
  const _FilterMenuButton();

  @override
  ConsumerState<_FilterMenuButton> createState() => _FilterMenuButtonState();
}

class _FilterMenuButtonState extends ConsumerState<_FilterMenuButton> {
  /// 菜单锚点（GlobalKey）：不挂的话 position 落 Offset.zero ⇒ 菜单弹到
  /// 屏幕左上角（全仓统一教训）。
  final GlobalKey _key = GlobalKey();

  Future<void> _openMenu() async {
    final NoteSort currentSort = ref.read(homeSortProvider);
    final NoteKindFacet currentKind = ref.read(homeKindFacetProvider);
    final List<(String, int)> tags = ref.read(allTagsProvider);
    final String? activeTag = ref.read(searchNotifierProvider).activeTag;

    // **锚点矩形**（Flutter 官方 PopupMenu 口径，别再手算零宽度点）：
    // 此前用 `RelativeRect.fromLTRB(dx, dy, dx, dy)`（锚点 = 按钮左下角的
    // 零宽度矩形）⇒ 菜单默认从按钮左缘**向右**展开；而漏斗钮贴着搜索框
    // 右端、离窗口右缘很近，放不下时被框架"吸"到屏幕边缘，菜单整体甩到
    // 按钮右边很远（用户实测"面板离搜索按钮很远"）。改成按钮相对屏幕的
    // **四边缘矩形**后，框架按 left/right 哪边空间大决定展开方向——按钮
    // 靠右 ⇒ **右缘对齐、向左展开**。
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
      items: <PopupMenuEntry<void>>[
        // 形态（2026-10-05 决策 E）：笔记 / 画布从"视图"降为**筛选维度**，
        // 与排序 / 标签同级。切它不入导航历史（见 [NoteKindFacet] 的说明）。
        _menuHeader('形态'),
        for (final NoteKindFacet f in NoteKindFacet.values)
          PopupMenuItem<void>(
            onTap: () => ref.read(homeKindFacetProvider.notifier).select(f),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(f.label),
                if (f == currentKind) ...<Widget>[
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
        const PopupMenuDivider(),
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
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: Bauhaus.inkMuted(Theme.of(context).colorScheme.brightness)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final NoteSort sort = ref.watch(homeSortProvider);
    final String? activeTag = ref.watch(
      searchNotifierProvider.select((SearchState s) => s.activeTag),
    );
    final bool active = sort != NoteSort.revised || activeTag != null;

    // ⚠️ 锚点 key 挂在 **32×32 外壳**上，不能挂 IconButton：material_ui 的
    // M3 IconButton 外层包了 48×48 的点击热区（_InputPadding），元素根
    // RenderBox 是热区而非可视按钮（实测落在按钮左下方，菜单因此整体
    // 错位 8~40px）。外壳尺寸与位置就是可视按钮的真实矩形。
    return SizedBox(
      key: _key,
      width: 32,
      height: 32,
      child: IconButton(
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
        icon: tabler.Filter(
          height: Tokens.iconMdSm,
          width: Tokens.iconMdSm,
          strokeWidth: Tokens.iconStroke,
          colorFilter: active
              ? ui.ColorFilter.mode(
                  Bauhaus.blue(theme.colorScheme.brightness),
                  ui.BlendMode.srcIn,
                )
              : null,
        ),
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
                              color: Bauhaus.inkMuted(scheme.brightness).withValues(
                                alpha: 0.6,
                              ),
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
      // 标签筛选是**全局控件**（顶栏 [_FilterMenuButton]）⇒ 任何视图都可能因它
      // 而空，先答这一条，再答各视图自己的空态（2026-09-29 定）。
      text = '「$activeTag」标签下还没有内容';
    } else {
      text = switch (view) {
        HomeView.timeline => '还没有笔记或画布',
        HomeView.all => '还没有笔记或画布',
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
class _CalendarView extends StatelessWidget {
  const _CalendarView({
    required this.notes,
    required this.month,
    required this.selected,
    required this.onPickMonth,
    required this.onPickDay,
    required this.onOpenNote,
    required this.onCreateToday,
  });

  final List<Note> notes;

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
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    // 按新建日期归组（每次 build 重算：桌面量级小，不值得缓存）。
    final Map<DateTime, List<Note>> byDay = <DateTime, List<Note>>{};
    for (final Note n in notes) {
      byDay.putIfAbsent(_dayKey(n.createdAt), () => <Note>[]).add(n);
    }
    for (final List<Note> list in byDay.values) {
      list.sort((Note a, Note b) => b.createdAt.compareTo(a.createdAt));
    }

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
              count: inMonth ? (byDay[_dayKey(d)]?.length ?? 0) : 0,
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
                Container(
                  height: 1,
                  color: Bauhaus.line(theme.brightness),
                ),
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
                    color: AppTheme.selectedPill(scheme),
                    shape: BoxShape.circle,
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
              '这天没有新建笔记',
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
  const _DiaryEntryButton({required this.day, required this.onTap});

  /// 恒为今天（由 [_CalendarView] 传入，本地时区零点）。
  final DateTime day;
  final VoidCallback onTap;

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

/// 日历单元格：36 高、数字居中、圆形状态底。无格线无底色——文字网格。
class _CalCell extends StatefulWidget {
  const _CalCell({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.count,
    this.onTap,
  });

  final DateTime date;
  final bool inMonth;
  final bool isToday;
  final bool isSelected;

  /// 当天新建篇数（0 = 无标记）。
  final int count;

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
                if (fill != null)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: fill,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                // 今天（未选中）：细描边圈，不填充（2026-09-26 用户定）。
                if (widget.isToday && !widget.isSelected)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Bauhaus.inkMuted(scheme.brightness)),
                      ),
                    ),
                  ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '${widget.date.day}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: widget.isSelected ? Bauhaus.ink(scheme.brightness) : textColor,
                        fontWeight: widget.isSelected ? FontWeight.w600 : null,
                      ),
                    ),
                    // 新建标记：日期下一枚小圆点；≥3 篇两枚（不显数字）。
                    if (widget.count > 0) ...<Widget>[
                      const SizedBox(height: 2),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          _calDot(theme.brightness),
                          if (widget.count >= 3) ...<Widget>[
                            const SizedBox(width: 3),
                            _calDot(theme.brightness),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 新建标记点：绿色系（2026-09-26 用户定），明暗各一档保证两种主题都清晰
  /// ——亮色窗用深绿、暗色窗用亮绿（同一色相，只调明度）。
  Widget _calDot(Brightness brightness) => Container(
    width: 4,
    height: 4,
    decoration: BoxDecoration(
      color: switch (brightness) {
        Brightness.dark => const Color(0xFF4ADE80),
        Brightness.light => const Color(0xFF16A34A),
      },
      shape: BoxShape.circle,
    ),
  );
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
