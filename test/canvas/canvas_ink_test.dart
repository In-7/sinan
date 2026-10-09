import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_raster.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 「墨色跟随主题」的回归（2026-09-17）。
///
/// ## 修的是什么
/// 画布底色**随主题**（`AppTheme.contentCanvas`：亮 `#DDDDDB` / 暗 `#161616`），
/// 而笔色曾是内核里写死的 `#1F1F1F`——暗色下就是"黑墨画黑纸"，用户截图里
/// `#1F1F1F` 压在 `#161616` 上几乎不可识别。
///
/// ## 修法
/// [kThemeInk] 哨兵：颜色等于它的笔迹按**宿主给的当前墨色**绘制。存量画布里的
/// 笔迹恰好全是这个值（当时**没有取色器**），所以**不需要任何数据迁移**。
///
/// ## 本文件钉住四件事
/// 1. 亮色墨色 **== 哨兵**：否则亮色渲染会变，存量画布观感回归；
/// 2. [resolveInk] 只替换哨兵色，用户自选色原样保留（将来加取色器不能误伤）；
/// 3. 新笔迹默认取哨兵（否则新画的东西在暗色下还是看不见）；
/// 4. 离屏栅格化（导出 / AI 输入）**白纸黑墨**，与界面主题无关——否则暗色下
///    浅墨铺白底就是一张空图。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('亮色墨色 == 哨兵：存量画布在亮色下渲染逐像素不变', () {
    expect(
      AppTheme.canvasInk(Brightness.light),
      kThemeInk,
      reason: '亮色档一旦不等于哨兵，存量画布的观感就被这次改动静默改掉了',
    );
    expect(
      AppTheme.canvasInk(Brightness.dark),
      isNot(kThemeInk),
      reason: '暗色档必须离开哨兵，否则暗色下仍是"黑墨画黑纸"',
    );
  });

  test('暗色墨色对暗色纸面有足够对比（不是"看起来换了个色"而已）', () {
    expect(
      _contrastRatio(
        AppTheme.canvasInk(Brightness.dark),
        AppTheme.contentCanvas(Brightness.dark),
      ),
      greaterThan(7),
      reason: '对比度不足 7:1 就谈不上"可识别"（AAA 正文标准）',
    );
  });

  test('resolveInk：只替换哨兵色，用户自选色原样保留', () {
    const Color picked = Color(0xFFCC0000); // 将来取色器可能选中的红
    const Color darkInk = Color(0xFFD6D6D6);
    expect(resolveInk(kThemeInk, darkInk), darkInk);
    expect(resolveInk(picked, darkInk), picked);
  });

  test('新笔迹默认取哨兵（跟随主题）', () {
    final CanvasController controller = CanvasController();
    expect(controller.penColor, kThemeInk);
    controller.dispose();
  });

  test('离屏栅格化白纸黑墨：墨色不随界面主题走', () async {
    final CanvasDocument doc = CanvasDocument()
      ..addStroke(
        InkStroke(
          color: kThemeInk, // 哨兵色：应当被解析成"传入的墨色"
          baseWidth: 8,
          points: const <InkPoint>[
            InkPoint(Offset(0, 2), 0),
            InkPoint(Offset(20, 2), 0),
            InkPoint(Offset(40, 2), 0),
          ],
        ),
      );
    const Rect world = Rect.fromLTWH(0, 0, 40, 4);

    // 默认口径（导出 / AI 输入）：白底 ⇒ 中心像素是**墨色**。
    final ui.Image printed = await _decode(await rasterizeRegion(doc, world));
    expect(
      await _centerLuminance(printed),
      lessThan(0.3),
      reason: '默认没走近黑墨：白底上导出出来的图会淡到看不见',
    );
    printed.dispose();

    // 显式传暗色档墨色 ⇒ 中心像素确实变浅（这正是"浅墨铺白底"的成因，
    // 也是导出必须自录、不能复用界面那张 Picture 的原因）。
    final ui.Image themed = await _decode(
      await rasterizeRegion(
        doc,
        world,
        inkColor: AppTheme.canvasInk(Brightness.dark),
      ),
    );
    expect(await _centerLuminance(themed), greaterThan(0.7));
    themed.dispose();
  });
}

Future<ui.Image> _decode(Uint8List bytes) {
  final Completer<ui.Image> completer = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, completer.complete);
  return completer.future;
}

/// 中心像素的亮度（0~1）。
Future<double> _centerLuminance(ui.Image img) async {
  // 不传 format：`ImageByteFormat.rawRgba` 本就是默认值（lint 会拦冗余实参）。
  final ByteData data = (await img.toByteData())!;
  final int offset = ((img.height ~/ 2) * img.width + img.width ~/ 2) * 4;
  final int r = data.getUint8(offset);
  final int g = data.getUint8(offset + 1);
  final int b = data.getUint8(offset + 2);
  return (r + g + b) / 3 / 255;
}

/// WCAG 相对亮度对比度（"底色 vs 墨色是否看得见"的量化判据）。
double _contrastRatio(Color a, Color b) {
  final double la = _relativeLuminance(a);
  final double lb = _relativeLuminance(b);
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

double _relativeLuminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

double _channel(double v) => v <= 0.03928
    ? v / 12.92
    : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
