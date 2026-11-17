import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/editor/blocks/block_markers.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';
import 'package:sinan/src/theme/app_theme.dart';

import '../support/app_font.dart';

/// [cjkInkCompensation] / [numberedInkOffset] / [bulletInkOffset] 的**重标定闸门**
/// （换字体这三个数都要回来改）。
///
/// ## 2026-11-18 起是真·墨迹断言
/// 旧文档称 `Picture.toImage` 在 flutter test 里会挂、只能离线标定——2026-11-18
/// 复查**已不复现**（软件光栅化可用）。于是这里直接光栅化扫墨迹带，断言三个
/// 常量与实测值成对；旧的"字体度量指纹"仍保留作廉价的早期报警。
///
/// 量测口径（见 `block_markers.dart` 常量文档）：生产同款样式
/// （[EditorTypography.body] + applyHeight:true/even），墨迹带 = 逐行扫
/// alpha>8 的带域；偏移 =（墨迹中心 − 行盒中心）/ 有效字号，常量 = −偏移。
/// 样本取**实际对齐物**：CJK 基准 / 序号（拉丁+句点）/ 圆点（0.5× 缩放文本）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 光栅化 [text] 扫墨迹带，返回 (墨迹中心 − 行盒中心) / 有效字号。
  Future<double> inkOffset(
    String text, {
    double fs = 200,
    double height = 1.75,
    double scaler = 1.0,
  }) async {
    final EditorTypography ty = EditorTypography(
      fontSize: fs,
      lineHeight: height,
    );
    // 默认 TextHeightBehavior 就是 applyHeight:true/true（= 生产几何，
    // 与排版优化后的正文同款）——显式写会被"冗余默认值"lint 拦，故不写。
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: ty.body()),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.linear(scaler),
    )..layout(maxWidth: fs * 8);
    final LineMetrics m = painter.computeLineMetrics().first;
    // 新几何（applyHeight:true + even）：行盒顶 = baseline − ascent。
    final double boxCenter = (m.baseline - m.ascent) + m.height / 2;

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    painter.paint(canvas, Offset.zero);
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(
      painter.width.ceil() + 2,
      m.height.ceil() + 2,
    );
    final ByteData? data = await image.toByteData(); // 默认即 rawRgba
    final Uint8List px = data!.buffer.asUint8List();
    final int w = image.width;
    int top = -1;
    int bottom = -1;
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < w; x++) {
        if (px[(y * w + x) * 4 + 3] > 8) {
          if (top < 0) top = y;
          bottom = y;
          break;
        }
      }
    }
    expect(top, greaterThanOrEqualTo(0), reason: '「$text」应有墨迹');
    final double inkCenter = (top + bottom + 1) / 2;
    picture.dispose();
    image.dispose();
    painter.dispose();
    return (inkCenter - boxCenter) / (fs * scaler);
  }

  Future<double> avgInk(
    List<String> samples, {
    double height = 1.75,
    double scaler = 1.0,
  }) async {
    double sum = 0;
    for (final String s in samples) {
      sum += await inkOffset(s, height: height, scaler: scaler);
    }
    return sum / samples.length;
  }

  test('字体度量指纹 = 思源黑体 SC VF（变了 ⇒ 重标三个墨迹常量）', () async {
    await loadAppFont();

    const double fs = 200;
    const double height = 1.5;
    final TextPainter painter = TextPainter(
      text: const TextSpan(
        text: '国',
        style: TextStyle(
          fontFamily: AppTheme.editorFont,
          fontSize: fs,
          height: height,
          leadingDistribution: TextLeadingDistribution.even,
          color: Color(0xFF000000),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: fs * 4);

    final LineMetrics m = painter.computeLineMetrics().first;
    final double ascentEm = m.ascent / fs;
    final double descentEm = m.descent / fs;

    // 思源黑体 SC @ height 1.5 的实测指纹（2026-10-24）。
    expect(ascentEm, closeTo(1.186, 0.01), reason: '字体度量变了 ⇒ 重标墨迹补偿');
    expect(descentEm, closeTo(0.314, 0.01), reason: '字体度量变了 ⇒ 重标墨迹补偿');
    // ascent + descent 恰好等于行高（even 分布的必然结果）。
    expect(ascentEm + descentEm, closeTo(height, 1e-6));
    painter.dispose();
  });

  test('CJK 墨迹偏移 = cjkInkCompensation 的配对值', () async {
    await loadAppFont();
    final double off = await avgInk(<String>['国', '永', '墨', '鬱', '汉字墨迹']);
    expect(-cjkInkCompensation, closeTo(off, 0.005), reason: '常量与实测成对，改一个要改两个');
    // 高度不变性（even 分配下墨迹偏移与行高倍数无关）：1.5 与 1.75 同值。
    final double off15 = await inkOffset('国', height: 1.5);
    final double off175 = await inkOffset('国');
    expect(off15, closeTo(off175, 1e-6), reason: '偏移应与行高倍数无关');
  });

  test('序号墨迹偏移 = numberedInkOffset 的配对值', () async {
    await loadAppFont();
    final double off = await avgInk(<String>['1.', '10.', '100.']);
    expect(numberedInkOffset, closeTo(off, 0.005), reason: '序号常量与实测成对');
  });

  test('圆点墨迹偏移 = bulletInkOffset 的配对值（按基文字号归一）', () async {
    await loadAppFont();
    // 圆点是 0.5× 缩放文本：实测按有效字号归一，×0.5 折到基文字号。
    final double off = await avgInk(<String>['•', '◦', '▪'], scaler: 0.5);
    expect(bulletInkOffset, closeTo(off * 0.5, 0.003), reason: '圆点常量与实测成对');
  });
}
