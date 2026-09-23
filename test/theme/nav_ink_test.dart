import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/theme/apca.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/nav_ink.dart';

/// **导航列水墨底**的闸门（2026-09-23）。
///
/// 架构：数学全在 Dart（`nav_ink.dart`），shader 只采样 Dart 烘焙的 LUT + 抖动
/// （第一版把噪声写进 GLSL 用了 uint ⇒ impellerc SIGABRT，SkSL 不支持无符号整数）。
/// ⇒ 闸门能钉的：
/// 1. **shader 保持极小且 SkSL 兼容**（不许把数学搬回 GLSL / 不许用 uint）；
/// 2. **同 pass 抖动还在**（删了就出色带，本仓实测独立噪点层治不了）；
/// 3. **釉是低彩度的自然色**（彩度一高就撞文字对比度闸门；上限 12%，实测判）；
/// 4. **灰阶底上的文字对比度**（沿整列密采样取最差点）；
/// 5. **"主白 / 主黑"**（水墨的前提是留白为主，别让墨铺满）。
void main() {
  final String frag = File('assets/shaders/nav_ink.frag').readAsStringSync();
  // ⚠️ 只查**代码**（去掉注释）：注释里提到"uint"这个词没关系，编译器不看注释。
  final String code = frag.replaceAll(RegExp(r'//[^\n]*'), '');

  test('shader 保持极小：只许采样 + 抖动（数学在 Dart，见 nav_ink.dart）', () {
    expect(code.contains('uniform sampler2D uLut'), isTrue);
    // ⚠️ uint / 位运算会撞 SkSL（impellerc SIGABRT，实测）⇒ 禁止回流：
    expect(code.contains('uint'), isFalse, reason: 'SkSL 不支持无符号整数');
    expect(
      code.contains('(ign(coord * uDpr) - 0.5) / 255.0'),
      isTrue,
      reason: '同 pass 抖动没了 ⇒ 晕染边缘出色带（独立噪点层治不了，实测）',
    );
    expect(NavInk.dither, closeTo(1 / 255, 1e-9));
  });

  test('釉是低彩度的自然色（RGB 极差 ≤ 12%）', () {
    // 2026-09-23：从"无彩暖灰（≤5%）"放宽到"苔石 / 青瓷（≤12%）"——用户要自然
    // 材质触感。放宽的**许可范围**就是这 12%：再高就撞上下面那两条 APCA 闸门
    // （历史教训：彩色 mesh 方案死在紫斑的 2.7:1）。所以彩度这条**不能删**，
    // 只能调档，而且调完必须看下面 print 出来的 Lc 是否还过。
    for (final Color c in <Color>[
      NavInk.inkLight,
      NavInk.inkDeepLight,
      NavInk.inkDark,
      NavInk.inkDeepDark,
    ]) {
      final double spread =
          math.max(math.max(c.r, c.g), c.b) - math.min(math.min(c.r, c.g), c.b);
      expect(
        spread,
        lessThanOrEqualTo(0.12),
        reason: '${c.toARGB32()} 彩度过高 ⇒ 底变彩底，文字对比度要重新过闸',
      );
    }
  });

  for (final Brightness b in Brightness.values) {
    test('$b：水墨底上主 / 次文字都过档 + 以${b == Brightness.light ? "白" : "黑"}为主', () {
      final scheme =
          (b == Brightness.light ? AppTheme.light() : AppTheme.dark())
              .colorScheme;
      final Color base = AppTheme.windowBackground(b);
      final Color ink = b == Brightness.light
          ? NavInk.inkLight
          : NavInk.inkDark;

      double minPrimary = 1000;
      double minSecondary = 1000;
      double sumWash = 0;
      int n = 0;

      // 导航列窄高（aspect ≈ 0.275）；水墨逐像素变化 ⇒ 采样要密。
      for (int iv = 0; iv <= 48; iv++) {
        for (int iu = 0; iu <= 8; iu++) {
          final Color bg = NavInk.colorAt(u: iu / 8, v: iv / 48, brightness: b);
          minPrimary = math.min(minPrimary, apcaLc(scheme.onSurface, bg).abs());
          minSecondary = math.min(
            minSecondary,
            apcaLc(scheme.onSurfaceVariant, bg).abs(),
          );
          sumWash +=
              (bg.r - base.r).abs() / math.max((ink.r - base.r).abs(), 1e-4);
          n++;
        }
      }

      final double meanWash = sumWash / math.max(n, 1);
      // ignore: avoid_print
      print(
        '[nav_ink][$b] 最差：主文字 Lc ${minPrimary.toStringAsFixed(1)}'
        ' / 次文字 Lc ${minSecondary.toStringAsFixed(1)}'
        ' / 平均晕染 ${(meanWash * 100).toStringAsFixed(1)}%',
      );

      expect(minPrimary, greaterThanOrEqualTo(65), reason: '$b：主文字掉档');
      expect(minSecondary, greaterThanOrEqualTo(60), reason: '$b：次文字掉档');
      expect(
        meanWash,
        lessThan(0.5),
        reason:
            '$b：平均晕染 ${(meanWash * 100).toStringAsFixed(0)}% ⇒ "主'
            '${b == Brightness.light ? "白" : "黑"}"不成立（水墨的前提是留白为主）',
      );
    });
  }

  test('LUT 按主题烘焙（尺寸与预设一致；测试环境装不了就跳过）', () async {
    await NavInk.preload();
    final ui.Image? lut = NavInk.lutFor(Brightness.light);
    if (lut == null) {
      // ignore: avoid_print
      print('[nav_ink] 测试环境未装载 shader/LUT ⇒ 跳过尺寸断言');
      return;
    }
    expect(lut.width, NavInk.lutWidth);
    expect(lut.height, NavInk.lutHeight);
    expect(NavInk.lutFor(Brightness.dark), isNotNull);
  });
}
