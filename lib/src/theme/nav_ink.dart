import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'app_theme.dart';

/// 导航列的**青瓷釉底**（2026-09-23 用户定）：
/// 亮色 = 主白纸 + 淡青瓷釉；暗色 = 主黑纸 + 亮青瓷釉（同一套数学，只换釉色）。
/// 形态 = **纵向平滑渐变 + 极淡颗粒**（见 [fieldAt]），不再是墨洇的块面。
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
/// ## ⚠️ 釉是**低彩度**的（自然材质色，不是鲜艳色）
/// 2026-09-23 由无彩暖灰改为**苔石 / 青瓷**：用户要"自然材质触感"，但彩度必须
/// **压住**——导航列上要放主 / 次两级文字，彩底一浓就掉对比度（彩色 mesh 方案
/// 当年就死在紫斑的 2.7:1 上）。现行口径：RGB 分量极差 ≤ 12%，由闸门
/// `nav_ink_test.dart` 钉着。**改色后必须跑那两条 APCA 闸门**（主 Lc≥65 / 次 Lc≥60）——
/// 色值能不能用是**实测**判的，不是看色号能断的。
abstract final class NavInk {
  static const String assetKey = 'assets/shaders/nav_ink.frag';

  // ── 形状常数（LUT 由它们烘焙；闸门断言行为，不比对 .frag 文本） ──────────────
  // 形态（2026-09-23 由"fBm 墨洇"改为"纵向渐变 + 极淡颗粒"）：
  static const double gradTop = 0.30; // 渐变起点（v 小于它 = 纯纸色 ⇒ 顶部留白）
  static const double gradBottom = 1.0; // 渐变终点（1.0 ⇒ 满釉只出现在底边）
  static const double grainScale = 3.2; // 颗粒噪声缩放（越大颗粒越细密）
  static const double grain = 0.10; // 颗粒幅度（**极淡**：只做材质触感，不成墨块）
  static const double offsetX = 11.3; // 噪声种子偏移（想换颗粒花样就改这两个）
  static const double offsetY = 7.7;
  static const double wash0 = 0.30; // 上釉下阈（低于它 = 纸；上调 ⇒ 留白更多）
  static const double wash1 = 1.0; // 上釉上阈（高于它 = 满釉）
  static const double deep0 = 0.72; // 积釉下阈（收窄覆盖：只压底部，给文字留余量）
  static const double deep1 = 1.0; // 积釉上阈
  static const double deepStrength = 0.45; // 积釉最深也只到浓釉的 45%
  static const double dither = 1 / 255; // 抖动幅度（±0.5 级）

  /// 设计基准纵横比（列宽 / 列高 ≈ 220/800）。
  /// LUT 按它烘焙 ⇒ 实际窗口高度变化时墨纹会轻微拉伸（壁纸同款行为，接受）。
  static const double designAspect = 220 / 800;

  /// LUT 分辨率：要盖住最小的墨纹特征（≈30 设备 px）绰绰有余。
  static const int lutWidth = 128;
  static const int lutHeight = 512;

  // ── 釉色（**苔石 / 青瓷**：低彩度自然色，明暗两套）────────────────────────
  // 亮色：纸 = 窗口底 #F8F8F6；釉比纸深 ⇒ "白纸淡青瓷"。
  // 暗色：纸 = #171715；釉比纸浅 ⇒ "黑纸亮青瓷"（别取太亮：暗色的次文字是**浅色**，
  // 面越亮对比越差，实测可用上限在 L\* 30 附近）。
  // ⚠️ 改这四个值后**必须**跑 `test/theme/nav_ink_test.dart`：彩度上限（12%）与两条
  // APCA 闸门（主 65 / 次 60）全是实测判的，看色号断不出来。
  static const Color inkLight = Color(0xFFCFDCD0); // 淡釉（青瓷）
  static const Color inkDeepLight = Color(0xFFB4C9B7); // 浓釉
  static const Color inkDark = Color(0xFF2A332B); // 亮釉（暗色）
  // #333E36（比初版 #37443A 压暗一档）：暗色的次文字是**浅色**，积釉越亮对比越差
  // ——初版实测次文字 Lc 62.5（门槛 60，余量只有 2.5）。压暗后余量翻倍，
  // 视觉上这一档几乎看不出来。
  static const Color inkDeepDark = Color(0xFF333E36); // 亮浓釉

  static final Map<Brightness, ui.Image> _lut = <Brightness, ui.Image>{};
  static ui.FragmentProgram? _program;
  static bool _loadFailed = false;

  /// **就绪信号**：shader + 两套主题 LUT 都烘焙完后翻 `true`。
  ///
  /// ## 为什么要有它（2026-09-23 的"打开要点一下才出来"）
  /// [preload] 是 `unawaited` 的、在 `runApp` 之后才异步完成；而 [HubNav] 只在
  /// `build` 时读一次 [painter]。preload 完成前首帧拿到的是 `null`（回退实色底），
  /// 完成后**没有任何 setState 会把它重新读出** ⇒ 必须靠点击触发某次重建釉面才出现。
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
    // 通知调用方重绘：首帧若已画过回退底，此刻才把釉面 painter 接上。
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

  /// 画釉面的 painter；**未就绪返回 null**（调用方用实色兜底）。
  static CustomPainter? painter(Brightness brightness) =>
      (_program == null || lutFor(brightness) == null)
      ? null
      : NavInkPainter(brightness);

  // ── 釉面数学（闸门测的就是这一份；shader 只采样它烘焙出来的 LUT） ────────────

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

  /// 釉场（0..1，越大越"该上釉"）：**纵向渐变 + 极淡颗粒**。
  ///
  /// 2026-09-23 由"fBm + 域扭曲 + 墨势"换成这套：用户反馈墨洇勾连的轮廓"怪异"，
  /// 要的是**材质渐变**而不是墨块。主体现在是沿 v 的一条平滑斜坡——像青瓷釉
  /// 自上而下**积釉**，越靠底越浓；fBm 只剩 ±[grain] 的极淡调制，保留一点材质
  /// 颗粒感，但不再形成可辨认的墨块形状（域扭曲 `warp` 就是勾连的来源，已去除）。
  static double fieldAt({
    required double u,
    required double v,
    double aspect = designAspect,
  }) {
    final double grad = _smoothstep(gradTop, gradBottom, v);
    final double px = u * aspect * grainScale + offsetX;
    final double py = v * grainScale + offsetY;
    final double noise = _fbm(px, py) - 0.5; // 居中，避免把整条渐变整体推亮/推暗
    return (grad + noise * grain).clamp(0.0, 1.0);
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

/// 把釉面 shader 铺满给定区域（导航列用）。圆角裁切由调用方负责。
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
