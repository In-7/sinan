import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/tokens.dart';
import '../blocks/code_block_component.dart';
import '../widgets/hover_state_layer.dart';
import 'align_toolbar_item.dart';
import 'color_toolbar_item.dart';
import 'heading_toolbar_item.dart';
import 'link_toolbar_item.dart';

/// 编辑器工具栏的**条目表与共用小件**（2026-09-12 起随官方 [FloatingToolbar]
/// 浮出，本文件不再自绘工具栏容器）。
///
/// ## 历史：为什么曾自绘固定栏
/// 官方浮动栏语义是"有选区才浮出"，曾因"想要 Word/飞书式常驻条"自绘容器
/// （`AppFlowyFixedToolbar`）。但常驻条必须监听全部事务/选区流，每次击键
/// 都要重建约 20 个条目（官方条目是黑盒，无法差量），是编辑器热路径上的
/// 固定成本。2026-09-12 撤销该取舍：回到官方 [FloatingToolbar]——**空闲时
/// widget 根本不挂载，零成本**；可见窗口短暂，官方"可见时整条重建"的实现
/// 就不再构成问题。
///
/// 条目仍然全部复用官方/共用实现（见下），一个都没复制。
///
/// ## 官方没有的自研条目（仍用官方渲染件）
/// 撤销 / 重做 / 待办列表 / 代码块 / 合并颜色——官方 6.2.0 桌面条目表里
/// 没有（实测）。自研条目复用官方 [SVGIconItemWidget] 的 `iconBuilder`
/// 槽位渲染我们自己的图标，30×30 热区 / 18px 图标 / 悬浮与按压反馈与官方
/// 条目完全一致（不另立一套视觉）。颜色条目因需要"单按钮双区色板"，
/// 面板也自研，见 [color_toolbar_item.dart]。
///
/// ## 保焦契约（浮出后仍成立）
/// 真正会抢焦点的是**菜单/浮层**：`MenuAnchor` 打开时会把焦点收到自己的
/// 按钮节点，官方的链接/颜色菜单更是自建 overlay 并显式
/// requestFocus——官方为此发明了 `keepEditorFocusNotifier`
/// （"浮层交互期间别清选区"）。浮动栏的条目在 root overlay 里，
/// 每个条目经 [_withKeepEditorFocus] 包上"按下 increase、抬起帧末
/// decrease"：既为菜单类条目备好通路，也保证"点完工具栏，焦点回到正文"
/// ——计数归零时官方实现会给编辑器 `requestFocus()`。
///
/// ## 官方 tooltip 的兜底
/// 官方把带前缀的 id（`editor.bold`）传给 `getTooltipText`，而它只认
/// `bold` ⇒ 取到空串，气泡不显示（上游小瑕疵）。用 [sinanToolbarTooltip]
/// 兜底（id → 文案表 [kEditorTooltips]，含快捷键）。

/// 编辑器工具栏（**悬浮栏**）的条目表。分组值沿用官方（决定分隔线位置）：
/// 1 块样式 · 2 行内格式 · 3 列表与块类型 · 4 颜色 · 6 对齐。
///
/// 原 group 0「撤销 / 重做」**已移出**（2026-09-14 用户定案）：悬浮栏只在有
/// 选区时出现，而撤销最常用的时刻是"刚打完字、光标还在那儿"——那时根本没有
/// 悬浮栏，按钮够不着。它们现在常驻标题行左侧，见
/// `note_editor_view_appflowy.dart` 的 `_HistoryButton`。
///
/// 返回的条目都包了保焦装饰（[_withKeepEditorFocusItem]）——id / group /
/// isActive 原样透传，只有 builder 多包一层 Listener。
List<ToolbarItem> sinanFixedToolbarItems() => <ToolbarItem>[
  // 块样式：正文 / 标题 1~3 **合并成一个下拉**（原来 4 个平铺按钮）。
  // 成熟方案见 heading_toolbar_item.dart 的注释。
  sinanHeadingItem,
  // 顺序按 Word/飞书面习惯排（官方 `markdownFormatItems` 的默认顺序
  // 是 U/B/I/S/code，与我们的既有工具栏不一致）。
  _formatItem('bold'),
  _formatItem('italic'),
  _formatItem('underline'),
  _formatItem('strikethrough'),
  _formatItem('code'),
  bulletedListItem,
  numberedListItem,
  todoListItem,
  quoteItem,
  codeBlockItem,
  // 颜色：把官方独立的"字体颜色 / 背景色"合并成单按钮双区色板，
  // 与参考图一致。group 4 = 官方"颜色组"，在列表组与对齐组之间独占分隔线。
  sinanColorItem,
  // 超链接：自研条目（官方的两处"静默失败"见 link_toolbar_item.dart 注释），
  // 与颜色同组 4。
  sinanLinkItem,
  // 对齐：把官方独立的"左 / 中 / 右"三个按钮合并成**一个下拉按钮**
  // （按钮显示当前对齐，点开三选一）。group 6 = 官方"对齐组"。
  sinanAlignItem,
].map(_withKeepEditorFocusItem).toList(growable: false);

/// 给**任意控件**包一层"按下保焦"：按下即 [keepEditorFocusNotifier.increase]，
/// 抬起后帧末 decrease（帧末的原因见 [_releaseEditorFocus]）。
///
/// 抽成公开件是因为**标题行常驻的撤销 / 重做**也要它
/// （`note_editor_view_appflowy.dart`）：点一下按钮就把焦点交出去的话，
/// 紧接着按 Ctrl+Z 就落不到编辑器了。
Widget withKeepEditorFocus(Widget child) => Listener(
  onPointerDown: (_) => keepEditorFocusNotifier.increase(),
  onPointerUp: (_) => _releaseEditorFocus(),
  onPointerCancel: (_) => _releaseEditorFocus(),
  child: child,
);

/// 给条目包一层"按下保焦"（[withKeepEditorFocus] 作用在 [ToolbarItem] 的
/// builder 上）**并补上悬停/按下底色**（[HoverStateLayer]）。
/// id / group / isActive 原样透传——浮动栏的可用性过滤、分组分隔线行为都不
/// 受影响（分隔线由官方 `_computeActiveItems` 另外插入，不经这里）。
ToolbarItem _withKeepEditorFocusItem(ToolbarItem item) => ToolbarItem(
  id: item.id,
  group: item.group,
  isActive: item.isActive,
  builder:
      (
        BuildContext context,
        EditorState editorState,
        Color highlightColor,
        Color? iconColor,
        ToolbarTooltipBuilder? tooltipBuilder,
      ) {
        final Widget child = item.builder!(
          context,
          editorState,
          highlightColor,
          iconColor,
          tooltipBuilder,
        );
        return withKeepEditorFocus(
          HoverStateLayer(
            base: iconColor ?? highlightColor,
            child: child,
          ),
        );
      },
);

/// 指针抬起后释放"保焦"计数。
///
/// 必须延到帧末：点击的 `onTap` 由手势竞技场在指针抬起**之后**裁决，
/// 提前 decrease 会让计数归零、编辑器抢回焦点，动作就可能落在"选区
/// 已被清空"的状态上。
void _releaseEditorFocus() {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    keepEditorFocusNotifier.decrease();
  });
}

/// 从官方行内格式条目表里按语义取件（上游改名/删件时**立刻报错**，
/// 由 `fixed_toolbar_test.dart` 兜住，而不是悄悄少一个按钮）。
ToolbarItem _formatItem(String name) => markdownFormatItems.firstWhere(
  (ToolbarItem item) => item.id == 'editor.$name',
  orElse:
      () => throw StateError(
        'appflowy 官方行内格式条目 "$name" 不存在——上游条目表变了，请同步 fixed_toolbar.dart',
      ),
);

// 撤销 / 重做的 [ToolbarItem] 定义**已删除**（2026-09-14，见文件头条目表的说明）：
// 它们不再属于悬浮栏，改由 `note_editor_view_appflowy.dart` 的 `_HistoryButton`
// 直接调 `editorState.undoManager.undo() / redo()` 常驻渲染。
// tooltip 文案（`sinan.undo` / `sinan.redo`）仍留在 [kEditorTooltips]，由标题行
// 那两个按钮消费；"tooltip 声明的快捷键 = 真实绑定"仍由
// `fixed_toolbar_test.dart` 守着（那条用例遍历的是文案表，与条目表无关）。

/// 待办列表（官方有 **块组件**、没有工具栏条目）。语义对齐官方列表条目：
/// 已是待办 → 转回正文；否则转待办（未勾选）。
final ToolbarItem todoListItem = ToolbarItem(
  id: 'sinan.todo_list',
  group: 3,
  isActive: onlyShowInTextType,
  builder: (context, editorState, highlightColor, iconColor, tooltipBuilder) {
    final Selection selection = editorState.selection!;
    final Node node = editorState.getNodeAtPath(selection.start.path)!;
    final bool isHighlight = node.type == TodoListBlockKeys.type;
    final Widget child = _iconItem(
      context: context,
      icon: LucideIcons.listTodo300,
      iconColor: iconColor,
      highlightColor: highlightColor,
      isHighlight: isHighlight,
      onPressed:
          () => editorState.formatNode(selection, (Node target) {
            final Map<String, dynamic> attributes = <String, dynamic>{
              ...target.attributes,
            };
            if (isHighlight) {
              // 离开待办态时摘掉 checked，别把它留给段落（脏属性会跟着落库）。
              attributes.remove(TodoListBlockKeys.checked);
            } else {
              attributes[TodoListBlockKeys.checked] = false;
            }
            // 官方条目同款：块类型转换时把文本 delta 显式带走。
            attributes[blockComponentDelta] = (target.delta ?? Delta()).toJson();
            return target.copyWith(
              type: isHighlight ? ParagraphBlockKeys.type : TodoListBlockKeys.type,
              attributes: attributes,
            );
          }),
    );
    return _withTooltip(context, tooltipBuilder, 'sinan.todo_list', child);
  },
);

/// 代码块（官方 6.2.0 **没有**这个块组件，我们用 `blocks/code_block_component.dart`
/// 自己补的；此处给它一个工具栏入口）。
final ToolbarItem codeBlockItem = ToolbarItem(
  id: 'sinan.code_block',
  group: 3,
  // 不能用官方 `onlyShowInTextType`：它的白名单不含 `code`，
  // 光标在代码块里时本条目会被禁用——**出不去**代码块。
  isActive: _inTextBlock,
  builder: (context, editorState, highlightColor, iconColor, tooltipBuilder) {
    final Selection selection = editorState.selection!;
    final Node node = editorState.getNodeAtPath(selection.start.path)!;
    final bool isHighlight = node.type == CodeBlockKeys.type;
    final Widget child = _iconItem(
      context: context,
      icon: LucideIcons.squareCode300,
      iconColor: iconColor,
      highlightColor: highlightColor,
      isHighlight: isHighlight,
      onPressed: () => toggleSinanCodeBlock(editorState),
    );
    return _withTooltip(context, tooltipBuilder, 'sinan.code_block', child);
  },
);

// `toggleSinanCodeBlock`（段落 ↔ 代码块）**已移到 `blocks/code_block_component.dart`**
// （2026-09-15）：它是代码块的块级行为，块操作菜单（`blocks/block_action_menu.dart`）
// 也要用——放在工具栏文件里会让 blocks 反向依赖 toolbar。本文件顶部已 import
// 那个文件，符号照旧可用。

/// 段落 ↔ [type] 的块类型切换（列表 / 引用等共用）；已在 [type] 时转回正文。
///
/// 与工具栏条目的实现同源（官方条目就是 `copyWith(type:)`），只是把
/// "先看当前类型再决定目标"这一步抽出来，供快捷键复用，避免两条路径分叉。
KeyEventResult toggleBlockType(EditorState editorState, String type) {
  final Selection? selection = editorState.selection;
  if (selection == null || !selection.isSingle) return KeyEventResult.ignored;
  final Node? node = editorState.getNodeAtPath(selection.start.path);
  if (node?.delta == null) return KeyEventResult.ignored;

  final bool isTarget = node!.type == type;
  unawaited(
    editorState.formatNode(
      selection,
      (Node target) => target.copyWith(
        type: isTarget ? ParagraphBlockKeys.type : type,
        attributes: <String, dynamic>{
          ...target.attributes,
          // 与自研待办条目同款：块类型转换时把文本 delta 显式带走。
          blockComponentDelta: (target.delta ?? Delta()).toJson(),
        },
      ),
    ),
  );
  return KeyEventResult.handled;
}

/// 块类型快捷键工厂（`cmd` 变体由 `ctrl` 前缀替换而来）。
CommandShortcutEvent _blockTypeCommand({
  required String key,
  required String description,
  required String command,
  required String type,
}) => CommandShortcutEvent(
  key: key,
  getDescription: () => description,
  command: command,
  macOSCommand: command.replaceFirst('ctrl', 'cmd'),
  handler: (EditorState editorState) => toggleBlockType(editorState, type),
);

/// **无序列表 Ctrl/Cmd + Shift + 8**（官方没有这条；取 Word / Google Docs 口径）。
///
/// ⚠️ 键名必须用官方 `key_mapping.dart` 里的 **`digit 8`**（裸 `'8'` 不在表里，
/// `keyCode` 查不到 → 按住 Ctrl+Shift 的瞬间就抛 null 检查异常，键盘分发整条断掉）。
final CommandShortcutEvent sinanBulletedListCommand = _blockTypeCommand(
  key: 'sinan.bulleted_list',
  description: '无序列表',
  command: 'ctrl+shift+digit 8',
  type: BulletedListBlockKeys.type,
);

/// **有序列表 Ctrl/Cmd + Shift + 7**（同上，Word 口径；键名见上面的 `digit 8` 说明）。
final CommandShortcutEvent sinanNumberedListCommand = _blockTypeCommand(
  key: 'sinan.numbered_list',
  description: '有序列表',
  command: 'ctrl+shift+digit 7',
  type: NumberedListBlockKeys.type,
);

/// **引用 Ctrl/Cmd + Shift + Q**（官方没有这条）。
final CommandShortcutEvent sinanQuoteCommand = _blockTypeCommand(
  key: 'sinan.quote',
  description: '引用',
  command: 'ctrl+shift+q',
  type: QuoteBlockKeys.type,
);

CommandShortcutEvent _alignCommand({
  required String command,
  required String align,
  required String description,
}) => CommandShortcutEvent(
  key: 'sinan.align_$align',
  getDescription: () => description,
  command: command,
  macOSCommand: command.replaceFirst('ctrl', 'cmd'),
  handler: (EditorState editorState) {
    final Selection? selection = editorState.selection;
    if (selection == null) return KeyEventResult.ignored;
    unawaited(
      editorState.updateNode(
        selection,
        (Node node) => node.copyWith(
          attributes: <String, dynamic>{
            ...node.attributes,
            blockComponentAlign: align,
          },
        ),
      ),
    );
    return KeyEventResult.handled;
  },
);

/// **对齐**：Ctrl/Cmd + Shift + L / E / R（左 / 中 / 右）。
///
/// 官方对齐三件套**没有任何快捷键**（工具栏条目里翻不到 command），这里补齐，
/// 与自研的对齐下拉按钮同一套 `updateNode` 语义。
final List<CommandShortcutEvent> sinanAlignCommands = <CommandShortcutEvent>[
  _alignCommand(command: 'ctrl+shift+l', align: 'left', description: '左对齐'),
  _alignCommand(command: 'ctrl+shift+e', align: 'center', description: '居中'),
  _alignCommand(command: 'ctrl+shift+r', align: 'right', description: '右对齐'),
];

/// **目录开关 Ctrl/Cmd + Shift + O**（状态在视图里，故做成工厂）。
CommandShortcutEvent sinanTocCommand({required VoidCallback onToggle}) =>
    CommandShortcutEvent(
      key: 'sinan.toc_shortcut',
      getDescription: () => '目录',
      command: 'ctrl+shift+o',
      macOSCommand: 'cmd+shift+o',
      handler: (EditorState editorState) {
        onToggle();
        return KeyEventResult.handled;
      },
    );

/// 代码块的快捷键 **Ctrl / Cmd + Shift + `**。
///
/// ⚠️ **官方 6.2.0 没有这条**（`standardCommandShortcutEvents` 里翻不到），
/// 而工具栏 tooltip 一直写着它——此前按下去**没有任何反应**。这里把它补上，
/// 实现与工具栏条目共用 [toggleSinanCodeBlock]。
///
/// 键名用官方的 `Backquote`（`key_mapping.dart`：`'Backquote': 0x60`），
/// 不是字面量反引号——官方 `Keybinding.parse` 会按这张表查键码。
final CommandShortcutEvent sinanCodeBlockCommand = CommandShortcutEvent(
  key: 'sinan.code_block',
  getDescription: () => '代码块',
  command: 'ctrl+shift+backquote',
  macOSCommand: 'cmd+shift+backquote',
  handler: toggleSinanCodeBlock,
);

// ─────────────────────────── 共用小件 ───────────────────────────

/// 光标（单点选区）落在**文本块**里——含官方白名单之外的 `code`。
bool _inTextBlock(EditorState editorState) {
  final Selection? selection = editorState.selection;
  if (selection == null || !selection.isSingle) return false;
  return editorState.getNodeAtPath(selection.start.path)?.delta != null;
}

/// 借官方 [SVGIconItemWidget] 渲染自研条目：尺寸与官方条目一致，
/// 只把图标换成我们的；`onPressed` 为 null 时把图标色调淡表达"不可用"
/// （不套 Opacity——那会 saveLayer，见函数内注释）。
///
/// ⚠️ **悬停/按下底色不在这里**：官方渲染件把三色显式置透明（见
/// [HoverStateLayer] 的说明），而**所有条目**统一由
/// [_withKeepEditorFocusItem] 外面包一层 [HoverStateLayer]——官方条目与
/// 自研条目因此拿到同一套指针反馈，不必各画一遍。
/// （这条更正了之前的记法"浮动栏下状态表达回归官方口径"：官方口径其实是
/// **没有反馈**，只在 2026-09-15 实机反馈后才补上。）
Widget _iconItem({
  required BuildContext context,
  required IconData icon,
  required Color? iconColor,
  required Color highlightColor,
  required VoidCallback? onPressed,
  bool isHighlight = false,
}) {
  final Color base = isHighlight
      ? highlightColor
      : iconColor ?? Theme.of(context).colorScheme.onSurfaceVariant;
  // 禁用态**直接调淡颜色**而不是套一层 Opacity。
  //
  // ⚠️ `Opacity` 会触发 `saveLayer`（离屏合成），是官方性能文档点名的昂贵
  // 操作；工具栏条目多，且禁用态是常态（无选区时一片条目都是禁用）。改色是
  // 纯绘制、零合成开销，视觉与 0.35 透明度等价（同样按原 alpha 相乘）。
  final Color color =
      onPressed == null ? base.withValues(alpha: base.a * 0.35) : base;
  return SVGIconItemWidget(
    iconBuilder: (BuildContext context) =>
        Icon(icon, size: Tokens.iconSm, color: color),
    isHighlight: isHighlight,
    highlightColor: highlightColor,
    iconColor: color,
    onPressed: onPressed,
  );
}

Widget _withTooltip(
  BuildContext context,
  ToolbarTooltipBuilder? tooltipBuilder,
  String id,
  Widget child,
) => tooltipBuilder?.call(context, id, _tooltipOf(id, ''), child) ?? child;

/// 工具栏 tooltip 的统一兜底：我们的文案表优先（官方把带前缀的 id 传给
/// `getTooltipText` 只认短 id ⇒ 气泡为空），表里没有才用官方传来的（可能
/// 为空串）。供视图接 [FloatingToolbar.tooltipBuilder] 用。
Widget sinanToolbarTooltip(
  BuildContext context,
  String id,
  String message,
  Widget child,
) {
  final String text = _tooltipOf(id, message);
  if (text.isEmpty) return child;
  return Tooltip(message: text, child: child);
}

/// 条目文案（含快捷键）。官方文案表只认不带前缀的 id；而行内格式条目
/// 传给 tooltipBuilder 的 id 本身也是短 id（`bold`/`italic`/…），所以这里
/// 对格式条目直接用短 id，其余官方条目用完整 id（如 `editor.paragraph`）。
///
/// ⚠️ **表里的快捷键必须与官方真实绑定一致**（`fixed_toolbar_test.dart` 有一条
/// 断言逐个核对）。这张表当年从 quill 版抄来，抄错了四条：
/// - 「待办列表 Ctrl+Shift+C」→ 官方是 **Ctrl+Enter**（`toggleTodoListCommand`）；
/// - 「无序列表 Ctrl+Shift+L」「有序列表 Ctrl+Shift+O」→ 官方**没有**绑定；
/// - 「引用 Ctrl+Shift+B」→ 官方 `ctrl+shift+b` 其实是**转回正文**（`toggleBody`），
///   引用本身没有快捷键。
/// 其余各条（撤销/重做/加粗/斜体/下划线/删除线/行内代码/标题 1~3）已核对无误，
/// 其中标题档位是新补的真实绑定（官方 `toggleH1/H2/H3`）。
const Map<String, String> kEditorTooltips = <String, String>{
  // 自研
  'sinan.undo': '撤销（Ctrl+Z）',
  'sinan.redo': '重做（Ctrl+Y）',
  'sinan.todo_list': '待办列表（Ctrl+Enter）',
  'sinan.code_block': '代码块（Ctrl+Shift+`）',
  'sinan.find': '搜索（Ctrl+F）',
  // 自研块样式下拉：一个 tooltip 声明四条官方绑定（toggleBody / H1 / H2 / H3），
  // 菜单里每项右侧也各自标注（见 heading_toolbar_item.dart）。
  'sinan.heading':
      '段落样式（正文 Ctrl+Shift+B / 标题 1 Ctrl+Shift+T / '
          '标题 2 Ctrl+Shift+G / 标题 3 Ctrl+Shift+J）',
  // 官方行内格式（⚠️ 它们传给 tooltipBuilder 的 id 是**不带 editor. 前缀**的
  // 'bold'/'italic'/…，与段落/标题/列表不同，所以这里用短 id）。
  'bold': '加粗（Ctrl+B）',
  'italic': '斜体（Ctrl+I）',
  'underline': '下划线（Ctrl+U）',
  'strikethrough': '删除线（Ctrl+Shift+S）',
  'code': '行内代码（Ctrl+E）',
  // 列表与引用：**官方没有任何快捷键**（工具栏条目里翻不到 command），
  // 以下三条是我们的自研绑定（`sinanBulletedListCommand` / Numbered / Quote）。
  'editor.bulleted_list': '无序列表（Ctrl+Shift+8）',
  'editor.numbered_list': '有序列表（Ctrl+Shift+7）',
  'editor.quote': '引用（Ctrl+Shift+Q）',
  // 官方颜色组：官方**高亮**有绑定（`toggleHighlightCommand` = Ctrl+Shift+H，
  // 直接切换默认高亮色，不打开面板），文字色没有。
  'editor.highlightColor': '背景色',
  // 自研颜色面板：组合色板本身没有绑定，提示沿用官方的"切换高亮"。
  'sinan.color': '颜色 / 高亮（Ctrl+Shift+H）',
  // 自研超链接（官方 showLinkMenuCommand 绑定 Ctrl+K，故新条目沿用提示）
  'sinan.link': '链接（Ctrl+K）',
  // 自研对齐下拉：三个方向各有自研绑定（一个 tooltip 声明三条）。
  'sinan.align': '对齐（左 Ctrl+Shift+L / 中 Ctrl+Shift+E / 右 Ctrl+Shift+R）',
  // 自研目录开关（sinanTocCommand，视图持有状态）。
  'sinan.toc': '目录（Ctrl+Shift+O）',
};

/// 取文案：我们的表优先，其次用官方传进来的（可能为空串）。
String _tooltipOf(String id, String message) => kEditorTooltips[id] ?? message;
