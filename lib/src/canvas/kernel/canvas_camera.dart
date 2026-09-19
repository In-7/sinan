import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 画布相机：**世界 ↔ 屏幕**坐标换算。
///
/// ## 为什么不用 Matrix4 / vector_math
/// 画布只有**缩放 + 平移**，没有旋转 ⇒ 换算就是 `s = w * scale + translation`，
/// 两行算术。上 Matrix4 会多一个依赖、每帧多做一次 4×4 乘法，收益为零。
/// （真要加旋转时再换矩阵：届时替换本文件即可，调用方只碰这四个方法。）
///
/// ## 语义
/// - [scale]：屏幕像素 / 世界单位；
/// - [translation]：世界原点在屏幕上的位置（**屏幕像素**）；
/// - [screenToWorld] / [worldToScreen] 互为逆变换，[visibleWorld] 给出当前
///   视口对应的世界矩形——裁剪/命中测试全靠它。
class CanvasCamera {
  // 用可空参数 + 构造器体赋值：直接写 `_scale = scale` 会触发
  // prefer_initializing_formals（它要求参数与字段同名，而公开参数不该叫
  // `_scale`）。
  CanvasCamera({
    double? scale,
    Offset? translation,
    this.minScale = 0.05,
    this.maxScale = maxScaleCeiling,
  }) {
    if (scale != null) _scale = scale;
    if (translation != null) _translation = translation;
  }

  /// 缩放上限的**天花板**（应用级常量）= 4 ⇒ 最多放大 **400%**。
  ///
  /// 2026-09-18 由 32（3200%）下调：笔记场景用不到几十倍，无边记的缩放范围也是
  /// 这个量级。⚠️ 它是**天花板**而不只是默认值——老存档里写着 `maxScale: 32`，
  /// [CanvasCamera.fromJson] 会把它钳到这里；只改默认值的话，**已存在的画布
  /// 一步都不会变**。
  static const double maxScaleCeiling = 4;

  /// 缩放下限（0.05 = 缩到 5%，足够"看全貌"）。
  final double minScale;

  /// 缩放上限（见 [maxScaleCeiling]，最多 400%）。
  final double maxScale;

  // 默认值写在声明处（构造器体只在传了值时覆盖），这样既没有
  // not_initialized_non_nullable 也避开 prefer_initializing_formals。
  double _scale = 1;
  Offset _translation = Offset.zero;

  double get scale => _scale;

  Offset get translation => _translation;

  /// 相机变更计数：任何平移/缩放/适配都 +1（值没真变则不加）。
  ///
  /// 用途是**重绘判定**：相机是就地修改的，painter 拿到的
  /// `oldDelegate.camera` 与当前是**同一个对象**，逐字段比较等于和自己比、
  /// 恒等 ⇒ 判定恒为 false。有了它，网格层（唯一的重层：整屏点阵）可以只认
  /// 相机变化，从而在**写字期间不重绘**——保住高频局部刷新。
  int revision = 0;

  Offset screenToWorld(Offset screen) => (screen - _translation) / _scale;

  Offset worldToScreen(Offset world) => world * _scale + _translation;

  double toScreen(double worldLength) => worldLength * _scale;

  double toWorld(double screenLength) => screenLength / _scale;

  /// 当前视口覆盖的世界矩形（裁剪与命中测试的入口）。
  Rect visibleWorld(Size viewport) {
    final Offset topLeft = screenToWorld(Offset.zero);
    return Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      viewport.width / _scale,
      viewport.height / _scale,
    );
  }

  /// 内容跟着指针走（拖动平移）：[delta] 为**屏幕像素**位移。
  void panBy(Offset delta) {
    if (delta == Offset.zero) return;
    _translation += delta;
    revision++;
  }

  /// 以 [focalScreen] 为焦点缩放：焦点下的世界点保持不动
  /// （滚轮缩放的手感前提——否则会"跑偏"）。
  void zoomAt(Offset focalScreen, double factor) {
    final Offset anchor = screenToWorld(focalScreen);
    final double next = (_scale * factor).clamp(minScale, maxScale);
    // 已在缩放极限：不改状态，也就没必要让各层重绘。
    if (next == _scale) return;
    _scale = next;
    // worldToScreen(anchor) == focalScreen ⇒ t = focal - anchor * scale
    _translation = focalScreen - anchor * _scale;
    revision++;
  }

  void setScaleAt(Offset focalScreen, double scale) =>
      zoomAt(focalScreen, scale / _scale);

  /// 把世界矩形 [world] 装进视口（居中，四周留 [padding] 屏幕像素）。
  void fit(Rect world, Size viewport, {double padding = 24}) {
    if (world.isEmpty || viewport.isEmpty) return;
    final double usableW = viewport.width - padding * 2;
    final double usableH = viewport.height - padding * 2;
    if (usableW <= 0 || usableH <= 0) return;
    final double nextScale = math
        .min(usableW / world.width, usableH / world.height)
        .clamp(minScale, maxScale);
    final Offset nextTranslation =
        Offset(viewport.width / 2, viewport.height / 2) -
        world.center * nextScale;
    if (nextScale == _scale && nextTranslation == _translation) return;
    _scale = nextScale;
    _translation = nextTranslation;
    revision++;
  }

  /// 序列化（相机 = 视口状态，重载时还原"看哪、放大多少"）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'scale': scale,
    'translation': <double>[translation.dx, translation.dy],
    'minScale': minScale,
    'maxScale': maxScale,
  };

  /// 反序列化。
  factory CanvasCamera.fromJson(Map<String, dynamic> j) => CanvasCamera(
    scale: (j['scale'] as num).toDouble(),
    translation: Offset(
      ((j['translation'] as List)[0] as num).toDouble(),
      ((j['translation'] as List)[1] as num).toDouble(),
    ),
    minScale: (j['minScale'] as num?)?.toDouble() ?? 0.05,
    // ⚠️ 钳到天花板：旧存档写的是 32，不钳的话"上限 400%"对它们无效。
    maxScale: math.min(
      (j['maxScale'] as num?)?.toDouble() ?? maxScaleCeiling,
      maxScaleCeiling,
    ),
  );
}
