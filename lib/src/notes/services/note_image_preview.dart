import 'dart:io';
import 'dart:ui' as ui;
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';/// 图片全屏预览（lightbox，对标网�?飞书预览器）�?
import '../../theme/tokens.dart';
///
/// - 进入：编辑器内单击图片（也可从右键菜单进�?
/// - 缩放：滚�?/ 顶部 �? 按钮 / 双击 1x�?.5x——全部围�?*预览中心**�?
///   固定范围 50%~1000%
/// - 平移：按住拖动（光标 move�?
/// - 重置：工具栏百分�?适应窗口按钮 �?100% + 居中
/// - 关闭：Esc / 右上�?×
///
/// 实现模型（与网页预览器同构，行为完全确定）：只有两个独立状�?
/// ——缩放标�?+ 平移偏移，渲染为 `T(offset)·S(scale)` 中心锚矩阵�?
/// 缩放永远围绕中心且不改偏移，拖动只改偏移——互不干扰，不会
/// 出现「越缩越�?漂移」（InteractiveViewer 手势矩阵与手工矩�?
/// 叠加会产生累积误差，故弃用）�?
Future<void> showNoteImagePreview(BuildContext context, String source) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black,
    useSafeArea: false,
    builder: (_) => _NoteImagePreview(source: source),
  );
}

class _NoteImagePreview extends StatefulWidget {
  const _NoteImagePreview({required this.source});

  /// 已解析的图片源（纯路径或 http URL，由 embed builder 预处理）�?
  final String source;

  @override
  State<_NoteImagePreview> createState() => _NoteImagePreviewState();
}

class _NoteImagePreviewState extends State<_NoteImagePreview> {
  static const double _minScale = 0.5;
  static const double _maxScale = 10;
  static const double _wheelStep = 1.15;

  double _scale = 1;
  Offset _offset = Offset.zero;

  /// 解码上限（长边像素）：预览图按屏幕长�?2 倍解码就足够 10 倍缩放看清，
  /// 再大纯属浪费内存与首次解码时间（相机原图 4000px+ 全量解码一次要几十毫秒）�?
  /// 首次 build 时按实际屏幕取值，之后恒定（不随缩放变，避免反复重解码）�?
  int? _maxDecodePx;

  void _setScale(double value) {
    setState(() => _scale = value.clamp(_minScale, _maxScale));
  }

  void _zoomStep(double factor) => _setScale(_scale * factor);

  void _reset() {
    setState(() {
      _scale = 1;
      _offset = Offset.zero;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 限分辨率解码：只约束宽度（保持纵横比），首次取屏幕长�?2 倍�?
    _maxDecodePx ??=
        (MediaQuery.sizeOf(context).longestSide * 2).round().clamp(1, 8192);
    final Widget image = widget.source.startsWith('http')
        ? Image.network(
            widget.source,
            fit: .contain,
            cacheWidth: _maxDecodePx,
            errorBuilder: (context, error, stackTrace) => _error(context),
          )
        : Image.file(
            File(widget.source),
            fit: .contain,
            cacheWidth: _maxDecodePx,
            errorBuilder: (context, error, stackTrace) => _error(context),
          );

    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: EdgeInsets.zero,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: <Widget>[
            // 图片层：拖动平移 + 滚轮中心缩放 + 双击放大�?
            Positioned.fill(
              child: GestureDetector(
                behavior: .opaque,
                onPanUpdate: (DragUpdateDetails details) =>
                    setState(() => _offset += details.delta),
                child: Listener(
                  onPointerSignal: (PointerSignalEvent event) {
                    if (event is PointerScrollEvent) {
                      _zoomStep(
                        event.scrollDelta.dy < 0 ? _wheelStep : 1 / _wheelStep,
                      );
                    }
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.move,
                    // RepaintBoundary：拖动平移每�?setState 只重绘这一�?
                    // （图片解码结果被栅格化缓存），不牵连整个对话框重绘�?
                    child: RepaintBoundary(
                      child: Transform(
                        // 中心锚缩�?+ 屏幕像素平移，两状态互不影响�?
                        transform: Matrix4.identity()
                          ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                          ..scaleByDouble(_scale, _scale, 1, 1),
                        alignment: Alignment.center,
                        child: Center(
                          child: GestureDetector(
                            onDoubleTap: () => _setScale(
                              _scale > 1.2 ? _scale / 2.5 : _scale * 2.5,
                            ),
                            child: image,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 顶部工具栏（悬浮胶囊）：整体下移避开窗口自定义标题栏
            // ——顶格放的话关闭 × 与标题栏关闭按钮过近，易误触�?
            Positioned(
              top: 44,
              left: 12,
              right: 12,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: <Widget>[
                    _ToolButton(
                      icon: const tabler.Minus(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                      tooltip: '缩小',
                      onTap: () => _zoomStep(1 / _wheelStep),
                    ),
                    const SizedBox(width: 4),
                    // 百分比即重置按钮（网页预览器惯例）�?
                    TextButton(
                      onPressed: _reset,
                      child: Text(
                        '${(_scale * 100).round()}%',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    _ToolButton(
                      icon: const tabler.Plus(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                      tooltip: '放大',
                      onTap: () => _zoomStep(_wheelStep),
                    ),
                    const SizedBox(width: 8),
                    _ToolButton(
                      icon: const tabler.ArrowsMaximize(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                      tooltip: '适应窗口',
                      onTap: _reset,
                    ),
                    const Spacer(),
                    _ToolButton(
                      icon: const tabler.X(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                      tooltip: '关闭（Esc�?,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _error(BuildContext context) {
    return Column(
      mainAxisSize: .min,
      children: <Widget>[
        const tabler.PhotoOff(height: Tokens.iconXl, width: Tokens.iconXl, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(Colors.white38, ui.BlendMode.srcIn)),
        const SizedBox(height: 12),
        Text(
          '图片无法加载',
          style: TextStyle(
            fontSize: 14,
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }
}

/// 工具栏按钮（半透明白，黑底预览�?chrome 样式）�?
class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: icon,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
    );
  }
}
