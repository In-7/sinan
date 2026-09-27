import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// **窗口底的噪点纹理**（`docs/ui_rewrite_plan.md` §5.6：方妗?2 + 3 是配对）銆?
///
/// ## 为什么它值得存在（不是审美，是功能）
/// 鈶?**消色甯?*锛?-bit 色深下极淡渐变（我们只跨 ~4%锛?*必然**出现一圈圈 banding锛?
///    噪点把它抖掉——这是最硬的价值；鈶?娑?数字塑料鎰?；③ 材质级的细节感€?
///
/// ## 三条硬约束（越一条就立刻廉价锛?
/// - 强度 **< 5%**（暗 3% / 浜?1.5%，见 `AppTheme.windowNoiseAlpha`），超过灏?鑴?锛?
/// - 颗粒**单色**（不是彩色），且鐢?[grain] 按明暗选白/黑（黑粒在近黑底上看不见）；
/// - **鎸?DPR 1:1**：颗绮?= 1 设备像素；放大成"浜?就废了€?
///
/// ## 为什么运行时生成、且种子固定
/// 不往仓库提交 PNG（本项目不放二进制资源）；固定种瀛?鈬?每次启动颗粒**完全一鑷?*
/// （否则会"闂?）。成本：启动后生成一次（几十微秒级），绘制是一次平铺，
/// **鏃?saveLayer、无模糊**（红线不碰）銆?
///
/// ## 用法：只能铺鍦?*窗口搴?*
/// 它必须在内容**之下**（见 `main.dart` 鐨?`builder`）——这样不透明页面（纸面）
/// 会自然盖住它，不会给正文添颗粒感銆?
class NoiseTexture extends StatelessWidget {
  const NoiseTexture({super.key, required this.intensity, required this.grain});

  /// 颗粒最澶?alpha锛?鈥?）€?
  final double intensity;

  /// 颗粒颜色：暗色底用白粒，亮色底用黑粒銆?
  final Color grain;

  /// 一寮?tile 的逻辑边长（会鎸?DPR 换成整数设备像素生成，保璇?1:1）€?
  static const double _tileLogical = 128;

  @override
  Widget build(BuildContext context) {
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final int px = (_tileLogical * dpr).round().clamp(32, 512);

    return FutureBuilder<ui.Image>(
      future: _noiseImage(px, intensity, grain),
      builder: (BuildContext context, AsyncSnapshot<ui.Image> snapshot) {
        final ui.Image? image = snapshot.data;
        // 还没生成好（启动后几十微秒）：就是纯渐变底，不闪不跳銆?
        if (image == null) return const SizedBox.expand();
        return CustomPaint(
          painter: _NoisePainter(image: image, tileLogical: _tileLogical),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

/// 缓存：同一 (设备边长, 强度, 颗粒鑹? 只生成一次€?
final Map<(int, int, Color), Future<ui.Image>> _noiseCache =
    <(int, int, Color), Future<ui.Image>>{};

Future<ui.Image> _noiseImage(int px, double intensity, Color grain) =>
    _noiseCache.putIfAbsent((
      px,
      (intensity * 1000).round(),
      grain,
    ), () => _generateNoise(px, intensity, grain));

Future<ui.Image> _generateNoise(int px, double intensity, Color grain) {
  // 固定种子：颗粒每次启动完全一致（否则浼?闂?）€?
  final math.Random rnd = math.Random(0x51A9);
  final int maxAlpha = (intensity * 255).round().clamp(0, 255);
  // 白粒/黑粒的基色：**预乘**写法（白 = a,a,a,a；黑 = 0,0,0,a）—€?
  // 这样无论 `rgba8888` 被按预乘还是直通解释，观感都不会跑到另一头去銆?
  final int base = grain == Colors.white ? 1 : 0;

  final Uint8List bytes = Uint8List(px * px * 4);
  for (int i = 0; i < px * px; i++) {
    final int a = maxAlpha == 0 ? 0 : rnd.nextInt(maxAlpha + 1);
    final int v = base == 1 ? a : 0;
    bytes[i * 4] = v;
    bytes[i * 4 + 1] = v;
    bytes[i * 4 + 2] = v;
    bytes[i * 4 + 3] = a;
  }

  final Completer<ui.Image> done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bytes,
    px,
    px,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return done.future;
}

class _NoisePainter extends CustomPainter {
  const _NoisePainter({required this.image, required this.tileLogical});

  final ui.Image image;
  final double tileLogical;

  @override
  void paint(Canvas canvas, Size size) {
    // 一寮?tile 鐨?*逻辑**边长固定 鈬?scale 鍙?image.width / tileLogical锛?
    // 于是 tile 的每个像素正好落鍦?1 个设备像素上（DPR 变化也不糊）銆?
    // `repeat` 在整鍧?rect 上平铺；`filterQuality.none` 保证颗粒不被插值糊掉€?
    paintImage(
      canvas: canvas,
      rect: Offset.zero & size,
      image: image,
      scale: image.width / tileLogical,
      repeat: .repeat,
      filterQuality: .none,
    );
  }

  @override
  bool shouldRepaint(covariant _NoisePainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.tileLogical != tileLogical;
}
