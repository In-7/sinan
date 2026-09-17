import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:appflowy_editor/src/editor/find_replace_menu/find_replace_widget.dart';
import 'package:flutter/material.dart';

abstract class FindReplaceService {
  void show();
  void dismiss();
}

OverlayEntry? _findReplaceMenuEntry;

class FindReplaceMenu implements FindReplaceService {
  FindReplaceMenu({
    required this.context,
    required this.editorState,
    required this.showReplaceMenu,
    this.localizations,
    required this.style,
    this.showRegexButton = true,
    this.showCaseSensitiveButton = true,
    this.topOffset = 52,
    this.rightOffset = 40,
  });

  final BuildContext context;
  final EditorState editorState;
  final bool showReplaceMenu;
  final FindReplaceLocalizations? localizations;
  final FindReplaceStyle style;
  final bool showRegexButton;
  final bool showCaseSensitiveButton;

  /// 面板相对 root overlay 的偏移。默认值取自官方 demo 布局（顶部一条
  /// 52px 的工具栏）——宿主有自定义标题区时应传入**实测**的标题区下沿
  /// （见 sinan 视图 `_showFind`：用标题行 GlobalKey 实测底部 + 间距），
  /// 否则面板会压住宿主的标题。
  final double topOffset;
  final double rightOffset;

  bool _selectionUpdateByInner = false;

  // sinan 补丁 8：面板打开期间压住"编辑器抢焦点"——官方在提交/导航后用
  // 延迟 requestFocus 把焦点抢回查找框，与 IME 组合输入竞态，候选窗会
  // 偶发消失。改为打开即 increase、关闭即 decrease（计数归零时编辑器
  // 自然拿回焦点），查找框焦点全程稳定。`_keepFocusApplied` 防重复
  // （dismiss 可能被关闭按钮 / 选区变化 / onDispose 多路触发）。
  bool _keepFocusApplied = false;

  @override
  void dismiss() {
    if (_findReplaceMenuEntry != null) {
      editorState.service.keyboardService?.enable();
      editorState.service.scrollService?.enable();
    }

    if (_keepFocusApplied) {
      _keepFocusApplied = false;
      keepEditorFocusNotifier.decrease();
    }

    editorState.onDispose.removeListener(dismiss);

    _findReplaceMenuEntry?.remove();
    _findReplaceMenuEntry = null;

    final isSelectionDisposed =
        editorState.service.selectionServiceKey.currentState == null;
    if (!isSelectionDisposed) {
      final selectionService = editorState.service.selectionService;
      selectionService.currentSelection.removeListener(_onSelectionChange);
    }
  }

  @override
  void show() {
    if (_findReplaceMenuEntry != null) {
      dismiss();
    }

    final selectionService = editorState.service.selectionService;
    final selectionRects = selectionService.selectionRects;
    if (selectionRects.isEmpty) {
      return;
    }

    editorState.onDispose.addListener(dismiss);

    if (!_keepFocusApplied) {
      _keepFocusApplied = true;
      keepEditorFocusNotifier.increase();
    }

    _findReplaceMenuEntry = OverlayEntry(
      builder: (context) {
        return Positioned(
          top: topOffset,
          right: rightOffset,
          child: style.findMenuBuilder?.call(
                context,
                editorState,
                localizations,
                style,
                showReplaceMenu,
                dismiss,
              ) ??
              Material(
                borderRadius: BorderRadius.circular(8.0),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: editorState.editorStyle.selectionColor,
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 5,
                        spreadRadius: 1,
                        color: Colors.black.withValues(alpha: 0.1),
                      ),
                    ],
                    borderRadius: BorderRadius.circular(6.0),
                  ),
                  child: FindAndReplaceMenuWidget(
                    onDismiss: dismiss,
                    editorState: editorState,
                    showReplaceMenu: showReplaceMenu,
                    localizations: localizations,
                    style: style,
                    showRegexButton: showRegexButton,
                    showCaseSensitiveButton: showCaseSensitiveButton,
                  ),
                ),
              ),
        );
      },
    );

    Overlay.of(context, rootOverlay: true).insert(_findReplaceMenuEntry!);
  }

  void _onSelectionChange() {
    // workaround: SelectionService has been released after hot reload.
    final isSelectionDisposed =
        editorState.service.selectionServiceKey.currentState == null;
    if (!isSelectionDisposed) {
      final selectionService = editorState.service.selectionService;
      if (selectionService.currentSelection.value == null) {
        return;
      }
    }

    if (_selectionUpdateByInner) {
      _selectionUpdateByInner = false;
      return;
    }

    dismiss();
  }
}
