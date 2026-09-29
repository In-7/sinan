import 'dart:async';
import 'dart:ui' as ui;

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

// 键盘事件类型（搜索框 Esc / Enter）：KeyDownEvent / LogicalKeyboardKey
// 在 `services.dart`，不由 material 转出。
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/note.dart';
import '../theme/app_custom_icons.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/noise_texture.dart';
import '../theme/tokens.dart';
import 'providers.dart';
import 'search_provider.dart';

/// 主页顶部的**视图切换**（2026-09-29 用户定，取代 Things 式单列一页纸）。
///
/// 六个视图各答一个问题，且**正交于搜索框**（[searchNotifierProvider]）：
/// - [HomeView.all]：**全部**——笔记 + 画布跨形态统一池，全局排序
///   （[homeSortProvider]）生效。默认排序就是"最近编辑在前"，看最近改过
///   什么直接看前几张卡即可（2026-09-29 用户定：不单设「最近」视图）。
/// - [HomeView.notes]：文档类笔记（spark + note）的卡片网格。**低频**，
///   顶栏无常驻 tab——入口在「更多」面板（2026-09-29 用户定）。
/// - [HomeView.canvas]：画布类（canvas）的卡片网格。同上收进「更多」。
/// - [HomeView.calendar]：按新建日期回看（日历网格成一张卡片，卡片底部
///   「写日记」**只写今天**——点选日只管回看；选中日的篇目列在卡片**之外**
///   的页面背景上）。
/// - [HomeView.favorites]：收藏（[Note.promotedAt] 非空），跨形态统一。
/// - [HomeView.filter]：**更多**（2026-09-29 改名）——视图入口（笔记 / 画布）
///   + 标签筛选 + 排序方案，排序对全部 / 笔记 / 画布 / 本视图全局生效
///   （[homeSortProvider]）。
///
/// ⚠️ 全部 / 日历 / 收藏 / 更多**不分笔记与画布**（用户 2026-09-29 明确）；
/// 只有笔记、画布两个视图按形态各自过滤。常驻 tab 只挂高频四枚
/// （[kHomeTabs]）；经「更多」进入笔记 / 画布时顶栏高亮「更多」。
enum HomeView {
  all('全部'),
  notes('笔记'),
  canvas('画布'),
  calendar('日历'),
  favorites('收藏'),
  filter('更多');

  const HomeView(this.label);

  /// 顶栏 tab 上显示的名字（也是测试 find 的锚点）。
  final String label;

  /// 顶栏 tab 的图标（Remix 单色线形，与第一列 [AppRail] 同族）。
  ///
  /// 画布用 `CustomIcons.canvas`（彩色插画）——它是"空间"不是"工具"，与
  /// 第二列切换器里的画布格同源；其余走 tabler 单色线形。
  Widget icon(Color color) => switch (this) {
    HomeView.all => tabler.LayoutGrid(
      height: Tokens.iconMdSm,
      width: Tokens.iconMdSm,
      strokeWidth: Tokens.iconStroke,
      colorFilter: ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
    ),
    HomeView.notes => tabler.FileText(
      height: Tokens.iconMdSm,
      width: Tokens.iconMdSm,
      strokeWidth: Tokens.iconStroke,
      colorFilter: ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
    ),
    HomeView.canvas => CustomIcons.canvas(size: Tokens.iconMdSm),
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
    // 「更多」= 视图选项（标签 + 排序），用滑杆图标而不是漏斗——它不只是
    // 筛选（2026-09-29 改名用户定）。
    HomeView.filter => tabler.AdjustmentsHorizontal(
      height: Tokens.iconMdSm,
      width: Tokens.iconMdSm,
      strokeWidth: Tokens.iconStroke,
      colorFilter: ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
    ),
  };
}

/// 主页当前选中的视图。默认落 [HomeView.all]——"全库扫一眼、最近编辑在
/// 前排"是最有用的落地页（2026-09-29 用户定，顶栏精简后笔记不再是常驻 tab）。
///
/// 放在 provider 而非 widget 的 `setState`：进编辑器再点「上一页」回主页时，
/// 顶栏要**记住上次停在哪个视图**（widget 会被重建，局部 State 丢失）。
///
/// ⚠️ riverpod 3.4.3 无 `StateProvider`，用显式 [Notifier]。
final homeViewProvider = NotifierProvider<HomeViewNotifier, HomeView>(
  HomeViewNotifier.new,
);

/// 自带**视图历史**（2026-09-29 用户定）：笔记 / 画布收进「更多」后是两跳
/// 目的地，主区顶条左缘的「上一步 / 下一步」（home_screen.dart 的
/// [NavHistoryButton]）把往返成本抹平。栈只记视图、不记滚动位置——低频导航，
/// 不欠这份精细。
class HomeViewNotifier extends Notifier<HomeView> {
  final List<HomeView> _back = <HomeView>[];
  final List<HomeView> _forward = <HomeView>[];

  /// 是否可退 / 可进（顶栏箭头钮的可用态）。每次导航 `state` 都会变 ⇒
  /// UI watch state 后重读这两个 getter 就能拿到正确的可用态。
  bool get canGoBack => _back.isNotEmpty;
  bool get canGoForward => _forward.isNotEmpty;

  @override
  HomeView build() => HomeView.all;

  /// 切换视图（顶栏 tab 与「更多」面板的视图入口都走这里）。
  void select(HomeView view) {
    if (view == state) return;
    _back.add(state);
    _forward.clear();
    state = view;
  }

  /// 回到上一个视图（「上一步」）。
  void goBack() {
    if (_back.isEmpty) return;
    _forward.add(state);
    state = _back.removeLast();
  }

  /// 前进到下一个视图（「下一步」）。
  void goForward() {
    if (_forward.isEmpty) return;
    _back.add(state);
    state = _forward.removeLast();
  }
}

/// 顶栏**常驻 tab**（2026-09-29 用户定：只放高频四枚——全部 / 日历 / 收藏 /
/// 更多）。笔记 / 画布是低频视图，入口收进「更多」面板（[_ViewEntriesRow]），
/// 点了照旧**整页切换**。[HomeView] 枚举仍是全量视图（内容区分发不变），
/// tab 只列这四枚。
const List<HomeView> kHomeTabs = <HomeView>[
  HomeView.all,
  HomeView.calendar,
  HomeView.favorites,
  HomeView.filter,
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

/// **主页**：顶栏（视图切换 + 常驻搜索）+ 内容区（卡片网格 / 日历）。
///
/// ## 为什么从"单列一页纸"改成这个（2026-09-29 用户定）
/// 旧的 Things 式一页纸把日历 / 收藏 / 继续 / 最近 / 新建**串成一列**，一次只能
/// 从上往下扫；用户要的是**空间切换**范式（对标 Craft / Bear）：顶部一排视图
/// 点哪个看哪个，内容统一用**小卡片**（带 2–3 行摘要，一眼知道大概内容），搜索
/// 从第一列图标挪到**顶部中间的常驻输入框**。
///
/// ## 三条结构事实
/// 1. **顶栏**：左 = 4 枚常驻视图 tab（[kHomeTabs]，选中披 [AppTheme.navSelectedTint]），
///    右 = 常驻搜索框（点击直接输入，走 [searchNotifierProvider]）。上一步 /
///    下一步（视图历史）与主页 / 设置在更外层的主区顶条（[WindowStrip]）。
/// 2. **内容区按视图 + 搜索词解析**（[_HomeBody._itemsFor]）：搜索词在**当前
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
  /// 常驻搜索框：文本控制器 + 焦点（Esc 清词 / Enter 跳首条，沿用旧搜索分区键位）。
  final TextEditingController _searchController = TextEditingController();
  late final FocusNode _searchFocus;

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
  void initState() {
    super.initState();
    // 回填上次的查询词（状态在 provider，不在本 widget）：进笔记再回来，词还在。
    _searchController.text = ref.read(searchNotifierProvider).query;
    _searchFocus = FocusNode(onKeyEvent: _onSearchKey);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// 搜索框键位：`Esc` 有词 = 清空（保留焦点），无词 = 失焦；`Enter` = 跳第一个命中。
  KeyEventResult _onSearchKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final SearchState s = ref.read(searchNotifierProvider);
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (s.query.isNotEmpty) {
        _searchController.clear();
        ref.read(searchNotifierProvider.notifier).submit('');
        _searchFocus.requestFocus();
      } else {
        _searchFocus.unfocus();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (s.hits.isNotEmpty) {
        ref
            .read(locateProvider.notifier)
            .locate(noteId: s.hits.first.note.id, focus: true);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final HomeView view = ref.watch(homeViewProvider);
    final SearchState s = ref.watch(searchNotifierProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildTopBar(context, view),
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

  /// 顶栏：左 = 4 枚常驻视图 tab（窄窗可横滚），右 = 常驻搜索框（定宽）。
  /// 上一步 / 下一步在主区顶条（[NavHistoryButton]），不在这里。
  Widget _buildTopBar(BuildContext context, HomeView view) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool hasQuery = ref.watch(
      searchNotifierProvider.select((SearchState s) => s.query.isNotEmpty),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.spaceLg,
        Tokens.spaceMd,
        Tokens.spaceLg,
        Tokens.spaceSm,
      ),
      // LayoutBuilder：搜索框**贴右定宽 260**，但主区被挤窄（开右轨 /
      // 拖窗过断点的过渡帧）时随剩余空间收缩，左侧 tab 区（`Expanded`
      // 横向滚动）吃掉其余 ⇒ 任何宽度都不撑破顶栏。
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double searchWidth = (constraints.maxWidth - Tokens.spaceMd)
              .clamp(0.0, 260.0)
              .toDouble();
          return Row(
            children: <Widget>[
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      // 常驻 tab 只挂高频四枚；经「更多」进入笔记 / 画布时，
                      // 「更多」高亮（More-tab 惯例：人在它的分区里）。
                      // 上一步 / 下一步不在这里——它们是全局导航，2026-09-29
                      // 用户定挪去主区顶条（home_screen.dart 的
                      // [NavHistoryButton]）。
                      for (final HomeView v in kHomeTabs)
                        Padding(
                          padding: const EdgeInsets.only(right: Tokens.spaceXs),
                          child: _ViewTab(
                            view: v,
                            active:
                                v == view ||
                                (v == HomeView.filter &&
                                    (view == HomeView.notes ||
                                        view == HomeView.canvas)),
                            onTap: () =>
                                ref.read(homeViewProvider.notifier).select(v),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: Tokens.spaceMd),
              SizedBox(
                width: searchWidth,
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    onChanged: (String v) =>
                        ref.read(searchNotifierProvider.notifier).submit(v),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '搜索标题与内容',
                      hintStyle: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      // tabler 图标是自绘 widget ⇒ 直接放（同旧搜索分区）。
                      prefixIcon: Center(
                        widthFactor: 1,
                        child: tabler.Search(
                          height: Tokens.iconSm,
                          width: Tokens.iconSm,
                          strokeWidth: Tokens.iconStroke,
                          colorFilter: ui.ColorFilter.mode(
                            hasQuery
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                            ui.BlendMode.srcIn,
                          ),
                        ),
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 34,
                        minHeight: 32,
                      ),
                      suffixIcon: hasQuery
                          ? IconButton(
                              icon: const tabler.CircleX(
                                height: Tokens.iconSm,
                                width: Tokens.iconSm,
                                strokeWidth: Tokens.iconStroke,
                              ),
                              tooltip: '清空（Esc）',
                              onPressed: () {
                                _searchController.clear();
                                ref
                                    .read(searchNotifierProvider.notifier)
                                    .submit('');
                                _searchFocus.requestFocus();
                              },
                            )
                          : null,
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 「最近」不单设视图（2026-09-29 用户定）：「全部」默认按最近编辑排序，
/// 看最近动过什么直接看前几张卡即可。
///
/// 内容区：按 [view] 分发——日历走网格，其余走卡片网格（取数口径见
/// [_HomeBody._itemsFor]）。
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

    // 日历视图：日历卡片 + 卡片外下方的选中日篇目（忽略搜索词）。
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

    // 其余四视图：卡片网格（搜索词在当前范围内过滤）。
    final List<Note> items = _itemsFor(ref, all);

    // 「更多」视图：排序方案 + 标签筛选两行常驻在网格上方（跨形态统一池）。
    final Widget? morePanel = view == HomeView.filter
        ? const _MorePanel()
        : null;

    if (items.isEmpty) {
      return Column(
        children: <Widget>[
          ?morePanel,
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
        ?morePanel,
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

  /// 与 [_HomeHubState] 顶栏同一套口径的取数（这里在 build 内直接算，
  /// 避免把 State 的方法下传到 StatelessWidget）。
  List<Note> _itemsFor(WidgetRef ref, List<Note> all) {
    final SearchState s = search;
    // 排序方案在「更多」里选，对全部 / 笔记 / 画布 / 更多四视图全局生效。
    final Comparator<Note> order = ref.watch(homeSortProvider).comparator;
    final List<Note> scope = switch (view) {
      // 全部：跨形态统一池，跟随全局排序。
      HomeView.all => all.toList()..sort(order),
      HomeView.notes =>
        all.where((Note n) => n.kind != NoteKind.canvas).toList()..sort(order),
      HomeView.canvas =>
        all.where((Note n) => n.kind == NoteKind.canvas).toList()..sort(order),
      // 收藏不读全局排序，坚持"最近收藏在前"（收藏视图自身的语义）。
      HomeView.favorites => <Note>[
        ...all.where((Note n) => n.promotedAt != null),
      ]..sort((Note a, Note b) => b.promotedAt!.compareTo(a.promotedAt!)),
      HomeView.filter =>
        all
            .where(
              (Note n) => s.activeTag != null && n.tags.contains(s.activeTag),
            )
            .toList()
          ..sort(order),
      HomeView.calendar => const <Note>[],
    };
    // 有搜索词时命中按相关度（s.hits）排序，不被全局排序打乱。
    if (s.query.trim().isEmpty) return scope;
    final Set<String> ids = scope.map((Note n) => n.id).toSet();
    return <Note>[
      for (final SearchHit h in s.hits)
        if (ids.contains(h.note.id)) h.note,
    ];
  }
}

/// 顶栏的一枚**视图 tab**：图标 + 文字，选中披 [AppTheme.navSelectedTint]。
///
/// 静止态显式透明（防 Material 落 canvasColor 变黑块，全仓统一教训）；hover
/// 叠 [AppTheme.boardFillHover]；自带 [FocusRing]（§5.2）。
class _ViewTab extends StatefulWidget {
  const _ViewTab({
    required this.view,
    required this.active,
    required this.onTap,
  });

  final HomeView view;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_ViewTab> createState() => _ViewTabState();
}

class _ViewTabState extends State<_ViewTab> {
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
    final Color fill = widget.active
        ? AppTheme.navSelectedTint(scheme.onSurface)
        : _hover
        ? AppTheme.boardFillHover(theme.brightness)
        : Colors.transparent;
    final Color iconColor = widget.active
        ? scheme.onSurface
        : scheme.onSurfaceVariant;

    return FocusRing(
      focusNode: _focus,
      borderRadius: radius,
      child: Material(
        color: fill,
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
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Tokens.spaceMd,
              vertical: Tokens.spaceSm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                widget.view.icon(iconColor),
                const SizedBox(width: Tokens.spaceSm),
                Text(
                  widget.view.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: widget.active ? scheme.onSurface : iconColor,
                    fontWeight: widget.active ? FontWeight.w600 : null,
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
        maxCrossAxisExtent: 260,
        childAspectRatio: 1.5,
        crossAxisSpacing: Tokens.spaceMd,
        mainAxisSpacing: Tokens.spaceMd,
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
      ),
    );
  }
}

/// 一张**笔记卡片**：标题 + 摘要（2–3 行）+ 标签 + 相对时间。
///
/// 用现成卡片三件套（[AppTheme.cardFill] / [cardStroke] / [cardFillHover]）——
/// 静止态**有底色**（与列表行"显式透明"相反：卡片是一块浮起的板子，透明就没了
/// 卡片的样子）。画布卡片用 [CustomIcons.canvas] 角标区分形态（无缩略图渲染管线）。
class _NoteCard extends StatefulWidget {
  const _NoteCard({
    super.key,
    required this.note,
    required this.onOpen,
    this.onUnfavorite,
  });

  final Note note;
  final VoidCallback onOpen;
  final VoidCallback? onUnfavorite;

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
    final BorderRadius radius = BorderRadius.circular(Tokens.radiusLg);
    final Note n = widget.note;
    final bool isCanvas = n.kind == NoteKind.canvas;

    final String summary = n.plainText.trim();
    final List<String> tags = n.tags;

    return FocusRing(
      focusNode: _focus,
      borderRadius: radius,
      child: Material(
        color: _hover
            ? AppTheme.cardFillHover(brightness)
            : AppTheme.cardFill(brightness),
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
              border: Border.all(color: AppTheme.cardStroke(brightness)),
            ),
            padding: const EdgeInsets.all(Tokens.spaceMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // 标题行：左 = 形态角标（仅画布）+ 标题，右 = 取消收藏星（仅收藏视图）。
                Row(
                  children: <Widget>[
                    if (isCanvas) ...<Widget>[
                      CustomIcons.canvas(size: Tokens.iconXs + 4),
                      const SizedBox(width: Tokens.spaceXs),
                    ],
                    Expanded(
                      child: Text(
                        _titleOf(n),
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                              scheme.onSurfaceVariant,
                              ui.BlendMode.srcIn,
                            ),
                          ),
                          onPressed: widget.onUnfavorite,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Tokens.spaceXs),
                // 摘要：2–3 行，让人一眼知道大概内容。
                Expanded(
                  child: summary.isEmpty
                      ? Text(
                          '（空白）',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.6,
                            ),
                            fontStyle: FontStyle.italic,
                          ),
                        )
                      : Text(
                          summary,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                ),
                const SizedBox(height: Tokens.spaceSm),
                // 底行：标签（最多 3 枚 + `+n`）+ 右对齐相对时间。
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Wrap(
                        spacing: Tokens.spaceXs,
                        runSpacing: Tokens.spaceXs,
                        children: <Widget>[
                          for (final String t in tags.take(3))
                            _CardTag(label: t),
                          if (tags.length > 3)
                            _CardTag(label: '+${tags.length - 3}'),
                        ],
                      ),
                    ),
                    const SizedBox(width: Tokens.spaceSm),
                    Text(
                      _relativeTime(n.revisedAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
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
        borderRadius: BorderRadius.circular(Tokens.radiusSm),
        border: Border.all(color: AppTheme.cardStroke(theme.brightness)),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
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
    } else {
      text = switch (view) {
        HomeView.notes => '还没有笔记',
        HomeView.canvas => '还没有画布',
        HomeView.all => '还没有笔记或画布',
        HomeView.favorites => '还没有收藏',
        HomeView.filter => switch ((
          activeTag,
          ref.watch(allTagsProvider).isNotEmpty,
        )) {
          (null, true) => '选一枚标签，看它名下的内容',
          (null, false) => '还没有标签，先在笔记里打上标签',
          (final String tag, _) => '「$tag」标签下还没有内容',
        },
        HomeView.calendar => '', // 不会走到。
      };
    }
    return Center(
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 「更多」视图顶部的常驻面板（2026-09-29 用户定）：第一行**视图入口**
/// （笔记 / 画布——2026-09-29 再定：低频视图收进来，顶栏只留高频四枚
/// [kHomeTabs]，点了照旧整页切换）、第二行排序方案、第三行标签筛选。
class _MorePanel extends ConsumerWidget {
  const _MorePanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[_ViewEntriesRow(), _SortRow(), _TagChips()],
    );
  }
}

/// 视图入口行：**笔记 / 画布**两枚 chips（低频视图的整页入口）。与排序 /
/// 标签 chips 同语言（[_TagChip]），但点它不是"过滤当前池"，是**切换视图**
/// （[HomeViewNotifier.select]）——顶栏随之高亮「更多」。
class _ViewEntriesRow extends ConsumerWidget {
  const _ViewEntriesRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceLg,
          vertical: Tokens.spaceSm,
        ),
        scrollDirection: Axis.horizontal,
        itemCount: 2,
        separatorBuilder: (BuildContext _, int _) =>
            const SizedBox(width: Tokens.spaceSm),
        itemBuilder: (BuildContext context, int i) {
          final HomeView v = i == 0 ? HomeView.notes : HomeView.canvas;
          return _TagChip(
            label: v.label,
            selected: false,
            onTap: () => ref.read(homeViewProvider.notifier).select(v),
          );
        },
      ),
    );
  }
}

/// 排序方案行：[NoteSort.values] 一排 chips，选中走 [homeSortProvider]。
/// 视觉与标签 chips 同语言（[_TagChip]，无篇数小字）。
class _SortRow extends ConsumerWidget {
  const _SortRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NoteSort sort = ref.watch(homeSortProvider);
    return SizedBox(
      height: 40,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceLg,
          vertical: Tokens.spaceSm,
        ),
        scrollDirection: Axis.horizontal,
        itemCount: NoteSort.values.length,
        separatorBuilder: (BuildContext _, int _) =>
            const SizedBox(width: Tokens.spaceSm),
        itemBuilder: (BuildContext context, int i) {
          final NoteSort s = NoteSort.values[i];
          return _TagChip(
            label: s.label,
            selected: s == sort,
            onTap: () => ref.read(homeSortProvider.notifier).select(s),
          );
        },
      ),
    );
  }
}

/// 标签筛选行（「更多」面板的第二行）：全库标签池（[allTagsProvider]，按出现
/// 篇数倒序），无标签时整行收起。
///
/// 用 `select` 只订阅 [SearchState.activeTag]——chips 行不该因结果变化而重建。
class _TagChips extends ConsumerWidget {
  const _TagChips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<(String, int)> tags = ref.watch(allTagsProvider);
    if (tags.isEmpty) return const SizedBox.shrink();
    final String? active = ref.watch(
      searchNotifierProvider.select((SearchState s) => s.activeTag),
    );
    return SizedBox(
      height: 40,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceLg,
          vertical: Tokens.spaceSm,
        ),
        scrollDirection: Axis.horizontal,
        itemCount: tags.length,
        separatorBuilder: (BuildContext _, int _) =>
            const SizedBox(width: Tokens.spaceSm),
        itemBuilder: (BuildContext context, int i) {
          final (String tag, int count) = tags[i];
          final bool selected = tag == active;
          return _TagChip(
            label: tag,
            count: count,
            selected: selected,
            onTap: () => ref
                .read(searchNotifierProvider.notifier)
                .selectTag(selected ? null : tag),
          );
        },
      ),
    );
  }
}

/// 一枚筛选 chip（排序 / 标签共用）：主文字 + 可选篇数小字。
/// 选中 = 导航项同款选中底，未选中 = 极淡描边。
class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;

  /// 篇数小字（标签行传；排序行不传则不渲染）。
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tokens.radiusLg),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceSm + 2,
          vertical: 4,
        ),
        decoration: BoxDecoration(
          color: selected ? AppTheme.navSelectedTint(scheme.onSurface) : null,
          borderRadius: BorderRadius.circular(Tokens.radiusLg),
          border: Border.fromBorderSide(
            BorderSide(color: AppTheme.cardStroke(theme.brightness)),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurface,
              ),
            ),
            if (count != null) ...<Widget>[
              const SizedBox(width: Tokens.spaceXs),
              Text(
                '$count',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────── 公共小料 ───────────────────────────

String _titleOf(Note note) => note.title.isEmpty ? '无标题' : note.title;

/// 相对时间：关心的是"多久没碰了"，不是精确时刻。
String _relativeTime(DateTime at) {
  final Duration d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  if (d.inDays < 7) return '${d.inDays} 天前';
  return '${at.month}-${at.day.toString().padLeft(2, '0')}';
}

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

    // 新拟态面板（2026-09-26 用户定）：同色浮起，软阴影分区，
    // 不引入实体边框——只靠光影把「日历 + 选中日列表」整组托起。
    final bool isLight = theme.brightness == Brightness.light;
    // 面板底色与纸面**只差一档**、两边对称（2026-09-26 用户定）：
    // 亮色比纸面**浅一档**（boardFill）；暗色比底**深一档**（从 contentCanvas
    // 往 board 方向取 30%）。
    // ⚠️ 两边**都不描边**：描边会让暗色那块出现一条框、与亮色无框的语言
    // 不一致（用户反馈别扭）——边界一律由「色差 + 阴影」定义。
    final Color panel = isLight
        ? AppTheme.boardFill(theme.brightness)
        : Color.lerp(
            AppTheme.contentCanvas(theme.brightness),
            AppTheme.boardFill(theme.brightness),
            0.3,
          )!;
    // 双向软阴影：暗侧把面板压在纸面、亮侧给左上缘高光，合成"浮起"。
    // 明暗分开（2026-09-26 用户反馈）：暗环境里底色差的感知弱，浮起感主要靠
    // 阴影撑；亮色底色差够读出边界，保持减弱版。
    final Color hi = isLight
        ? Color.lerp(panel, Colors.white, 0.7)!
        : Color.lerp(panel, Colors.white, 0.06)!;
    final Color lo = isLight
        ? Color.lerp(panel, Colors.black, 0.15)!
        : Color.lerp(panel, Colors.black, 0.45)!;
    // 偏移/羽化同样明暗分开：亮色收紧（它的色差够用），暗色放开——去掉描边后
    // 暗色的边界由"色差 + 更强阴影"撑，offset 太小就又糊。
    final Offset shadowOffset = isLight
        ? const Offset(2, 2)
        : const Offset(6, 6);
    final double shadowBlur = isLight ? 6 : 8;

    // 日历**卡片**：只装月份头 / 星期 / 网格 / 底部「写日记」。选中日的篇目
    // 列表挪到卡片之外（见本方法 return 的第二段），两种背景分开。
    final Widget card = DecoratedBox(
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(Tokens.radiusLg),
        // ⚡ 暗色改用应用统一的"微阴影"（floatShadows）：纯下投软影，不再双向
        // 拟态（2026-09-27 用户定）；背景靠 panel 实色差分层，阴影只给浮起感。
        boxShadow: isLight
            ? <BoxShadow>[
                BoxShadow(
                  color: lo,
                  offset: shadowOffset,
                  blurRadius: shadowBlur,
                ),
                BoxShadow(
                  color: hi,
                  offset: -shadowOffset,
                  blurRadius: shadowBlur,
                ),
              ]
            : AppTheme.floatShadows(theme.brightness),
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
                              color: scheme.onSurfaceVariant,
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
                  color: AppTheme.cardStroke(theme.brightness),
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
                    color: AppTheme.navSelectedTint(scheme.onSurface),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '${selected.day}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurface,
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
                          color: scheme.onSurface,
                        ),
                      ),
                      TextSpan(
                        text: '  ·  新建 ${dayNotes.length} 篇',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
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
                color: scheme.onSurfaceVariant,
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
              color: scheme.onSurface,
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
              scheme.onSurfaceVariant,
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
              scheme.onSurfaceVariant,
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
              ? AppTheme.boardFillHover(theme.brightness)
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
                        scheme.onSurfaceVariant,
                        ui.BlendMode.srcIn,
                      ),
                    ),
                    const SizedBox(width: Tokens.spaceSm),
                    Text(
                      '写日记',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${widget.day.month} 月 ${widget.day.day} 日 · 周${weekdays[widget.day.weekday - 1]}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
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
    // 状态底：选中 = 玻璃 tint（与导航选中同语言）；hover = 再叠一档。
    final Color? fill = widget.isSelected
        ? AppTheme.navSelectedTint(scheme.onSurface)
        : (_hover && widget.onTap != null)
        ? AppTheme.boardFillHover(theme.brightness)
        : null;
    final Color textColor = dim
        ? scheme.onSurface.withValues(alpha: 0.3)
        : scheme.onSurfaceVariant;

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
                        border: Border.all(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '${widget.date.day}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: widget.isSelected ? scheme.onSurface : textColor,
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
                  ? AppTheme.boardFillHover(brightness)
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
              ? AppTheme.boardFillHover(theme.brightness)
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
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
