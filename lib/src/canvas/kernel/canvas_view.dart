import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'canvas_controller.dart';
import 'canvas_item.dart';
import 'canvas_painters.dart';

/// 画布视图：**输入层 + 三层绘制**。
///
/// ```
/// Listener（原始指针事件，含压感/笔类型/接触面）
///   └ MouseRegion（光标）
///     └ ListenableBuilder（控制器变化即重建）
///       ├ CustomPaint 网格层（屏幕坐标，随相机）
///       ├ CustomPaint 笔迹层（世界坐标，按相机变换；只画视口内的）
///       └ CustomPaint 浮层（框选矩形 / 橡皮光标）
/// ```
///
/// 三层拆开是为了**重绘隔离**：平移/缩放时三层的 `shouldRepaint` 都只比相机，
/// 而写字时只有笔迹层与浮层重绘。项目渲染规范要求的高频局部刷新即此。
///
/// 颜色由调用方给（不在这里读 Theme）：本文件刻意不依赖 Material，
/// 保证内核在两套主题（material_ui / 官方 material）下都能用。
class CanvasView extends StatefulWidget {
  const CanvasView({
    super.key,
    required this.controller,
    required this.backgroundColor,
    required this.gridColor,
    required this.accentColor,
    required this.staleColor,
    required this.inkColor,
  });

  final CanvasController controller;

  final Color backgroundColor;

  /// 主题**墨色**：底色既然是主题给的，墨色就必须一起给——否则出现
  /// "黑墨画黑纸"（暗色纸面 `#161616` 上的 `#1F1F1F` 几乎不可识别）。
  /// 只有 [kThemeInk] 色的笔迹按它绘制，其余笔迹用自己的存储色。
  final Color inkColor;

  /// 点阵网格颜色。
  final Color gridColor;

  /// 交互浮层（框选 / 橡皮光标）与选中态的颜色。
  final Color accentColor;

  /// AI 层"输入已变、可重算"标记的颜色（与选中态区分，故单独一支）。
  final Color staleColor;

  @override
  State<CanvasView> createState() => _CanvasViewState();
}

class _CanvasViewState extends State<CanvasView> {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = Size(constraints.maxWidth, constraints.maxHeight);
        final CanvasController controller = widget.controller;

        // ⚠️ 不能在 build 里直接 setViewport：它会 notifyListeners ⇒
        // "build 期间 setState/markNeedsBuild"。延到帧末；且只在尺寸真变了
        // 才排（否则每帧都排一个回调）。
        if (controller.viewport != size) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) controller.setViewport(size);
          });
        }

        return ListenableBuilder(
          listenable: controller,
          builder: (BuildContext context, Widget? child) {
            // 已完笔迹始终走一张缓存的 Picture（一次 drawPicture），
            // 书写时只额外重绘 activeStroke —— 与笔迹条数无关，故不按数量分支。
            final ui.Picture? picture = controller.pictureFor(widget.inkColor);
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Listener(
                  // 原始事件：压感 / 笔类型 / 接触面都要，GestureDetector 给不全。
                  onPointerDown: controller.onPointerDown,
                  onPointerMove: controller.onPointerMove,
                  onPointerUp: controller.onPointerUp,
                  onPointerCancel: controller.onPointerCancel,
                  onPointerHover: controller.onPointerHover,
                  onPointerSignal: controller.onPointerSignal,
                  // opaque：空白区域也要能接到 hover / down（Stack 里的 CustomPaint
                  // 自身不参与命中）。
                  behavior: HitTestBehavior.opaque,
                  child: MouseRegion(
                    cursor: _cursorOf(controller),
                    child: ColoredBox(
                      color: widget.backgroundColor,
                      // ⚠️ 裁剪**必须**加在这里，否则笔迹会画到相邻的列表栏上：
                      // `CustomPaint` 不会裁剪绘制内容，而 `Stack` 的 `clipBehavior`
                      // 只在"子件**布局**越界"时才生效——下面这层 Stack 的子件尺寸
                      // 恰好等于它自身，它认为没越界，于是不裁。
                      //
                      // 无限画布画到边界外是**正常**的（指针按住后可以拖出控件，
                      // Flutter 会把后续 move 继续送给本控件；内容也确实存在于视口
                      // 之外的世界坐标上），所以这里要的是"裁掉不可见部分"，而不是
                      // 丢弃那些点。hardEdge 单层裁剪，不嵌套、不走 saveLayer。
                      child: ClipRect(
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            // 网格层最重（整屏点阵）⇒ 刻意**不**接 repaintStamp：
                            // 它只认相机的版本号快照，于是写字/拖 item 时保持不动。
                            CustomPaint(
                              painter: GridPainter(
                                camera: controller.camera,
                                color: widget.gridColor,
                                stamp: controller.camera.revision,
                              ),
                            ),
                            // item 层（图片/形状），画在笔迹下方；只画视口内的。
                            CustomPaint(
                              painter: ItemPainter(
                                camera: controller.camera,
                                // 形状的哨兵色按主题墨色画（与笔迹同一口径）。
                                inkColor: widget.inkColor,
                                items: controller.document.itemsIn(
                                  controller.camera.visibleWorld(size),
                                ),
                                stamp: controller.repaintStamp,
                                staleColor: widget.staleColor,
                                // 懒加载图片：解码完成后下一帧重建重绘，占位框先顶着。
                                onImageMissing: (ImageItem item) {
                                  unawaited(
                                    item.load(
                                      onLoaded: () => WidgetsBinding.instance
                                          .addPostFrameCallback(
                                            (_) => controller.requestRepaint(),
                                          ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            CustomPaint(
                              painter: InkPainter(
                                camera: controller.camera,
                                // 湿墨与逐条路径在 painter 内解析墨色，故这里也要给
                                // （缓存那张 Picture 已由 pictureFor 按同一墨色烤好）。
                                inkColor: widget.inkColor,
                                picture: picture,
                                activeStroke: controller.activeStroke,
                                stamp: controller.repaintStamp,
                              ),
                            ),
                            CustomPaint(
                              painter: OverlayPainter(
                                camera: controller.camera,
                                color: widget.accentColor,
                                marquee: controller.marquee,
                                shapeDraft: controller.shapeDraft,
                                shapeDraftKind: controller.shapeKind,
                                eraserCenter:
                                    controller.tool == CanvasTool.eraser
                                    ? controller.eraserAt
                                    : null,
                                eraserRadius: controller.eraserRadius,
                                selectedItems: controller.selectedItems,
                                stamp: controller.repaintStamp,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // AI 生成入口：有选区时浮在选区右上角。与画布 Listener **平级**，
                // 自身命中拦截点击，不会误触发画布框选。
                if (controller.selectionBounds != null)
                  _aiGenerateButton(controller, size),
              ],
            );
          },
        );
      },
    );
  }

  /// 选区右上角的"AI 生成"浮层按钮（仅用 widgets/painting，不引入 Material，
  /// 保持内核两套主题通用）。点击调用 [CanvasController.generateFromSelection]。
  Widget _aiGenerateButton(CanvasController controller, Size size) {
    final Rect world = controller.selectionBounds!;
    final Offset topLeft = controller.camera.worldToScreen(world.topLeft);
    final Offset bottomRight = controller.camera.worldToScreen(
      world.bottomRight,
    );
    final double left = (bottomRight.dx + 8).clamp(8.0, size.width - 110.0);
    final double top = (topLeft.dy - 36).clamp(8.0, size.height - 36.0);
    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onTap: () => controller.generateFromSelection(
          prompt: controller.aiPrompt.isEmpty ? null : controller.aiPrompt,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xDD000000),
            borderRadius: BorderRadius.circular(16),
            boxShadow: const <BoxShadow>[
              BoxShadow(color: Color(0x40000000), blurRadius: 6),
            ],
          ),
          child: const Text(
            '✨ AI 生成',
            style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 13),
          ),
        ),
      ),
    );
  }

  MouseCursor _cursorOf(CanvasController controller) =>
      switch (controller.tool) {
        CanvasTool.pen => SystemMouseCursors.precise,
        CanvasTool.eraser => SystemMouseCursors.precise,
        CanvasTool.select => SystemMouseCursors.basic,
        CanvasTool.pan => SystemMouseCursors.grab,
        // 十字光标：形状工具是"落点定框"的绘制行为（同笔），不是选择行为。
        CanvasTool.shape => SystemMouseCursors.precise,
      };
}
