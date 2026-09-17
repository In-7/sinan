import 'dart:math';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

class FloatingToolbarStyle {
  const FloatingToolbarStyle({
    this.backgroundColor = Colors.black,
    this.toolbarActiveColor = Colors.lightBlue,
    this.toolbarIconColor = Colors.white,
    this.toolbarShadowColor,
    this.toolbarElevation = 0,
  });

  final Color backgroundColor;
  final Color toolbarActiveColor;
  final Color toolbarIconColor;
  final Color? toolbarShadowColor;
  final double toolbarElevation;
}

typedef FloatingToolbarBuilder = Widget Function(
  BuildContext context,
  Widget child,
  VoidCallback onDismiss,
  bool isMetricsChanged,
);

/// A floating toolbar that displays at the top of the editor when the selection
///   and will be hidden when the selection is collapsed.
///
class FloatingToolbar extends StatefulWidget {
  const FloatingToolbar({
    super.key,
    required this.items,
    required this.editorState,
    required this.editorScrollController,
    required this.textDirection,
    required this.child,
    this.style = const FloatingToolbarStyle(),
    this.tooltipBuilder,
    this.floatingToolbarHeight = 32,
    this.padding,
    this.decoration,
    this.placeHolderBuilder,
    this.toolbarBuilder,
  });

  final List<ToolbarItem> items;
  final EditorState editorState;
  final EditorScrollController editorScrollController;
  final TextDirection? textDirection;
  final Widget child;
  final FloatingToolbarStyle style;
  final ToolbarTooltipBuilder? tooltipBuilder;
  final double floatingToolbarHeight;
  final EdgeInsets? padding;
  final Decoration? decoration;
  final PlaceHolderItemBuilder? placeHolderBuilder;
  final FloatingToolbarBuilder? toolbarBuilder;

  @override
  State<FloatingToolbar> createState() => _FloatingToolbarState();
}

class _FloatingToolbarState extends State<FloatingToolbar>
    with WidgetsBindingObserver {
  OverlayEntry? _toolbarContainer;
  FloatingToolbarWidget? _toolbarWidget;

  EditorState get editorState => widget.editorState;

  double get floatingToolbarHeight => widget.floatingToolbarHeight;

  late Brightness brightness = Theme.of(context).brightness;

  bool hasMetricsChanged = false;
  Selection? lastSelection;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    editorState.selectionNotifier.addListener(_onSelectionChanged);
    lastSelection = editorState.selection;
    widget.editorScrollController.offsetNotifier.addListener(
      _onScrollPositionChanged,
    );
  }

  @override
  void didUpdateWidget(FloatingToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.editorState != oldWidget.editorState) {
      editorState.selectionNotifier.addListener(_onSelectionChanged);
    }
  }

  @override
  void dispose() {
    editorState.selectionNotifier.removeListener(_onSelectionChanged);
    widget.editorScrollController.offsetNotifier.removeListener(
      _onScrollPositionChanged,
    );
    WidgetsBinding.instance.removeObserver(this);

    _clear();
    _toolbarWidget = null;

    super.dispose();
  }

  @override
  void reassemble() {
    super.reassemble();

    _clear();
    _toolbarWidget = null;
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    hasMetricsChanged = true;
    _showAfterDelay(isMetricsChanged: true);
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  void _onSelectionChanged() {
    final selection = editorState.selection;
    final selectionType = editorState.selectionType;

    final disableToolbar =
        editorState.selectionExtraInfo?[selectionExtraInfoDisableToolbar] ==
            true;

    if (disableToolbar) {
      _clear();
    }

    if (lastSelection == selection) return;
    lastSelection = selection;

    if (selection == null ||
        selection.isCollapsed ||
        selectionType == SelectionType.block) {
      _clear();
    } else if (!disableToolbar) {
      // uses debounce to avoid the computing the rects too frequently.
      _showAfterDelay(
        duration: const Duration(milliseconds: 200),
        isMetricsChanged: hasMetricsChanged,
      );
      if (hasMetricsChanged) hasMetricsChanged = false;
    }
  }

  void _onScrollPositionChanged() {
    _clear();

    // TODO: optimize the toolbar showing logic, making it more smooth.
    // A quick idea: based on the scroll controller's offset to display the toolbar.
    _showAfterDelay();
  }

  final String _debounceKey = 'show the toolbar';

  void _clear() {
    Debounce.cancel(_debounceKey);

    _toolbarContainer?.remove();
    _toolbarContainer = null;
  }

  void _showAfterDelay({
    Duration duration = Duration.zero,
    bool isMetricsChanged = false,
  }) {
    // uses debounce to avoid the computing the rects too frequently.
    Debounce.debounce(
      _debounceKey,
      duration,
      () {
        _clear(); // clear the previous toolbar.
        _showToolbar(isMetricsChanged);
      },
    );
  }

  void _showToolbar(bool isMetricsChanged) {
    final selection = editorState.selection;
    if (selection == null || selection.isCollapsed) {
      return;
    }

    if (editorState.selectionExtraInfo?[selectionExtraInfoDisableToolbar] ==
        true) {
      return;
    }

    if (!editorState.editable) {
      return;
    }

    // check the content is visible
    final nodes = editorState.getSelectedNodes();
    if (nodes.isEmpty ||
        nodes.every((node) {
          final delta = node.delta;
          return delta == null || delta.isEmpty;
        })) {
      return;
    }

    final rects = editorState.selectionRects();
    if (rects.isEmpty) {
      return;
    }

    final rect = _findSuitableRect(rects);
    final (left, top, right) = calculateToolbarOffset(rect);
    // if the selection is not visible, then don't show the toolbar.
    if ((top <= floatingToolbarHeight || (left == 0 && right == 0)) &&
        widget.toolbarBuilder != null) {
      return;
    }
    _toolbarContainer = OverlayEntry(
      builder: (context) {
        final child = _buildToolbar(context);
        return widget.toolbarBuilder
                ?.call(context, child, _clear, isMetricsChanged) ??
            Positioned(
              top: _toolbarTop(rect),
              left: left,
              right: right,
              child: child,
            );
      },
    );
    Overlay.of(context, rootOverlay: true).insert(_toolbarContainer!);
  }

  Widget _buildToolbar(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    bool needRefreshToolbar = brightness != this.brightness;
    if (needRefreshToolbar) {
      this.brightness = brightness;
    }
    if (needRefreshToolbar || _toolbarWidget == null) {
      _toolbarWidget = FloatingToolbarWidget(
        items: widget.items,
        editorState: editorState,
        backgroundColor: widget.style.backgroundColor,
        toolbarActiveColor: widget.style.toolbarActiveColor,
        toolbarIconColor: widget.style.toolbarIconColor,
        toolbarElevation: widget.style.toolbarElevation,
        toolbarShadowColor: widget.style.toolbarShadowColor,
        textDirection: widget.textDirection ?? Directionality.of(context),
        tooltipBuilder: widget.tooltipBuilder,
        floatingToolbarHeight: floatingToolbarHeight,
        padding: widget.padding,
        decoration: widget.decoration,
        placeHolderBuilder: widget.placeHolderBuilder,
      );
    }
    return _toolbarWidget!;
  }

  Rect _findSuitableRect(Iterable<Rect> rects) {
    assert(rects.isNotEmpty);

    final editorOffset =
        editorState.renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;

    // find the min offset with non-negative dy.
    final rectsWithNonNegativeDy = rects.where(
      (element) => element.top >= editorOffset.dy,
    );
    if (rectsWithNonNegativeDy.isEmpty) {
      // if all the rects offset is negative, then the selection is not visible.
      return Rect.zero;
    }

    final minRect = rectsWithNonNegativeDy.reduce((min, current) {
      if (min.top < current.top) {
        return min;
      } else if (min.top == current.top) {
        return min.top < current.top ? min : current;
      } else {
        return current;
      }
    });

    return minRect;
  }

  (double? left, double top, double? right) calculateToolbarOffset(Rect rect) {
    final editorOffset =
        editorState.renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
    final editorSize = editorState.renderBox?.size ?? Size.zero;
    final editorRect = editorOffset & editorSize;
    final left = (rect.left - editorOffset.dx).abs();
    final right = (rect.right - editorOffset.dx).abs();
    final width = editorSize.width;
    final threshold = width / 3.0;
    final top = rect.top < floatingToolbarHeight
        ? rect.bottom + floatingToolbarHeight
        : rect.top;
    if (left <= threshold) {
      // show in left
      return (rect.left, top, null);
    } else if (left >= threshold && right <= threshold * 2.0) {
      // show in center
      return (editorRect.left + threshold, top, null);
    } else {
      // show in right
      return (null, top, editorRect.right - rect.right);
    }
  }

  /// [sinan 补丁 13]（2026-09-15）：浮条落位的纵向坐标——**与选区留
  /// [_toolbarGap] 间隔**。
  ///
  /// 官方口径（`Positioned(top: max(0, top) - floatingToolbarHeight)`）是让浮条
  /// **紧贴**选区：上方落位时条的下缘正好等于选区上缘，贴顶改下方落位时条的
  /// 顶缘正好等于选区下缘。实机观感是"条和选区粘在一起"（用户反馈），故上下
  /// 各让出 [_toolbarGap]（2px），并把结果钳在非负（浮条不能跑出屏幕上方）。
  ///
  /// 落位方向沿用 [calculateToolbarOffset] 的判据（`rect.top <
  /// floatingToolbarHeight` ⇒ 上方放不下 ⇒ 改放选区下方），但这里**直接用
  /// `rect` 算**而不复用它的返回值：那个 `top` 在"下方落位"分支里已经加过
  /// `floatingToolbarHeight`，再减回去容易错符号。
  double _toolbarTop(Rect rect) {
    final double top = rect.top < floatingToolbarHeight
        ? rect.bottom + _toolbarGap
        : rect.top - floatingToolbarHeight - _toolbarGap;
    return max(0, top);
  }

  /// [sinan 补丁 13]：浮条与选区的间隔（屏幕像素）。
  ///
  /// 8 是"现代应用那档"：先取 2 试过（用户实机反馈**变化不大**），
  /// 对照新版官方/主流笔记应用的浮条（截图里间隔 ≈ 正文行高的 1/3）定为 8。
  /// 这个值只跟"手感"有关，不牵动任何布局契约（浮条是 overlay，不占正文）。
  static const double _toolbarGap = 8;
}
