import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'app_theme.dart';

/// 导航列的**水墨底**（2026-09-23 用户定）：
/// 亮色 = 主白纸 + 淡墨晕染；暗色 = 主黑纸 + 亮墨晕染（同一套数学，只换墨色）。
///
/// ## 架构：数学在 Dart，渲染走 LUT
/// 形状数学（fBm 分形噪声 + 域扭曲 + 阈值晕染）**全部在本文件**，`preload()` 时按
/// 主题烘焙成一张低分辨率 LUT（`ui.Image`，最终颜色）；shader 只做"采样 + 抖动"。
/// 这样安排的三个理由：
/// 1. **单一事实来源**：对比度闸门直接测这里的数学（GLSL 在测试里编译不了）；
/// 2. **SkSL 兼容**：第一版把噪声写在 GLSL 里、用了 uint 位运算 ⇒ impellerc 直接
///    SIGABRT（SkSL 不支持无符号整数）；
/// 3. LUT 的双线性采样会平均相邻值 ⇒ 残余台阶进一步被抹平。
///
/// ## ⚠️ 噪声 hash 必须用整数运算
/// GLSL float32 与 Dart double 对不上 ⇒ sin 大数 hash 的镜像会失真。这里用
/// **uint32 回绕的整数 hash**，Dart 侧每步 `& 0xFFFFFFFF` ⇒ 与 GLSL 逐位一致
/// （虽然现在数学只在 Dart，闸门仍钉着这条，防止未来有人把它挪回 GLSL）。
///
/// ## ⚠️ 墨是**无彩色**的（R≈G≈B 暖灰）
/// 灰阶底上明暗两种文字都好过档（彩色 mesh 方案就死在紫斑的 2.7:1 上）。
/// **别把墨色调成带彩色的**——闸门里有一条专门拦这个。
abstract final class NavInk {
  static const String assetKey = 'assets/shaders/nav_ink.frag';

  // ── 形状常数（LUT 由它们烘焙；闸门断言行为，不比对 .frag 文本） ──────────────
  static const double scale = 2.4; // 噪声缩放：越小墨块越大越醒目（2026-09-23 加浓）
  static const double warp = 2.2; // 域扭曲强度（略增，墨洇勾连更明显）
  static const double offsetX = 11.3; // 种子偏移（想换花样就改这两个 + 重跑闸门）
  static const double offsetY = 7.7;
  static const double flowX = 0.5; // 墨势中心（uv）
  static const double flowY = 0.72;
  static const double flowRadius = 0.92;
  static const double wash0 = 0.28; // 晕染下阈（低于它 = 纸；下调 ⇒ 墨铺得更开）
  static const double wash1 = 0.66; // 晕染上阈（高于它 = 全染）
  static const double deep0 = 0.48; // 浓墨下阈（收窄覆盖，给暗色次文字留余量）
  static const double deep1 = 0.82; // 浓墨上阈
  static const double deepStrength = 0.90;
  static const double dither = 1 / 255; // 抖动幅度（±0.5 级）

  /// 设计基准纵横比（列宽 / 列高 ≈ 220/800）。
  /// LUT 按它烘焙 ⇒ 实际窗口高度变化时墨纹会轻微拉伸（壁纸同款行为，接受）。
  static const double designAspect = 220 / 800;

  /// LUT 分辨率：要盖住最小的墨纹特征（≈30 设备 px）绰绰有余。
  static const int lutWidth = 128;
  static const int lutHeight = 512;

  // ── 墨色（**无彩色暖灰**，明暗两套）────────────────────────────────────────
  // 亮色：纸 = 窗口底 #F8F8F6；墨比纸深 ⇒ "白纸淡墨"。
  // 暗色：纸 = #171715；墨比纸浅 ⇒ "黑纸亮墨"（用户口径的"白色墨染"是亮灰，不是纯白
  // ——纯白上浅色文字过不了闸门，实测 9:1 的上限在 #3A 附近）。
  static const Color inkLight = Color(0xFFD4D3CB); // 淡墨（晕染，2026-09-23 加深）
  static const Color inkDeepLight = Color(0xFFBAB9B0); // 浓墨
  static const Color inkDark = Color(0xFF3C3C39); // 亮墨（晕染，加深）
  static const Color inkDeepDark = Color(0xFF4E4E4B); // 亮浓墨

  static final Map<Brightness, ui.Image> _lut = <Brightness, ui.Image>{};
  static ui.FragmentProgram? _program;
  static bool _loadFailed = false;

  /// **就绪信号**：shader + 两套主题 LUT 都烘焙完后翻 `true`。
  ///
  /// ## 为什么要有它（2026-09-23 的"打开要点一下才出来"）
  /// [preload] 是 `unawaited` 的、在 `runApp` 之后才异步完成；而 [HubNav] 只在
  /// `build` 时读一次 [painter]。preload 完成前首帧拿到的是 `null`（回退实色底），
  /// 完成后**没有任何 setState 会把它重新读出** ⇒ 必须靠点击触发某次重建水墨才出现。
  /// 这里翻一下，[HubNav] 订阅它即可自动重绘接上 painter，无需用户点击。
  static final ValueNotifier<bool> readyNotifier = ValueNotifier<bool>(false);

  /// shader 与 LUT 是否都已就位（未就位时 [painter] 返回 null ⇒ 走实色回退）。
  static bool get ready =>
      _program != null && _lut.containsKey(Brightness.values.first);

  /// 预装载（在 `main()` 里调一次；失败只记一次，不重试到烦）。
  static Future<void> preload() async {
    if (_program == null && !_loadFailed) {
      try {
        _program = await ui.FragmentProgram.fromAsset(assetKey);
      } on Object catch (error) {
        _loadFailed = true;
        debugPrint('[nav_ink] shader 装载失败 ⇒ 回退实色底：$error');
        return;
      }
    }
    for (final Brightness b in Brightness.values) {
      if (!_lut.containsKey(b)) {
        _lut[b] = await _buildLut(b);
      }
    }
    // 通知调用方重绘：首帧若已画过回退底，此刻才把水墨 painter 接上。
    readyNotifier.value = true;
  }

  static ui.Image? lutFor(Brightness brightness) => _lut[brightness];

  /// 按主题烘焙 LUT：逐像素调用 [colorAt]（与闸门同一份数学）写进 RGBA 缓冲。
  static Future<ui.Image> _buildLut(Brightness brightness) async {
    final Uint8List data = Uint8List(lutWidth * lutHeight * 4);
    int i = 0;
    for (int y = 0; y < lutHeight; y++) {
      for (int x = 0; x < lutWidth; x++) {
        final Color c = colorAt(
          u: (x + 0.5) / lutWidth,
          v: (y + 0.5) / lutHeight,
          brightness: brightness,
        );
        data[i++] = (c.r * 255).round();
        data[i++] = (c.g * 255).round();
        data[i++] = (c.b * 255).round();
        data[i++] = 255;
      }
    }
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      data,
    );
    final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: lutWidth,
      height: lutHeight,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final ui.Codec codec = await descriptor.instantiateCodec();
    final ui.FrameInfo frame = await codec.getNextFrame();
    return frame.image;
  }

  /// 画水墨的 painter；**未就绪返回 null**（调用方用实色兜底）。
  static CustomPainter? painter(Brightness brightness) =>
      (_program == null || lutFor(brightness) == null)
      ? null
      : NavInkPainter(brightness);

  // ── 水墨数学（闸门测的就是这一份；shader 只采样它烘焙出来的 LUT） ────────────

  /// 整数 hash（uint32 回绕；负坐标经补码自然回绕）。
  static int _uhash(int qx, int qy) {
    int u = (qx * 3933493697 + qy * 842502087 + 0x9E3779B9) & 0xFFFFFFFF;
    u ^= u >> 15;
    u = (u * 0x2C1B3C6D) & 0xFFFFFFFF;
    u ^= u >> 12;
    u = (u * 0x297A2D39) & 0xFFFFFFFF;
    u ^= u >> 15;
    return u;
  }

  static double _vhash(int qx, int qy) => _uhash(qx, qy) / 4294967295.0;

  static double _vnoise(double x, double y) {
    final int ix = x.floor();
    final int iy = y.floor();
    final double fx = x - ix;
    final double fy = y - iy;
    final double ux = fx * fx * (3 - 2 * fx);
    final double uy = fy * fy * (3 - 2 * fy);
    final double a = _vhash(ix, iy);
    final double b = _vhash(ix + 1, iy);
    final double c = _vhash(ix, iy + 1);
    final double d = _vhash(ix + 1, iy + 1);
    return (a + (b - a) * ux) * (1 - uy) + (c + (d - c) * ux) * uy;
  }

  static double _fbm(double x, double y) {
    double v = 0;
    double a = 0.5;
    double px = x;
    double py = y;
    for (int i = 0; i < 4; i++) {
      v += a * _vnoise(px, py);
      px = px * 2.03 + 17.17;
      py = py * 2.03 + 17.17;
      a *= 0.5;
    }
    return v / 0.9375;
  }

  /// 墨场（0..1，越大越"该染"）：fBm + **域扭曲** + 墨势。
  /// 域扭曲是"无规则染色"的关键——等值线弯折勾连，才像墨洇而不是椭圆噪点。
  static double fieldAt({
    required double u,
    required double v,
    double aspect = designAspect,
  }) {
    final double px = u * aspect * scale + offsetX;
    final double py = v * scale + offsetY;
    final double qx = _fbm(px, py);
    final double qy = _fbm(px + 5.2, py + 1.3);
    final double f = _fbm(px + warp * qx, py + warp * qy);
    final double dx = (u - flowX) * aspect;
    final double dy = v - flowY;
    final double flow = (1 - math.sqrt(dx * dx + dy * dy) / flowRadius).clamp(
      0.0,
      1.0,
    );
    return f * 0.72 + flow * 0.28;
  }

  static double _smoothstep(double e0, double e1, double x) {
    final double t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  /// 该点的最终颜色（不含 ±0.5 级抖动 —— 对对比度的影响 <1 LSB，闸门忽略）。
  static Color colorAt({
    required double u,
    required double v,
    required Brightness brightness,
    double aspect = designAspect,
  }) {
    final bool dark = brightness == Brightness.dark;
    final Color ink = dark ? inkDark : inkLight;
    final Color inkDeep = dark ? inkDeepDark : inkDeepLight;
    final double f = fieldAt(u: u, v: v, aspect: aspect);
    final double wash = _smoothstep(wash0, wash1, f);
    final double deep = _smoothstep(deep0, deep1, f) * deepStrength;

    final Color base = AppTheme.windowBackground(brightness);
    final Color first = Color.lerp(base, ink, wash)!;
    return Color.lerp(first, inkDeep, deep)!;
  }
}

/// 把水墨 shader 铺满给定区域（导航列用）。圆角裁切由调用方负责。
class NavInkPainter extends CustomPainter {
  NavInkPainter(this.brightness);

  final Brightness brightness;

  ui.FragmentShader? _shader;

  @override
  void paint(Canvas canvas, Size size) {
    final ui.FragmentProgram? program = NavInk._program;
    final ui.Image? lut = NavInk.lutFor(brightness);
    if (program == null || lut == null || size.isEmpty) return;

    final ui.FragmentShader shader = _shader ??= program.fragmentShader();
    final double dpr = ui.PlatformDispatcher.instance.views.isEmpty
        ? 1.0
        : ui.PlatformDispatcher.instance.views.first.devicePixelRatio;

    shader.setImageSampler(0, lut);
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, dpr);

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant NavInkPainter oldDelegate) =>
      oldDelegate.brightness != brightness;
}
