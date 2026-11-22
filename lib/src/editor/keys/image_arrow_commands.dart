import 'dart:ui' show Offset, Rect;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/rendering.dart' show RenderBox;
import 'package:flutter/widgets.dart' show KeyEventResult;

/// 键盘 ↓/↑ 遇到**图片块**时的两阶段放行（2026-11-22）。
///
/// ## 为什么要特判
/// 图片块整块只有 0/1 两个 position，`getCursorRectInPosition` 返回**整图矩形**；
/// AppFlowy 的 `moveVertical` 按 1px 逐行试探，caret ≈ 整图高 ⇒ 整段跳过、
/// `return this` 原地不动。于是"按 ↓ 到图片就停了、大图看不全"。
///
/// ## 两阶段策略
/// - 选区**已在图片块**且图片**未完整入视口** ⇒ 经 AppFlowy 官方滚动通道
///   `editorState.scrollService.scrollTo(dy ± 50)` 滚一档，返回 `handled` 消费
///   该键——连按即可把大图看完。步长 50px 取 Flutter 默认 `ScrollAction` 的
///   line 档口径（`scrollable_helpers.dart:_calculateScrollIncrement`），
///   边界由官方 scrollService 钳制，不自造滚动逻辑。
/// - 图片**已完整入视口** ⇒ 返回 `ignored`：交回官方 `moveCursorDownCommand`
///   跳到下一块，继续往下读。
/// - 选区不在图片块 ⇒ 一律 `ignored`，文本块内逐行移动手感完全不变。
///
/// ⚠️ 必须放在命令表**标准表之前**：`keyboard_service_widget` 是先命中先赢，
/// `handled` 会直接 return、跳过后面所有命令（含官方箭头键）。
/// 只接管"图片"这一种场景，其余零改动。
///
/// ⚠️ 试过两条"让 Flutter 原生接管"的路都不通，记下来免得再踩：
/// ① `skipRemainingHandlers` 不向上冒泡到 Shortcuts（实测 ↓ 不滚、PageDown 滚）；
/// ② `ScrollAction().invoke` 在此 context 下退回 PrimaryScrollController，
///    编辑器里多个 ScrollPosition ⇒ 断言"多于一个"直接抛。
///
/// 判"完整入视口"用全局矩形：图片 `node.rect`（renderBox 全局矩形）完全落在
/// 滚动服务 renderBox（`editorState.renderBox`）的全局矩形内。两者都在同一
/// 全局坐标系，不依赖 AppFlowy 的 caret 几何（那正是出问题的地方）。

/// 纯几何判据：[target] 是否完整落在 [viewport] 内（1px 容差）。
///
/// 抽成纯函数便于单测钉住"部分露出 = 未看全"这个关键分界。
bool rectFullyVisible(Rect viewport, Rect target) =>
    !target.isEmpty &&
    target.top >= viewport.top - 1 &&
    target.bottom <= viewport.bottom + 1;

/// 图片块是否**完整**落在编辑器视口内。
///
/// 未布局 / 取不到 renderBox ⇒ 返回 false（宁可先滚动，也不让光标卡住）。
bool imageFullyVisible(EditorState editorState, Node node) {
  final RenderBox? viewport = editorState.renderBox;
  final Rect imageRect = node.rect;
  if (viewport == null || imageRect.isEmpty) return false;
  final Rect viewportRect = viewport.localToGlobal(Offset.zero) & viewport.size;
  return rectFullyVisible(viewportRect, imageRect);
}

/// 当前选区所在的**顶层块**（沿 path 首段取，嵌套块也算在其顶层块里）。
Node? _topLevelNodeAtSelection(EditorState editorState) {
  final Selection? selection = editorState.selection;
  if (selection == null) return null;
  final List<int> path = selection.end.path;
  if (path.isEmpty) return null;
  final Node? node = editorState.getNodeAtPath(<int>[path.first]);
  return node;
}

/// ↓ 的图片两阶段命令。
final CommandShortcutEvent sinanImageArrowDownCommand = CommandShortcutEvent(
  key: 'sinan.image.arrow.down',
  getDescription: () => '图片未看完时向下滚动',
  command: 'arrow down',
  handler: (EditorState editorState) =>
      _imageArrowHandler(editorState, upwards: false),
);

/// ↑ 的图片两阶段命令（对称：向上滚完再跳上一块）。
final CommandShortcutEvent sinanImageArrowUpCommand = CommandShortcutEvent(
  key: 'sinan.image.arrow.up',
  getDescription: () => '图片未看完时向上滚动',
  command: 'arrow up',
  handler: (EditorState editorState) =>
      _imageArrowHandler(editorState, upwards: true),
);

KeyEventResult _imageArrowHandler(
  EditorState editorState, {
  required bool upwards,
}) {
  final Node? node = _topLevelNodeAtSelection(editorState);
  // 只接管"选区就在图片块上"这一种场景；其余交回官方命令。
  if (node == null || node.type != ImageBlockKeys.type) {
    return KeyEventResult.ignored;
  }
  // 图片还没看全 ⇒ **直接触发 Flutter 原生 ScrollAction** 滚一个 line 步长。
  //
  // ⚠️ 不能用 skipRemainingHandlers 指望事件冒泡到祖先 Shortcuts：Focus 系统
  // 对它的语义只是"跳过本节点剩余 handler"，并不会向上冒泡（实测 ↓ 不滚、
  // PageDown 却滚——后者走的正是祖先默认 ScrollIntent）。所以这里拿滚动服务
  // 的 context 显式调 ScrollAction，仍然复刻平台原生的 50px 步长与边界语义，
  // 不自写动画/像素数。
  if (!imageFullyVisible(editorState, node)) {
    // 走 AppFlowy 官方滚动通道（内部 EditorScrollController.animateTo + 边界
    // clamp），步长取 Flutter 默认 ScrollAction 的 line 档 50 逻辑像素
    // （`scrollable_helpers.dart:_calculateScrollIncrement`）——不自造步长。
    // 时长取 1ms（Flutter 的 animateTo 断言 duration > 0，不能传 zero）：
    // 足够短，连按时几乎立刻到位；每次基于最新 dy，前一次被打断也不丢累积量。
    editorState.scrollService?.scrollTo(
      editorState.scrollService!.dy + (upwards ? -50 : 50),
      duration: const Duration(milliseconds: 1),
    );
    // 已经消费这个键（滚动完成），不再交回官方 moveCursorDown（否则光标也走，
    // 图还没看全就跳走了）。
    return KeyEventResult.handled;
  }
  // 已看全 ⇒ 交回官方命令跳到相邻块。
  return KeyEventResult.ignored;
}
