import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

extension EditorStateSelection on EditorState {
  List<Node> getVisibleNodes(EditorScrollController controller) {
    final List<Node> sortedNodes = [];
    final positions = controller.visibleRangeNotifier.value;
    // https://github.com/AppFlowy-IO/AppFlowy/issues/3651
    final min = math.max(positions.$1 - 1, 0);
    final max = positions.$2;
    if (min < 0 || max < 0) {
      return sortedNodes;
    }

    int i = -1;
    for (final child in document.root.children) {
      i++;
      if (min > i) {
        continue;
      }
      if (i > max) {
        break;
      }
      sortedNodes.add(child);
    }
    return sortedNodes;
  }

  Node? getNodeInOffset(
    List<Node> sortedNodes,
    Offset offset,
    int start,
    int end, [
    Map<String, Rect>? rectCache,
  ]) {
    // Create rect cache for this operation if not provided
    rectCache ??= {};

    if (start < 0 && end >= sortedNodes.length) {
      return null;
    }

    var min = _findCloseNode(
      sortedNodes,
      start,
      end,
      rectCache: rectCache,
      match: (index, rect) {
        final isMatch = rect.contains(offset);
        AppFlowyEditorLog.selection.debug(
          'findNodeInOffset: $index, rect: $rect, offset: $offset, isMatch: $isMatch',
        );
        return isMatch;
      },
      compare: (index, rect) => rect.bottom <= offset.dy,
    );

    final rowBottom = _getCachedRect(sortedNodes[min], rectCache).bottom;
    final filteredNodes = <Node>[];
    for (final node in sortedNodes) {
      if (_getCachedRect(node, rectCache).bottom == rowBottom) {
        filteredNodes.add(node);
      }
    }
    min = 0;
    if (filteredNodes.length > 1) {
      min = _findCloseNode(
        filteredNodes,
        0,
        filteredNodes.length - 1,
        rectCache: rectCache,
        match: (index, rect) {
          final isMatch = rect.contains(offset);
          AppFlowyEditorLog.selection.debug(
            'findNodeInOffset: $index, rect: $rect, offset: $offset, isMatch: $isMatch',
          );
          return isMatch;
        },
        compare: (index, rect) => rect.right <= offset.dx,
      );
    }

    final node = filteredNodes[min];
    // [sinan 补丁 22] 带 children 的块，其子节点被 virtualization 卸载时 rect 为
    // Rect.zero。原判定 `child.rect.top <= offset.dy` 对 zero 恒真（0 <= 186）⇒
    // 递归进 children 后用 zero rect 二分，点击被路由到**别的块**——用户实报
    // 「带子节点的 heading 点不中、选不上、编辑/删除全失效」（2026-11-22）。
    // 子节点的 renderBox 不存在（rect 为空）时，点击应落在父节点自己。
    final bool firstChildLaidOut = node.children.isNotEmpty &&
        !_getCachedRect(node.children.first, rectCache).isEmpty;
    if (node.children.isNotEmpty &&
        firstChildLaidOut &&
        _getCachedRect(node.children.first, rectCache).top <= offset.dy) {
      final skipSortingChildren =
          node.selectable?.skipSortingChildrenWhenSelecting ?? false;

      List<Node> children;

      if (skipSortingChildren) {
        children = node.children;
      } else {
        children = node.children.toList(growable: false)
          ..sort(
            (a, b) {
              final aRect = _getCachedRect(a, rectCache!);
              final bRect = _getCachedRect(b, rectCache);
              return aRect.bottom != bRect.bottom
                  ? aRect.bottom.compareTo(bRect.bottom)
                  : aRect.left.compareTo(bRect.left);
            },
          );
      }

      // if the nodes are in the same tab view, their rect are overlaid,
      //  we need to filter out the invisible nodes
      bool hasInvisibleChildren = false;
      final visibleChildren = <Node>[];
      for (final child in children) {
        final context = child.key.currentContext;
        var isVisible = true;
        context?.visitAncestorElements((element) {
          final widget = element.widget;
          if (widget is Opacity && widget.opacity == 0) {
            isVisible = false;
            return false;
          }
          return true;
        });
        if (isVisible) {
          visibleChildren.add(child);
        } else {
          hasInvisibleChildren = true;
        }
      }
      if (hasInvisibleChildren) {
        children = visibleChildren;
      }

      // [sinan 补丁 22] 同上：即便首个子节点已布局，也可能有部分子节点被
      // virtualization 卸载（zero rect）。把它们从候选里剔掉，否则二分时
      // zero rect 会把点击吸走。真的一个都没布局 ⇒ 落回父节点。
      final List<Node> laidOutChildren = children
          .where((Node c) => !_getCachedRect(c, rectCache!).isEmpty)
          .toList(growable: false);
      if (laidOutChildren.length != children.length) {
        children = laidOutChildren;
      }

      if (children.isEmpty) {
        return node;
      }

      return getNodeInOffset(
        children,
        offset,
        0,
        children.length - 1,
        rectCache,
      );
    }
    return node;
  }

  /// Get cached rect for a node, computing and caching if not present
  Rect _getCachedRect(Node node, Map<String, Rect> cache) {
    return cache.putIfAbsent(node.id, () => node.rect);
  }

  int _findCloseNode(
    List<Node> sortedNodes,
    int start,
    int end, {
    required Map<String, Rect> rectCache,
    bool Function(int index, Rect rect)? match,
    required bool Function(int index, Rect rect) compare,
  }) {
    for (var i = start; i <= end; i++) {
      final rect = _getCachedRect(sortedNodes[i], rectCache);
      if (match != null && match(i, rect)) {
        return i;
      }
    }

    var min = start;
    var max = end;
    while (min <= max) {
      final mid = min + ((max - min) >> 1);
      final rect = _getCachedRect(sortedNodes[mid], rectCache);
      if (compare(mid, rect)) {
        min = mid + 1;
      } else {
        max = mid - 1;
      }
    }

    return min.clamp(start, end);
  }
}
