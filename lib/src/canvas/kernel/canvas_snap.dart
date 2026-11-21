import 'dart:ui';

/// 吸附系统：移动/缩放 item 时自动对齐到其他 item 的边缘/中心。
///
/// 设计要点：
/// - **世界坐标**计算（与缩放无关）
/// - 容差随缩放反向调整（保持屏幕观感一致）
/// - 只返回最优吸附结果（避免抖动）
/// - 对齐线用于绘制参考（屏幕坐标）
class SnapEngine {
  SnapEngine({this.baseTolerance = 8.0});

  /// 基础吸附容差（屏幕像素）；实际容差 = baseTolerance / scale。
  final double baseTolerance;

  /// 当前激活的对齐线（供绘制层读取）。
  final List<SnapLine> activeLines = [];

  /// 计算移动吸附后的位置。
  ///
  /// [delta] 原始移动增量（世界坐标）
  /// [movingRect] 移动前的 item rect（世界坐标）
  /// [others] 其他 item 的 rect（世界坐标）
  /// [scale] 当前相机缩放（用于容差换算）
  ///
  /// 返回吸附调整后的 delta。
  Offset snapMove(Offset delta, Rect movingRect, List<Rect> others, double scale) {
    activeLines.clear();
    if (others.isEmpty) return delta;

    final double tolerance = baseTolerance / scale;
    final Rect moved = movingRect.shift(delta);

    double bestDx = delta.dx;
    double bestDy = delta.dy;
    double bestScoreX = tolerance * 2;
    double bestScoreY = tolerance * 2;
    SnapLine? bestLineX;
    SnapLine? bestLineY;

    // X 轴对齐检测
    for (final Rect other in others) {
      // 移动后 rect 的关键 x 坐标
      final List<double> movingXs = [moved.left, moved.center.dx, moved.right];
      // 目标 rect 的关键 x 坐标
      final List<double> targetXs = [other.left, other.center.dx, other.right];

      for (final double mx in movingXs) {
        for (final double tx in targetXs) {
          final double dist = (mx - tx).abs();
          if (dist < bestScoreX) {
            bestScoreX = dist;
            bestDx = delta.dx - (mx - tx);
            bestLineX = SnapLine.vertical(tx);
          }
        }
      }
    }

    // Y 轴对齐检测
    for (final Rect other in others) {
      final List<double> movingYs = [moved.top, moved.center.dy, moved.bottom];
      final List<double> targetYs = [other.top, other.center.dy, other.bottom];

      for (final double my in movingYs) {
        for (final double ty in targetYs) {
          final double dist = (my - ty).abs();
          if (dist < bestScoreY) {
            bestScoreY = dist;
            bestDy = delta.dy - (my - ty);
            bestLineY = SnapLine.horizontal(ty);
          }
        }
      }
    }

    // 只在真正吸附时记录对齐线
    if (bestScoreX < tolerance) {
      activeLines.add(bestLineX!);
    }
    if (bestScoreY < tolerance) {
      activeLines.add(bestLineY!);
    }

    return Offset(bestDx, bestDy);
  }

  /// 清空激活的对齐线（手势结束时调用）。
  void clear() {
    activeLines.clear();
  }
}

/// 对齐参考线（世界坐标）。
class SnapLine {
  SnapLine.vertical(this.x)
      : y = null,
        isVertical = true;

  SnapLine.horizontal(this.y)
      : x = null,
        isVertical = false;

  /// 垂直线的 x 坐标（isVertical = true 时有效）。
  final double? x;

  /// 水平线的 y 坐标（isVertical = false 时有效）。
  final double? y;

  /// 是否为垂直线。
  final bool isVertical;
}
