import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// **绐楀彛搴曠殑鍣偣绾圭悊**锛坄docs/ui_rewrite_plan.md` 搂5.6锛氭柟妗?2 + 3 鏄厤瀵癸級銆?
///
/// ## 涓轰粈涔堝畠鍊煎緱瀛樺湪锛堜笉鏄缇庯紝鏄姛鑳斤級
/// 鈶?**娑堣壊甯?*锛?-bit 鑹叉繁涓嬫瀬娣℃笎鍙橈紙鎴戜滑鍙法 ~4%锛?*蹇呯劧**鍑虹幇涓€鍦堝湀 banding锛?
///    鍣偣鎶婂畠鎶栨帀鈥斺€旇繖鏄渶纭殑浠峰€硷紱鈶?娑?鏁板瓧濉戞枡鎰?锛涒憿 鏉愯川绾х殑缁嗚妭鎰熴€?
///
/// ## 涓夋潯纭害鏉燂紙瓒婁竴鏉″氨绔嬪埢寤変环锛?
/// - 寮哄害 **< 5%**锛堟殫 3% / 浜?1.5%锛岃 `AppTheme.windowNoiseAlpha`锛夛紝瓒呰繃灏?鑴?锛?
/// - 棰楃矑**鍗曡壊**锛堜笉鏄僵鑹诧級锛屼笖鐢?[grain] 鎸夋槑鏆楅€夌櫧/榛戯紙榛戠矑鍦ㄨ繎榛戝簳涓婄湅涓嶈锛夛紱
/// - **鎸?DPR 1:1**锛氶绮?= 1 璁惧鍍忕礌锛涙斁澶ф垚"浜?灏卞簾浜嗐€?
///
/// ## 涓轰粈涔堣繍琛屾椂鐢熸垚銆佷笖绉嶅瓙鍥哄畾
/// 涓嶅線浠撳簱鎻愪氦 PNG锛堟湰椤圭洰涓嶆斁浜岃繘鍒惰祫婧愶級锛涘浐瀹氱瀛?鈬?姣忔鍚姩棰楃矑**瀹屽叏涓€鑷?*
/// 锛堝惁鍒欎細"闂?锛夈€傛垚鏈細鍚姩鍚庣敓鎴愪竴娆★紙鍑犲崄寰绾э級锛岀粯鍒舵槸涓€娆″钩閾猴紝
/// **鏃?saveLayer銆佹棤妯＄硦**锛堢孩绾夸笉纰帮級銆?
///
/// ## 鐢ㄦ硶锛氬彧鑳介摵鍦?*绐楀彛搴?*
/// 瀹冨繀椤诲湪鍐呭**涔嬩笅**锛堣 `main.dart` 鐨?`builder`锛夆€斺€旇繖鏍蜂笉閫忔槑椤甸潰锛堢焊闈級
/// 浼氳嚜鐒剁洊浣忓畠锛屼笉浼氱粰姝ｆ枃娣婚绮掓劅銆?
class NoiseTexture extends StatelessWidget {
  const NoiseTexture({super.key, required this.intensity, required this.grain});

  /// 棰楃矑鏈€澶?alpha锛?鈥?锛夈€?
  final double intensity;

  /// 棰楃矑棰滆壊锛氭殫鑹插簳鐢ㄧ櫧绮掞紝浜壊搴曠敤榛戠矑銆?
  final Color grain;

  /// 涓€寮?tile 鐨勯€昏緫杈归暱锛堜細鎸?DPR 鎹㈡垚鏁存暟璁惧鍍忕礌鐢熸垚锛屼繚璇?1:1锛夈€?
  static const double _tileLogical = 128;

  @override
  Widget build(BuildContext context) {
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final int px = (_tileLogical * dpr).round().clamp(32, 512);

    return FutureBuilder<ui.Image>(
      future: _noiseImage(px, intensity, grain),
      builder: (BuildContext context, AsyncSnapshot<ui.Image> snapshot) {
        final ui.Image? image = snapshot.data;
        // 杩樻病鐢熸垚濂斤紙鍚姩鍚庡嚑鍗佸井绉掞級锛氬氨鏄函娓愬彉搴曪紝涓嶉棯涓嶈烦銆?
        if (image == null) return const SizedBox.expand();
        return CustomPaint(
          painter: _NoisePainter(image: image, tileLogical: _tileLogical),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

/// 缂撳瓨锛氬悓涓€ (璁惧杈归暱, 寮哄害, 棰楃矑鑹? 鍙敓鎴愪竴娆°€?
final Map<(int, int, Color), Future<ui.Image>> _noiseCache =
    <(int, int, Color), Future<ui.Image>>{};

Future<ui.Image> _noiseImage(int px, double intensity, Color grain) =>
    _noiseCache.putIfAbsent((
      px,
      (intensity * 1000).round(),
      grain,
    ), () => _generateNoise(px, intensity, grain));

Future<ui.Image> _generateNoise(int px, double intensity, Color grain) {
  // 鍥哄畾绉嶅瓙锛氶绮掓瘡娆″惎鍔ㄥ畬鍏ㄤ竴鑷达紙鍚﹀垯浼?闂?锛夈€?
  final math.Random rnd = math.Random(0x51A9);
  final int maxAlpha = (intensity * 255).round().clamp(0, 255);
  // 鐧界矑/榛戠矑鐨勫熀鑹诧細**棰勪箻**鍐欐硶锛堢櫧 = a,a,a,a锛涢粦 = 0,0,0,a锛夆€斺€?
  // 杩欐牱鏃犺 `rgba8888` 琚寜棰勪箻杩樻槸鐩撮€氳В閲婏紝瑙傛劅閮戒笉浼氳窇鍒板彟涓€澶村幓銆?
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
    // 涓€寮?tile 鐨?*閫昏緫**杈归暱鍥哄畾 鈬?scale 鍙?image.width / tileLogical锛?
    // 浜庢槸 tile 鐨勬瘡涓儚绱犳濂借惤鍦?1 涓澶囧儚绱犱笂锛圖PR 鍙樺寲涔熶笉绯婏級銆?
    // `repeat` 鍦ㄦ暣鍧?rect 涓婂钩閾猴紱`filterQuality.none` 淇濊瘉棰楃矑涓嶈鎻掑€肩硦鎺夈€?
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
