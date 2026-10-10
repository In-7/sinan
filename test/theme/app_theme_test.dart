import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/theme/apca.dart';
import 'package:sinan/src/theme/app_float_surface.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/surface_ladder.dart' show SurfaceShape;
import 'package:sinan/src/theme/tokens.dart';

/// 主题不变量的回归（`app_theme.dart`）。
///
/// 背景：编辑区画布色 `AppTheme.contentCanvas()` 是**主题外的基色**——它没进
/// `ColorScheme`，而 `scheme.surface` 装的是 `windowBackground`
/// （亮 chrome 灰 `#DDDDDB` L\*88.1 / 深近黑 `#080806`（CIE L\*2.2 /
/// 仓内连续尺 −0.33），明暗同色相的极淡暖调；2026-10-09 晚亮色两度下压
/// 94.5 → 91.2 → 88.1 为白卡软投影让路；暗色轨迹：近黑 1.83 → 2026-09-22 抬到 7.7
/// → 2026-10-09 按 opencode 压回 #080808）。
/// ⚠️ 2026-09-22 起二者**同色**（纸面直接复用窗口底，见 `contentCanvas` 的文档）。
/// 所以画布上的文字用的 `onSurface*` 与它并非"一套配对"，只能靠对比度兜住；
/// 这条测试把兜底变成机器可检的不变量（编辑器正文、工具栏、附件卡都铺在画布色上）。
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

  for (final ThemeData theme in <ThemeData>[
    AppTheme.light(),
    AppTheme.dark(),
  ]) {
    final Brightness brightness = theme.brightness;

    test('$brightness：onSurface 对画布色保持正文级对比（≥ 4.5）', () {
      expect(
        contrast(
          theme.colorScheme.onSurface,
          AppTheme.contentCanvas(brightness),
        ),
        greaterThanOrEqualTo(4.5),
        reason: '画布是主题外基色；界面文字（onSurface）必须与它可读',
      );
    });

    test('$brightness：APCA 公式自检（黑 on 白 / 白 on 黑锚点）', () {
      // 先验尺子：公式或常量被改错的话，下面那条"舒适带"就没有意义了。
      expect(
        apcaLc(const Color(0xFF000000), const Color(0xFFFFFFFF)),
        closeTo(106.04, 0.1),
      );
      expect(
        apcaLc(const Color(0xFFFFFFFF), const Color(0xFF000000)),
        closeTo(-107.88, 0.1),
      );
    });

    test('$brightness：编辑器正文色落点（亮 `#3A3A3A` / 暗 `#DDDDDD`）', () {
      final Color text = AppTheme.editorText(brightness, theme.colorScheme);
      expect(
        contrast(text, AppTheme.contentCanvas(brightness)),
        greaterThanOrEqualTo(4.5),
        reason: '$brightness：正文色对底必须过 WCAG AA（兜底下限）',
      );
      if (brightness == Brightness.dark) {
        // 📌 2026-09-22 暗底抬档（`#0C0C0A` → `#171715`，+1 档）后**这档不用改**：
        // 实测对纸面 Lc −85.0，仍在 [−92, −84] 舒适带内，也比 `onSurface`（−87.5）更柔
        // ⇒ 两条闸门都过。（曾经在 +2 档下必须提到 `#E0E0E0`，那是抬得更多才有的连带。）
        expect(text, const Color(0xFFDDDDDD), reason: '暗色正文档变了（Lc −85）');
        expect(
          contrast(text, AppTheme.contentCanvas(brightness)),
          lessThan(
            contrast(
              theme.colorScheme.onSurface,
              AppTheme.contentCanvas(brightness),
            ),
          ),
          reason: '暗色正文没有比 onSurface 更柔 ⇒ 护眼取向丢了',
        );
      } else {
        expect(text, const Color(0xFF3A3A3A), reason: '亮色正文档变了（Lc ≈ +92）');
        expect(
          text,
          isNot(theme.colorScheme.onSurface),
          reason: '亮色正文退回 onSurface ⇒ Lc 又到 100，长文偏"刺"（2026-09-22 用户定要收）',
        );
      }
    });

    // 2026-09-22 用户定：正文按 **APCA** 定档（不是 WCAG——那把尺子在深色里失灵）。
    // APCA 档位：正文首选 Lc 90（≥14px/400）/ 最低 75；**暗色上限约 −90**。
    // 取偏上值：APCA 以 Helvetica 为基准，中文笔画更细、我们正文又是 13px。
    //
    // 2026-10-09 浮面外壳后正文有**两块真实承面**，各自有闸：
    // ① 桌面工作区浮面卡 [AppTheme.panelFill]（亮纯白 / 暗 #161616）——主阅读面，
    //    守 ±90 舒适带；
    // ② 移动端纸面 [AppTheme.contentCanvas]（亮 chrome 灰 / 暗近黑）——守 **75**
    //    （APCA 正文最低档；两份体检表统一用这一档）。
    //    ⚠️ 2026-10-09 晚 chrome 压到 #DDDDDB（88.1）后，亮纸正文 Lc 落到 ~76
    //    ——刚好压在最低档上方。继续压 chrome 会**先耗尽纸面的对比预算**
    //    （桌面不受影响：编辑区在纯白卡内）。要再深就得把移动端纸面拆成
    //    独立令牌，别把这里的下限一路往下放。
    test('$brightness：正文在浮面卡上落 APCA ±90 舒适带、在纸面上不低于 75', () {
      final Color ink = AppTheme.editorText(brightness, theme.colorScheme);
      final double lcOnPanel = apcaLc(ink, AppTheme.panelFill(brightness));
      final double lcOnPaper = apcaLc(ink, AppTheme.contentCanvas(brightness));
      if (brightness == Brightness.light) {
        expect(
          lcOnPanel,
          inInclusiveRange(88, 98),
          reason: '亮色浮面正文 Lc $lcOnPanel：低于 88 偏灰、高于 98 比首选档（90）黑太多',
        );
        expect(
          lcOnPaper,
          greaterThanOrEqualTo(75),
          reason:
              '亮色灰纸正文 Lc $lcOnPaper：灰纸面允许低于首选档，但不得低于'
              'APCA 正文最低档 75（再低就是联调时能量出来的可读性回归）',
        );
      } else {
        expect(
          lcOnPanel,
          inInclusiveRange(-92, -80),
          reason:
              '暗色浮面正文 Lc $lcOnPanel：APCA 暗色上限约 −90（越过去"字在发光"）；'
              '#161616 承面允许比首选档保守，但不得弱于 −80',
        );
        expect(
          lcOnPaper,
          lessThanOrEqualTo(-80),
          reason: '暗色近黑纸正文 Lc $lcOnPaper 不得弱于 −80',
        );
      }
    });

    test('$brightness：hint 色由 onSurface 派生（低浓度 + APCA 兜底）', () {
      // 标题占位、编辑器占位、查找框 hint 共用这一个来源。
      final Color hint = AppTheme.hintColor(theme.colorScheme.onSurface);
      if (brightness == Brightness.light) {
        // 亮色：Material 口径的 35% 已过占位符档（实测 Lc 41.5）⇒ 保持半透明语义，
        // 与基色**同源**（只降不透明度、不动 RGB）。
        expect(hint.a, closeTo(0.35, 0.01));
        expect(hint.r, theme.colorScheme.onSurface.r);
      } else {
        // 暗色：35% 叠完只有 Lc −16.5（占位文字看不见）⇒ 被 [withMinLc] 钳成实色。
        // 所以这里**不断言 alpha**（细节随阈值浮动），只钉真正要命的那条：过档。
        expect(
          apcaLcBlended(hint, AppTheme.contentCanvas(brightness)).abs(),
          greaterThanOrEqualTo(30),
          reason: '暗色占位符没过 APCA 占位符档（Lc 30）⇒ 提示文字等于看不见',
        );
      }
    });

    test('$brightness：surface 与窗口底色同源（边界不跳色）', () {
      expect(theme.colorScheme.surface, AppTheme.windowBackground(brightness));
    });

    // ── §5.6 底色契约：纸面 = 窗口底（2026-09-22 用户定） ────────────────
    // 两层都必须**不透明**（否则桌面壁纸从底下透上来）；而"纸面比窗口底更亮"那条序
    // **已被用户取消**（合并成同色）⇒ 分层改由描边 + 浮层承担。
    // 合上"浮层 > 纸面"那一条，剩下的序是：**浮层 > 底**。
    test('$brightness：纸面与窗口底都**不透明**（壁纸不许从底下透上来）', () {
      expect(
        AppTheme.contentCanvas(brightness).a,
        1.0,
        reason: '$brightness：纸面透明 ⇒ 二级页面会透出桌面壁纸',
      );
      expect(
        AppTheme.windowBackground(brightness).a,
        1.0,
        reason: '$brightness：窗口底透明 ⇒ 直接露出锐利的桌面壁纸',
      );
    });

    // ⚠️ 这叫"档位明度序"，**不是叠层**：页面是切换的（同一时刻只有一个页面在场），
    // 但一个页面内部仍有"底"与"浮在底上的块"（主页：底 + 导航板/卡片；笔记页：底 + 菜单）。
    // §5.6：卡片/导航项**直接坐在窗口底上**（"面板档"已实拍否决）——交互填充
    // 叠在窗口底上仍要比底亮，否则交互态"陷进去"。
    test('$brightness：卡片档叠在窗口底上仍比底亮', () {
      final Color window = AppTheme.windowBackground(brightness);
      final Color card = Color.alphaBlend(
        AppTheme.cardFill(brightness),
        window,
      );
      expect(
        card.computeLuminance(),
        greaterThan(window.computeLuminance()),
        reason: '$brightness：卡片/悬停档没有比窗口底亮 ⇒ 交互态"陷进去"',
      );
    });

    // §5.6：导航**板底**（boardFill 叠在窗口底上）上的文字对比度。
    // Craft 式侧栏靠字重与灰度分层 ⇒ 未选中项（次文字）也不能糊。
    test('$brightness：导航板底上，主/次文字都过 AA', () {
      final Color board = Color.alphaBlend(
        AppTheme.boardFill(brightness),
        AppTheme.windowBackground(brightness),
      );
      for (final (String label, Color fg) in <(String, Color)>[
        ('主文字', theme.colorScheme.onSurface),
        ('次文字', theme.colorScheme.onSurfaceVariant),
      ]) {
        final double ratio = contrast(fg, board);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              '$brightness：$label 放在导航板底上必须可读（实测 ${ratio.toStringAsFixed(1)}:1）',
        );
      }
    });

    // §5.6：噪点的**强度铁律**（超过 5% 就"脏"，与板底同一条教训）。
    // ⚠️ `windowNoiseAlpha` 当前**未挂载**（渐变换纯色后没有色带可治）；这条钉的是
    // "要么别留这个令牌、要么它得是个合理正数"，不是"它正在被用"。
    test('$brightness：窗口底噪点令牌在铁律内（0 < α ≤ 5%）', () {
      final double alpha = AppTheme.windowNoiseAlpha(brightness);
      expect(alpha, greaterThan(0), reason: '强度为 0 ⇒ 这个令牌已失效，要么给正数、要么连组件一起删');
      expect(
        alpha,
        lessThanOrEqualTo(0.05),
        reason: '$brightness：噪点超过 5% 立刻变"脏"',
      );
    });

    // §5.6（2026-09-26 提亮）：**纸面噪点**——暗 `2%` 白粒 / 亮 `2%` 黑粒。
    // ⚠️ 上限压到 **2%**（比窗口底那档更保守）：它离正文更近，颗粒削的是字周对比。
    // 两档都钉在「> 0 且 ≤ 2%」：亮色此前为 0 导致完全看不见颗粒（用户反馈
    // "看不出颗粒感"），已提到 2% 与暗色一致。
    test('$brightness：纸面噪点 0 < α ≤ 2%（两档都挂颗粒）', () {
      final double alpha = AppTheme.paperNoiseAlpha(brightness);
      expect(
        alpha,
        lessThanOrEqualTo(0.02),
        reason: '$brightness：纸面噪点超过 2% ⇒ 字周对比被削掉一档（它比窗口底那档更危险）',
      );
      expect(
        alpha,
        greaterThan(0),
        reason: '$brightness：纸面噪点必须 > 0，否则颗粒看不见、这一版白做',
      );
    });

    // §5.6：窗口渐变底的**极淡铁律**——两端每通道差 ≤ 10/255（≈4% 明度）。
    // "淡到说不出哪里变了才对；能看出是个渐变就廉价了。"这条钉住它。
    test('$brightness：窗口渐变极淡（两端每通道差 ≤ 10/255）', () {
      final LinearGradient g = AppTheme.windowGradient(brightness);
      expect(g.colors.length, 2);
      final Color a = g.colors.first;
      final Color b = g.colors.last;
      final double maxDiff = <double>[
        (a.r - b.r).abs(),
        (a.g - b.g).abs(),
        (a.b - b.b).abs(),
      ].reduce(math.max);
      expect(
        maxDiff,
        lessThanOrEqualTo(10 / 255),
        reason:
            '$brightness：渐变两端差 ${(maxDiff * 255).toStringAsFixed(0)}/255 ——'
            '超过 10 就"能看出是个渐变"，观感立刻掉档',
      );
    });

    // §5.6（2026-09-22 用户定）：纸面**就是**窗口底（主页与笔记页同底）。
    // 这条把"两处不许再漂开"钉死——此前是"纸面比窗口底更亮"那条档位序，
    // 用户明确取消（亮色侧那点差本来也只剩 ΔL\*≈0.74，低于分辨阈）。
    test('$brightness：纸面与窗口底**同色**（不再分档，分层交给描边/浮层）', () {
      expect(
        AppTheme.contentCanvas(brightness),
        AppTheme.windowBackground(brightness),
        reason: '$brightness：纸面又和窗口底分开了 ⇒ 主页与笔记页不同底（用户已定要同底）',
      );
    });

    // §5.6：主页整屏铺**窗口底**，卡片上要放标题 / 时间 / 一两行预览
    // ⇒ "底色上能不能放字"不必靠感觉，用同一套对比度算法就能判。
    test('$brightness：窗口底上，主/次文字都过 AA（主页卡片可显示预览）', () {
      final Color base = AppTheme.windowBackground(brightness);
      for (final (String label, Color fg) in <(String, Color)>[
        ('主文字', theme.colorScheme.onSurface),
        ('次文字', theme.colorScheme.onSurfaceVariant),
      ]) {
        final double ratio = contrast(fg, base);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              '$brightness：$label 放在窗口底上必须可读（实测 ${ratio.toStringAsFixed(1)}:1）',
        );
      }
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
      // **纸族**（2026-10-09 改拍为类纸暖白）：R=G、B 按 [SurfaceShape.warmRatio]
      // **按比例**下沉，与纸面同族 —— 不允许"暖白纸 + 冷白浮层"的冷暖并置。
      // ⚠️ 原来的 R==G==B 是"大面不染种子色"的机器形式，但那条性质**自动成立**
      // （明度序是静态表、不接收 seed），它反倒把"固定暖调"一起禁掉了。
      expect(floating.r, floating.g);
      expect(
        (floating.b * 255).round(),
        ((floating.r * 255).round() * (1 - SurfaceShape.warmRatio))
            .round()
            .clamp(0, 255),
      );
    });

    test('$brightness：两套菜单底色 = 浮层令牌（全局实色）', () {
      final Color expected = AppTheme.floatSurface(brightness);
      expect(
        theme.popupMenuTheme.color,
        expected,
        reason: '笔记列表右键菜单（PopupMenu）',
      );
      expect(
        theme.menuTheme.style?.backgroundColor?.resolve(<WidgetState>{}),
        expected,
        reason: '主菜单主题（MenuAnchor）——本仓其实没有 MenuAnchor，见下条',
      );
      expect(
        theme.popupMenuTheme.elevation,
        AppTheme.menuElevation,
        reason: '右键菜单曾 elevation 0（连投影都没有）',
      );
    });

    // ⚠️ 主菜单**不再**走这两套菜单主题：2026-09-22 它换成了自家锚定浮层
    // （`AppMenuButton`）——因为 `PopupMenuButton` 的面板在路由内部，插不进
    // `BackdropFilter`，做不出磨砂。它那层的结构闸门在
    // `test/app/app_menu_test.dart`（四项都在 + 模糊真的在 + 选完即关）。
    // 这里只钉**两个旋钮的数值契约**（配对使用，缺一个就白做）：
    test('$brightness：主菜单磨砂的两个旋钮（半透明 + 模糊半径）', () {
      final Color fill = AppTheme.menuFill(brightness);
      expect(
        fill.a,
        AppTheme.menuLayerAlpha,
        reason: '底色透明度旋钮 = menuLayerAlpha（一处可调）',
      );
      expect(fill.a, lessThan(1), reason: '必须真半透明——实色会把模糊整块盖住，等于没做');
      expect(
        AppTheme.floatBlurSigma,
        greaterThan(0),
        reason: '模糊半径必须 > 0，否则"磨砂"退化成纯半透明（清晰字影那份难看）',
      );
      expect(
        AppTheme.menuFillOver(
          brightness,
          AppTheme.windowBackground(brightness),
        ).a,
        1.0,
        reason: '合成后必须是不透明色，否则"拿合成色当底量对比度"这个前提不成立',
      );
    });
  }

  // §5.6（2026-09-22 用户定，2026-10-09 晚定档）：窗口底亮 chrome 灰
  // `#DDDDDB` / 暗近黑 `#080806`——明暗只差明度、同色相暖调。
  //
  // 这是**决定**，不是巧合：切主题时不该像"换了个应用"。它同时挡住两种回退：
  // ① 某一侧被改回**中性灰**（饱和度为 0）；② 两侧色相漂开（一暖一冷）。
  test('窗口底：明暗**同色相**的极淡暖调（不是中性灰，也不是一冷一暖）', () {
    final HSVColor light = HSVColor.fromColor(
      AppTheme.windowBackground(Brightness.light),
    );
    final HSVColor dark = HSVColor.fromColor(
      AppTheme.windowBackground(Brightness.dark),
    );
    expect(light.saturation, greaterThan(0), reason: '亮底成了纯中性灰');
    expect(dark.saturation, greaterThan(0), reason: '暗底成了纯中性灰');
    expect(dark.hue, closeTo(light.hue, 1), reason: '明暗色相漂开 ⇒ 切主题像换了个应用');
  });

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
      // ⚠️ 投影**不由 Material 的 elevation 承担**（改为双层软阴影后）：
      // elevation 只有单层固定投影，出不来"贴地影 + 环境影"的质感，且与外面那层
      // 叠加会发脏 ⇒ 它保持 0，投影移到外层 DecoratedBox（下面那条断言）。
      expect(
        surface.elevation,
        0,
        reason: '$brightness：投影不该由 Material 承担（会与外层影子叠脏）',
      );
      final DecoratedBox backdrop = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(AppFloatSurface),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(
        (backdrop.decoration as BoxDecoration).boxShadow,
        AppTheme.floatShadows(brightness),
        reason: '$brightness：缺双层软阴影——三件套少一件就不像浮层',
      );
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

      // 圆角：条加高后必须用 radiusLg——比控件档（radiusSm）更圆，否则高条显"方"。
      // （档位数值见 Tokens，属 Apple 口径 §9.2；这里只断言"用的是大档"。）
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

  test('图标/次级色/正文都退染为纯灰（不随种子染色）', () {
    // M3 会给中性角色染种子色相（onSurface C6~10 / onSurfaceVariant C10~15，
    // 实测）。主题层在 _build 里对这两档"退染"（保留明度、清零色度）——
    // 这里把明暗两套主题钉住：R==G==B 即纯灰，任何一个带色相都说明
    // 退染被绕开了。
    for (final ThemeData theme in <ThemeData>[
      AppTheme.light(),
      AppTheme.dark(),
    ]) {
      for (final Color c in <Color>[
        theme.colorScheme.onSurface, // 正文/标题/编辑器文字
        theme.colorScheme.onSurfaceVariant, // 图标/次级文字
      ]) {
        expect(c.r, c.g, reason: '${theme.brightness}：R!=G，前景色带染色');
        expect(c.g, c.b, reason: '${theme.brightness}：G!=B，前景色带染色');
      }
    }
  });

  /// Apple 口径（`docs/ui_rewrite_plan.md` §9.2）：规格表里的每个值都要**机器可检**
  /// ——否则下次有人"顺手"把字号调回 14、把分隔线调回满档，没人会注意到。
  group('Apple 口径（§9.2 规格）', () {
    test('界面排印：正文 13 / 小字 11 / 标题靠字重分层', () {
      for (final ThemeData theme in <ThemeData>[
        AppTheme.light(),
        AppTheme.dark(),
      ]) {
        final TextTheme t = theme.textTheme;
        final String label = '${theme.brightness}';
        expect(t.bodyMedium?.fontSize, 13, reason: '$label：macOS 桌面正文是 13');
        expect(t.bodySmall?.fontSize, 11, reason: '$label：辅助文字 11');
        expect(t.labelMedium?.fontSize, 11, reason: '$label：标签 11');
        expect(t.titleSmall?.fontSize, 13, reason: '$label：面板标题不放大字号');
        expect(
          t.titleSmall?.fontWeight,
          FontWeight.w600,
          reason: '$label：标题用**字重**分层（§9.2）',
        );
        expect(
          t.titleLarge?.letterSpacing,
          lessThan(0),
          reason: '$label：大字号负字距是 SF 的标志',
        );
        expect(t.bodyMedium?.height, greaterThan(1.2), reason: '$label：正文要留呼吸');
        expect(
          t.bodyMedium?.height,
          lessThan(1.5),
          reason: '$label：但必须比 M3 的松行高更紧——桌面手感',
        );
      }
    });

    test('「当前项」令牌与分段控件（2026-10-08 强调色药丸换装）', () {
      for (final ThemeData theme in <ThemeData>[
        AppTheme.light(),
        AppTheme.dark(),
      ]) {
        final ColorScheme scheme = theme.colorScheme;
        final String label = '${theme.brightness}';

        // 两个语义令牌：「当前项」选中 = primary 12% 药丸（用户拍板全局统一）；
        // 开关态 tint = onSurface 10%（开/关如实显示，仍留用）。
        expect(
          AppTheme.selectedPill(scheme),
          scheme.primary.withValues(alpha: 0.12),
          reason: '$label：selectedPill 必须是 primary @12%（拍板比例）',
        );
        expect(
          AppTheme.navSelectedTint(scheme.onSurface).a,
          closeTo(0.10, 0.001),
          reason: '$label：navSelectedTint 的比例变了（开关态 10% 是实测下限）',
        );

        // 分段控件：选中底 = 强调色药丸（不是 M3 默认的 secondaryContainer），
        // 且选中态加粗——"当前项"的第二支（形状上没有左侧 ⇒ 不配左条）。
        final ButtonStyle? style = theme.segmentedButtonTheme.style;
        expect(
          style?.backgroundColor?.resolve(<WidgetState>{WidgetState.selected}),
          AppTheme.selectedPill(scheme),
          reason: '$label：分段控件选中底退回了 secondaryContainer？',
        );
        expect(
          style?.textStyle?.resolve(<WidgetState>{
            WidgetState.selected,
          })?.fontWeight,
          FontWeight.w600,
          reason: '$label：分段控件选中项应加粗',
        );
        expect(
          style?.textStyle?.resolve(<WidgetState>{})?.fontWeight,
          FontWeight.w400,
          reason: '$label：未选中项不该加粗',
        );
      }
    });

    test('密度与分隔线：图标按钮与工具栏同档、分隔线退一档', () {
      for (final ThemeData theme in <ThemeData>[
        AppTheme.light(),
        AppTheme.dark(),
      ]) {
        final String label = '${theme.brightness}';
        expect(
          theme.dividerTheme.color,
          AppTheme.divider(theme.colorScheme),
          reason: '$label：分隔线应与视图层共用同一个 divider 令牌',
        );
        expect(
          theme.dividerTheme.color,
          isNot(theme.colorScheme.outlineVariant),
          reason: '$label：分隔线退回了满档 outlineVariant（比浮层边界还实，主次反了）',
        );
        expect(
          theme.iconButtonTheme.style?.minimumSize?.resolve(<WidgetState>{}),
          const Size.square(Tokens.toolbarButtonSize),
          reason: '$label：图标按钮与 Tokens.toolbarButtonSize 不同档（曾是 40 vs 32）',
        );
        expect(
          theme.listTileTheme.minVerticalPadding,
          6,
          reason: '$label：列表项密度（§9.2）',
        );
      }
    });
  });
}
