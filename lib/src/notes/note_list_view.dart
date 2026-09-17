import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../app/undo_toast.dart';
import '../domain/note.dart';
import '../app/providers.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// 左栏笔记列表。
///
/// 条目靠圆角与间距区分（无分割线，对齐 Win11 设置）；
/// 「新建」在标题栏左侧（见 main 的 actions）。
///
/// ## 条目的操作入口（对齐 AppFlowy）
/// 两种入口、同一个菜单：**右键条目** 与 **悬停时右侧浮出的「···」**。
/// 菜单三件事：重命名（就地改标题）/ 收藏 / 删除。
///
/// 删除**不弹确认框**，改用左下角 [showUndoToast] 通知条的「撤销」——
/// 这也是 AppFlowy 的做法：确认框每次都拦一道，撤销只在误删时才用得上。
/// 为什么不用 [SnackBar]：它在自绘窗口里铺满整行、且实测不自动消失，
/// 见 `undo_toast.dart` 的说明。
class NoteListView extends ConsumerWidget {
  const NoteListView({
    super.key,
    required this.selectedId,
    required this.onPick,
  });

  final String? selectedId;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Note>> notes = ref.watch(notesProvider);

    /// 删除 + 可撤销提示（两个入口共用）。
    Future<void> deleteNote(BuildContext context, Note note) async {
      final NotesNotifier notifier = ref.read(notesProvider.notifier);
      final Note? removed = await notifier.deleteNote(note.id);
      if (removed == null || !context.mounted) return;
      final String title = removed.title.isNotEmpty ? removed.title : '无标题';
      // 左下角通知条（不是 SnackBar：后者在本应用里铺满整行、且不自动
      // 消失——见 `undo_toast.dart` 的说明）。
      showUndoToast(
        context,
        message: '已删除「$title」',
        onUndo: () => notifier.restoreNote(removed),
      );
    }

    return Column(
      children: <Widget>[
        SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '笔记',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
        ),
        Expanded(
          child: notes.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('加载失败: $e')),
            data: (list) {
              if (list.isEmpty) {
                return const Center(child: Text('还没有笔记，点击「新建」开始'));
              }
              // 无分割线：条目靠圆角与间距区分（对齐 Win11 设置）。
              return ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: Tokens.spaceXs),
                itemCount: list.length,
                // 条目定高（44 + 上下 2×2）：O(1) 布局——滚动定位、
                // jumpTo、cacheExtent 计算都不再逐条测量。
                itemExtent: Tokens.noteTileHeight,
                itemBuilder: (context, i) {
                  final Note note = list[i];
                  return _NoteTile(
                    // ⚠️ 必须给**稳定 key**：Sliver 的子元素按**索引**匹配，
                    // 而这个列表会重排（收藏置顶改 promoted_at、每次保存改
                    // revised_at，两者的 ORDER BY 见 NoteStore.allNotes）。
                    // 没有 key 时行内 State（就地改名的 _renaming /
                    // TextEditingController / _menuOpen）跟着索引走而非跟着
                    // 笔记走 ⇒ 重排一来，编辑框连同已输入的文字会落到**另一篇**
                    // 笔记的行上，提交就把标题写错对象（数据正确性问题，不是
                    // 单纯的列表抖动）。有 key 后重排时元素跟着笔记迁移。
                    key: ValueKey<String>(note.id),
                    note: note,
                    selected: note.id == selectedId,
                    onTap: () => onPick(note.id),
                    onDelete: () => deleteNote(context, note),
                    onRename: (String title) =>
                        ref.read(notesProvider.notifier).saveTitle(
                              note.id,
                              title,
                            ),
                    onTogglePromoted: () => ref
                        .read(notesProvider.notifier)
                        .togglePromoted(note),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 单个笔记条目：自绘圆角块 + 悬浮反馈 + 选中指示条。
///
/// - 常态：透明
/// - 悬浮 / 选中：内容区画布色（明暗各一档）——条目浮起即「纸面」；
///   选中靠左侧 3px 主色指示条区分。
///
/// 操作入口（AppFlowy 同款）：**右键** 或 **悬停时右侧浮出的「···」**，
/// 二者弹同一个菜单（见 [_NoteTileState._openMenu]）：重命名 / 收藏 / 删除。
/// 「重命名」是**就地**编辑（不弹对话框），与 AppFlowy 的侧栏一致。
///
/// 实现注意：hover 状态用 [ValueNotifier] 只重建颜色层——
/// 若用 setState 重建整个子树，[MouseRegion] 会在重建中反复
/// 触发 enter/exit，表现为悬浮高亮闪烁。裁剪用独立的
/// [ClipRRect]（稳定层），而不是动画容器的 clipBehavior。
class _NoteTile extends StatefulWidget {
  const _NoteTile({
    super.key,
    required this.note,
    required this.selected,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
    required this.onTogglePromoted,
  });

  final Note note;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  /// 就地改名后的回调（父层落库）。
  final ValueChanged<String> onRename;
  final VoidCallback onTogglePromoted;

  @override
  State<_NoteTile> createState() => _NoteTileState();
}

class _NoteTileState extends State<_NoteTile> {
  final ValueNotifier<bool> _hover = ValueNotifier<bool>(false);

  /// **本条目的菜单是否正开着**（2026-09-14）。
  ///
  /// 为什么必须单独记一个状态：菜单是**模态路由**，指针随即落到菜单上 ⇒
  /// `hovered` 变 false ⇒ 行高亮与「···」一起消失，菜单与"它要操作哪一篇"
  /// 就断了视觉联系（用户实机反馈："点更多/右键后不知道菜单对着哪条"）。
  ///
  /// 用 `setState` 而非像 [_hover] 那样挂 `ValueNotifier`：悬浮事件每帧都可能
  /// 来（那条路径刻意只重建内层 Container），而菜单开/关是低频的一次性事件，
  /// 整行重建的代价可以忽略。
  bool _menuOpen = false;

  /// 「···」按钮的锚点（菜单要贴在按钮下方弹出）。
  final GlobalKey _moreKey = GlobalKey();

  /// 就地重命名的编辑态与控制器。
  bool _renaming = false;
  final TextEditingController _renameController = TextEditingController();
  final FocusNode _renameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // 失焦即提交（点别处/点别的笔记都算"改完了"）。
    _renameFocus.addListener(_onRenameFocusChanged);
  }

  void _onRenameFocusChanged() {
    if (!_renameFocus.hasFocus && _renaming) _commitRename();
  }

  @override
  void dispose() {
    _renameFocus.removeListener(_onRenameFocusChanged);
    _renameFocus.dispose();
    _renameController.dispose();
    _hover.dispose();
    super.dispose();
  }

  void _startRename() {
    final String title = widget.note.title;
    _renameController
      ..text = title
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: title.length,
      );
    setState(() => _renaming = true);
    // 菜单刚 pop、焦点还在路由上：延到帧末再抢焦点，否则会被弹层收走。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _renameFocus.requestFocus();
    });
  }

  void _commitRename() {
    final String value = _renameController.text.trim();
    if (mounted) setState(() => _renaming = false);
    if (value != widget.note.title.trim()) widget.onRename(value);
  }

  /// 弹出条目菜单。[globalPosition] 为空时贴「···」按钮右下角。
  Future<void> _openMenu([Offset? globalPosition]) async {
    Offset position = globalPosition ?? Offset.zero;
    if (globalPosition == null) {
      final RenderBox? box =
          _moreKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        position = box.localToGlobal(Offset(box.size.width, box.size.height));
      }
    }

    // 菜单开着期间把本行标成"菜单目标"（见 [_menuOpen]）。
    // 注意 `showMenu` 在**菜单关闭后**才返回，所以这里是一对 setState。
    setState(() => _menuOpen = true);

    final bool promoted = widget.note.promotedAt != null;
    await showMenu<void>(
      context: context,
      // showMenu 的 position 是"相对整个屏幕的矩形"，给一个零尺寸矩形即锚点。
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: <PopupMenuEntry<void>>[
        _menuItem(
          icon: LucideIcons.pencil300,
          label: '重命名',
          onTap: _startRename,
        ),
        _menuItem(
          icon: promoted ? LucideIcons.starOff300 : LucideIcons.star300,
          label: promoted ? '取消收藏' : '收藏',
          onTap: widget.onTogglePromoted,
        ),
        const PopupMenuDivider(),
        _menuItem(
          icon: LucideIcons.trash2300,
          label: '删除笔记',
          // 危险动作：图标与文字都用 error 色（M3 的 destructive 口径）。
          danger: true,
          onTap: widget.onDelete,
        ),
      ],
    );
    // 菜单已关闭才走到这里（`showMenu` 在 pop 之后返回）。
    // `mounted` 为假 = 本条目已被删掉，跳过（对未挂载的 State 调 setState 会抛）。
    if (mounted) setState(() => _menuOpen = false);
  }

  PopupMenuItem<void> _menuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = danger ? scheme.error : scheme.onSurface;
    return PopupMenuItem<void>(
      onTap: onTap,
      child: Row(
        children: <Widget>[
          Icon(icon, size: Tokens.iconSm, color: color),
          const SizedBox(width: Tokens.spaceSm),
          Text(label, style: TextStyle(color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // 底色改中性灰后，选中/悬浮文字同走 onSurface（原
    // onSecondaryContainer 是配着主色底用的，随之移除）。

    final Widget tile = MouseRegion(
      onEnter: (_) => _hover.value = true,
      onExit: (_) => _hover.value = false,
      child: GestureDetector(
        // 就地改名时禁用整条点击：否则点击输入框会连带"切换笔记"。
        onTap: _renaming ? null : widget.onTap,
        // 右键（AppFlowy 同款入口）：在指针处弹出条目菜单。
        onSecondaryTapDown: _renaming
            ? null
            : (TapDownDetails details) => _openMenu(details.globalPosition),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Tokens.spaceSm,
          ),
          child: ClipRRect(
          borderRadius: BorderRadius.circular(Tokens.radiusMd),
          child: ValueListenableBuilder<bool>(
            valueListenable: _hover,
            // 悬浮高亮用瞬切而非渐变：渐变经过半透明中间态时，
            // 新旧两块同时半透明，观感是「闪一下」；Win11 原生
            // 列表的悬浮反馈也是即时的。
            builder: (context, hovered, _) {
              // "本条正被交互"：指针在行上，**或**本条的菜单开着。
              // 后者是 2026-09-14 补的——菜单一开指针就落到菜单上，`hovered`
              // 随即为 false，行高亮与「···」会一起消失，于是"菜单到底对着
              // 哪一篇"没有任何视觉线索（用户实机反馈）。
              final bool active = hovered || _menuOpen;
              return Container(
                height: Tokens.noteTileHeight,
                // 悬浮与选中同色 = 内容区画布色（明暗各一档：亮色暖纸白 /
                // 深色 #2B2B2B）——条目浮起即「纸面」，与右栏同源，辨识度
                // 来自色温而非深浅；选中态由指示条承担区分职责。
                color: widget.selected || active
                    ? AppTheme.contentCanvas(theme.brightness)
                    : Colors.transparent,
                child: Row(
                  children: <Widget>[
                    // 选中指示条：位置固定，不随文字跳动。
                    AnimatedContainer(
                      duration: Tokens.durationFast,
                      width: Tokens.indicatorWidth,
                      color: widget.selected
                          ? scheme.onSurface
                          : Colors.transparent,
                    ),
                    const SizedBox(width: Tokens.spaceMd),
                    // 收藏标记：星标紧贴标题（不占额外宽度，无收藏时不显示）。
                    if (widget.note.promotedAt != null) ...<Widget>[
                      Icon(
                        LucideIcons.star300,
                        size: Tokens.iconSm - 4,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: Tokens.spaceXs),
                    ],
                    Expanded(
                      child: _renaming
                          // 就地改名：同样的字号/字色，去掉装饰，读起来还是"标题"。
                          ? TextField(
                              controller: _renameController,
                              focusNode: _renameFocus,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurface,
                              ),
                              cursorColor: scheme.onSurface,
                              decoration: const InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                              ),
                              onSubmitted: (_) => _commitRename(),
                            )
                          : Text(
                              widget.note.title.isNotEmpty
                                  ? widget.note.title
                                  : '无标题',
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: scheme.onSurface),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                    ),
                    const SizedBox(width: Tokens.spaceMd),
                    // 「···」入口：**悬停或选中时**才显形（AppFlowy 同款），
                    // 但**位置始终占位**——否则显隐会让标题宽度跳动。
                    // 用 IconButton 而非自绘：拿现成的 hover/splash/Tooltip。
                    // 改名期间让位给输入框（同时避免误点）。
                    SizedBox(
                      width: Tokens.formatButtonHeight,
                      child: Visibility(
                        // 「菜单开着」时也留着它：那是"菜单从哪弹出来"的锚点，
                        // 一起消失会让菜单显得悬空。
                        visible: !_renaming && (widget.selected || active),
                        // 只留占位：maintainSize 保宽高，避免标题被挤动。
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: IconButton(
                          key: _moreKey,
                          tooltip: '更多',
                          padding: EdgeInsets.zero,
                          iconSize: Tokens.iconSm,
                          icon: const Icon(LucideIcons.ellipsisVertical300),
                          onPressed: _openMenu,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
      ),
    );
    return tile;
  }
}
