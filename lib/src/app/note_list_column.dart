import 'dart:async' show unawaited;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../command/commands.dart';
import '../theme/app_custom_icons.dart';
import '../theme/app_float_surface.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import '../domain/note.dart';
import 'home_hub.dart'
    show
        FilterMenuButton,
        NoteSort,
        homeItemsProvider,
        homeKindFacetProvider,
        homeSortProvider;
import 'note_display.dart';
import 'note_import.dart';
import 'providers.dart';
import 'search_provider.dart';
import 'stream_delete.dart' show showStreamConfirm;

/// 列表头**动作带**的上/下留白（4）：与编辑页头部按钮带的上留白同值
///（`_kHeaderActionTopPadding` = 4）。两条带都从内容卡顶边起算 ⇒ 按钮
/// **同一 y、同一尺寸**（2026-10-22 用户定）。
const double _kHeadBandPadding = 4;

/// 动作钮热区：与编辑页撤销 / 重做 / 双耳同一个 [Tokens.headerActionSize]（30）。
const double _kHeadButtonSize = Tokens.headerActionSize;

/// 列表头**工具行**左内缩：悬浮折叠钮（5 内缩 + 30 钮）+ 5 呼吸 = 40。
///
/// 钮本体不在列表里——它悬浮在内容卡左上角（`home_screen.dart` 的 Stack 顶层，
/// 折叠时不随列宽移动），这里只是给它让位。
const double _kHeadToolInset = _kHeadBandPadding + _kHeadButtonSize + _kHeadBandPadding;

/// 240px **笔记列表列**（主从布局的"主"，Option 2 进卡）：坐在浮面卡左格，右格是详情
/// （编辑器 / 画布 / 空态）。服务「全部 / 笔记 / 画布 / 收藏」四个主从视图——
/// 灵感是一页纸时间流，由外壳直接挂 `StreamView`，不经过这里（2026-10-17 收口）；
/// 日历整卡显示，也不经过这里。
///
/// - 头（2026-10-21 用户定，复刻 ima）：**第一行 = 工具行**（左留位给悬浮折叠钮，
///   右端 新建 / 搜索 / 筛选 三枚）；**第二行 = 视图名 + 篇数**（从按钮行下移）。
/// - 体 = 当前视图的笔记行（[homeItemsProvider]，已按排序 + 形态 + 标签过滤），
///   再叠一层**页内搜索**（标题 + 摘要内存过滤，见 [_NoteListColumnState]）。
/// - 行：点 / Enter 开（走 [locateProvider]，`focus` 默认 false ⇒ 焦点不被编辑器抢走）；
///   选中行（== [selectedNoteIdProvider]）铺 navSelectedTint 同款选中底（= hover 2×）。
///
/// ## 极简留白（2026-10-17 用户定）
/// 不用行间分割线（满格横线 = 表格感）——分层靠：① 留白（行 vertical padding spaceMd）；
/// ② 字重三级（标题 w600 浓墨 / 摘要 w400 淡墨 / 时间·图标 最小最淡）；③ 选中态淡色底。
class NoteListColumn extends ConsumerStatefulWidget {
  const NoteListColumn({super.key});

  @override
  ConsumerState<NoteListColumn> createState() => _NoteListColumnState();
}

class _NoteListColumnState extends ConsumerState<NoteListColumn> {
  /// 页内搜索态（2026-10-21）：点 ⌕ 展开输入框，Esc / 清空收起。
  ///
  /// 只过滤**当前列表**（标题 + 摘要），刻意不碰全局检索
  /// （[searchNotifierProvider]）——全局搜索后续要撤，先不耦合。
  bool _searching = false;
  final TextEditingController _searchInput = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _searchInput.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    _searchInput.removeListener(_onQueryChanged);
    _searchInput.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onQueryChanged() => setState(() {});

  void _openSearch() {
    setState(() => _searching = true);
    // 帧末再要焦点：AnimatedSwitcher 的新子件当帧还没挂上焦点节点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  /// 收起并清词（Esc 或点收起钮）。
  void _closeSearch() => setState(() {
    _searching = false;
    _searchInput.clear();
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    final HomeView view = ref.watch(
      navHistoryProvider.select((NavHistoryState s) => s.view),
    );
    final List<Note> items = ref.watch(
      homeItemsProvider((
        view: view,
        tag: ref.watch(searchNotifierProvider).activeTag,
        kind: ref.watch(homeKindFacetProvider),
      )),
    );
    final String? selectedId = ref.watch(selectedNoteIdProvider);

    // 页内过滤：命中标题或摘要（大小写不敏感；中文天然子串命中）。
    final String query = _searchInput.text.trim();
    final List<Note> shown = query.isEmpty
        ? items
        : items
              .where(
                (Note n) =>
                    noteDisplayTitle(n).toLowerCase().contains(
                      query.toLowerCase(),
                    ) ||
                    n.summary.toLowerCase().contains(query.toLowerCase()),
              )
              .toList(growable: false);

    // **按时间分组**（2026-10-21 用户定，方案 A）：组头（今天 / 昨天 / `12 月 31 日`）
    // 替行内日期说话，行内不再显示"2 天前"——那玩意儿每行重复同一天、还把右缘
    // 占成一条竖列（见 [_NoteRow]）。
    //
    // 只在**列表顺序本身是时间顺序**时分组：默认「最近编辑」；收藏视图按收藏时间
    // 排（不是 revisedAt）、标题 / 最近创建排序同理 ⇒ 那些情况退回平铺。
    final bool grouped =
        view != HomeView.favorites &&
        ref.watch(homeSortProvider) == NoteSort.revised;
    // 组头与行交错成扁平列表，交给一个 ListView.builder 渲染（组头 = String，
    // 行 = Note）。
    final List<Object> rows = <Object>[];
    if (grouped) {
      String? label;
      for (final Note n in shown) {
        final String next = dayLabel(n.revisedAt);
        if (next != label) {
          rows.add(next);
          label = next;
        }
        rows.add(n);
      }
    } else {
      rows.addAll(shown);
    }
    // ⚠️ 灵感**不走这里**：它是独立的一页纸流（`StreamView`，由外壳直接挂载）。

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 第一行 = **工具行**（2026-10-21 用户定）：右端三枚动作钮（新建 / 搜索 /
        // 筛选）；点「搜索」整行换成输入框。左留位给悬浮折叠钮（见 [_kHeadToolInset]）。
        Padding(
          // 上/下留白 = 编辑页按钮带同值；右侧取 spaceMd（与编辑页右留白一致）。
          padding: const EdgeInsets.fromLTRB(
            _kHeadToolInset,
            _kHeadBandPadding,
            Tokens.spaceMd,
            _kHeadBandPadding,
          ),
          child: AnimatedSwitcher(
            duration: Tokens.durationFast,
            child: _searching
                ? _ListSearchField(
                    key: const ValueKey<String>('list-search'),
                    hint: view == HomeView.canvas ? '搜索画布' : '搜索笔记',
                    controller: _searchInput,
                    focusNode: _searchFocus,
                    onClose: _closeSearch,
                  )
                : Row(
                    key: const ValueKey<String>('list-head-actions'),
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      // 新建（2026-10-21 复刻 ima 的 `+ ▾`）：左半 `+` 直建**当前页
                      // 类型**，右半 `▾` 开托盘（新建笔记 / 新建画布 / 导入…）。
                      _ListNewButton(view: view),
                      const SizedBox(width: Tokens.spaceXxs),
                      _HeadIconButton(
                        tooltip: '搜索',
                        icon: const tabler.Search(
                          height: Tokens.iconSm,
                          width: Tokens.iconSm,
                          strokeWidth: 1.5,
                        ),
                        onPressed: _openSearch,
                      ),
                      const SizedBox(width: Tokens.spaceXxs),
                      const FilterMenuButton(),
                    ],
                  ),
          ),
        ),
        // 第二行 = **视图名 + 篇数**（同日定：从按钮行下移，独占一行）。
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Tokens.spaceMd,
            0,
            Tokens.spaceSm,
            Tokens.spaceSm,
          ),
          child: Row(
            children: <Widget>[
              Text(
                _viewLabel(view),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: Bauhaus.ink(b),
                ),
              ),
              const SizedBox(width: Tokens.spaceXs),
              Text(
                '${shown.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Bauhaus.inkMuted(b),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
        // 头下发丝（通栏，结构线：固定头 ↔ 滚动体；非行间装饰线）。
        Container(height: 1, color: Bauhaus.line(b)),
        // 体：滚动条目 / 空态。
        Expanded(
          child: shown.isEmpty
              ? _ListEmpty(view: view, query: query)
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (BuildContext context, int i) {
                    final Object row = rows[i];
                    // 组头 = String（不可点、不进焦点链，只做分段）。
                    if (row is String) {
                      return _RowHeader(
                        // key 钉在**组名**：组头随日期变化时靠它换元素，
                        // 不会把上一个组头的 State 借给新组。
                        key: ValueKey<String>('note-row-header-$row'),
                        label: row,
                        first: i == 0,
                      );
                    }
                    final Note n = row as Note;
                    return _NoteRow(
                      // key 钉在 **noteId**（2026-10-21）：`ListView.builder` 按**下标**
                      // 复用 Element，无 key 时 `_NoteRowState` 里的 hover / 键盘焦点锚
                      // 会跟着**位置**走而不是跟着笔记走——新建一篇插到最前，所有行下移
                      // 一格，锚点就错配到别的笔记上。与网格卡片 `_NoteCard`
                      //（`note-card-$id`）同一处理。
                      key: ValueKey<String>('note-row-${n.id}'),
                      note: n,
                      selected: n.id == selectedId,
                      onOpen: () => ref
                          .read(locateProvider.notifier)
                          .locate(noteId: n.id),
                      onDelete: () => _trash(context, ref, n),
                      // ↑/↓：读当前顺序 + 选中，算上/下一篇，走 [LocateNotifier.preview]
                      // （静默选中、**不入历史**，不刷爆前进/后退栈）。选中行自己在
                      // didUpdateWidget 里滚入视野 + 接管焦点（焦点锚跟着选中走）。
                      onNavigate: (int delta) {
                        final String? cur = ref.read(selectedNoteIdProvider);
                        final int i = cur == null
                            ? -1
                            : items.indexWhere((Note n) => n.id == cur);
                        final int target = i < 0
                            ? (delta > 0 ? 0 : items.length - 1)
                            : (i + delta).clamp(0, items.length - 1);
                        if (target == i) return;
                        ref
                            .read(locateProvider.notifier)
                            .preview(noteId: items[target].id);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 删除 = 软删进**全局回收站**（30 天后自动彻底删除）。
  Future<void> _trash(BuildContext context, WidgetRef ref, Note note) async {
    final bool ok = await showStreamConfirm(
      context: context,
      title: '移入回收站',
      message: '将「${noteDisplayTitle(note)}」移入回收站？30 天后自动彻底删除。',
      confirmLabel: '移入回收站',
    );
    if (!ok) return;
    await ref.read(notesProvider.notifier).trashNote(note.id);
  }
}

String _viewLabel(HomeView v) => switch (v) {
  HomeView.timeline => '灵感',
  HomeView.all => '全部',
  HomeView.notes => '笔记',
  HomeView.canvas => '画布',
  HomeView.calendar => '日历',
  HomeView.favorites => '收藏',
};

/// 列表内的**日期组头**（今天 / 昨天 / `12 月 31 日`）：一句 labelSmall，左对齐
/// 行文字左缘（= 行的 horizontal padding），不可点、不进焦点链。
///
/// 读法沿用灵感页的日期组头（`stream_view._DayHeader`）：时间信息由组头承担，
/// 行内不再重复（2026-10-21 用户定，方案 A）。
class _RowHeader extends StatelessWidget {
  const _RowHeader({super.key, required this.label, this.first = false});

  final String label;

  /// 是不是**列表第一组**：第一组紧贴表头分界线，顶距收成 `spaceSm`；
  /// 其余组之间要拉开段落感，用 `spaceLg`（2026-10-21 用户定）。
  final bool first;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Tokens.spaceMd,
        first ? Tokens.spaceSm : Tokens.spaceLg,
        Tokens.spaceMd,
        Tokens.spaceXs,
      ),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: Bauhaus.inkMuted(theme.brightness),
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}

/// 列表头工具行的单枚图标钮（32 方块，与 [FilterMenuButton] 同规格）。
///
/// hover 铺 [AppTheme.hoverOverlay]、焦点环**只给键盘**（同 [_NoteRow] 口径，
/// 2026-10-21：鼠标点过也戴环会被误读成选中态）。
class _HeadIconButton extends StatefulWidget {
  const _HeadIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final Widget icon;
  final VoidCallback onPressed;

  @override
  State<_HeadIconButton> createState() => _HeadIconButtonState();
}

class _HeadIconButtonState extends State<_HeadIconButton> {
  bool _hover = false;
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    final Color bg = _hover ? AppTheme.hoverOverlay(b) : Colors.transparent;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: FocusableActionDetector(
          focusNode: _focus,
          mouseCursor: SystemMouseCursors.click,
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<Intent>(
              onInvoke: (_) {
                widget.onPressed();
                return null;
              },
            ),
          },
          child: Semantics(
            button: true,
            label: widget.tooltip,
            child: FocusRing(
              focusNode: _focus,
              keyboardOnly: true,
              borderRadius: BorderRadius.circular(Tokens.radiusButton),
              child: GestureDetector(
                onTap: widget.onPressed,
                child: Container(
                  width: _kHeadButtonSize,
                  height: _kHeadButtonSize,
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(Tokens.radiusButton),
                  ),
                  child: Center(
                    child: IconTheme(
                      // 图标档与编辑页撤销 / 重做同一个 [Tokens.iconSm]（18）。
                      data: IconThemeData(
                        color: theme.colorScheme.onSurfaceVariant,
                        size: Tokens.iconSm,
                      ),
                      child: widget.icon,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 托盘宽（180：容得下最长的一条「导入 Markdown…」）。
const double _kTrayWidth = 180;

/// 列表头的**新建分半钮**（2026-10-21 用户定，复刻 ima 的 `+ ▾`）：
/// 左半 `+` 直建**当前页类型**（笔记页建笔记、画布页建画布），右半 `▾` 开托盘
/// （新建笔记 / 新建画布 / 导入…）。
///
/// 刻意**不复用** [NewNoteCapsule]：那个是"整块点击即开托盘"（轨上在用，交互已
/// 定型），这里要的是"主按钮直接建 + 箭头开托盘"两种分工。
class _ListNewButton extends ConsumerStatefulWidget {
  const _ListNewButton({required this.view});

  final HomeView view;

  @override
  ConsumerState<_ListNewButton> createState() => _ListNewButtonState();
}

class _ListNewButtonState extends ConsumerState<_ListNewButton> {
  /// 托盘开合（供箭头翻转）：`MenuAnchor` 的 onOpen / onClose 驱动。
  bool _menuOpen = false;

  @override
  Widget build(BuildContext context) {
    final Brightness b = Theme.of(context).brightness;
    final bool canvasPage = widget.view == HomeView.canvas;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _HeadIconButton(
          tooltip: canvasPage ? '新建画布' : '新建笔记',
          icon: const tabler.Plus(
            height: Tokens.iconSm,
            width: Tokens.iconSm,
            strokeWidth: 1.5,
          ),
          onPressed: () => unawaited(
            runCommandById(ref, canvasPage ? 'canvas.new' : 'note.new'),
          ),
        ),
        // 箭头 = 托盘锚点。主按钮（`+`）在它**外面**，点击不开托盘、直接建。
        MenuAnchor(
          style: MenuStyle(
            elevation: const WidgetStatePropertyAll<double?>(0),
            // 面板本体不涂色：真正的面由 menuChildren 里的 [AppFloatSurface] 画
            // （同 `NewNoteCapsule` 的口径，主题 surface 实色）。
            backgroundColor: const WidgetStatePropertyAll<Color?>(
              Colors.transparent,
            ),
            side: const WidgetStatePropertyAll<BorderSide?>(BorderSide.none),
            shape: WidgetStatePropertyAll<OutlinedBorder?>(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Tokens.radiusLg),
              ),
            ),
            padding: const WidgetStatePropertyAll<EdgeInsetsGeometry?>(
              EdgeInsets.zero,
            ),
            // 从箭头**正下方**向下展开（左缘对齐、顶边贴底边）——零布局位移。
            alignment: AlignmentDirectional.bottomStart,
            minimumSize: const WidgetStatePropertyAll<Size?>(
              Size(_kTrayWidth, 0),
            ),
          ),
          alignmentOffset: const Offset(0, Tokens.spaceXxs),
          // ⚠️ `MenuAnchor` **不会**自动在点击 child 时开菜单（官方用法就是按钮的
          // `onPressed` 里自己 `controller.open()`）。所以箭头必须拿到 builder 里的
          // 控制器、自己 toggle——只挂个装饰性箭头会"点了没反应"。
          onOpen: () => setState(() => _menuOpen = true),
          onClose: () => setState(() => _menuOpen = false),
          builder: (BuildContext context, MenuController controller, Widget? _) =>
              _TrayArrow(
                // 菜单开着时箭头下翻（收起时翻回），给一个"这是个下拉"的线索。
                open: _menuOpen,
                onTap: () {
                  if (_menuOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
              ),
          menuChildren: <Widget>[
            AppFloatSurface(
              color: Bauhaus.surface(b),
              borderRadius: BorderRadius.circular(Tokens.radiusLg),
              width: _kTrayWidth,
              padding: EdgeInsets.zero,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // ⚠️ 托盘行**不放快捷键提示**：180 宽放"图标 + 标签 +
                  // Ctrl+Shift+N" 会溢出 52px（实测）。键位由命令面板 / 设置
                  // 里的键位表负责，这里只给动作本身。
                  _TrayTile(
                    icon: CustomIcons.edit19(
                      size: Tokens.iconMdSm,
                      color: Bauhaus.ink(b),
                    ),
                    label: '新建笔记',
                    onTap: () =>
                        unawaited(runCommandById(ref, 'note.new')),
                  ),
                  const _TrayHairline(),
                  _TrayTile(
                    icon: CustomIcons.brush(
                      size: Tokens.iconMdSm,
                      color: Bauhaus.ink(b),
                    ),
                    label: '新建画布',
                    onTap: () =>
                        unawaited(runCommandById(ref, 'canvas.new')),
                  ),
                  const _TrayHairline(),
                  // 导入 = **新建**（不覆盖）：md 走 appflowy 的 md 解析器、
                  // 画布走 bundle 还原，两条链路都落在 importNote 上。
                  _TrayTile(
                    icon: tabler.Download(
                      height: Tokens.iconMdSm,
                      width: Tokens.iconMdSm,
                      strokeWidth: Tokens.iconStroke,
                      colorFilter: ui.ColorFilter.mode(
                        Bauhaus.ink(b),
                        ui.BlendMode.srcIn,
                      ),
                    ),
                    label: canvasPage ? '导入画布文件…' : '导入 Markdown…',
                    onTap: () => unawaited(_runImport(ref, canvasPage)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 跑导入并把结果接到定位 / 报错上。
  Future<void> _runImport(WidgetRef ref, bool canvasPage) async {
    final NotesNotifier notes = ref.read(notesProvider.notifier);
    final ImportOutcome outcome = canvasPage
        ? await importCanvasNote(
            notes,
            media: ref.read(mediaResolverProvider),
          )
        : await importMarkdownNote(notes);
    if (!mounted) return;
    final String? error = outcome.error;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    final Note? note = outcome.note;
    if (note == null) return; // 用户取消
    // 建完就打开（带焦点：导入就是为了接着看 / 改）。
    ref.read(locateProvider.notifier).locate(noteId: note.id, focus: true);
  }
}

/// 托盘箭头（`▾`）：24 宽、32 高的窄钮，hover 铺底；菜单开着时**向上翻**。
class _TrayArrow extends StatefulWidget {
  const _TrayArrow({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  State<_TrayArrow> createState() => _TrayArrowState();
}

class _TrayArrowState extends State<_TrayArrow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Brightness b = Theme.of(context).brightness;
    return Tooltip(
      // 读屏与测试都靠它：一枚没有名字的箭头按钮，键盘 / 辅助技术无从下手。
      message: '更多新建选项',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 22,
            height: _kHeadButtonSize,
            decoration: BoxDecoration(
              color: _hover ? AppTheme.hoverOverlay(b) : Colors.transparent,
              borderRadius: BorderRadius.circular(Tokens.radiusButton),
            ),
            child: Center(
              child: IconTheme(
                // 箭头是**行内装饰记号**，比动作图标再小一档 [Tokens.iconXs]（14）
                // ——28 的热区里放 18 的箭头会显得笨重。
                data: IconThemeData(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  size: Tokens.iconXs,
                ),
                child: widget.open
                    ? const tabler.ChevronUp(strokeWidth: 1.5)
                    : const tabler.ChevronDown(strokeWidth: 1.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 托盘里的一行：图标 + 标签，36 高，hover 铺底。
///
/// 标签走 `Expanded` + 省略号：托盘宽 180，**任何**标签都不许把行撑溢出
/// （"导入 Markdown…" 差 5px 就溢出过一次）。
class _TrayTile extends StatefulWidget {
  const _TrayTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Widget icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_TrayTile> createState() => _TrayTileState();
}

class _TrayTileState extends State<_TrayTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 36,
          margin: const EdgeInsets.symmetric(horizontal: Tokens.spaceXxs),
          padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceSm),
          decoration: BoxDecoration(
            color: _hover ? AppTheme.hoverOverlay(b) : Colors.transparent,
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
          ),
          child: Row(
            children: <Widget>[
              widget.icon,
              const SizedBox(width: Tokens.spaceSm),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Bauhaus.ink(b),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 托盘里的 1px 发丝分隔（与面板底反相，两种明度下都分得开）。
class _TrayHairline extends StatelessWidget {
  const _TrayHairline();

  @override
  Widget build(BuildContext context) {
    final Brightness b = Theme.of(context).brightness;
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: Tokens.spaceXs),
      color: Bauhaus.inkMuted(b).withValues(alpha: 0.16),
    );
  }
}

/// 页内搜索框（2026-10-21）：点 ⌕ 后**整行替换**工具钮（ima 同款）。
///
/// 32 高、1px 发丝边、左放大镜、有词时右显出收起钮；Esc 收起并清词。
/// 过滤逻辑在 [_NoteListColumnState]（标题 + 摘要内存过滤），本件只管输入。
class _ListSearchField extends StatelessWidget {
  const _ListSearchField({
    super.key,
    required this.hint,
    required this.controller,
    required this.focusNode,
    required this.onClose,
  });

  final String hint;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    final Color line = Bauhaus.line(b);
    final Widget magnifier = IconTheme(
      data: IconThemeData(color: Bauhaus.inkMuted(b), size: Tokens.iconMdSm),
      child: const tabler.Search(strokeWidth: 1.5),
    );
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): onClose,
      },
      child: Container(
        height: Tokens.headerActionSize,
        padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceSm),
        decoration: BoxDecoration(
          color: Bauhaus.surface(b),
          borderRadius: BorderRadius.circular(Tokens.radiusMd),
          border: Border.all(color: line),
        ),
        child: Row(
          children: <Widget>[
            magnifier,
            const SizedBox(width: Tokens.spaceXs),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                cursorColor: theme.colorScheme.primary,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Bauhaus.ink(b),
                ),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  hintText: hint,
                  hintStyle: theme.textTheme.bodySmall?.copyWith(
                    color: Bauhaus.inkMuted(b),
                  ),
                  // 四个状态全置空：主题的 inputDecorationTheme 有描边框
                  // （表单场景），只写 border 会被 enabledBorder 盖掉。
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                ),
              ),
            ),
            // 有词时才显出收起钮（无词时 Esc 就够了，别多一枚占位的钮）。
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (BuildContext context, TextEditingValue v, Widget? _) {
                if (v.text.isEmpty) return const SizedBox.shrink();
                return GestureDetector(
                  onTap: onClose,
                  child: IconTheme(
                    data: IconThemeData(
                      color: Bauhaus.inkMuted(b),
                      size: Tokens.iconMdSm,
                    ),
                    child: const tabler.X(strokeWidth: 1.5),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 列表列空态（当前视图 / 筛选下没有笔记）。
class _ListEmpty extends StatelessWidget {
  const _ListEmpty({required this.view, this.query = ''});

  final HomeView view;

  /// 页内搜索的查询词（非空 ⇒ 空态说"没有匹配"，不说"还没有"）。
  final String query;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    final String text = query.isNotEmpty
        ? '没有匹配「$query」'
        : switch (view) {
            HomeView.favorites => '还没有收藏的笔记',
            HomeView.notes => '还没有笔记',
            HomeView.canvas => '还没有画布',
            _ => '这个视图还没有笔记',
          };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Tokens.spaceLg),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: Bauhaus.inkMuted(b),
          ),
        ),
      ),
    );
  }
}

/// 单行笔记：标题（1 行 w600 浓墨）+ 摘要（2 行 w400 淡墨）+ 右对齐相对时间。
/// **行首不放 kind 图标**（2026-10-21 用户定），**删除走右键菜单**（同日定，行内
/// 不再有垃圾桶按钮——常驻的时间 + 桶把右缘占成一条竖列，视觉很重）。
/// 选中 / hover 底与 60 轨同口径（选中 = hover 2×）。
class _NoteRow extends StatefulWidget {
  const _NoteRow({
    super.key,
    required this.note,
    required this.selected,
    required this.onOpen,
    required this.onNavigate,
    required this.onDelete,
  });

  final Note note;
  final bool selected;
  final VoidCallback onOpen;

  /// ↑/↓ 由本行方向键快捷键触发，回调给父列切上/下一篇（父才知道全局顺序）。
  final ValueChanged<int> onNavigate;

  /// 行内「删除」（软删进全局回收站）。
  final VoidCallback onDelete;

  @override
  State<_NoteRow> createState() => _NoteRowState();
}

/// ↑/↓ 的意图（带方向 delta）：行内 [SingleActivator] 快捷键映射到它，动作回调给父
/// 切上/下一篇——父才知道全局顺序，行只知道"我被按了"。
class _RowNavIntent extends Intent {
  const _RowNavIntent(this.delta);
  final int delta;
}

class _NoteRowState extends State<_NoteRow> {
  bool _hover = false;
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_NoteRow old) {
    super.didUpdateWidget(old);
    // 被选中（点开 / ↑↓ 预览切到这篇）⇒ 帧末把自己滚进视野 + 接管焦点。这样 ↑/↓ 的
    // "键盘锚"始终跟着选中行走，连续按不会断；只抢**行**的焦点、不抢编辑器（locate
    // 不带 focus）。放 post-frame：didUpdateWidget 在 build 期，布局还没定。
    if (widget.selected && !old.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _revealIfNeeded();
        _focus.requestFocus();
      });
    }
  }

  /// **只在看不见时**才滚动（2026-10-21 用户定：点一下就"置顶"太跳）。
  ///
  /// 此前直接调 `Scrollable.ensureVisible`：它默认 `alignment: 0.0`，会把目标行
  /// 对齐到视口**顶端** —— 于是点一行**当前就可见**的笔记，整列也会猛地滚到顶
  ///（用户读作"点击后这一条被置顶了"）。这里先量：整行已在视口内就一动不动，
  /// 只有键盘 ↑/↓ 走到折叠区外时才滚。
  void _revealIfNeeded() {
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    final RenderObject? box = context.findRenderObject();
    if (scrollable == null || box is! RenderBox || !box.hasSize) return;
    final RenderAbstractViewport? viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;

    // 对齐顶端 / 底端所需的两个滚动偏移：当前像素区间能同时容下这两个 ⇒ 完全可见。
    final ScrollPosition pos = scrollable.position;
    final double alignTop = viewport.getOffsetToReveal(box, 0.0).offset;
    final double alignBottom = viewport.getOffsetToReveal(box, 1.0).offset;
    final double visibleMin = pos.pixels;
    final double visibleMax = pos.pixels + pos.viewportDimension;
    if (alignTop >= visibleMin && alignBottom <= visibleMax) return; // 已整行可见

    Scrollable.ensureVisible(
      context,
      duration: Tokens.durationFast,
      curve: Curves.easeOut,
    );
  }

  /// 条目菜单（右键）：目前在列里的动作只有「删除」（软删进全局回收站）。
  ///
  /// 入口与样式对齐左侧旧列表 `NoteListView._openMenu`：零尺寸矩形锚在指针处、
  /// 危险项用 `scheme.error`。
  Future<void> _openMenu(Offset position) async {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: <PopupMenuEntry<void>>[
        PopupMenuItem<void>(
          onTap: widget.onDelete,
          child: Row(
            children: <Widget>[
              tabler.Trash(
                height: Tokens.iconSm,
                width: Tokens.iconSm,
                strokeWidth: Tokens.iconStroke,
                color: scheme.error,
              ),
              const SizedBox(width: Tokens.spaceSm),
              Text('删除', style: TextStyle(color: scheme.error)),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Brightness b = theme.brightness;
    final Note n = widget.note;
    final bool selected = widget.selected;
    // 选中底 = hover 的 2×（与 60 轨 [_RailButton] 同口径，2026-10-21 用户定）。

    final Color selectedBg = b == Brightness.dark
        ? Colors.white.withValues(alpha: 0.12)
        : scheme.onSurface.withValues(alpha: 0.08);
    final Color bg = selected
        ? selectedBg
        : (_hover ? AppTheme.hoverOverlay(b) : Colors.transparent);

    final String title = noteDisplayTitle(n);
    final String summary = n.summary.trim();

    return MouseRegion(
      onEnter: (_) {
        if (!_hover) setState(() => _hover = true);
      },
      onExit: (_) {
        if (_hover) setState(() => _hover = false);
      },
      child: FocusableActionDetector(
        focusNode: _focus,
        mouseCursor: SystemMouseCursors.click,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowDown): _RowNavIntent(1),
          SingleActivator(LogicalKeyboardKey.arrowUp): _RowNavIntent(-1),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<Intent>(
            onInvoke: (_) {
              widget.onOpen();
              return null;
            },
          ),
          _RowNavIntent: CallbackAction<_RowNavIntent>(
            onInvoke: (_RowNavIntent intent) {
              widget.onNavigate(intent.delta);
              return null;
            },
          ),
        },
        child: Semantics(
          button: true,
          enabled: true,
          selected: selected,
          // 标签 = 显示标题（屏幕阅读器 / 焦点顺序测试靠它认行）。
          label: title,
          child: FocusRing(
            focusNode: _focus,
            // 环只给**键盘**（2026-10-21 用户定）——鼠标点行也会抢焦点
            //（为了 ↑/↓ 的键盘锚），环若跟着焦点走就会被误读成选中态。
            keyboardOnly: true,
            borderRadius: Bauhaus.radius,
            child: GestureDetector(
              onTap: () {
                // 点行即把键盘锚放到这行：紧接着按 ↑/↓ 能继续在列表里走。
                _focus.requestFocus();
                widget.onOpen();
              },
              // 右键（2026-10-21 用户定）：删除从行内挪进**条目菜单**——入口与
              // 样式对齐左侧旧列表 `NoteListView`（指针处弹出、危险项红字）。
              onSecondaryTapDown: (TapDownDetails d) =>
                  _openMenu(d.globalPosition),
              child: Container(
                // hover / 选中都做成**内缩的圆角块**（2026-10-21 用户定"和图标栏
                // 一致"）：60 轨的钮就是 36 圆角 pill，不是通栏色带。外缩 4 + 内距 8
                // = 原来的 12 ⇒ 文字左缘不动。
                margin: const EdgeInsets.symmetric(horizontal: Tokens.spaceXs),
                padding: const EdgeInsets.symmetric(
                  horizontal: Tokens.spaceMd - Tokens.spaceXs,
                  vertical: Tokens.spaceMd,
                ),
                decoration: BoxDecoration(color: bg, borderRadius: Bauhaus.radius),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // 标题前**不再放 kind 图标**（2026-10-21 用户定：各页列表列统一去掉
                    // 行首图标，标题直接从行左缘起排，行更干净、也不靠小图标区分形态）。
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Bauhaus.ink(b),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (summary.isNotEmpty) ...<Widget>[
                            const SizedBox(height: Tokens.spaceXxs),
                            Text(
                              summary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Bauhaus.inkMuted(b),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // 行内**不再显示日期**（2026-10-21 方案 A）：时间由上方组头
                    // （今天 / 昨天 / `12 月 31 日`）表达 ⇒ 每行右缘不再重复同一天，
                    // 行 = 纯标题 + 摘要。删除同样已收进右键菜单。
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
