import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

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

  Widget action({
    required String label,
    required VoidCallback onPressed,
  }) =>
      MenuItemButton(onPressed: onPressed, child: Text(label));

  /// 换块类型：一律走官方 `formatNode`（只改 `type` 与该类型必需的属性）。
  Widget typeItem(String label, Node Function(Node node) transform) =>
      action(
        label: label,
        onPressed: () {
          unawaited(editorState.formatNode(selection, transform));
          onClose();
        },
      );

  return <Widget>[
    SubmenuButton(
      menuChildren: <Widget>[
        // 正文 / 标题：走 `applyBlockStyle`（工具栏样式下拉的同一实现——它负责
        // **摘掉 level** 这类脏属性，不让正文留着 `level` 键）。
        // ⚠️ 它们**不能**塞进 `typeItem`：那会把 `applyBlockStyle` 放进
        // `formatNode` 的 transform 里执行（transform 里做事务 = 重入）。
        for (final int? level in <int?>[null, 1, 2, 3])
          action(
            label: level == null ? '正文' : '标题 $level',
            onPressed: () {
              applyBlockStyle(editorState, selection, level: level);
              onClose();
            },
          ),
        typeItem('无序列表', (Node n) => n.copyWith(
              type: BulletedListBlockKeys.type,
            )),
        typeItem('有序列表', (Node n) => n.copyWith(
              type: NumberedListBlockKeys.type,
            )),
        typeItem('待办列表', (Node n) => n.copyWith(
              type: TodoListBlockKeys.type,
              attributes: <String, dynamic>{
                ...n.attributes,
                TodoListBlockKeys.checked: false,
              },
            )),
        typeItem('引用', (Node n) => n.copyWith(
              type: QuoteBlockKeys.type,
            )),
        typeItem('折叠块', (Node n) => n.copyWith(
              type: ToggleListBlockKeys.type,
              attributes: <String, dynamic>{
                ...n.attributes,
                ToggleListBlockKeys.collapsed: false,
              },
            )),
        typeItem('高亮块', (Node n) => n.copyWith(
              type: CalloutBlockKeys.type,
            )),
        // 代码块有整块级的特殊语义（行盒/占位/回车行为），走它自己的实现。
        action(
          label: '代码块',
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
