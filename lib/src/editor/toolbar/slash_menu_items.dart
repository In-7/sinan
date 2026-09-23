import 'dart:async';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
// 只用到 BuildContext（句柄签名要求）；widgets 层是两套 Material 共用的，
// 这里不需要也不该牵进任何一方的 Material。
import 'package:flutter/widgets.dart';import '../../notes/services/attachment_meta.dart';
import '../../notes/services/formula_render.dart';
import '../../notes/services/note_media_service.dart';
import '../blocks/attachment_block_component.dart';
import '../blocks/callout_block_component.dart';
import '../blocks/code_block_component.dart';
import '../blocks/block_picker.dart';
import '../blocks/formula_block_component.dart';
import '../blocks/note_picker.dart';
import '../blocks/ref_block_component.dart';
import '../blocks/toggle_block_component.dart';

/// 斜杠菜单的配色——**从应用主题色构造**，不能省。
///
/// 官方 `customSlashCommand(items)` 的 `style` 默认值是
/// `SelectionMenuStyle.light`（`shortcuts/character/slash_command.dart`）：
/// 那是一套**硬编码**调色板——白底 `#FFFFFF`、文字 `#333333`、强调色是官方
/// 自己的青蓝 `#00BCF0`（见 `selection_menu_widget.dart` 的 `light`/`dark`
/// 静态常量）。它**既不读应用种子色、也不看明暗** ⇒ 深色主题下会弹出一个
/// 白底青蓝的菜单（实测现象："斜杠菜单没有跟随主题"）。
///
/// 官方为这种情况留了口子（`customSlashCommand(..., style:)`），所以这里
/// **零补丁**，只做角色映射。入参收 `Color` 而非 `ColorScheme`：material_ui
/// （应用侧）与官方 flutter/material（编辑器侧）的 `ColorScheme` 是两个类型，
/// 只有 `Color` 两侧通用（与 `EditorTypography` 收 `Color` 同一口径）。
///
/// 选中态用中性 `foreground @10%`：与目录面板的激活项**同值**（那里实测
/// 8% 在浅色下几乎看不出选中态）。**全部走 onSurface 中性系**，不染主题色。
SelectionMenuStyle sinanSlashMenuStyle({
  required Color background,
  required Color foreground,
  required Color muted,
  required Color outline,
  required Color error,
}) => SelectionMenuStyle(
  // 浮层底：与 `popupMenuTheme` / 主菜单 / 悬浮工具栏同一档
  // （[AppTheme.floatSurface]，见 `app_float_surface.dart` 的浮层三件套）。
  selectionMenuBackgroundColor: background,
  selectionMenuItemTextColor: foreground,
  selectionMenuItemIconColor: muted,
  selectionMenuItemSelectedTextColor: foreground,
  selectionMenuItemSelectedIconColor: foreground,
  selectionMenuItemSelectedColor: foreground.withValues(alpha: 0.10),
  selectionMenuUnselectedLabelColor: muted,
  selectionMenuDividerColor: outline,
  selectionMenuLinkBorderColor: outline,
  selectionMenuInvalidLinkColor: error,
  // 下面几条斜杠菜单本身不渲染（同一套 `SelectionMenuStyle` 还被链接编辑等
  // 场景复用），一并按角色给对，免得将来复用时报错色。
  // 中性填充按钮：foreground 作底、background 作字 ⇒ 深浅模式都高对比。
  selectionMenuButtonColor: foreground,
  selectionMenuButtonTextColor: background,
  selectionMenuButtonIconColor: background,
  selectionMenuButtonBorderColor: outline,
  selectionMenuTabIndicatorColor: foreground,
);

/// 斜杠菜单（`/`）的 sinan 条目表——**官方的扩展点，不是自造机制**。
///
/// 官方 `standardSelectionMenuItems` 只有它自带那批块（段落/标题/列表/待办/
/// 引用/图片/表格/分隔线）。我们的三个增量块**没有入口就等于插不进去**——之前
/// 正是如此（只有代码块还能靠工具栏按钮）。官方为这种情况留了
/// `customSlashCommand(items)`：把标准表展开、追加自己的条目即可，零补丁。
///
/// 条目形态照官方（如 `dividerMenuItem` / `tableMenuItem`）写：
/// `getName` + `icon`（官方 [SelectionMenuIconWidget] 渲染，我们的图标是
/// Lucide 字体图标，它本来就收 `IconData`）+ `keywords`（中英都给，中文用户
/// 会直接打汉字）+ `handler`。
List<SelectionMenuItem> sinanSelectionMenuItems() {
  return _withChineseKeywords(<SelectionMenuItem>[
    // 官方条目：**剔掉**图标是 Material `Icons.*` 的那两条（表格 / 分隔线），
    // 下面用语义一致、图标为 Lucide 的自家条目替代。
    ...standardSelectionMenuItems.where(_isNotMaterialIconItem),
    tableSlashMenuItem,
    dividerSlashMenuItem,
    codeSlashMenuItem,
    calloutSlashMenuItem,
    ...toggleSlashMenuItems,
    formulaSlashMenuItem,
    attachmentSlashMenuItem,
    refSlashMenuItem,
    refBlockSlashMenuItem,
    embedNoteSlashMenuItem,
    embedBlockSlashMenuItem,
  ]);
}

/// 折叠块：**一个节点类型覆盖四个条目**（折叠列表 + 折叠标题 1/2/3），
/// 官方口径（`toggle_list` + `level`），见 `blocks/toggle_block_component.dart`。
///
/// 只给 1/2/3 级：正文里 h4~h6 靠字重而非字号区分（我们的排版表），
/// 折叠标题再往下没有层级意义；`level` 支持 1..6，将来要放开是加一行。
final List<SelectionMenuItem> toggleSlashMenuItems = <SelectionMenuItem>[
  _toggleSlashMenuItem(
    name: '折叠列表',
    keywords: const <String>['toggle', 'toggle list', '折叠', '折叠列表', '折叠清单'],
    nodeBuilder: toggleListNode,
  ),
  for (int level = 1; level <= 3; level++)
    _toggleSlashMenuItem(
      name: '折叠标题 $level',
      keywords: <String>[
        'toggle heading $level',
        '折叠标题 $level',
        '折叠标题$level',
      ],
      nodeBuilder: () => toggleHeadingNode(level: level),
    ),
];

/// 折叠块四个条目共用的插入语义（与代码块/高亮块那条同款：空块原地替换、
/// 光标落块首）。
SelectionMenuItem _toggleSlashMenuItem({
  required String name,
  required List<String> keywords,
  required Node Function() nodeBuilder,
}) => SelectionMenuItem.node(
  getName: () => name,
  iconData: tabler.ChevronRight(height: 24, width: 24, strokeWidth: 1.5),
  keywords: keywords,
  nodeBuilder: (editorState, context) => nodeBuilder(),
  replace: (editorState, node) => node.delta?.isEmpty ?? false,
  updateSelection: (editorState, insertPath, replaced, insertedBefore) =>
      Selection.collapsed(Position(path: insertPath)),
);

/// Callout / 高亮块（2026-09-14：对齐官方应用侧的 `calloutItem`）。
///
/// 与代码块那条**同一形态**：走官方 `SelectionMenuItem.node`，我们只回答
/// "造什么节点、要不要替换、光标放哪"。名称与关键字中英都给（官方只有
/// `['callout']`，中文用户会直接打"高亮块"）。
final SelectionMenuItem calloutSlashMenuItem = SelectionMenuItem.node(
  getName: () => '高亮块',
  iconData: tabler.InfoCircle(height: 24, width: 24, strokeWidth: 1.5),
  keywords: const <String>['callout', '高亮块', '提示', '强调'],
  nodeBuilder: (editorState, context) => calloutNode(),
  // 空块 → 原地替换（与官方 callout / table 同一判据），不留多余空段落。
  replace: (editorState, node) => node.delta?.isEmpty ?? false,
  // 文本块：光标进块内，接着就能打字。
  updateSelection: (editorState, insertPath, replaced, insertedBefore) =>
      Selection.collapsed(Position(path: insertPath)),
);

/// 官方 `tableMenuItem` / `dividerMenuItem` 的图标是 Material 的
/// `Icons.table_view` / `Icons.horizontal_rule`（定义在各自的块组件文件里），
/// 是**全应用最后两处 Material 图标**——应用其余图标（含编辑器工具栏）都是
/// Lucide。它们的 `icon` 字段是 `final`、没法在应用侧替换，故用自家条目替代。
bool _isNotMaterialIconItem(SelectionMenuItem item) =>
    !identical(item, tableMenuItem) && !identical(item, dividerMenuItem);

/// 表格：**语义照抄官方 `tableMenuItem`**，只换图标。
///
/// `SelectionMenuIconWidget` 本身收 `IconData`，所以换图标**不需要任何补丁**。
/// 行为与官方逐字一致：光标所在块为空 ⇒ **就地替换**（不留多余空段落），
/// 非空则插到下一行；收尾把光标放进新表格左上单元格。
final SelectionMenuItem tableSlashMenuItem = SelectionMenuItem(
  getName: () => AppFlowyEditorL10n.current.table,
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: tabler.Table(height: 24, width: 24, strokeWidth: 1.5),
    isSelected: isSelected,
    style: style,
  ),
  keywords: const <String>['table', '表格'],
  handler: (editorState, _, _) {
    final Selection? selection = editorState.selection;
    if (selection == null || !selection.isCollapsed) {
      return;
    }
    final Node? current = editorState.getNodeAtPath(selection.end.path);
    if (current == null) {
      return;
    }

    final TableNode tableNode = TableNode.fromList(<List<String>>[
      <String>['', ''],
      <String>['', ''],
    ]);

    final Transaction transaction = editorState.transaction;
    final Delta? delta = current.delta;
    if (delta != null && delta.isEmpty) {
      transaction
        ..insertNode(selection.end.path, tableNode.node)
        ..deleteNode(current);
      transaction.afterSelection = Selection.collapsed(
        Position(path: selection.end.path + <int>[0, 0]),
      );
    } else {
      transaction.insertNode(selection.end.path.next, tableNode.node);
      transaction.afterSelection = Selection.collapsed(
        Position(path: selection.end.path.next + <int>[0, 0]),
      );
    }

    unawaited(editorState.apply(transaction));
  },
);

/// 分隔线：同上（语义照抄官方 `dividerMenuItem`，图标换 Lucide）。
final SelectionMenuItem dividerSlashMenuItem = SelectionMenuItem(
  getName: () => AppFlowyEditorL10n.current.divider,
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: tabler.Minus(height: 24, width: 24, strokeWidth: 1.5),
    isSelected: isSelected,
    style: style,
  ),
  keywords: const <String>['horizontal rule', 'divider', '分隔线', '分割线'],
  handler: (editorState, _, _) {
    final Selection? selection = editorState.selection;
    if (selection == null || !selection.isCollapsed) {
      return;
    }
    final Path path = selection.end.path;
    final Node? node = editorState.getNodeAtPath(path);
    final Delta? delta = node?.delta;
    if (node == null || delta == null) {
      return;
    }

    // 空块就地放分隔线并其后再补一个空段落承接光标；非空块插到下一行。
    final Path insertedPath = delta.isEmpty ? path : path.next;
    final Transaction transaction = editorState.transaction
      ..insertNode(insertedPath, dividerNode())
      ..insertNode(insertedPath, paragraphNode())
      ..afterSelection = Selection.collapsed(Position(path: insertedPath.next));
    unawaited(editorState.apply(transaction));
  },
);

// ───────────────────── 官方条目的中文关键词 ─────────────────────

/// 官方条目只写死了**英文**关键词（`selection_menu_service.dart` 里是
/// `['text']`、`['bulleted list', 'list', 'unordered list']` 这种），
/// 中文用户打「待办」「引用」搜不到——条目名虽然是中文（走 l10n，见
/// `editor_l10n_test.dart`），但那是**精确匹配条目名**才生效，别名全靠这里。
///
/// 做法：应用侧给官方条目**追加**中文别名——`SelectionMenuItem.keywords` 是
/// 公开的普通 `List<String>`（`final` 的是引用、内容可增），所以**零补丁**；
/// 官方英文关键词原样保留 ⇒ 中英都能搜。
///
/// 匹配依据是官方那串英文关键词（稳定、与 locale 无关）。新增/改名的官方条目
/// 不会被静默漏掉：`slash_menu_items_test.dart` 有一条"官方条目个个都有中文
/// 关键词"的验收断言。
///
/// 注意：官方条目**分散在多个文件**（`selection_menu_service.dart` 12 条，
/// 另有 `tableMenuItem` / `dividerMenuItem` 定义在各自的块组件里），所以下面
/// 的函数作用在**最终条目表**上，不依赖任何单个官方常量。
const Map<String, List<String>> _kChineseSlashKeywords = <String, List<String>>{
  'text': <String>['正文', '文本', '段落'],
  'heading 1': <String>['标题 1', '一级标题'],
  'heading 2': <String>['标题 2', '二级标题'],
  'heading 3': <String>['标题 3', '三级标题'],
  'image': <String>['图片'],
  'bulleted list': <String>['无序列表', '项目符号'],
  'numbered list': <String>['有序列表', '编号列表'],
  'todo list': <String>['待办', '待办列表', '任务', '复选框'],
  'quote': <String>['引用'],
  'horizontal rule': <String>['分隔线', '分割线', '横线'],
  'table': <String>['表格'],
};

/// 给整张表补中文关键词。
///
/// **不改官方条目**：`SelectionMenuItem.keywords` 是**不可变列表**——实测直接
/// `add` 会抛 `Cannot add to an unmodifiable list`（第一版就是这么写的，被
/// `slash_menu_items_test.dart` 当场抓住）。所以这里**包一层委托条目**：
/// 只把 keywords 换成"官方关键词 + 中文别名"，其余（`getName` / `icon` /
/// `nameBuilder` / `handler`）**全部透传**，行为与官方完全一致。
///
/// 幂等：每次都从官方那份不可变列表重新拼，**不累积**——条目表每次开笔记都会
/// 重建一遍。
List<SelectionMenuItem> _withChineseKeywords(List<SelectionMenuItem> items) =>
    items.map(_withChineseKeywordsOf).toList();

SelectionMenuItem _withChineseKeywordsOf(SelectionMenuItem item) {
  // 已有中文别名的（我们自研那几条）原样返回——保持**同一实例**，
  // 外部按 `identical` 认条目（测试与视图都这么用）。
  if (item.keywords.any(_containsCjk)) return item;

  final List<String> extra = <String>[
    for (final MapEntry<String, List<String>> entry
        in _kChineseSlashKeywords.entries)
      // 官方把多个词塞进同一个元素（`'heading 1, h1'`）⇒ 用包含匹配。
      if (item.keywords.any((String keyword) => keyword.contains(entry.key)))
        ...entry.value,
  ];
  if (extra.isEmpty) return item;

  return SelectionMenuItem(
    getName: () => item.name, // 仍走官方 l10n（locale 变了名字跟着变）
    icon: item.icon,
    // Set 去重（插入序保留）：官方词在前，中文别名在后。
    keywords: <String>{...item.keywords, ...extra}.toList(),
    handler: item.handler,
    nameBuilder: item.nameBuilder,
    // ⚠️ 官方构造器已经把"删斜杠 / 删关键词"包进它自己的 handler 了，这里
    // **不能再开**——否则同一次插入会删两次，可能多删掉一个字符。
    deleteSlash: false,
  );
}

/// 是否含汉字（判断"这个条目已经有中文别名了"）。
bool _containsCjk(String value) => RegExp(r'[\u4e00-\u9fa5]').hasMatch(value);

/// 代码块（官方 6.2.0 没有这个块，见 `custom_block_components.dart`）。
///
/// 这条**完全走官方工厂** `SelectionMenuItem.node`：插入位置语义（默认插到
/// 当前块之后、`replace` 为真时原地替换并删掉原块）与光标收尾都由官方实现，
/// 我们只回答三个问题：造什么节点、要不要替换、光标放哪。
final SelectionMenuItem codeSlashMenuItem = SelectionMenuItem.node(
  getName: () => '代码块',
  iconData: tabler.Terminal(height: 24, width: 24, strokeWidth: 1.5),
  keywords: const <String>['code', 'code block', '代码', '代码块'],
  nodeBuilder: (editorState, context) => codeBlockNode(delta: Delta()),
  // 空块 → 原地替换（与官方 tableMenuItem 同一判据），不留多余空段落。
  replace: (editorState, node) => node.delta?.isEmpty ?? false,
  // 代码块是文本块：光标进块内，接着就能敲代码。
  updateSelection: (editorState, insertPath, replaced, insertedBefore) =>
      Selection.collapsed(Position(path: insertPath)),
);

/// 公式（块类型 `formula`，属性 `latex`）。
final SelectionMenuItem formulaSlashMenuItem = SelectionMenuItem(
  getName: () => '公式',
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: tabler.Function(height: 24, width: 24, strokeWidth: 1.5),
    isSelected: isSelected,
    style: style,
  ),
  keywords: const <String>['formula', 'latex', 'math', '公式'],
  handler: (editorState, _, BuildContext context) async {
    // 落点必须在弹对话框**之前**取好（见 _InsertionPoint 的说明）。
    final _InsertionPoint? point = _InsertionPoint.capture(editorState);
    if (point == null) return;
    final String? latex = await showFormulaDialog(context);
    if (latex == null || latex.isEmpty) return;
    await _insertBlockAt(
      editorState,
      point,
      node: formulaBlockNode(latex: latex),
      canHoldCursor: false,
    );
  },
);

/// 附件（块类型 `attachment`，属性 `meta` = 元数据 JSON）。
final SelectionMenuItem attachmentSlashMenuItem = SelectionMenuItem(
  getName: () => '附件',
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: tabler.Paperclip(height: 24, width: 24, strokeWidth: 1.5),
    isSelected: isSelected,
    style: style,
  ),
  keywords: const <String>['attachment', 'file', '附件', '文件'],
  handler: (editorState, _, _) async {
    final _InsertionPoint? point = _InsertionPoint.capture(editorState);
    if (point == null) return;
    final AttachmentMeta? meta = await NoteMediaService.pickAndStoreAttachment();
    if (meta == null) return;
    await _insertBlockAt(
      editorState,
      point,
      node: attachmentBlockNode(metaJson: jsonEncode(meta.toJson())),
      canHoldCursor: false,
    );
  },
);

/// 引用笔记（块类型 `ref`，属性 `ref_type='note'` / `ref_id`）。
///
/// 双链在文档侧的**创建入口**：引用存 id 而不是标题，于是"谁引用了我"（反链）
/// 只是一条 SQL，改名也不会断链（见 `RefBlockKeys` 与 `NoteStore.backlinks`）。
final SelectionMenuItem refSlashMenuItem = SelectionMenuItem(
  getName: () => '引用笔记',
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: tabler.Link(height: 24, width: 24, strokeWidth: 1.5),
    isSelected: isSelected,
    style: style,
  ),
  keywords: const <String>[
    'ref',
    'reference',
    'link',
    'backlink',
    '引用',
    '引用笔记',
    '双链',
    '反链',
    '链接',
  ],
  handler: (editorState, _, BuildContext context) async {
    // 落点必须在弹对话框**之前**取好（见 _InsertionPoint 的说明）。
    final _InsertionPoint? point = _InsertionPoint.capture(editorState);
    if (point == null) return;
    final String? noteId = await pickNoteToReference(context);
    if (noteId == null) return;
    await _insertBlockAt(
      editorState,
      point,
      node: refBlockNode(
        refType: RefBlockKeys.refNote,
        refId: noteId,
      ),
      canHoldCursor: false,
    );
  },
);

/// 引用块（块类型 `ref`，属性 `ref_type='block'` / `ref_id` = 目标块 id）。
///
/// 与上面的「引用笔记」同源（都是 `ref` 块），只差 `ref_type`：
/// - `ref_type='note'` ⇒ 指向整篇笔记；
/// - `ref_type='block'` ⇒ 指向**某一块**（块级双链）。
///
/// 反链查询、渲染、跳转三处**早已支持** `ref_type='block'`（见
/// `NoteStore.backlinks` / `ref_block_component.dart` 的 `_labelOf` /
/// `note_editor_view` 的 bridge），本项补的只是**创建入口**——此前
/// `refBlockNode` 只在引用笔记处被调用，块级引用因此"数据层全有、用户摸不到"。
final SelectionMenuItem refBlockSlashMenuItem = SelectionMenuItem(
  getName: () => '引用块',
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    // 与「引用笔记」的 link 图标区分：这里强调的是"引用一段正文"。
    icon: tabler.FileText(height: 24, width: 24, strokeWidth: 1.5),
    isSelected: isSelected,
    style: style,
  ),
  keywords: const <String>[
    'block',
    'blockref',
    '引用块',
    '块引用',
    '块',
    '段落',
  ],
  handler: (editorState, _, BuildContext context) async {
    // 落点必须在弹对话框**之前**取好（见 _InsertionPoint 的说明）。
    final _InsertionPoint? point = _InsertionPoint.capture(editorState);
    if (point == null) return;
    final String? blockId = await pickBlockToReference(context);
    if (blockId == null) return;
    await _insertBlockAt(
      editorState,
      point,
      node: refBlockNode(
        refType: RefBlockKeys.refBlock,
        refId: blockId,
      ),
      canHoldCursor: false,
    );
  },
);

/// 嵌入块：`ref` 块 + `ref_view='embed'` ⇒ **就地展开**那一块的内容。
///
/// 与「引用块」只差 `ref_view`：引用是一行卡片（显示标题），嵌入是把内容摊开
/// 在这里（Obsidian 的 `![[…]]` / Notion 的"显示为 embed"）。两者共用同一块
/// 类型 ⇒ 反链、渲染、跳转一条链都不用改。
final SelectionMenuItem embedBlockSlashMenuItem = SelectionMenuItem(
  getName: () => '嵌入块',
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: tabler.Quote(height: 24, width: 24, strokeWidth: 1.5),
    isSelected: isSelected,
    style: style,
  ),
  keywords: const <String>[
    'embed',
    '嵌入块',
    '块嵌入',
    '展开块',
  ],
  handler: (editorState, _, BuildContext context) async {
    final _InsertionPoint? point = _InsertionPoint.capture(editorState);
    if (point == null) return;
    final String? blockId = await pickBlockToReference(context);
    if (blockId == null) return;
    await _insertBlockAt(
      editorState,
      point,
      node: refBlockNode(
        refType: RefBlockKeys.refBlock,
        refId: blockId,
        refView: RefBlockKeys.viewEmbed,
      ),
      canHoldCursor: false,
    );
  },
);

/// 嵌入笔记：就地展开那篇笔记的**开头一段**（只读，限 30 块）。
///
/// 整篇嵌入不做递归展开：预览只取有文本的块，而 `ref` 块没有文本 ⇒ 即便
/// "A 嵌 B、B 又嵌 A" 也不会无限展开（见 `NoteStore.embedPreview`）。
final SelectionMenuItem embedNoteSlashMenuItem = SelectionMenuItem(
  getName: () => '嵌入笔记',
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: tabler.Quote(height: 24, width: 24, strokeWidth: 1.5),
    isSelected: isSelected,
    style: style,
  ),
  keywords: const <String>[
    'embed',
    '嵌入笔记',
    '笔记嵌入',
    '展开笔记',
  ],
  handler: (editorState, _, BuildContext context) async {
    final _InsertionPoint? point = _InsertionPoint.capture(editorState);
    if (point == null) return;
    final String? noteId = await pickNoteToReference(context);
    if (noteId == null) return;
    await _insertBlockAt(
      editorState,
      point,
      node: refBlockNode(
        refType: RefBlockKeys.refNote,
        refId: noteId,
        refView: RefBlockKeys.viewEmbed,
      ),
      canHoldCursor: false,
    );
  },
);

// ───────────────────────── 插入骨架 ─────────────────────────

/// 插入落点：在**弹任何浮层之前**取好它。
///
/// 原因很硬：公式对话框/文件选择器会让编辑器失焦，而 appflowy 的键盘服务
/// 在失焦时会把 `editorState.selection` 置 null（`keyboard_service_widget.dart`）
/// ——等浮层关掉再读选区就晚了，插不进去。
class _InsertionPoint {
  const _InsertionPoint({
    required this.path,
    required this.current,
    required this.replaceCurrent,
  });

  /// 光标所在块的路径。
  final Path path;

  /// 光标所在块（替换时要用它做删除）。
  final Node current;

  /// 该块是否为空块（空块就地替换，不留多余空段落）。
  final bool replaceCurrent;

  static _InsertionPoint? capture(EditorState editorState) {
    final Selection? selection = editorState.selection;
    if (selection == null || !selection.isCollapsed) return null;
    final Node? current = editorState.getNodeAtPath(selection.end.path);
    if (current == null) return null;
    return _InsertionPoint(
      path: selection.end.path,
      current: current,
      replaceCurrent: current.delta?.isEmpty ?? false,
    );
  }
}

/// 在光标处落一个块。语义与官方 `SelectionMenuItem.node` 工厂**一致**
/// （空块就地替换并删掉旧块、非空插到下一行，见官方 `tableMenuItem`），
/// 之所以没直接用那个工厂：它的 `nodeBuilder` 是**同步**的，而公式要弹
/// LaTeX 对话框、附件要开文件选择器——本次插入的节点得等异步结果才知道。
///
/// 收尾分两种：
/// - [canHoldCursor]（文本块，如代码块）：光标进新块；
/// - 否则（非文本块，如公式/附件）：块后补一个空段落承接光标，否则光标无处可去。
Future<void> _insertBlockAt(
  EditorState editorState,
  _InsertionPoint? point, {
  required Node node,
  required bool canHoldCursor,
}) async {
  if (point == null) return;
  final Path blockPath = point.replaceCurrent ? point.path : point.path.next;

  final Transaction transaction = editorState.transaction
    ..insertNode(blockPath, node);
  if (point.replaceCurrent) {
    transaction.deleteNode(point.current);
  }

  if (canHoldCursor) {
    transaction.afterSelection = Selection.collapsed(
      Position(path: blockPath),
    );
  } else {
    final Path after = blockPath.next;
    transaction
      ..insertNode(after, paragraphNode())
      ..afterSelection = Selection.collapsed(Position(path: after));
  }

  // 走官方事务 → 可撤销（与官方条目一致）。
  await editorState.apply(transaction);
}
