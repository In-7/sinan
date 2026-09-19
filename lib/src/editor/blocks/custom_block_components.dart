import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:provider/provider.dart';

import 'attachment_block_component.dart';
import 'block_markers.dart';
import 'callout_block_component.dart';
import 'code_block_component.dart';
import 'formula_block_component.dart';
import 'ref_block_component.dart';
import 'toggle_block_component.dart';
import '../../theme/app_theme.dart';
import '../core/editor_typography.dart';
import '../toolbar/slash_menu_items.dart';
import 'block_action_menu.dart';
import 'reference_to_canvas.dart';
import '../widgets/float_menu_style.dart';
import '../widgets/hover_state_layer.dart';

// sinan 的块组件/快捷键注册表：**官方标准件 + 我们的增量**。
//
// 官方推荐的扩展姿势就是"展开标准表再加自己的"（见其 AppFlowyEditor
// 文档注释），因此这里不复制、不改官方组件，只做增量——补丁为零：
// - `code`：代码块（**官方 6.2.0 没有**；实测其注册表只有 page/paragraph/
//   todo_list/bulleted_list/numbered_list/quote/heading/image/divider/
//   table、table/cell）；
// - `formula` / `attachment`：Delta 里本就是"独占一行的块级嵌入"，
//   这里给它们对应的块类型与渲染组件。

/// 编辑器用：块组件注册表（官方标准 + 我们的自定义块）。
///
/// [typography] 只用于**标题档位**：官方默认档位（32/28/24，写死在
/// `HeadingBlockComponentBuilder.defaultTextStyle`）是按拉丁文标定的，
/// 对汉字过大且不随正文字号缩放 → 换成中文口径（16px 下 24/20/17，
/// 见 `editor_typography.dart`）。
///
/// 块的**内边距刻意不动**：官方 `BlockComponentConfiguration` 默认
/// （上下各 4）即 [standardBlockComponentConfiguration] 的值，块间距按官方来。
/// 替换官方 heading 条目时必须原样带上它的 `configuration`（占位文案 +
/// 标准内边距），只追加 `textStyleBuilder`。
///
/// 标题**不挂编号前缀**（2026-09-14 撤）：正文与目录都不再显示
/// 1 / 1.1 / 1.1.1——层级完全交给目录面板的「缩进 16 + 字号梯度 +
/// 字重梯度」表达（多数笔记应用同此）。此前正文那层前缀要求视图在每个
/// 事务上做一次全文档遍历重算编号表，且给标题块套了一层常驻包装组件
/// ——一并删除，标题块回到官方组件本体。
///
/// 「多余空行」**有意不动**（不是没做）：官方渲染的空段落块高有硬地板
/// （14px 的无样式空 span，配置层压不下去）；而"装载时折叠连续空行"会
/// **改数据**且不可逆（首次编辑即按折叠后落库）——两条路都已实测否决，
/// 见 `docs/editor_migration_spike.md` 的「已否决方案」与原则 5
/// （"不为了顺手而改数据"）。
Map<String, BlockComponentBuilder> sinanBlockComponentBuilders({
  required EditorTypography typography,
  required Color markerColor,
  RefBlockBridge? refBridge,
}) {
  final builders = <String, BlockComponentBuilder>{
  ...standardBlockComponentBuilderMap,
  HeadingBlockKeys.type: HeadingBlockComponentBuilder(
    configuration: BlockComponentConfiguration(
      // 官方这里写死英文 `Heading N`（没走 l10n），中文界面下突兀，换掉。
      placeholderText: (Node node) =>
          '标题 ${node.attributes[HeadingBlockKeys.level] ?? 1}',
      // 官方标题与正文的上下内边距完全一致（各 4）＝"不靠间距区分标题"；
      // 这里只补**上间距**（按级/首块规则见 EditorTypography.headingPadding）。
      padding: typography.headingPadding,
    ),
    textStyleBuilder: typography.heading,
  ),
  // 列表/待办标记：统一视觉尺寸（共用 26×22 容器）+ 主题色（见
  // `_Sinan*Icon`）。官方默认无序圆点压到 0.5×、待办是固定 22px SVG、
  // 有序数字满字号 —— 三者大小不一；这里拉齐后再染主题色。
  BulletedListBlockKeys.type: BulletedListBlockComponentBuilder(
    configuration: standardBlockComponentConfiguration.copyWith(
      placeholderText: (_) => AppFlowyEditorL10n.current.listItemPlaceholder,
    ),
    iconBuilder: (context, node) => _SinanBulletedIcon(
      node: node,
      color: markerColor,
    ),
  ),
  NumberedListBlockKeys.type: NumberedListBlockComponentBuilder(
    configuration: standardBlockComponentConfiguration.copyWith(
      placeholderText: (_) => AppFlowyEditorL10n.current.listItemPlaceholder,
    ),
    iconBuilder: (context, node, direction) => _SinanNumberedIcon(
      node: node,
      direction: direction,
      color: markerColor,
    ),
  ),
  TodoListBlockKeys.type: TodoListBlockComponentBuilder(
    configuration: standardBlockComponentConfiguration.copyWith(
      placeholderText: (_) => AppFlowyEditorL10n.current.listItemPlaceholder,
    ),
    iconBuilder: (context, node, onCheck) => _SinanTodoIcon(
      checked: node.attributes[TodoListBlockKeys.checked] ?? false,
      onTap: onCheck,
      color: markerColor,
    ),
  ),
  CodeBlockKeys.type: CodeBlockComponentBuilder(typography: typography),
  FormulaBlockKeys.type: FormulaBlockComponentBuilder(),
  AttachmentBlockKeys.type: AttachmentBlockComponentBuilder(),
  // Callout（2026-09-14，对齐官方应用侧的同名块；见该文件的对照说明）。
  CalloutBlockKeys.type: CalloutBlockComponentBuilder(),
  // 折叠块：**一个 builder 覆盖两种节点**（折叠列表 / 折叠标题，靠 `level`
  // 分流，官方口径）。需要 typography：折叠标题的字号取自与正文标题同一份
  // 档位表——预算器也用同一份，否则预测会偏。
  ToggleListBlockKeys.type: ToggleBlockComponentBuilder(typography: typography),
  // 引用块（2026-09-18，双链）：指向另一篇笔记 / 另一个块。目标标题与跳转由宿主
  // 注入（[refBridge]），块本身不碰 provider —— 见 `ref_block_component.dart`。
  RefBlockKeys.type: RefBlockComponentBuilder(bridge: refBridge),
};

  // 给**所有非页面块**加上左侧手柄（+ / 拖拽）。
  //
  // 官方 6.2.0 的块手柄由 `BlockComponentActionWrapper` + `actionBuilder` 实现：
  // 每个 `BlockComponentBuilder` 有 `showActions` 和 `actionBuilder` 两个钩子，
  // 标准组件（Image/Paragraph/Heading/...）与我们的增量块（Code/Formula/...）
  // 内部都已经包好 `BlockComponentActionWrapper`，只是默认
  // `showActions = (_) => false`、`actionBuilder = SizedBox.shrink()`。
  // 官方最新示例（`desktop_editor.dart`）正是遍历 builder 表、统一打开手柄。
  builders.forEach((key, builder) {
    if (key == PageBlockKeys.type) return;
    builder.showActions = (_) => true;
    builder.actionBuilder = (context, state) {
      return _SinanBlockHandle(
        blockComponentContext: context,
        builder: builder,
      );
    };
  });

  return builders;
}

/// 块手柄：+（下方插入空段落）/ ⠿（选中该块，拖拽光标）。
///
/// **首行居中靠实测，不靠估算**：post-frame 读 `node.selectable`
/// `.getCursorRectInPosition(Position(offset: 0))` —— 这是块自己实现的
/// "块首光标矩形"，坐标系就是块本体（`DefaultSelectableMixin` 已 shift），
/// 列表标记、Callout 内层 padding、标题上间距等全都被天然计入。
/// 它与编辑器画光标/官方 App 定位工具栏用的是同一套几何，所以
/// "官方 App 是居中的"我们这里也居中。之前用排版数据手算行盒偏移，
/// 在列表块（标记盒另有光学补偿）与标题（上间距规则）上对不齐，已废弃。
class _SinanBlockHandle extends StatefulWidget {
  const _SinanBlockHandle({
    required this.blockComponentContext,
    required this.builder,
  });

  static const double _iconSize = 20;

  /// 点击热区边长（[_HandleButton] 的正方形盒子）。图标在盒内居中，
  /// 所以**图标实际中心 = 盒顶 + [_buttonSize] / 2**——对齐计算必须用它，
  /// 用 [_iconSize] / 2 会差 (20-20)/2 = 0px（图标现已充满按钮，两者等价）。
  static const double _buttonSize = 20;

  /// 两个按钮之间的间距。
  static const double _gap = 2;

  /// 手柄右缘与正文左缘之间的留白。
  ///
  /// ⚠️ 手柄是**行内布局**（`Row[手柄, 正文]` 常驻占位）⇒ 手柄总宽
  /// （`_textGap + _buttonSize + _gap + _buttonSize` = 48）会被从每个块的
  /// 文字列里扣掉。**块高预测器必须同步扣除**——契约单一来源是
  /// `EditorTypography.blockHandleWidth`（预测器与列宽档位都消费它），
  /// 三处任何一处不同步，预测与渲染就会脱节
  /// （2026-09-15 的"总高漂移 286px"即此）。改手柄几何 ⇒ 同步那一处。
  static const double _textGap = 6;

  /// CJK 光学补偿（em）：caret 中心是**度量盒**几何中心（= 行盒中心），
  /// 与汉字墨迹中心相差 [cjkInkCompensation] × 字号（负值 = 墨迹在中心
  /// 下方）。与列表圆点共用同一个常量（单一来源，见其文档）：换字体只改
  /// 一处，圆点与手柄不漂移。英文墨迹分布与度量盒偏差小，补偿后仍居中。

  final BlockComponentContext blockComponentContext;

  /// 本块的 builder：拖拽 feedback 用它重渲染一份块副本
  /// （官方 `DragToReorderAction` 同款，见 `drag_to_reorder_editor.dart`）。
  final BlockComponentBuilder builder;

  @override
  State<_SinanBlockHandle> createState() => _SinanBlockHandleState();
}

class _SinanBlockHandleState extends State<_SinanBlockHandle> {
  /// 手柄上偏移。首帧先 0（此时块还没布局，读不到几何），post-frame 修正。
  double _top = 0;

  /// 拖拽中（用于抑制手柄提示，见 [_HandleButton.showTooltip]）。
  bool _dragging = false;

  /// 块操作菜单（⠿ 点击打开，见 [sinanBlockActionMenuItems]）。
  final MenuController _actionsMenu = MenuController();

  /// “+” 的提示：两行 = 默认动作 + 修饰键动作（照官方 `BlockAddButton`）。
  ///
  /// ⚠️ 与项目"tooltip 声明的快捷键 = 真实绑定"同一条纪律：这里承诺的
  /// **Alt+点击在上方插入**在 [_addBlock] 里真的实现了（有测试守着）。
  static const TextSpan _addButtonTooltip = TextSpan(
    children: <InlineSpan>[
      TextSpan(text: '点击在下方添加块'),
      TextSpan(text: '\n'),
      TextSpan(text: 'Alt+点击 在上方添加'),
    ],
  );

  /// “⠿” 的提示：两行 = 拖拽动作 + 点击动作（照官方 `OptionButton`
  /// 的「Drag to move / Click to open menu」）。
  static const TextSpan _dragButtonTooltip = TextSpan(
    children: <InlineSpan>[
      TextSpan(text: '拖拽以移动'),
      TextSpan(text: '\n'),
      TextSpan(text: '点击打开菜单'),
    ],
  );

  Node get _node => widget.blockComponentContext.node;

  late final EditorState editorState = context.read<EditorState>();

  /// 官方同款（`drag_to_reorder_editor.dart`）：手柄上的点击要先拦下来，
  /// 否则编辑器的 selection 服务会把它当正文点击、把手柄刚设置的块选区
  /// 清掉。`canTap = !点在手柄内`，即"点在手柄内 ⇒ 编辑器不处理这次 tap"。
  /// 每块一个实例，key 带 node.id 避免相互覆盖；selection 服务按 `every`
  /// 裁决，点某块手柄时其余块的 canTap 都为 true，互不干扰。
  late final String _interceptorKey = 'sinan_block_handle_${_node.id}';

  /// 点手柄前的正文选区（官方语义：若原选区已覆盖本块，点击 = 恢复它为
  /// 块选区；否则 = 新建块选区）。
  Selection? _beforeSelection;

  late final gestureInterceptor = SelectionGestureInterceptor(
    key: _interceptorKey,
    canTap: (details) => !_isTapInBounds(details.globalPosition),
  );

  // ── 拖拽换位（官方 DragToReorderAction 同款） ──

  /// feedback 用的节点副本：`copyWith()` 生成新 key（新 GlobalKey），
  /// 文档里的节点拖拽期间被更新也不会反馈到 feedback。
  late final Node _dragNode = _node.copyWith();
  late final BlockComponentContext _dragContext = BlockComponentContext(
    widget.blockComponentContext.buildContext,
    _dragNode,
  );

  /// 拖拽中的指针全局坐标（onDragEnd 时用于判定落点）。
  Offset? _dragGlobalPosition;

  RenderBox? get _renderBox => context.findRenderObject() as RenderBox?;

  @override
  void initState() {
    super.initState();
    editorState.service.selectionService.registerGestureInterceptor(
      gestureInterceptor,
    );
    // 内容/属性变化（换标题档位、增删文字触发 reflow 等）后重新对齐。
    _node.addListener(_scheduleAlign);
    WidgetsBinding.instance.addPostFrameCallback((_) => _alignToFirstLine());
  }

  @override
  void dispose() {
    editorState.service.selectionService.unregisterGestureInterceptor(
      _interceptorKey,
    );
    _node.removeListener(_scheduleAlign);
    super.dispose();
  }

  void _scheduleAlign() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _alignToFirstLine());
  }

  /// 官方同款判定：点击落点是否在本手柄的绘制范围内（`drag_to_reorder_editor.dart`
  /// 的 `_isTapInBounds`），命中时顺带记录点击前的选区。
  bool _isTapInBounds(Offset offset) {
    final box = _renderBox;
    if (box == null) return false;
    final hit = box.paintBounds.contains(box.globalToLocal(offset));
    if (hit) {
      _beforeSelection = editorState.selection;
    } else {
      _beforeSelection = null;
    }
    return hit;
  }

  /// 官方同款点击语义（`_onTap`）：块级选区（`SelectionType.block`）——
  /// 整块高亮，而不是选中第一个字符。若点击前选区已覆盖本块，恢复它。
  void _onTap() {
    final path = _node.path;
    final beforeSelection = _beforeSelection;
    if (beforeSelection != null && path.inSelection(beforeSelection)) {
      unawaited(
        editorState.updateSelectionWithReason(
          beforeSelection,
          customSelectionType: SelectionType.block,
        ),
      );
    } else {
      unawaited(
        editorState.updateSelectionWithReason(
          Selection.collapsed(Position(path: path)),
          customSelectionType: SelectionType.block,
        ),
      );
    }
  }

  /// 拖拽三件套：落点指示线（`renderDropTargetForOffset`）+ 自动滚动
  /// （`startAutoScroll`）+ 松手换位（`transaction.moveNode`）。
  /// 与官方 `drag_to_reorder_editor.dart` 的 `_DragToReorderActionState` 一致。
  Widget _buildDraggable(Widget child) {
    return Draggable<Node>(
      data: _node,
      feedback: _buildFeedback(),
      onDragStarted: () {
        setState(() => _dragging = true);
        editorState.selectionService.removeDropTarget();
      },
      onDragUpdate: (details) {
        editorState.selectionService.renderDropTargetForOffset(
          details.globalPosition,
          builder: _buildDropArea,
        );

        _dragGlobalPosition = details.globalPosition;

        editorState.scrollService?.startAutoScroll(details.globalPosition);
      },
      onDragEnd: (details) {
        setState(() => _dragging = false);
        editorState.selectionService.removeDropTarget();
        editorState.scrollService?.stopAutoScroll();

        final position = _dragGlobalPosition;
        if (position == null) {
          return;
        }

        final data = editorState.selectionService.getDropTargetRenderData(
          position,
        );
        unawaited(
          _moveNodeToNewPosition(_node, data?.cursorNode?.path, position),
        );
      },
      child: child,
    );
  }

  /// 拖拽跟手的块副本。整块重渲染；不套 Opacity（saveLayer，Impeller 红线
  /// —— 见项目渲染规范①），保持全不透明。
  Widget _buildFeedback() {
    Widget child;
    if (_node.type == TableBlockKeys.type) {
      // 表格块渲染依赖 provider/context，feedback 里直接给占位卡片
      // （官方同款处置）。
      child = Container(
        width: 200,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text('Table'),
      );
    } else {
      child = IntrinsicWidth(
        child: IntrinsicHeight(
          child: Provider<EditorState>.value(
            value: editorState,
            child: widget.builder.build(_dragContext),
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: child,
    );
  }

  /// 落点指示线：官方 `_buildDropArea` 的移植，颜色换主题色。
  /// 坐标是全局坐标（selection 服务把 builder 的产物插到全屏 Overlay）。
  Widget _buildDropArea(BuildContext context, DragAreaBuilderData data) {
    final targetNode = data.targetNode;

    if (_shouldIgnoreDrop(_node, targetNode.path)) {
      return const SizedBox.shrink();
    }

    final selectable = targetNode.selectable;
    final RenderBox? renderBox =
        selectable?.context.findRenderObject() as RenderBox?;
    if (selectable == null || renderBox == null) {
      return const SizedBox.shrink();
    }

    final position = _dragPosition(
      targetNode,
      data.dragOffset,
    );
    if (position == null) {
      return const SizedBox.shrink();
    }

    final (vertical, horizontal, globalBlockRect) = position;

    // 44 = 拖拽指示器让出的宽度（官方口径）。
    const double indicatorWidth = 44.0;
    final double width = globalBlockRect.width - indicatorWidth;
    final Color color = Theme.of(context).colorScheme.primary;

    Widget child = Container(height: 2, width: width, color: color);

    if (horizontal == _DragHorizontal.center) {
      // 中段：带一个"断口"装饰（官方样式），提示"插入到子级"。
      const double breakWidth = 22.0;
      const double padding = 8.0;
      child = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(height: 2, width: breakWidth, color: color),
          const SizedBox(width: padding),
          Container(
            height: 2,
            width: width - breakWidth - padding,
            color: color,
          ),
        ],
      );
    }

    return Positioned(
      top: vertical == _DragVertical.top
          ? globalBlockRect.top
          : globalBlockRect.bottom,
      left: globalBlockRect.left + 22,
      child: child,
    );
  }

  /// 官方 `_moveNodeToNewPosition` 的移植（去掉 columns 分支——本项目
  /// 没有分栏块；drop 到右半边按 center 语义处理）。
  Future<void> _moveNodeToNewPosition(
    Node realNode,
    Path? acceptedPath,
    Offset dragOffset,
  ) async {
    if (acceptedPath == null) return;
    final targetNode = editorState.getNodeAtPath(acceptedPath);
    if (targetNode == null) return;

    final position = _dragPosition(targetNode, dragOffset);
    if (position == null) return;

    final (vertical, horizontal, _) = position;
    final _DragHorizontal effectiveHorizontal = horizontal == _DragHorizontal.right
        ? _DragHorizontal.center
        : horizontal;

    Path newPath = targetNode.path;
    // top = 插到目标上方；bottom-left = 插到下方兄弟；
    // bottom-center = 作为目标的第一个子块（嵌套入口）。
    if (vertical == _DragVertical.bottom) {
      newPath = effectiveHorizontal == _DragHorizontal.left
          ? newPath.next
          : newPath.child(0);
    }

    if (_shouldIgnoreDrop(realNode, newPath)) {
      return;
    }

    final transaction = editorState.transaction;
    transaction.moveNode(newPath, realNode);
    await editorState.apply(transaction);
  }

  /// 首行对齐：**全局坐标自校正**，不猜 caret 矩形在哪个局部坐标系。
  ///
  /// 历史教训（2026-09-14 两轮返工）：caret 矩形的坐标空间按块实现而异
  /// （DefaultSelectableMixin 是 forward 局部坐标、`shiftWithBaseOffset`
  /// 的语义各实现也不齐），拿它直接当块内偏移用，段落/标题各偏各的。
  /// 正确姿势：caret 中心经 `selectable.localToGlobal` 换到全局（这正是
  /// 编辑器画光标用的同一套换算，光标位置是被验证过对的），再和本手柄盒的
  /// 全局顶相减得 delta，把 delta 加到现有偏移上——一次迭代收敛，任何
  /// 块实现差异都被吸收。
  void _alignToFirstLine() {
    if (!mounted) return;
    final selectable = _node.selectable;
    final box = _renderBox;
    if (selectable == null || box == null || !box.hasSize) return;
    final Rect? caret = selectable.getCursorRectInPosition(
      Position(path: _node.path),
    );
    if (caret == null) return;

    final double caretGlobalCenter = selectable.localToGlobal(caret.center).dy;
    // 光学补偿：目标从"度量盒中心"移到"汉字墨迹中心"（见常量说明，
    // 现字体下墨迹中心低于中心，comp 为负 ⇒ inkCenter 在 caret 下方）。
    final double fontSize =
        editorState.editorStyle.textStyleConfiguration.text.fontSize ?? 16;
    final double inkCenter = caretGlobalCenter - cjkInkCompensation * fontSize;
    // 手柄基准 Y = Padding 盒原点 + _top。
    //
    // ⚠️ 这里的 `_top` **必须加**：`findRenderObject()` 拿到的是
    // `Padding(top: _top)` 的 **RenderPadding 自身**，它的原点**不含**
    // 自己施加的内边距（padding 只往内推子件，不挪盒子）——而按钮的真实
    // 起点在"原点 + _top"处。漏掉它时 delta 永远少减一份已生效的 `_top`，
    // `_top += delta` 每轮把上一轮的补偿**再叠一遍**：每来一次事务（点
    // 工具栏加粗/斜体/下划线/删除线/行内代码都会改 delta → 触发本对齐）
    // 手柄就往下掉一行（实测 2026-09-15，块高 34 → 35 → 43 → 51 → 58）。
    final double handleGlobalTop = box.localToGlobal(Offset.zero).dy + _top;
    final double delta =
        inkCenter - _SinanBlockHandle._buttonSize / 2 - handleGlobalTop;
    final double top = (_top + delta).clamp(0.0, double.infinity);
    if ((top - _top).abs() > 0.5) {
      setState(() => _top = top);
    }
  }

  @override
  Widget build(BuildContext context) {
    final node = _node;
    final color = Theme.of(context).colorScheme.onSurfaceVariant;

    // **行内动作槽**（2026-09-15 定案，2026-09-15 晚回滚）：手柄作为
    // `Row[手柄, 正文]` 的真实子件占布局宽度，`maintainSize` 常驻 ⇒
    // 正文列恒为"列宽 − 32 − 48"。
    //
    // 为什么不用"零宽 + OverflowBox 侧绘"：那个方案下，手柄画在块盒**外**，
    // 而 Flutter 的 `RenderBox.hitTest` 要求指针位置在盒子自己的 size 内
    // ⇒ 盒外画的部件**点不到**；且鼠标从正文移向手柄就离开了 vendored
    // MouseRegion 的范围 ⇒ `onExit` 隐藏。实测确认。要修只能上真 Overlay
    // + 两条 vendored 补丁（见对话记录），故回到行内。
    //
    // ⚠️ 连带契约（三处必须同步）：文字列 = 列宽 − 32 − [handleWidth]；
    // 预测器（`BlockHeightPredictor.textWidthOf`）与列宽档位
    // （`EditorWidthMode` 三档已各 +48）都含这笔。
    return Padding(
      padding: EdgeInsets.only(right: _SinanBlockHandle._textGap, top: _top),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _HandleButton(
            icon: Icons.add,
            color: color,
            tooltip: _addButtonTooltip,
            onTap: () => _addBlock(editorState, node, context),
          ),
          const SizedBox(width: _SinanBlockHandle._gap),
          _buildDraggable(
            // ⠿：点击 = 切块选区 + **打开块操作菜单**（照官方 `OptionButton`
            // 的 `controller.show()`）；拖拽 = 换位（`_buildDraggable`）。
            MenuAnchor(
              controller: _actionsMenu,
              // 显式浮层样式：子树里桥不过 menuTheme，不传就是 M3 默认
              //（带种子色的 surface + elevation 3 + 无描边，见该函数文档）。
              style: sinanEditorFloatMenuStyle(context),
              menuChildren: sinanBlockActionMenuItems(
                editorState: editorState,
                node: node,
                onClose: _actionsMenu.close,
                // 块可迁移 #5「双链多视图」：把这块引用到画布上（文档里原地不动）。
                // 延到下一帧再弹：菜单浮层正在收起，同帧开对话框会打架。
                onReferenceOnCanvas: () => WidgetsBinding.instance
                    .addPostFrameCallback((_) {
                  if (!mounted) return;
                  unawaited(
                    referenceBlockToCanvas(context: context, blockId: node.id),
                  );
                }),
              ),
              builder: (
                BuildContext context,
                MenuController controller,
                Widget? child,
              ) =>
                  _HandleButton(
                icon: Icons.drag_indicator_rounded,
                color: color,
                tooltip: _dragButtonTooltip,
                cursor: SystemMouseCursors.grab,
                showTooltip: !_dragging,
                onTap: () {
                  _onTap();
                  controller.open();
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HandleButton extends StatelessWidget {
  const _HandleButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    this.cursor = SystemMouseCursors.basic,
    this.onTap,
    this.showTooltip = true,
  });

  final IconData icon;
  final Color color;

  /// 富文本提示（**两行**：主要动作 + 次要动作）——结构照官方
  /// `BlockActionButton` 的 `richMessage`（`block_action_button.dart`）。
  final TextSpan tooltip;

  final MouseCursor cursor;
  final VoidCallback? onTap;

  /// 拖拽中抑制提示（官方 `OptionButton` 的 `showTooltip: !isDragging`：
  /// 拖动时手指/指针就压在手柄上，气泡只会碍事）。
  final bool showTooltip;

  @override
  Widget build(BuildContext context) {
    Widget button = MouseRegion(
      cursor: cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        child: SizedBox(
          width: _SinanBlockHandle._buttonSize,
          height: _SinanBlockHandle._buttonSize,
          child: Icon(icon, size: _SinanBlockHandle._iconSize, color: color),
        ),
      ),
    );
    if (showTooltip) {
      button = Tooltip(richMessage: tooltip, child: button);
    }
    // 悬停/按下底色：官方那套渲染件把三色显式置透明（只给 tooltip），
    // 这里补自己的状态层——与浮动工具条**同一件**（口径不会漂）。
    return HoverStateLayer(base: color, child: button);
  }
}

// ── 拖拽换位的几何判定（官方 `drag_to_reorder_editor.dart` 的移植） ──

enum _DragHorizontal { left, center, right }

enum _DragVertical { top, bottom }

/// 判定拖拽点相对目标块的方位，用于选落点与画指示线。
/// 水平：左 44px 内 = left（整块上方/下方插入）；右 1/3 之外 = right
/// （本项目按 center 语义处理，见 `_moveNodeToNewPosition`）；其余 = center。
/// 垂直：中线之上 = top，之下 = bottom。不在块内返回 null。
(_DragVertical, _DragHorizontal, Rect)? _dragPosition(
  Node targetNode,
  Offset dragOffset,
) {
  final selectable = targetNode.selectable;
  final RenderBox? renderBox =
      selectable?.context.findRenderObject() as RenderBox?;
  if (selectable == null || renderBox == null) {
    return null;
  }

  final globalBlockRect =
      renderBox.localToGlobal(Offset.zero) & renderBox.size;

  if (!globalBlockRect.contains(dragOffset)) {
    return null;
  }

  _DragHorizontal horizontal;
  if (dragOffset.dx < globalBlockRect.left + 44) {
    horizontal = _DragHorizontal.left;
  } else if (dragOffset.dx > globalBlockRect.right / 3.0 * 2.0) {
    horizontal = _DragHorizontal.right;
  } else {
    horizontal = _DragHorizontal.center;
  }

  final _DragVertical vertical =
      dragOffset.dy < globalBlockRect.top + globalBlockRect.height / 2
          ? _DragVertical.top
          : _DragVertical.bottom;

  return (vertical, horizontal, globalBlockRect);
}

/// 这些落点直接忽略：没有目标、拖到自己身上、拖到自己的子孙块里
/// （会把子树挂到自己下面，官方同款防护）。
bool _shouldIgnoreDrop(Node dragNode, Path? targetPath) {
  if (targetPath == null) {
    return true;
  }
  if (dragNode.path.equals(targetPath)) {
    return true;
  }
  if (dragNode.path.isAncestorOf(targetPath)) {
    return true;
  }
  return false;
}

void _addBlock(EditorState editorState, Node node, BuildContext context) {
  final bool above = HardwareKeyboard.instance.isAltPressed;
  // 官方同款：当前块**已经是空段落**时复用，不再新建
  //（否则连按 + 会拉出一串空行）。
  final bool reuseEmpty =
      node.type == ParagraphBlockKeys.type && (node.delta?.isEmpty ?? false);

  final Transaction transaction = editorState.transaction;
  final Path target;
  if (reuseEmpty) {
    target = node.path;
  } else {
    target = above ? node.path : node.path.next;
    transaction.insertNode(target, paragraphNode());
  }
  transaction.afterSelection = Selection.collapsed(Position(path: target));

  unawaited(
    editorState.apply(transaction).then((_) {
      // 菜单要等新块**布局完成**再弹：锚点读的是块的 rect，早一帧就落空。
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _showSlashMenu(editorState, context);
      });
    }),
  );
}

/// 唤起斜杠菜单——照官方 `BlockAddButton` 的 `showSlashMenu`。
///
/// `shouldInsertSlash: false`：不走"先打一个 `/` 字再出菜单"那条路。点手柄
/// 不该往正文里留字符（官方应用侧就是直接弹菜单，插块与选类型一步完成）。
///
/// 配色与字符快捷键（`sinanCharacterShortcutEvents` 里注册的那条）**共用
/// `sinanSlashMenuStyle`**，所以两条入口弹出的菜单长得一样；色值取自桥接后的
/// 主题（本组件在编辑器子树内，`Theme.of` 读到的就是应用色板）。
Future<void> _showSlashMenu(
  EditorState editorState,
  BuildContext context,
) async {
  final ThemeData theme = Theme.of(context);
  final ColorScheme scheme = theme.colorScheme;
  await customSlashCommand(
    sinanSelectionMenuItems(),
    shouldInsertSlash: false,
    style: sinanSlashMenuStyle(
      background: AppTheme.floatSurface(theme.brightness),
      foreground: scheme.onSurface,
      muted: scheme.onSurfaceVariant,
      outline: scheme.outlineVariant,
      error: scheme.error,
    ),
  ).handler(editorState);
}

/// 无序列表标记：●/◯/□（按嵌套层级轮换），主题色，尺寸与数字/待办对齐。
class _SinanBulletedIcon extends StatelessWidget {
  const _SinanBulletedIcon({required this.node, required this.color});

  final Node node;
  final Color color;

  int get level {
    var l = 0;
    var parent = node.parent;
    while (parent != null) {
      if (parent.type == BulletedListBlockKeys.type) l++;
      parent = parent.parent;
    }
    return l;
  }

  @override
  Widget build(BuildContext context) {
    const List<String> icons = ['●', '◯', '□'];
    final EditorState editorState = context.read<EditorState>();
    final double tsf = editorState.editorStyle.textScaleFactor;
    // 用正文字体样式作为基础，保证符号与正文在同一套字体度量里对齐；
    // 只覆盖颜色，尺寸交给 textScaler。
    final TextStyle baseStyle = editorState.editorStyle.textStyleConfiguration.text;
    return markerBox(
      context,
      Text(
        icons[level % icons.length],
        style: baseStyle.copyWith(color: color),
        textScaler: TextScaler.linear(0.5 * tsf),
      ),
    );
  }
}

/// 有序列表标记：1./a./i. 等层级编号（复刻官方 `levelString` 逻辑，因其为私有扩展），
/// 主题色。
class _SinanNumberedIcon extends StatelessWidget {
  const _SinanNumberedIcon({
    required this.node,
    required this.direction,
    required this.color,
  });

  final Node node;
  final TextDirection direction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final EditorState editorState = context.read<EditorState>();
    final double tsf = editorState.editorStyle.textScaleFactor;
    // 用正文字体样式作为基础，只覆盖颜色和字号，保证数字与正文同字体度量。
    final TextStyle baseStyle = editorState.editorStyle.textStyleConfiguration.text;
    return markerBox(
      context,
      Text(
        _numberedLevelString(node),
        // 1.0×正文：与待办勾选框（0.88×正文）同基准、随正文缩放，仅改外观。
        style: baseStyle.copyWith(
          color: color,
          fontSize: (baseStyle.fontSize ?? 16) * tsf,
        ),
        textScaler: const TextScaler.linear(1),
        // 与官方 numbered 一致：不把行高余量算进首行升部之上/末行降部之下，
        // 让 marker 的高度约定与正文相同，Center 才会真正落到文字中心。
        textHeightBehavior: const TextHeightBehavior(
          applyHeightToFirstAscent: false,
          applyHeightToLastDescent: false,
        ),
        textDirection: direction,
      ),
    );
  }
}

/// 复刻 `appflowy_editor` 私有的 `node.levelString`：按嵌套层级在
/// 数字 / 小写字母 / 小写罗马数字间轮换，并累加同级序号。
String _numberedLevelString(Node node) {
  int indexInRootLevel = 0;
  var parent = node.parent;
  while (parent != null) {
    if (parent.type == NumberedListBlockKeys.type) indexInRootLevel++;
    parent = parent.parent;
  }

  int indexInSameLevel;
  int level = 1;
  final Node? previous = node.previous;
  if (previous == null || previous.type != NumberedListBlockKeys.type) {
    final int? attr = node.attributes[NumberedListBlockKeys.number] as int?;
    indexInSameLevel = attr ?? level;
  } else {
    int? startNumber;
    Node? prev = previous;
    while (prev != null && prev.type == NumberedListBlockKeys.type) {
      startNumber = prev.attributes[NumberedListBlockKeys.number] as int?;
      level++;
      prev = prev.previous;
    }
    indexInSameLevel = startNumber != null ? startNumber + level - 1 : level;
  }

  final int levelMod = indexInRootLevel % 3;
  final String s = switch (levelMod) {
    1 => _toLatin(indexInSameLevel),
    2 => _toRoman(indexInSameLevel),
    _ => '$indexInSameLevel',
  };
  return '$s.';
}

/// 26 进制小写字母（1→a, 26→z, 27→aa），对应官方 `int.latin` 扩展。
String _toLatin(int number) {
  String result = '';
  int n = number;
  while (n > 0) {
    final int remainder = (n - 1) % 26;
    result = String.fromCharCode(remainder + 65) + result;
    n = (n - 1) ~/ 26;
  }
  return result.toLowerCase();
}

/// 小写罗马数字，对应官方 `int.roman` 扩展（正整数）。
String _toRoman(int number) {
  if (number <= 0) return '$number';
  const List<(String, int)> map = <(String, int)>[
    ('M', 1000),
    ('CM', 900),
    ('D', 500),
    ('CD', 400),
    ('C', 100),
    ('XC', 90),
    ('L', 50),
    ('XL', 40),
    ('X', 10),
    ('IX', 9),
    ('V', 5),
    ('IV', 4),
    ('I', 1),
  ];
  int n = number;
  String result = '';
  for (final (String sym, int val) in map) {
    while (n >= val) {
      result += sym;
      n -= val;
    }
  }
  return result.toLowerCase();
}

/// 待办标记：**自绘勾选框**（不用图标字形），主题色。
///
/// ## 为什么不用 Lucide（曾是 `uncheck`/`check` → square300/squareCheck300）
/// 图标字体自带一套垂直度量（`lucide.ttf`：hhea asc 1.0em / desc 0，
/// win asc 1.09em），而 `Icon` 是按**图标字体的行盒**在 size 方框内居中的。
/// 于是同一行里出现两条对齐轨道：汉字走**正文字体**的度量，勾选框走
/// **图标字体**的度量——无序/有序标记是文字字形（与正文同轨）所以对得齐，
/// 待办是图标字形所以怎么调都对不上（2026-09-11 实测）。
/// 自绘后：边长 / 描边 / 圆角 / 居中全部由我们的几何决定，与
/// [_markerBox] 的文字墨迹补偿严丝合缝，也去掉了对图标字形的依赖。
class _SinanTodoIcon extends StatelessWidget {
  const _SinanTodoIcon({
    required this.checked,
    required this.onTap,
    required this.color,
  });

  final bool checked;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final double tsf =
        context.read<EditorState>().editorStyle.textScaleFactor;
    final TextStyle baseStyle =
        context.read<EditorState>().editorStyle.textStyleConfiguration.text;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: markerBox(
          context,
          SizedBox(
            // 0.88×正文：与数字标记（1.0×正文）同基准、随正文缩放；
            // 旧 Lucide 方框可见边长 18×18/24=13.5，这里取 0.88×让轮廓更实。
            width: (baseStyle.fontSize ?? 16) * 0.88 * tsf,
            height: (baseStyle.fontSize ?? 16) * 0.88 * tsf,
            child: CustomPaint(
              painter: _TodoBoxPainter(
                checked: checked,
                color: color,
                stroke: (baseStyle.fontSize ?? 16) * 0.088 * tsf,
                radius: (baseStyle.fontSize ?? 16) * 0.176 * tsf,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 自绘勾选框：圆角方框描边 + （选中时）内嵌对勾。
///
/// 纯几何绘制 ⇒ 盒子中心就是方框中心，不受任何字体度量影响；
/// 描边压在半像素上也无妨（几何线条有抗锯齿，观感与字形无关）。
class _TodoBoxPainter extends CustomPainter {
  const _TodoBoxPainter({
    required this.checked,
    required this.color,
    required this.stroke,
    required this.radius,
  });

  final bool checked;
  final Color color;
  final double stroke;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..color = color;

    // 描边内缩 stroke/2，方框外沿正好落在给定尺寸上。
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(stroke / 2),
        Radius.circular(radius),
      ),
      paint,
    );

    if (!checked) return;
    // 对勾用两段直线（圆头线帽，拐点自然）——避免 `Path` 与官方文档模型的
    // `Path`（块路径）同名冲突。视觉重心略偏上，与方框光学居中一致。
    final Offset elbow = Offset(size.width * 0.44, size.height * 0.70);
    canvas.drawLine(Offset(size.width * 0.26, size.height * 0.52), elbow, paint);
    canvas.drawLine(elbow, Offset(size.width * 0.76, size.height * 0.30), paint);
  }

  @override
  bool shouldRepaint(_TodoBoxPainter oldDelegate) =>
      oldDelegate.checked != checked ||
      oldDelegate.color != color ||
      oldDelegate.stroke != stroke ||
      oldDelegate.radius != radius;
}

/// 编辑器用：字符快捷键（我们的 + 官方标准）。
///
/// 顺序有意义——**先命中先赢**：代码块的回车必须排在官方 `insertNewLine`
/// 之前，否则代码块会被拆成两段（见 `insertNewLineInCodeBlock` 的说明）。
///
/// 斜杠菜单是**顶掉官方那个换自己的**：官方 `slashCommand` 挂的是
/// `standardSelectionMenuItems`，其中没有代码块/公式/附件——那三种就没有
/// 插入入口。这里换成 `customSlashCommand(sinanSelectionMenuItems())`：
/// 官方条目一条不少，只追加我们的三个（见 `slash_menu_items.dart`）。
///
/// [slashMenuStyle] **必传**：官方 `customSlashCommand` 的 `style` 默认是
/// `SelectionMenuStyle.light`（硬编码白底 + 青蓝强调色，既不看种子色也不看
/// 明暗）——不传就是"斜杠菜单没跟随主题"。由 [sinanSlashMenuStyle] 从应用
/// `ColorScheme` 构造后注入（视图侧，见 `note_editor_view_appflowy.dart`）。
///
/// 参数**不给默认值**是有意的：这条配色必须由视图按当前主题算，
/// 留个默认值等于把"忘了传"变成静默的浅色菜单。
List<CharacterShortcutEvent> sinanCharacterShortcutEvents({
  required SelectionMenuStyle slashMenuStyle,
}) => <CharacterShortcutEvent>[
  // 两个自定义回车都排在官方标准件之前（先命中先赢，见各自说明）。它们彼此
  // 的顺序无关紧要——各自只接管自己的块类型（`code` / `toggle_list`），
  // 不会互相抢；但都必须早于官方 `insertNewLine`，否则那两类块会被拆成两段。
  insertNewLineInCodeBlock,
  insertNewLineInToggle,
  customSlashCommand(sinanSelectionMenuItems(), style: slashMenuStyle),
  ...standardCharacterShortcutEvents.where(
    (CharacterShortcutEvent event) => event.key != slashCommand.key,
  ),
];
