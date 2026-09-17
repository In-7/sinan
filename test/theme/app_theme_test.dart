import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/theme/app_float_surface.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/tokens.dart';

/// 主题不变量的回归（`app_theme.dart`）。
///
/// 背景：编辑区画布色 `AppTheme.contentCanvas()`（亮 `#FAFAFA` / 深 `#161616`）
/// 是**主题外的基色**——它没进 `ColorScheme`，而 `scheme.surface` 装的是
/// `windowBackground`（亮 `#F3F3F3` / 深 `#0A0A0A`）。所以画布上的文字用的
/// `onSurface*` 与它并非"一套配对"，只能靠对比度兜住；这条测试把兜底变成
/// 机器可检的不变量（编辑器正文、工具栏、附件卡都铺在画布色上）。
///
/// 浮层（菜单 / 面板 / 工具条）另有一档 `AppTheme.floatSurface()`：与纸面**只差
/// 一档明度**，靠"三件套"（底色 + `menuBorder` 描边 + `menuElevation` 投影）
/// 浮起。下面两条把它钉住——防止有人把它改回画布色、或让某个菜单偷偷走回
/// "M3 默认表面色"（2026-09-14 之前就是那样：同屏两个菜单两种色）。
void main() {
  /// WCAG 相对对比度。
  double contrast(Color a, Color b) {
    double linear(double c) => c <= 0.03928
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    double luminance(Color c) =>
        0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
    final double la = luminance(a);
    final double lb = luminance(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  for (final ThemeData theme in <ThemeData>[AppTheme.light(), AppTheme.dark()]) {
    final Brightness brightness = theme.brightness;

    test('$brightness：onSurface 对画布色保持正文级对比（≥ 4.5）', () {
      expect(
        contrast(theme.colorScheme.onSurface, AppTheme.contentCanvas(brightness)),
        greaterThanOrEqualTo(4.5),
        reason: '画布是主题外基色；正文前景色必须与它可读（编辑器文字色取自 onSurface）',
      );
    });

    test('$brightness：编辑器正文色对纸面保持正文级对比（且暗色比 onSurface 更柔）', () {
      final Color text = AppTheme.editorText(brightness, theme.colorScheme);
      final double ratio = contrast(text, AppTheme.contentCanvas(brightness));
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason: '$brightness：正文色对纸面必须过 AA（实测 ${ratio.toStringAsFixed(1)}:1）',
      );
      if (brightness == Brightness.dark) {
        // 护眼取舍（2026-09-15）：纸面抬到 `#161616` + 正文降到 `#D6D6D6`
        // ——两个杠杆各让一步，14.6:1 → 12.5:1。
        expect(text, const Color(0xFFD6D6D6));
        expect(
          ratio,
          lessThan(
            contrast(
              theme.colorScheme.onSurface,
              AppTheme.contentCanvas(brightness),
            ),
          ),
          reason: '暗色正文没有比 onSurface 更柔 ⇒ 护眼改动没生效',
        );
      } else {
        expect(text, theme.colorScheme.onSurface, reason: '亮色正文色不动');
      }
    });

    test('$brightness：hint 色由 onSurface 派生（35% 浓度）', () {
      // 标题占位、编辑器占位、查找框 hint 共用这一个来源。
      expect(AppTheme.hintColor(theme.colorScheme.onSurface).a, closeTo(0.35, 0.01));
    });

    test('$brightness：surface 与窗口底色同源（Mica 回退不跳色）', () {
      expect(
        theme.colorScheme.surface,
        AppTheme.windowBackground(brightness),
      );
    });

    test('$brightness：浮层底色比纸面**抬一档**明度（且不染种子色）', () {
      final Color paper = AppTheme.contentCanvas(brightness);
      final Color floating = AppTheme.floatSurface(brightness);
      expect(floating, isNot(paper), reason: '与纸面同色 ⇒ 浮层只能靠描边投影硬撑');
      expect(
        floating.computeLuminance(),
        greaterThan(paper.computeLuminance()),
        reason: '浮层要"浮起"⇒ 明度高于纸面（亮暗两个主题都是抬一档）',
      );
      // 中性灰：R==G==B（本项目"大面不染种子色"的机器可检形式）。
      expect(floating.r, floating.g);
      expect(floating.g, floating.b);
    });

    test('$brightness：两套菜单底色 = 浮层令牌（此前一为画布色、一为 M3 表面色）', () {
      final Color expected = AppTheme.floatSurface(brightness);
      expect(
        theme.popupMenuTheme.color,
        expected,
        reason: '笔记列表右键菜单（PopupMenu）',
      );
      expect(
        theme.menuTheme.style?.backgroundColor?.resolve(<WidgetState>{}),
        expected,
        reason: '主菜单（MenuAnchor）——曾走 M3 默认 surfaceContainer',
      );
      expect(
        theme.popupMenuTheme.elevation,
        AppTheme.menuElevation,
        reason: '右键菜单曾 elevation 0（连投影都没有）',
      );
    });
  }

  testWidgets('浮层三件套：AppFloatSurface = 浮层底 + 描边 + 投影', (
    WidgetTester tester,
  ) async {
    for (final ThemeData theme in <ThemeData>[
      AppTheme.light(),
      AppTheme.dark(),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: AppFloatSurface(child: SizedBox(width: 8, height: 8)),
          ),
        ),
      );
      // 必须 settle：`MaterialApp` 的换肤走 `AnimatedTheme`（200ms）——
      // 不 settle 会读到**上一轮**主题的颜色（第一版就是这么误报的）。
      await tester.pumpAndSettle();
      final Material surface = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(AppFloatSurface),
              matching: find.byType(Material),
            )
            .first,
      );
      final Brightness brightness = theme.brightness;
      expect(surface.color, AppTheme.floatSurface(brightness));
      expect(surface.elevation, AppTheme.menuElevation, reason: '$brightness：缺投影');
      expect(
        (surface.shape! as RoundedRectangleBorder).side,
        AppTheme.menuBorder(theme.colorScheme),
        reason: '$brightness：缺描边——三件套少一件就不像浮层',
      );
    }
  });

  test('浮动工具条：浮层口径（floatSurface 底色 + menuBorder 描边 + 下投投影）', () {
    for (final ThemeData theme in <ThemeData>[
      AppTheme.light(),
      AppTheme.dark(),
    ]) {
      final Brightness brightness = theme.brightness;
      final ColorScheme scheme = theme.colorScheme;
      final BoxDecoration decoration = AppTheme.neuFloatBar(brightness, scheme);
      final String label = '$brightness';

      // 2026-09-16：工具条由"轻拟态（纸面同色）"改为浮层口径——底色取
      // [floatSurface]，明确比纸面抬一档，压在正文上不再"融进纸里"。
      expect(
        decoration.color,
        AppTheme.floatSurface(brightness),
        reason: '$label：浮条底色应为 floatSurface（与纸面差一档）',
      );
      expect(
        decoration.color,
        isNot(AppTheme.contentCanvas(brightness)),
        reason: '$label：浮条不可再与纸面逐像素同色（改回即退回"融进纸里"）',
      );

      // 圆角：条加高到 40 后必须用 radiusLg（14）——10 在高条上显"方"。
      expect(
        (decoration.borderRadius! as BorderRadius).topLeft.x,
        Tokens.radiusLg,
        reason: '$label：浮条圆角不是 radiusLg',
      );

      // 描边：走浮层三件套的 [menuBorder]（满档 outlineVariant），边界清晰；
      // 1px 同时是调用方布局补偿的依据（见 neuFloatBar 文档）。
      final BorderSide border = (decoration.border! as Border).top;
      expect(border.width, 1, reason: '$label：浮条描边必须 1px');
      expect(
        border.color,
        AppTheme.menuBorder(scheme).color,
        reason: '$label：浮条描边应取满档 menuBorder，而非发丝线',
      );
      expect(
        border.color.a,
        greaterThan(AppTheme.hairlineBorder(scheme).color.a),
        reason: '$label：满档描边应比发丝线更实',
      );

      // 投影：左上受光提示 + 右下下投暗影（给"抬起"实体感）。
      final List<BoxShadow> shadows = decoration.boxShadow!;
      expect(shadows, hasLength(2), reason: '$label：投影缺一不可');
      // 受光在左上、暗影在右下（偏移方向反了就成了"内陷"而不是"抬起"）。
      expect(shadows[0].offset.dx, lessThan(0));
      expect(shadows[0].offset.dy, lessThan(0));
      // 亮色下表面已是纯白，白高光与表面等亮（隐形、无妨）⇒ 用 >= 而非 >。
      expect(
        shadows[0].color.computeLuminance(),
        greaterThanOrEqualTo(decoration.color!.computeLuminance()),
        reason: '$label：左上那层不可比表面更暗（否则不是受光）',
      );
      expect(shadows[1].offset.dx, greaterThan(0));
      expect(shadows[1].offset.dy, greaterThan(0));
      expect(
        shadows[1].color.computeLuminance(),
        lessThan(decoration.color!.computeLuminance()),
        reason: '$label：右下那层必须比表面更暗（否则不是暗影）',
      );
      // 暗影比高光更软更长：自然光而非模板描边。
      expect(shadows[1].blurRadius, greaterThan(shadows[0].blurRadius));
    }
  });

  test('滚动条：主轴不吃边距（滑块必须能从滚动区域顶部开始）', () {
    // `mainAxisMargin` 是"滑块起点/终点到视口边缘的距离"（Flutter 默认 0）。
    // 设成正数（曾为 4）会让滑块**永远离区域顶部一段距离**、到底也差同样一段
    // ——看起来像"滚动条不从滚动区域顶部开始"（2026-09-14 用户实机发现）。
    for (final ThemeData theme in <ThemeData>[
      AppTheme.light(),
      AppTheme.dark(),
    ]) {
      expect(
        theme.scrollbarTheme.mainAxisMargin,
        0,
        reason: '${theme.brightness}：非 0 会让滑块两端离开区域边缘',
      );
    }
  });

  test('图标/次级色/正文都不随种子染色（纯灰）', () {
    // M3 会给中性角色染种子色相（onSurface C6~10 / onSurfaceVariant C10~15，
    // 实测）。主题层在 _build 里对这两档"退染"（保留明度、清零色度）——
    // 这里把 8 个预设 × 明暗全部钉住：R==G==B 即纯灰，任何一个带色相都说明
    // 退染被绕开了。
    for (final Color seed in AppTheme.seedPresets) {
      for (final ThemeData theme in <ThemeData>[
        AppTheme.light(seed: seed),
        AppTheme.dark(seed: seed),
      ]) {
        for (final Color c in <Color>[
          theme.colorScheme.onSurface, // 正文/标题/编辑器文字
          theme.colorScheme.onSurfaceVariant, // 图标/次级文字
        ]) {
          expect(
            c.r,
            c.g,
            reason: 'seed $seed / ${theme.brightness}：R!=G，前景色带染色',
          );
          expect(
            c.g,
            c.b,
            reason: 'seed $seed / ${theme.brightness}：G!=B，前景色带染色',
          );
        }
      }
    }
  });
}
