import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Because the flutter's [DoubleTapGestureRecognizer] will block the [TapGestureRecognizer]
/// for a while. So we need to implement our own GestureDetector.
@immutable
class SelectionGestureDetector extends StatefulWidget {
  const SelectionGestureDetector({
    super.key,
    this.child,
    this.onTapDown,
    this.onDoubleTapDown,
    this.onTripleTapDown,
    this.onSecondaryTapDown,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
    this.enablePanImmediate = true,
  });

  @override
  State<SelectionGestureDetector> createState() =>
      SelectionGestureDetectorState();

  final Widget? child;

  final bool enablePanImmediate;

  final GestureTapDownCallback? onTapDown;
  final GestureTapDownCallback? onDoubleTapDown;
  final GestureTapDownCallback? onTripleTapDown;
  final GestureTapDownCallback? onSecondaryTapDown;
  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;
}

class SelectionGestureDetectorState extends State<SelectionGestureDetector> {
  bool _isDoubleTap = false;
  Timer? _doubleTapTimer;
  int _tripleTabCount = 0;
  Timer? _tripleTabTimer;

  final kTripleTapTimeout = const Duration(milliseconds: 500);

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      // [sinan] 补丁 17：不要把"整块编辑器可点"暴露给无障碍树。
      // 这一层给**整个编辑器**挂 onTapDown（落光标用），但它是一片无名区域：
      // 语义树上会多出一个没有 label 的可点节点——2026-09-17 `test/a11y/` 实测，
      // 滚动视口与文档容器两个节点因此被 `labeledTapTargetGuideline` 判红。
      // `excludeFromSemantics: true` 只让**本层**不贡献语义（连 _GestureSemantics
      // 都不挂），子节点（各块、文本域）自己的语义不受影响——这正是"只删掉那个
      // 多余动作"的精确手段，外层包 Semantics 做不到（只能加、不能减）。
      excludeFromSemantics: true,
      gestures: {
        if (widget.enablePanImmediate)
          ImmediateMultiDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                  ImmediateMultiDragGestureRecognizer>(
            () => ImmediateMultiDragGestureRecognizer(),
            (recognizer) {
              recognizer.onStart = (offset) {
                return _ImmediateDrag(
                  offset: offset,
                  onStart: widget.onPanStart,
                  onUpdate: widget.onPanUpdate,
                  onEnd: widget.onPanEnd,
                );
              };
            },
          ),
        if (!widget.enablePanImmediate)
          PanGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
            () => PanGestureRecognizer(
              supportedDevices: {
                // https://docs.flutter.dev/release/breaking-changes/trackpad-gestures#for-gesture-interactions-not-suitable-for-trackpad-usage
                // Exclude PointerDeviceKind.trackpad.
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.stylus,
                PointerDeviceKind.invertedStylus,
              },
            ),
            (recognizer) {
              recognizer
                // ..onStart = widget.onPanStart
                ..onUpdate = widget.onPanUpdate
                ..onEnd = widget.onPanEnd;
            },
          ),
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          () => TapGestureRecognizer(),
          (recognizer) {
            recognizer.onTapDown = _tapDownDelegate;
            recognizer.onSecondaryTapDown = widget.onSecondaryTapDown;
          },
        ),
      },
      child: widget.child,
    );
  }

  void _tapDownDelegate(TapDownDetails tapDownDetails) {
    if (_tripleTabCount == 2) {
      _tripleTabCount = 0;
      _tripleTabTimer?.cancel();
      _tripleTabTimer = null;
      if (widget.onTripleTapDown != null) {
        widget.onTripleTapDown!(tapDownDetails);
      }
    } else if (_isDoubleTap) {
      _isDoubleTap = false;
      _doubleTapTimer?.cancel();
      _doubleTapTimer = null;
      if (widget.onDoubleTapDown != null) {
        widget.onDoubleTapDown!(tapDownDetails);
      }
      _tripleTabCount++;
    } else {
      if (widget.onTapDown != null) {
        widget.onTapDown!(tapDownDetails);
      }

      _isDoubleTap = true;
      _doubleTapTimer?.cancel();
      _doubleTapTimer = Timer(kDoubleTapTimeout, () {
        _isDoubleTap = false;
        _doubleTapTimer = null;
      });

      _tripleTabCount = 1;
      _tripleTabTimer?.cancel();
      _tripleTabTimer = Timer(kTripleTapTimeout, () {
        _tripleTabCount = 0;
        _tripleTabTimer = null;
      });
    }
  }

  @override
  void dispose() {
    _doubleTapTimer?.cancel();
    _tripleTabTimer?.cancel();
    super.dispose();
  }
}

// Custom pan gesture recognizer to trigger immediately
// The callbacks in  _ImmediateDrag will be called immediately
class _ImmediateDrag extends Drag {
  _ImmediateDrag({
    required this.offset,
    this.onStart,
    this.onUpdate,
    this.onEnd,
  }) {
    onStart?.call(DragStartDetails(globalPosition: offset));
  }

  final Offset offset;

  final GestureDragStartCallback? onStart;
  final GestureDragUpdateCallback? onUpdate;
  final GestureDragEndCallback? onEnd;

  @override
  void update(DragUpdateDetails details) {
    onUpdate?.call(details);
  }

  @override
  void end(DragEndDetails details) {
    onEnd?.call(details);
  }
}
