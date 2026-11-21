import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
/// ## 2026-09-19 核实：这套隔离已经是**到位**的，不要再往上加东西
/// 逐层 `shouldRepaint` 收窄（网格只认相机快照、item 与笔迹各按 `repaintStamp`）
/// ＋ 视口裁剪（只画 `visibleWorld` 内的）＋ 笔迹烤成 `Picture`，已经把每帧重绘
/// 压到"只画变了的那一层、只画视口内的那部分"。通用的"增量重绘 / 脏区收窄"
/// 类建议在这里属于**已实现**状态。
///
/// 补丁（2026-09-19）：item 层加了 **LOD 代理渲染**（`ItemPainter(lod: true)`）。
/// 这条**不是**上面那套的重复，而是它的缺口——视口裁剪只在 item 落在视口**外**
/// 时有用；缩小时 `visibleWorld` 会包住整张画布 ⇒ 裁剪失效、变成全量全保真绘制。
/// LOD 承接的正是这个裁剪救不了的场景。
///
/// ⚠️ 真要改这里，先确认不会让某层开始**跟着高频事件**（写字、拖 item）一起
/// 重绘——尤其别给网格层接 `repaintStamp`（它是唯一"每帧上千个圆"的重层）。
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
                GestureDetector(
                  onSecondaryTapDown: (TapDownDetails details) {
                    _showContextMenu(context, details.globalPosition);
                  },
                  child: Listener(
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
                                // LOD 代理渲染（见 `ItemPainter` 类文档）：缩小时视口
                                // 会包住整张画布 ⇒ 裁剪失效，此时小到看不清的 item
                                // 只画身份色块并跳过图片解码。**只有实时视图开**，
                                // 导出 / AI 栅格化保持默认全保真。
                                lod: true,
                                // 判据用控制器的**稳定缩放**（不是 `camera.scale`）：
                                // 缩放中冻结、停稳才跳一次 ⇒ 不闪变、也不会在
                                // 手势正忙时批量解码图片（见 `lodScale` 的文档）。
                                lodScale: controller.lodScale,
                                // 选中 / 编辑中的 item 保持全保真——照 tldraw
                                // 「正在操作的东西必须看得见」，选中的卡片不该
                                // 突然变成一个色块。
                                pinnedIds: <String>{
                                  for (final CanvasItem selected
                                      in controller.selectedItems)
                                    selected.id,
                                },
                                items: controller.document.itemsIn(
                                  controller.camera.visibleWorld(size),
                                ),
                                // 连线：端点在绘制时由两端卡片**现算**（binding），
                                // 所以拖动卡片时它会自己跟随，无需任何同步代码。
                                edges: controller.document.edgesIn(
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
                                selectedItems: controller.selectedItems,
                                // 端点拖改（缺口4）的预览走同一条虚线通道。
                                pendingEdge:
                                    controller.pendingEdgeGeometry ??
                                    controller.edgeGripPreview,
                                selectedEdge: controller.selectedEdgeGeometry,
                                stamp: controller.repaintStamp,
                              ),
                            ),
                            // 吸附对齐线（移动时显示）
                            CustomPaint(
                              painter: SnapLinesPainter(
                                camera: controller.camera,
                                color: widget.accentColor,
                                lines: controller.snapEngine.activeLines,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                ),
                // 文本编辑 overlay（双击卡片时显示）
                if (controller.isEditing && controller.textEditController != null)
                  _CardTextEditor(
                    controller: controller,
                    backgroundColor: widget.backgroundColor,
                    accentColor: widget.accentColor,
                  ),
              ],
            );
          },
        );
      },
    );
  }

  void _showContextMenu(BuildContext context, Offset position) {
    final CanvasController controller = widget.controller;
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    unawaited(
      showMenu<void>(
        context: context,
        position: RelativeRect.fromRect(
          Rect.fromPoints(position, position),
          Offset.zero & overlay.size,
        ),
        items: [
          if (controller.hasSelection)
            PopupMenuItem<void>(
              onTap: controller.deleteSelection,
              child: const Row(
                children: [
                  Icon(Icons.delete_outline, size: 18),
                  SizedBox(width: 8),
                  Text('删除'),
                ],
              ),
            ),
        ],
      ),
    );
  }

  MouseCursor _cursorOf(CanvasController controller) =>
      switch (controller.tool) {
        CanvasTool.select => SystemMouseCursors.basic,
        CanvasTool.pan => SystemMouseCursors.grab,
        // 十字光标：形状工具是"落点定框"的绘制行为（同笔），不是选择行为。
        CanvasTool.shape => SystemMouseCursors.precise,
        // 连线工具：精确十字光标，提示"从一个 item 拖到另一个"。
        CanvasTool.connect => SystemMouseCursors.precise,
      };
}

/// 卡片文本编辑 overlay（双击卡片时叠加在卡片位置）。
///
/// 设计要点：
/// - 世界坐标 → 屏幕坐标定位（跟随相机变换）
/// - Enter 提交、Esc 取消、点击外部提交
/// - 样式跟随卡片（圆角、边框、字号随缩放）
class _CardTextEditor extends StatelessWidget {
  const _CardTextEditor({
    required this.controller,
    required this.backgroundColor,
    required this.accentColor,
  });

  final CanvasController controller;
  final Color backgroundColor;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final String? editId = controller.editingItemId;
    if (editId == null) return const SizedBox.shrink();

    final CanvasItem? item = controller.document.itemById(editId);
    if (item == null) return const SizedBox.shrink();

    // 世界坐标 → 屏幕坐标
    final Rect worldRect = item.rect;
    final Offset topLeft = controller.camera.worldToScreen(worldRect.topLeft);
    final Offset bottomRight = controller.camera.worldToScreen(worldRect.bottomRight);
    final Rect screenRect = Rect.fromPoints(topLeft, bottomRight);

    // 字号随缩放调整（保持视觉一致）
    final double fontSize = 14 * controller.camera.scale;

    return Positioned(
      left: screenRect.left,
      top: screenRect.top,
      width: screenRect.width,
      height: screenRect.height,
      child: Material(
        color: Colors.transparent,
        child: Focus(
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.escape) {
                controller.cancelEdit();
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.enter &&
                  !HardwareKeyboard.instance.isControlPressed) {
                controller.commitEdit();
                return KeyEventResult.handled;
              }
              // 格式快捷键：Ctrl+B/I/U
              if (HardwareKeyboard.instance.isControlPressed) {
                final TextEditingController? textCtrl = controller.textEditController;
                if (textCtrl == null) return KeyEventResult.ignored;
                final TextSelection sel = textCtrl.selection;
                if (!sel.isValid) return KeyEventResult.ignored;
                final String text = textCtrl.text;
                final int start = sel.start;
                final int end = sel.end;
                String marker = '';
                if (event.logicalKey == LogicalKeyboardKey.keyB) {
                  marker = '**';
                } else if (event.logicalKey == LogicalKeyboardKey.keyI) {
                  marker = '*';
                } else if (event.logicalKey == LogicalKeyboardKey.keyU) {
                  marker = '__';
                } else {
                  return KeyEventResult.ignored;
                }
                // 插入 markdown 标记
                final String newText = text.replaceRange(
                  start,
                  end,
                  '$marker${text.substring(start, end)}$marker',
                );
                textCtrl.text = newText;
                textCtrl.selection = TextSelection.collapsed(
                  offset: end + marker.length * 2,
                );
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: TextField(
            controller: controller.textEditController,
            autofocus: true,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: TextStyle(
              fontSize: fontSize,
              color: Theme.of(context).colorScheme.onSurface,
              height: 1.4,
            ),
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: accentColor, width: 2),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: accentColor, width: 2),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: accentColor, width: 2),
              ),
              contentPadding: EdgeInsets.all(8 * controller.camera.scale),
              fillColor: backgroundColor,
              filled: true,
              isDense: true,
            ),
            onTapOutside: (_) => controller.commitEdit(),
          ),
        ),
      ),
    );
  }
}
