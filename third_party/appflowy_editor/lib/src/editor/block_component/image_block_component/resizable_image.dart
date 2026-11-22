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
    // [sinan 补丁 26] 盒子比图片宽 2×handle（两侧各留一条），把手才能挂在
    // **图片外侧**的描边旁——像 Notion 那样"框 + 外侧把手"，归属一眼可辨。
    // 为什么不能直接 `Positioned(left: -8)` 画到盒外：Flutter 的命中测试要求
    // 指针落在盒子自己的 size 内，画出去**点不到**（块手柄已踩过这个坑）。
    return Align(
      alignment: widget.alignment,
      child: SizedBox(
        width: _clampWidth(imageWidth - moveDistance) +
            (_kImageBlockHandleWidth * 2),
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
          // [sinan 补丁 26] hover 也画出"框"（弱一档）：成熟产品是"框 + 外侧
          // 把手"一体，只有框在各状态都可见，"有框 = 有控件"才成立。选中态用
          // 全强度色，hover 用 35% —— 不抢选中态的视觉优先级。
          if (!focused && !onFocus) return child!;
          final Color color = focused
              ? widget.focusColor!
              : widget.focusColor!.withValues(alpha: 0.35);
          return DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(border: Border.all(color: color)),
            child: child,
          );
        },
        child: imageChild,
      );
    }
    return Stack(
      // 把手已落在盒子内的两侧留白里，不需要向外溢出绘制。
      clipBehavior: Clip.none,
      children: [
        // 图片作为**非 Positioned** 子件决定 Stack 尺寸（`height` 为 null 时
        // 高度全靠它撑），两侧 padding 就是给把手的留白。
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _kImageBlockHandleWidth,
          ),
          child: child,
        ),
        if (widget.editable) ...[
          // [sinan 补丁 26] 把手贴**盒子两端**（= 图片外侧留白里），8px 热区。
          // 官方是 left/right:5 + 宽 5（落在「距边缘 5~10px」的窄带，点最边缘
          // 拖不动）；且那时把手压在图片内，看着像图片里的一条线。
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
          // [sinan 补丁 26] 视觉条：**整条高度**（官方固定 height:40 ⇒ 图片一高，
          // 中部"看不见却能拖"、看见的又不在热区正中），4px 宽 + 1px 白描边
          // （纯黑在深色图片上根本看不见），圆角只在两端。
          child: onFocus
              ? Center(
                  child: Container(
                    width: 4,
                    height: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: const BorderRadius.all(
                        Radius.circular(2.0),
                      ),
                      border: Border.all(
                        width: 1,
                        color: Colors.white.withValues(alpha: 0.9),
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
