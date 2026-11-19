import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../../theme/tokens.dart';
import '../toolbar/heading_toolbar_item.dart';
import 'callout_block_component.dart';
import 'code_block_component.dart';
import 'toggle_block_component.dart';

/// 块操作菜单的内容（**照官方 `block_action_option_cubit` 的结构**，2026-09-15）：
/// **转为** ▸ / **复制** / **删除**。
///
/// 由块手柄的 ⠿ 点击打开（`custom_block_components.dart` 的 `_buildDragHandle`）；
/// 官方那份菜单还带"颜色"子菜单（`blockActionOptionButton` 里是文字色 + 背景色
/// 两块）——我们已有独立的颜色面板（`color_toolbar_item.dart`，浮动栏用），
/// 这里先不重复一份，等真要区块级配色时再抽公共面板。
///
/// 所有操作都作用于**整块**：`selection` 由手柄点击时设成块选区（`SelectionType.block`），
/// 与本函数里的 [node] 指向同一块。
///
/// [onReferenceOnCanvas] 是块可迁移 #5「双链多视图」的入口（把这块引用到画布上）：
/// 它要读 provider、弹选择框，故由调用方（块手柄）提供；为 null 时不出现这一项。
List<Widget> sinanBlockActionMenuItems({
  required EditorState editorState,
  required Node node,
  required VoidCallback onClose,
  VoidCallback? onReferenceOnCanvas,
}) {
  // 手柄点击已把选区切成本块 ⇒ 这里以块的起点为准（不依赖调用顺序）。
  final Selection selection = Selection.collapsed(Position(path: node.path));

  /// 一条菜单项。[isCurrent] 为真时左侧勾选（标记当前块类型，2026-11-19 借鉴
  /// Notion / 官方——让用户知道"我这是什么块"，避免无意义重复转换）。
  Widget action({
    required String label,
    required VoidCallback onPressed,
    bool isCurrent = false,
  }) => MenuItemButton(
    leadingIcon: SizedBox(
      width: Tokens.iconXs,
      height: Tokens.iconXs,
      child: isCurrent
          ? const tabler.Check(
              height: Tokens.iconXs,
              width: Tokens.iconXs,
              strokeWidth: 1.5,
            )
          : null,
    ),
    onPressed: onPressed,
    child: Text(label),
  );

  /// 换块类型：**白名单继承属性**（照 [applyBlockStyle] 口径，2026-11-19 修
  /// 脏属性 bug）——只带走背景色 / 文字方向 / 文本 delta，其余不继承。
  ///
  /// ⚠️ 原来用 `node.copyWith(type: X)` 会**保留全部旧属性**（`Node.copyWith`
  /// 的 `attributes ?? {...this.attributes}`）⇒ 标题转列表留 `level`、待办转
  /// 引用留 `checked`，脏属性跟着落库、导出 markdown 时异常；且与正文/标题那条
  /// 路径（[applyBlockStyle] 摘 `level`）口径不一致。这里改成同一白名单。
  /// [extra] 是新类型**必需**的属性（如待办的 `checked`、折叠的 `collapsed`）。
  Widget typeItem(
    String label,
    String type, {
    Attributes extra = const {},
    bool isCurrent = false,
  }) => action(
    label: label,
    isCurrent: isCurrent,
    onPressed: () {
      unawaited(
        editorState.formatNode(
          selection,
          (Node node) => node.copyWith(
            type: type,
            attributes: <String, dynamic>{
              ...extra,
              blockComponentBackgroundColor:
                  node.attributes[blockComponentBackgroundColor],
              blockComponentTextDirection:
                  node.attributes[blockComponentTextDirection],
              blockComponentDelta: (node.delta ?? Delta()).toJson(),
            },
          ),
        ),
      );
      onClose();
    },
  );

  /// 当前块是否已是该类型（勾选标记用）；标题按 [level] 细分。
  bool isCurrent(String type, {int? level}) {
    if (node.type != type) return false;
    if (type == HeadingBlockKeys.type) {
      final Object? lv = node.attributes[HeadingBlockKeys.level];
      return (lv is int ? lv : 1) == (level ?? 1);
    }
    return true;
  }

  return <Widget>[
    SubmenuButton(
      menuChildren: <Widget>[
        // ── 标题类 ── 正文 / 标题 1~3，走 `applyBlockStyle`（工具栏样式下拉的
        // 同一实现——它负责**摘掉 level** 这类脏属性）。⚠️ 不能塞进 `typeItem`：
        // 那会把 `applyBlockStyle` 放进 `formatNode` 的 transform 里执行 = 重入。
        for (final int? level in <int?>[null, 1, 2, 3])
          action(
            label: level == null ? '正文' : '标题 $level',
            isCurrent: isCurrent(
              level == null ? ParagraphBlockKeys.type : HeadingBlockKeys.type,
              level: level,
            ),
            onPressed: () {
              applyBlockStyle(editorState, selection, level: level);
              onClose();
            },
          ),
        const Divider(height: 1),
        // ── 列表类 ──
        typeItem(
          '无序列表',
          BulletedListBlockKeys.type,
          isCurrent: isCurrent(BulletedListBlockKeys.type),
        ),
        typeItem(
          '有序列表',
          NumberedListBlockKeys.type,
          isCurrent: isCurrent(NumberedListBlockKeys.type),
        ),
        typeItem(
          '待办列表',
          TodoListBlockKeys.type,
          extra: <String, dynamic>{TodoListBlockKeys.checked: false},
          isCurrent: isCurrent(TodoListBlockKeys.type),
        ),
        const Divider(height: 1),
        // ── 其他 ──
        typeItem(
          '引用',
          QuoteBlockKeys.type,
          isCurrent: isCurrent(QuoteBlockKeys.type),
        ),
        typeItem(
          '折叠块',
          ToggleListBlockKeys.type,
          extra: <String, dynamic>{ToggleListBlockKeys.collapsed: false},
          isCurrent: isCurrent(ToggleListBlockKeys.type),
        ),
        typeItem(
          '高亮块',
          CalloutBlockKeys.type,
          isCurrent: isCurrent(CalloutBlockKeys.type),
        ),
        // 代码块有整块级的特殊语义（行盒/占位/回车行为），走它自己的实现。
        action(
          label: '代码块',
          isCurrent: isCurrent(CodeBlockKeys.type),
          onPressed: () {
            toggleSinanCodeBlock(editorState);
            onClose();
          },
        ),
      ],
      child: const Text('转为'),
    ),
    const Divider(height: 1),
    action(
      label: '复制',
      onPressed: () {
        final Transaction transaction = editorState.transaction
          ..insertNode(node.path.next, node.deepCopy());
        unawaited(editorState.apply(transaction));
        onClose();
      },
    ),
    action(
      label: '删除',
      onPressed: () {
        final Transaction transaction = editorState.transaction
          ..deleteNode(node);
        unawaited(editorState.apply(transaction));
        onClose();
      },
    ),
    if (onReferenceOnCanvas != null) ...<Widget>[
      const Divider(height: 1),
      // 块可迁移 #5「双链多视图」：文档里这块**原地不动**，画布上多一张指向
      // 同一份内容的卡片（两边编辑同一份真身）。与"搬去画布"是两回事。
      action(
        label: '在画布上引用这张卡片',
        onPressed: () {
          onClose();
          onReferenceOnCanvas();
        },
      ),
    ],
  ];
}
