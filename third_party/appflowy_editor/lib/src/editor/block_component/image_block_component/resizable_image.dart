import 'dart:io';
import 'dart:math';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:string_validator/string_validator.dart';

import 'base64_image.dart';

class ResizableImage extends StatefulWidget {
  const ResizableImage({
    super.key,
    required this.alignment,
    required this.editable,
    required this.onResize,
    required this.width,
    required this.src,
    this.height,
    this.focusedListenable,
    this.focusColor,
    this.maxWidth,
  });

  final String src;
  final double width;
  final double? height;
  final Alignment alignment;
  final bool editable;

  /// [sinan 补丁 26] 可拖到的**最大宽度**（= 正文可用列宽，由外层 LayoutBuilder
  /// 传入）。null ⇒ 不设上限（沿用官方行为）。
  ///
  /// 为什么要它：官方无上限，能把图片拖到超过列宽——存的 `width` 大于列宽，
  /// 窗口/列宽一变就被裁；而且首次插入的默认宽度取的是**屏幕宽**，语义本身
  /// 就不对。
  final double? maxWidth;

  /// [sinan 补丁 25] 选中态的可监听值。用 ValueListenable 而非 bool，避免
  /// 选区变化重建 ResizableImage 本体（会丢 imageWidth / _cacheImage 状态）。
  final ValueListenable<bool>? focusedListenable;
  final Color? focusColor;

  final void Function(double width) onResize;

  @override
  State<ResizableImage> createState() => _ResizableImageState();
}

/// [sinan 补丁 26] 最小宽度：官方 30px（几乎等于没有下限，能拖成一条缝）。
/// 80px 是"还能看出是张图"的下限。
const _kImageBlockComponentMinWidth = 80.0;

/// [sinan 补丁 26] 拖拽热区宽度：官方 5px 且内缩 5px（热区落在「距边缘 5~10px」
/// 的窄带里 ⇒ **点最边缘反而拖不动**，用户第一反应就是拖边缘）。改为贴边 8px。
const _kImageBlockHandleWidth = 8.0;

class _ResizableImageState extends State<ResizableImage> {
  late double imageWidth;

  double initialOffset = 0;
  double moveDistance = 0;

  Image? _cacheImage;

  @visibleForTesting
  bool onFocus = false;

  @override
  void initState() {
    super.initState();

    imageWidth = widget.width;
  }

  /// [sinan 补丁 26] 外部改 `width`（撤销、右键「恢复原始大小」删属性后回落到
  /// 列宽）时同步本地值。官方只在 initState 取一次 ⇒ 之后属性变了画面不动，
  /// 「恢复原始大小」会像失效。
  @override
  void didUpdateWidget(ResizableImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.width != oldWidget.width) {
      imageWidth = widget.width;
      moveDistance = 0;
    }
  }

  /// 宽度一律走这里：夹在 [最小宽度, 列宽] 之间。
  ///
  /// 存量的超宽值（早先无上限时拖出来的）在这里被夹回列宽，不会溢出排版；
  /// 列宽比最小宽度还窄时以列宽为准。
  double _clampWidth(double value) {
    final double upper = widget.maxWidth ?? double.infinity;
    return min(max(_kImageBlockComponentMinWidth, value), upper);
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: widget.alignment,
      child: SizedBox(
        width: _clampWidth(imageWidth - moveDistance),
        height: widget.height,
        child: MouseRegion(
          onEnter: (event) => setState(() {
            onFocus = true;
          }),
          onExit: (event) => setState(() {
            onFocus = false;
          }),
          child: _buildResizableImage(context),
        ),
      ),
    );
  }

  Widget _buildResizableImage(BuildContext context) {
    Widget child;
    final src = widget.src;
    if (isBase64(src)) {
      // load base64 image (url is raw base64 from web)
      _cacheImage ??= Image.memory(
        dataFromBase64String(src),
      );
      child = _cacheImage!;
    } else if (isURL(src)) {
      // load network image
      _cacheImage ??= Image.network(
        widget.src,
        width: widget.width,
        gaplessPlayback: true,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null ||
              loadingProgress.cumulativeBytesLoaded ==
                  loadingProgress.expectedTotalBytes) {
            return child;
          }
          return _buildLoading(context);
        },
        errorBuilder: (context, error, stackTrace) => _buildError(context),
      );
      child = _cacheImage!;
    } else {
      // load local file
      _cacheImage ??= Image.file(File(src));
      child = _cacheImage!;
    }
    // [sinan 补丁 25] 聚焦描边贴在**图片像素**外沿，而不是 ResizableImage
    // 外层（Align 会撑满整列宽 ⇒ 描边比图片大一圈、不同比例对不齐）。
    // 放 Stack 内、Positioned 手柄之下：描边盒 = Image 的渲染盒，任何原始
    // 尺寸/比例/alignment 都严丝合缝；foreground 不占位、无圆角。
    // 用 focusedListenable 驱动：选区变化只重建这层 DecoratedBox，不动
    // ResizableImage 本体（保住 imageWidth / moveDistance / _cacheImage）。
    final Widget imageChild = child;
    if (widget.focusedListenable != null && widget.focusColor != null) {
      child = ValueListenableBuilder<bool>(
        valueListenable: widget.focusedListenable!,
        builder: (BuildContext context, bool focused, Widget? child) {
          if (!focused) return child!;
          return DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: Border.all(color: widget.focusColor!),
            ),
            child: child,
          );
        },
        child: imageChild,
      );
    }
    return Stack(
      children: [
        child,
        if (widget.editable) ...[
          // [sinan 补丁 26] 热区**贴边**且加宽到 8px（官方 left/right:5 + 宽 5
          // ⇒ 热区在「距边缘 5~10px」的窄带里，点最边缘拖不动）。
          _buildEdgeGesture(
            context,
            top: 0,
            left: 0,
            bottom: 0,
            width: _kImageBlockHandleWidth,
            onUpdate: (distance) {
              setState(() {
                moveDistance = distance;
              });
            },
          ),
          _buildEdgeGesture(
            context,
            top: 0,
            right: 0,
            bottom: 0,
            width: _kImageBlockHandleWidth,
            onUpdate: (distance) {
              setState(() {
                moveDistance = -distance;
              });
            },
          ),
        ],
      ],
    );
  }

  Widget _buildLoading(BuildContext context) {
    return SizedBox(
      height: 150,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox.fromSize(
            size: const Size(18, 18),
            child: const CircularProgressIndicator(),
          ),
          SizedBox.fromSize(
            size: const Size(10, 10),
          ),
          Text(AppFlowyEditorL10n.current.loading),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Container(
      height: 100,
      width: imageWidth,
      alignment: Alignment.center,
      padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(4.0)),
        border: Border.all(width: 1, color: Colors.black),
      ),
      child: Text(AppFlowyEditorL10n.current.imageLoadFailed),
    );
  }

  Widget _buildEdgeGesture(
    BuildContext context, {
    double? top,
    double? left,
    double? right,
    double? bottom,
    double? width,
    void Function(double distance)? onUpdate,
  }) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      width: width,
      child: GestureDetector(
        onHorizontalDragStart: (details) {
          initialOffset = details.globalPosition.dx;
        },
        onHorizontalDragUpdate: (details) {
          if (onUpdate != null) {
            var offset = (details.globalPosition.dx - initialOffset);
            if (widget.alignment == Alignment.center) {
              offset *= 2.0;
            }
            onUpdate(offset);
          }
        },
        onHorizontalDragEnd: (details) {
          imageWidth = _clampWidth(imageWidth - moveDistance);
          initialOffset = 0;
          moveDistance = 0;

          widget.onResize(imageWidth);
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          // [sinan 补丁 26] 视觉条改成**整条高度**（官方固定 height:40：图片一高，
          // 中部"看不见把手"却能拖，顶部看见的又不在视觉条上 ⇒ 可见性与可拖区
          // 不一致）。细条 3px、贴边，和热区一样贯穿全高。
          child: onFocus
              ? Center(
                  child: Container(
                    width: 3,
                    height: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: const BorderRadius.all(
                        Radius.circular(2.0),
                      ),
                    ),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}
