import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/theme/apca.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// **APCA 体检表 + 闸门**（2026-09-22）：把"文字/图形 vs 它实际铺的底"逐对算 Lc。
///
/// 为什么要有它：这类"差一档"的问题**肉眼看不出来**，改主题时又最容易悄悄越界。
/// 第一版就抓出三处真问题（此前没人发现）：暗色的**分隔线 Lc 0.0**（线完全不可见）、
/// **占位符 −16.5**、**浮层描边 −8.2**（三件套白缺一件）；链接色吃种子色，
/// 深种子下暗色侧只有 1.83:1。
///
/// ## 档位（APCA 官方）
/// - **正文**（分栏、≥14px/400）：首选 **90**、最低 **75**
/// - **非分栏文本**（短句、标签）：最低 **60**；**占位符 / 禁用**：最低 **30**
/// - **图形**：重要的 ≥ 30、**绝对最低 15**（细线最容易掉到 15 以下 ⇒ 等于看不见）
/// - ⚠️ **暗色上限约 −90**（初步结论）：再亮就是"字在发光"
///
/// ⚠️ 半透明（`divider` 的 `outlineVariant@60%`、`hint` 的 `onSurface@35%`）**必须先叠到
/// 底上再算**（用 [apcaLcBlended]）——直接拿色值算会把淡色当成"不透明的深色"，
/// Lc 虚高一大截，第一版就这么骗过了自己（暗色分隔线显示 26，实际 0）。
///
/// 本表**同时是闸门**：任一行掉出档位，`flutter test` 会带着"应该改成什么色"一起报出来。
void main() {
  test('APCA 体检表：所有「文字/图形 vs 它的底」都达标', () {
    final List<String> failures = <String>[];

    for (final ThemeData theme in <ThemeData>[
      AppTheme.light(),
      AppTheme.dark(),
    ]) {
      final Brightness b = theme.brightness;
      final ColorScheme s = theme.colorScheme;
      final Color paper = AppTheme.contentCanvas(b);
      final Color base = AppTheme.windowBackground(b);
      final Color panel = AppTheme.panelFill(b);
      final Color floatSurface = AppTheme.floatSurface(b);
      final Color board = Color.alphaBlend(AppTheme.boardFill(b), base);
      final Color card = Color.alphaBlend(AppTheme.cardFill(b), base);

      // ignore: avoid_print
      print('\n═══ ${b.name} ═══');

      void row(String label, Color fg, Color bg, double target) {
        final bool translucent = fg.a < 1.0;
        final Color eff = translucent ? Color.alphaBlend(fg, bg) : fg;
        final double lc = apcaLc(eff, bg);
        final bool ok = lc.abs() >= target;
        final String suggest = ok
            ? ''
            : '  ⇒ 建议 ${_hex(_suggest(eff, bg, target))}'
                  '${translucent ? '（叠加后效果色）' : ''}';
        // ignore: avoid_print
        print(
          '${ok ? ' ok ' : ' ✗  '} ${label.padRight(34)} '
          'Lc ${lc.toStringAsFixed(1).padLeft(6)}  (需 ≥ ${target.toStringAsFixed(0)})'
          '$suggest',
        );
        if (!ok) {
          failures.add(
            '${b.name} / $label：Lc ${lc.toStringAsFixed(1)}，低于 ${target.toStringAsFixed(0)}$suggest',
          );
        }
      }

      // ── 正文档（≥75） ──────────────────────────────────
      row('正文(editorText)', AppTheme.editorText(b, s), paper, 75);
      row('链接(primary)', AppTheme.editorLink(s), paper, 80);
      row('画布墨迹(canvasInk)', AppTheme.canvasInk(b), paper, 75);
      row(
        '正文 on 行内代码底',
        AppTheme.editorText(b, s),
        AppTheme.editorInlineCodeBg(b),
        75,
      );

      // ── 代码块语法高亮（≥65：短 token，但属正文级阅读面） ──
      final Color codeBg = AppTheme.editorCodeBlockBg(b);
      AppTheme.syntaxColors(b).forEach((String name, Color color) {
        row('代码 $name', color, codeBg, 65);
      });

      // ── 界面文字（≥60） ────────────────────────────────
      for (final (String where, Color bg) in <(String, Color)>[
        ('纸面', paper),
        ('内嵌浮面', panel),
        ('浮层', floatSurface),
        ('导航板', board),
        ('卡片', card),
      ]) {
        row('onSurface on $where', s.onSurface, bg, 60);
        row('onSurfaceVariant on $where', s.onSurfaceVariant, bg, 60);
      }

      // ── 主菜单 Layer（半透明 ⇒ 真实底是"合成色"，不是实色） ──
      // ⚠️ 半透明面板的对错**不能拿实色当底量**：合成后更贴近窗口底，对比会略降。
      final Color menu = AppTheme.menuFillOver(b, base);
      row('主菜单Layer：onSurface', s.onSurface, menu, 60);
      row('主菜单Layer：onSurfaceVariant', s.onSurfaceVariant, menu, 60);
      row('主菜单Layer：描边', AppTheme.menuBorder(s).color, menu, 22);

      // ── 主菜单 Layer 的**最坏底**（这一行是 α 的下界依据） ──────────────
      // 半透明面板必须假设"背后是最亮/最暗的内容"：模糊只把它糊开、**不改变亮度**。
      // 暗色主题背后可能是白图/亮块（`#FFFFFF`）、亮色主题背后可能是暗图（`#000000`）
      // ⇒ 合成色跟着走，面板上的文字对比度就是最差的那一档。
      // 拿它反推：α 越低 ⇒ 合成色越靠近那个极端 ⇒ 这一行最先掉。
      final Color worstBackdrop = b == Brightness.dark
          ? const Color(0xFFFFFFFF)
          : const Color(0xFF000000);
      final Color menuOnWorst = Color.alphaBlend(
        AppTheme.menuFill(b),
        worstBackdrop,
      );
      row('主菜单Layer 压最坏底：onSurface', s.onSurface, menuOnWorst, 65);
      // ⚠️ 菜单的 `onSurfaceVariant` **刻意不设这一行**：实测暗色 −55.2，本身就够不
      // 着 60 档——那是"菜单背后正好压着一大片亮色（如一张白图）"的极端情形。它是
      // **先于磨砂就存在**的暴露面（菜单背后没有遮罩），不是这次引入的；要收掉只有
      // 两条路：抬 `menuLayerAlpha`（磨砂会变实）或抬暗色的 `onSurfaceVariant`
      // （全局令牌，牵动全仓）。先如实记录，不动手。

      // ── **玻璃面板**（设置 / 关于）：实色底 + 光泽（2026-09-22 统一成一档）──
      // ⚠️ 有内光泽之后，"面板上的文字对比度"要按**最亮的一条带**算：顶端 = 光泽
      // 顶端（白 @ `glassSheenAlpha`），而**标题正好在那儿**（设置是「设置」标题栏、
      // 关于是图标 + 名称那一行）。标题之下的行只会更暗 ⇒ 更安全。
      // 📌 **面板是实色** ⇒ 背后是什么都影响不到它（遮罩浓度 `settingsScrimAlpha`
      // 也已归 0）⇒ 算式里**不需要**再乘背后那层。早先面板半透时有"遮罩压在最坏内容上"
      // 一档，那条随 `panelFill` 一起删了（那层遮罩曾经是承重的：底 α 0.88 时暗色
      // 副标题靠它才从 −55.2 回到 −61.7）。
      // ⚠️ 暗色的 `onSurfaceVariant` 两行是**钳制出来的**（钳到 60 档，参考底 =
      // [AppTheme.lightestDarkSurface]，即"面板底 + 光泽顶端"），所以它们**该贴着
      // 档位**；别把它当"余量不足"去放宽。
      // 📌 亮色下**光泽是隐形的**（白面板 + 5% 白 = 白）⇒ 那里的"玻璃感"只有顶沿
      // 光边在贡献，这也是为什么光边不能省。
      final Color sheenTop = const Color(0xFFFFFFFF)
          .withValues(alpha: AppTheme.glassSheenAlpha);
      final Color glassTop = Color.alphaBlend(
        sheenTop,
        AppTheme.floatSurface(b),
      );
      row('玻璃面板 光泽顶端：onSurface', s.onSurface, glassTop, 65);
      row('玻璃面板 光泽顶端：onSurfaceVariant', s.onSurfaceVariant, glassTop, 60);

      // ── 占位符（≥30） ──────────────────────────────────
      row('hint(占位) on 纸面', AppTheme.hintColor(s.onSurface), paper, 30);

      // ── 图形（细线踩线等于看不见，取 20~30） ──────────────
      row('分隔线 divider on 纸面', AppTheme.divider(s), paper, 20);
      row(
        '浮层描边 menuBorder on 浮层',
        AppTheme.menuBorder(s).color,
        floatSurface,
        22,
      );
      row('焦点环 primary on 纸面', s.primary, paper, 30);
      row('画布网格 on 纸面', AppTheme.divider(s), paper, 20);
    }

    expect(failures, isEmpty, reason: 'APCA 体检未过：\n${failures.join('\n')}');
  });
}

String _hex(Color c) =>
    '#${c.toARGB32().toRadixString(16).substring(2).toUpperCase()}';

/// 达标建议：朝黑（亮底）或朝白（暗底）平移**明度**，保色相。
Color _suggest(Color fg, Color bg, double target) {
  final bool darken = bg.computeLuminance() > 0.5;
  for (int i = 0; i <= 100; i++) {
    final Color c = Color.lerp(
      fg,
      darken ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
      i / 100,
    )!;
    if (apcaLc(c, bg).abs() >= target) return c;
  }
  return darken ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
}
