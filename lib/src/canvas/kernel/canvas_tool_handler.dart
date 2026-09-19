part of 'canvas_controller.dart';

/// 工具状态机（2026-09-18 第一步）：把 `onPointerDown` 里"按工具分的 if/else 分支"
/// 收进各自的处理器。**新增工具只注册一个 handler，不再动**那个几百行的巨型 switch。
///
/// 为什么只抽 `onPointerDown`？move / up / cancel 是**按手势瞬态**分（拖拽中 / 橡皮中 /
/// 框选中 / 端点拖改中…），不按工具分，抽到处理器里反而要把共享瞬态状态传来传去。
/// 它们留在控制器里，等状态机成熟后再逐步下放。
///
/// 处理器直接读写控制器的私有字段/方法（本文件是 `part of` 同一库），所以**逻辑与
/// 原 switch 分支逐字一致**，只是换了栖身之所——行为零变化，回归闸门是 canvas 测试。
abstract class CanvasToolHandler {
  const CanvasToolHandler();

  /// 处理一次按下（[world] 已经是世界坐标，[event] 含屏幕坐标 / 设备种类）。
  void onPointerDown(CanvasController c, PointerDownEvent event, Offset world);
}

/// 选择工具：手柄 > item 命中 > 框选；笔的橡皮端（inverted stylus）无条件当橡皮。
class _SelectHandler extends CanvasToolHandler {
  const _SelectHandler();
  @override
  void onPointerDown(CanvasController c, PointerDownEvent event, Offset world) {
    // 笔的橡皮端（inverted stylus）无条件当橡皮，与当前工具无关
    // —— 这是手写设备的通用约定。
    if (event.kind == PointerDeviceKind.invertedStylus) {
      c._erasing = true;
      c._eraserAt = world;
      c.document.eraseAt(world, c.eraserRadius);
      return;
    }
    // 优先级：缩放/旋转手柄 > item 命中 > 框选。
    // （手柄是屏幕尺寸常量，命中要在屏幕坐标做；item 命中容差换算成世界单位，
    // 保证任何缩放级别下"好点"的程度一致。）
    final grip = c._gripAtScreen(event.localPosition);
    if (grip != null) {
      c._beginGrip(grip, world);
      return;
    }
    final CanvasItem? item = c.document.hitItemAt(
      world,
      c.camera.toWorld(CanvasController._itemHitTolerance),
    );
    if (item != null) {
      // 已在多选集合内 ⇒ 保持选区整体拖动；否则单选该 item。
      if (!c._selectedItems.contains(item)) {
        c._selectedItems
          ..clear()
          ..add(item);
      }
      // 起点（多选一起动）。
      c._moveStartWorld = world;
      c._moveStartRects = <CanvasItem, Rect>{
        for (final CanvasItem it in c._selectedItems) it: it.rect,
      };
    } else {
      c._selectedItems.clear();
      c._marqueeStart = world;
      c._marquee = Rect.fromPoints(world, world);
      c._selection.clear();
    }
  }
}

/// 笔工具：橡皮端当橡皮；否则起一条新笔迹。
class _PenHandler extends CanvasToolHandler {
  const _PenHandler();
  @override
  void onPointerDown(CanvasController c, PointerDownEvent event, Offset world) {
    if (event.kind == PointerDeviceKind.invertedStylus) {
      c._erasing = true;
      c._eraserAt = world;
      c.document.eraseAt(world, c.eraserRadius);
      return;
    }
    c._activeStroke = InkStroke(
      color: c.penColor,
      baseWidth: c.penWidth,
      simulatePressure: !c._hasRealPressure(event),
    )..add(InkPoint(world, c._pressureOf(event)));
  }
}

/// 橡皮工具：起擦除（也覆盖 inverted stylus，见 [_SelectHandler] / [_PenHandler]）。
class _EraserHandler extends CanvasToolHandler {
  const _EraserHandler();
  @override
  void onPointerDown(CanvasController c, PointerDownEvent event, Offset world) {
    c._erasing = true;
    c._eraserAt = world;
    c.document.eraseAt(world, c.eraserRadius);
  }
}

/// 形状工具：按下即开始定尺寸。不碰命中/选区——"拖出来变成框选"正是要修的问题。
class _ShapeHandler extends CanvasToolHandler {
  const _ShapeHandler();
  @override
  void onPointerDown(CanvasController c, PointerDownEvent event, Offset world) {
    c._shapeStartWorld = world;
    c._shapeStartScreen = event.localPosition;
    c._shapeDraft = Rect.fromPoints(world, world);
  }
}

/// 连线工具：先判是否点中已有连线（选中），否则从卡片起拉。
class _ConnectHandler extends CanvasToolHandler {
  const _ConnectHandler();
  @override
  void onPointerDown(CanvasController c, PointerDownEvent event, Offset world) {
    c._beginConnect(world);
  }
}

/// 平移：到这里已经是 bug（平移在 `onPointerDown` 里早已 return），给个空实现兜底。
class _PanHandler extends CanvasToolHandler {
  const _PanHandler();
  @override
  void onPointerDown(CanvasController c, PointerDownEvent event, Offset world) {}
}

/// 工具 → 处理器 的注册表（状态机的「状态集合」）。
///
/// `of` 永远不返回 null：未知工具回落到选择工具，避免 `null` 调用炸在手势分发里。
class CanvasToolHandlers {
  const CanvasToolHandlers._();

  static const Map<CanvasTool, CanvasToolHandler> _map =
      <CanvasTool, CanvasToolHandler>{
    CanvasTool.select: _SelectHandler(),
    CanvasTool.pen: _PenHandler(),
    CanvasTool.eraser: _EraserHandler(),
    CanvasTool.shape: _ShapeHandler(),
    CanvasTool.connect: _ConnectHandler(),
    CanvasTool.pan: _PanHandler(),
  };

  static CanvasToolHandler of(CanvasTool tool) =>
      _map[tool] ?? _map[CanvasTool.select]!;
}
