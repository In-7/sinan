import 'package:appflowy_editor/src/editor/editor_component/service/scroll/auto_scroller.dart';
import 'package:flutter/material.dart';

/// [AppFlowyScrollService] is responsible for processing document scrolling.
///
/// Usually, this service can be obtained by the following code.
/// ```dart
/// final keyboardService = editorState.service.scrollService;
/// ```
///
abstract class AppFlowyScrollService implements AutoScrollerService {
  /// Returns the offset of the current document on the vertical axis.
  double get dy;

  /// Returns the height of the current document.
  double? get onePageHeight;

  /// Returns the number of pages in the current document.
  int? get page;

  /// Returns the maximum scroll height on the vertical axis.
  double get maxScrollExtent;

  /// Returns the minimum scroll height on the vertical axis.
  double get minScrollExtent;

  /// scroll controller
  ScrollController get scrollController;

  /// Scrolls to the specified position.
  ///
  /// This function will filter illegal values.
  /// Only within the range of minScrollExtent and maxScrollExtent are legal values.
  void scrollTo(
    double dy, {
    Duration duration,
  });

  /// 滚到第 [index] 个块。
  ///
  /// **[sinan 补丁]** [alignment]（0 = 置顶，1 = 置底）：查找跳转传 0.35
  /// 让命中落在视野上 1/3（留点上文、命中醒目）。为 null 时保持原语义
  /// （已在可见范围就不滚，避免无谓抖动）。
  void jumpTo(
    int index, {
    double? alignment,
  });

  void jumpToTop();
  void jumpToBottom();

  void goBallistic(double velocity);

  /// Enables scroll service.
  void enable();

  /// Disables scroll service.
  ///
  /// In some cases, you can disable scroll service of flowy_editor
  ///  when your custom component appears,
  ///
  /// But you need to call the `enable` function to restore after exiting
  ///   your custom component, otherwise the scroll service will fails.
  void disable();
}
