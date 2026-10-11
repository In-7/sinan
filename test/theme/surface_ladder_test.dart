import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/theme/apca.dart';
import 'package:sinan/src/theme/app_theme.dart';
import 'package:sinan/src/theme/surface_ladder.dart';

/// **明度序**（`surface_ladder.dart`）的闸门（2026-09-22）。
///
/// 它存在的理由：抬一次暗底原先要动**四处绝对色值**（底 / 浮层 / 板底 / 呼出块），
/// 漏一处就是"比底还暗、整块陷进去"。收成一张"底 + ΔL*"的表之后，抬档 = 改一个数 ——
/// 这几条测试钉的就是这个性质，以及"表里的数字别写着好看"。
///
/// ⚠️ L* 用**连续式** `116·∛Y − 16`（与文档 / 体检表同一把尺子）。
double _lstar(Color c) => 116 * math.pow(c.computeLuminance(), 1 / 3) - 16;

void main() {
  final List<(String, SurfaceLadder)> named = <(String, SurfaceLadder)>[
    ('亮色', SurfaceLadder.light),
    ('暗色', SurfaceLadder.dark),
  ];

  for (final (String name, SurfaceLadder ladder) in named) {
    test('$name：每档的 L* 与表里声称的一致（表不是"写着好看"）', () {
      // 色值是从 L* 反解出来的（256 次搜索），所以量到的东西必须与声称值吻合；
      // 不吻合 = 反解或形状实现坏了，而"档差"会因此悄悄失真。
      // ⚠️ 容差 0.5（原 0.3）：sRGB 在**近黑端是量化的**，暗底 8 → 9 跳一级
      // L* 就跳约 1.0，0.3 容差会把它判成"反解坏了"。放宽到 0.5 仍能抓出
      // 真正的失真（档差写错的量级都是好几档）。
      expect(_lstar(ladder.base), closeTo(ladder.baseLstar, 0.5));
      expect(_lstar(ladder.panel), closeTo(ladder.panelLstar, 0.5));
      expect(_lstar(ladder.board), closeTo(ladder.boardLstar, 0.5));
      expect(_lstar(ladder.floating), closeTo(ladder.floatingLstar, 0.5));
    });

    test('$name：四档的形状（**纸族**底 / 浮面 / 浮层 + 冷板底）', () {
      // 2026-10-09 晚：底 / 浮面 / 浮层**同族**（[SurfaceShape.warm]，
      // R=G、B 按 [SurfaceShape.warmRatio] **按比例**下沉）——浅色走类纸暖白。
      // 此前浮面 / 浮层是纯中性，暖底配冷白卡会出现**色温差**（两种材质并置），
      // 故一并收族。层次**只**由明度承担，这也是纸感的定义。
      //
      // ⚠️ 2026-10-10 起下沉是**比例**不是绝对值：同一绝对偏移在近黑端会被
      // 感知放大数倍（R=244 时 2% / R=34 时 15%）⇒ 暗色发棕。所以这里按
      // **整数通道**精确比对实现（`(r × (1−ratio)).round()`），不用浮点容差，
      // 免得小值上的舍入把断言带偏。
      for (final (String what, Color c) in <(String, Color)>[
        ('底', ladder.base),
        ('内嵌浮面', ladder.panel),
        ('浮层', ladder.floating),
      ]) {
        final int r = (c.r * 255).round();
        expect(c.r, c.g, reason: '$name/$what：纸族要求 R=G');
        expect(
          (c.b * 255).round(),
          (r * (1 - SurfaceShape.warmRatio)).round().clamp(0, 255),
          reason: '$name/$what：纸族 B 应为 R × (1 − ${SurfaceShape.warmRatio})',
        );
      }
      // 板底：冷灰（R, R+1, R+5）——Craft 那种"中性 sheet"。
      // 亮色的板底是**叠白 95%**（不走明度序），所以只验暗色。
      if (ladder.boardOverride == null) {
        expect(ladder.board.g, closeTo(ladder.board.r + 1 / 255, 0.005));
        expect(ladder.board.b, closeTo(ladder.board.r + 5 / 255, 0.005));
      }
    });

    // ⚠️ 2026-09-23 起这条**不再是"一律向上"**：两个方向的板底代表两种语义。
    // - 暗色：板底 = **浮在底上的 sheet** ⇒ 必须比底亮（否则"陷进去"）；
    // - 亮色：板底 = **下沉的一列**（导航列实色）⇒ 必须比主区深
    //   （这正是 2026-09-23 用户定的那次翻转，见 [SurfaceLadder.boardOverride] 的说明）。
    // 两种语义下"板底都不能越过浮层"这条不变。
    test('$name：板底相对底的方向（暗色向上 / 亮色向下）+ 都不越过浮层', () {
      final double delta = ladder.boardLstar - ladder.baseLstar;
      final bool isDark = ladder == SurfaceLadder.dark;
      if (isDark) {
        expect(
          delta,
          greaterThan(0),
          reason: '$name：板底比底暗 ⇒ 导航板会"陷进去"（2026-09-22 手工抬档时真踩过）',
        );
      } else {
        expect(
          delta,
          lessThan(0),
          reason:
              '$name：亮色导航列必须比主区**深**——亮色那端已经贴到白，'
              '继续往上提就是"白面板压白底"（分不出列）',
        );
        expect(
          delta.abs(),
          greaterThanOrEqualTo(2.5),
          reason:
              '$name：只深 ${delta.abs().toStringAsFixed(2)} ΔL* ⇒ 分不出来'
              '（实测门限约 2.5；参考：Notion 侧栏比页面深 2.4）',
        );
      }
      expect(
        ladder.boardLstar,
        lessThanOrEqualTo(ladder.floatingLstar),
        reason: '板是"sheet / 下沉列"、浮层是"短暂浮起"——板不该比浮层还亮',
      );
    });

    // 2026-09-23：亮色板底是**纯实色**⇒ 底下没有任何材质，透一点就等于把窗口底的
    // 颜色掺进来了（颜色立刻不确定）。
    if (ladder.boardOverride != null) {
      test('$name：实色板底必须**不透明**', () {
        expect(
          ladder.board.a,
          1.0,
          reason: '$name：实色板底半透 ⇒ 颜色由"它掺了谁"决定，不再是令牌说了算',
        );
      });
    }
  }

  test('抬档只改 baseLstar：其余档位跟着走（这就是它存在的理由）', () {
    // 构造一个"假设的 +2 档"：只动一个数，板底 / 浮层应当跟着抬。
    final SurfaceLadder raised = SurfaceLadder(
      baseLstar: 13.65,
      floatingDelta: 11.7,
      boardDelta: 9.9,
      panelDelta: 5.5,
    );
    expect(_lstar(raised.base), closeTo(13.65, 0.3));
    expect(
      _lstar(raised.board) - _lstar(raised.base),
      closeTo(9.9, 0.3),
      reason: '档差没跟着走 ⇒ 这个表白做了',
    );
    expect(_lstar(raised.floating) - _lstar(raised.base), closeTo(11.7, 0.3));
  });

  test('暗色的浮层档差要比亮色大得多（投影更弱，只能靠底色差撑）', () {
    expect(
      SurfaceLadder.dark.floatingDelta,
      greaterThan(SurfaceLadder.light.floatingDelta * 1.5),
      reason: '亮面有软投影撑高度，档差让到 11.9；暗色无投影，档差 19.7 仍需约 1.7 倍',
    );
  });

  // ── **结构闸门**：四个"面"必须真的取自明度序 ────────────────────────────
  // 这条是"以后别再写死 hex"的机器形式：谁把值抄回去，这里立刻报。
  //（2026-09-26 亮色 #F7F7F5 的破例已于 2026-10-09 随镜像重排作废，
  // 明暗两档重新统一走 ladder。）
  for (final (String name, Brightness brightness) in <(String, Brightness)>[
    ('亮色', Brightness.light),
    ('暗色', Brightness.dark),
  ]) {
    test('$name：四个面都取自明度序（谁写死 hex 就报）', () {
      final SurfaceLadder ladder = AppTheme.ladder(brightness);
      expect(AppTheme.windowBackground(brightness), ladder.base);
      expect(
        AppTheme.contentCanvas(brightness),
        ladder.base,
        reason: '纸面必须与底同色（两处共用一个令牌，2026-09-22 用户定）',
      );
      expect(AppTheme.floatSurface(brightness), ladder.floating);
      expect(AppTheme.boardFill(brightness), ladder.board);
      expect(
        AppTheme.panelFill(brightness),
        ladder.panel,
        reason: '内嵌浮面必须取自明度序 panel 档（谁写死 hex 就报）',
      );
    });
  }

  // ⚠️ 2026-10-10：这条**不再"一律向上"**——暗色内容区由"浮面"翻转为"凹陷"。
  // - **亮色**：仍是浮面（卡片比窗口底亮）⇒ 靠明度差 + 环缝浮起；
  // - **暗色**：是**凹陷**（内容区比 chrome 暗）⇒ 暗色模式的第一目的是减少
  //   发光面积，让**只有文字**在发光，而不是一大块深灰面板在发光。
  //   这也是它与亮色真正镜像的那一面（浅色 chrome 灰 → 卡片趋向白；
  //   暗色 chrome 灰 → 内容区趋向黑）。
  // 两种语义下"内容区都不越过浮层"这条不变。
  test('内容区相对底的方向（亮色浮面向上 / 暗色凹陷向下）+ 都不越过浮层', () {
    for (final (String name, SurfaceLadder ladder) in <(String, SurfaceLadder)>[
      ('亮色', SurfaceLadder.light),
      ('暗色', SurfaceLadder.dark),
    ]) {
      final bool isDark = ladder == SurfaceLadder.dark;
      final double delta = ladder.panelLstar - ladder.baseLstar;
      if (isDark) {
        expect(
          delta,
          lessThan(0),
          reason: '$name：内容区必须比 chrome **暗** —— 凹陷语义（浮面会让'
              '一大块面板发光，那是暗色模式要避免的）',
        );
        expect(
          delta.abs(),
          greaterThanOrEqualTo(2.5),
          reason: '$name：只沉 ${delta.abs().toStringAsFixed(2)} ΔL* ⇒ 读不出凹陷',
        );
      } else {
        expect(
          delta,
          greaterThan(0),
          reason: '$name：浮面必须比窗口底亮，否则缝隙分层失效',
        );
      }
      expect(
        ladder.panelLstar,
        lessThanOrEqualTo(ladder.floatingLstar),
        reason: '$name：菜单等浮层压在内容区上仍要有一档差',
      );
    }
  });

  test('暗色：**中性深灰**底 #222221（2026-10-10 第③步）', () {
    final SurfaceLadder dark = SurfaceLadder.dark;
    // 底：连续尺 13 ⇒ sRGB 34。暖度改为**按比例**后 B 只低 1（34×2%≈0.7）
    // ⇒ #222221，**几乎中性**——这是 Apple 暗色的语言（中性深灰、非暖黑）。
    // 📌 同一处的绝对值版本是 B 低 5 ⇒ #22221D，实机看是**发棕发脏**的。
    // 不再锚定 opencode 的 #080808：那是近黑的 IDE 语言。
    expect((dark.base.r * 255).round(), 34);
    expect((dark.base.g * 255).round(), 34);
    expect((dark.base.b * 255).round(), 33);
    // 内容区（主阅读面）#1A1A19 —— 比 chrome **暗**，凹陷语义。
    // 之前的浮面版是 #2C2C2B（L\*18），用户实机反馈"面板有点亮"。
    expect((dark.panel.r * 255).round(), 26);
    expect((dark.panel.g * 255).round(), 26);
    expect((dark.panel.b * 255).round(), 25);
    // 浮层 / 板底改为**相对** delta（底抬回深灰后"绝对钉死"的理由已消失），
    // 值是照原绝对值反推的 ⇒ 这两面的观感几乎不变。
    expect(_lstar(dark.floating), closeTo(19.5, 0.5));
    expect(_lstar(dark.board), closeTo(17.5, 0.5));
  });

  test('亮色：**类纸暖白** #F4F4EF 托微差浮面（2026-10-09 晚改拍）', () {
    final SurfaceLadder light = SurfaceLadder.light;
    // 纸面（暖白，B 按 [SurfaceShape.warmRatio] 下沉：244×2%≈5 ⇒ #F4F4EF）；
    // 📌 浅色这一侧按比例与按绝对值几乎等价（都是差 5），所以观感不变。
    // 工作区浮面只比它亮 **3 档**（#FCFCF7），不再跳到纯白 —— IDE 那套
    // "深灰 chrome + 白卡"已被换成纸感：层次靠暖度 + 微差，不靠色阶对撞。
    expect((light.base.r * 255).round(), 244);
    expect((light.base.g * 255).round(), 244);
    expect((light.base.b * 255).round(), 239);
    expect((light.panel.r * 255).round(), 252);
    expect((light.panel.g * 255).round(), 252);
    expect((light.panel.b * 255).round(), 247);
    // 浮层仍在天花板（255 那档），与浮面差 1 档 ⇒ 菜单靠描边 / 投影分层。
    expect((light.floating.r * 255).round(), 255);
    expect(_lstar(light.base), closeTo(96, 0.5));
    expect(light.panelDelta, closeTo(3, 0.05));
  });

  // 常驻内容区**恒无投影**（2026-10-10）。真正的浮层走 AppTheme.floatShadows，
  // 这条钉的是"别又把投影挂回常驻面上"——它俩语义不同：常驻面是"区域"，
  // 浮层才是"压在上面的东西"。
  test('常驻内容区明暗都无投影（层次交给发丝边；浮层另有 floatShadows）', () {
    expect(AppTheme.panelShadow(Brightness.light), isEmpty);
    expect(AppTheme.panelShadow(Brightness.dark), isEmpty);
    // 反向确认：真正的浮层**仍然有**投影（双层柔影），别一起删掉。
    expect(AppTheme.floatShadows(Brightness.light), isNotEmpty);
    expect(AppTheme.floatShadows(Brightness.dark), isNotEmpty);
  });

  // ⚠️ 2026-10-10：暗色那侧**方向反了**。内容区翻转为凹陷之后，给它描一道
  // 白亮边是自相矛盾（给深井画受光边）。现在明暗两侧**都是暗边**，只是语义
  // 不同：亮色 = 浮面卡片的边缘收影；暗色 = 凹陷内容区的内阴影。
  // 描边三级（2026-10-10 显式化）里**真正要钉的那条关系**。
  //
  // ⚠️ 不是"三级严格递增"——实测**不成立**，而且是有原因的：
  // [AppTheme.divider] 带着 **APCA Lc≥20 的强制钳制**（2026-09-22 体检修过
  // "暗色下 outlineVariant@60% 叠近黑底只剩 Lc 0.0、线完全不可见"），
  // 亮色实测约 **20.9**；而 [AppTheme.panelEdge]（黑 α0.10）没有钳制，
  // 约 **12.1** ⇒ **分隔线事实上比内容区的边更强**。这是那次历史修复留下的
  // 语义倒挂，**已被记进 [EdgeLevel] 的文档**，不在这里偷偷改数值。
  //
  // 所以这里只钉两件真正不能破的事：① 浮层边必须能"挑"出来（强于分隔线）；
  // ② 每一级在**它自己的底**上都读得出来。
  test('浮层边强于分隔线边（亮色：浮层必须能被"挑"出来）', () {
    final ColorScheme scheme = AppTheme.light().colorScheme;
    final Color base = AppTheme.windowBackground(Brightness.light);
    double strength(Color edge) =>
        apcaLc(Color.alphaBlend(edge, base), base).abs();

    expect(
      strength(AppTheme.menuBorder(scheme).color),
      greaterThan(strength(AppTheme.divider(scheme))),
      reason: '浮层边必须强于分隔线 —— 否则菜单在内容上"挑"不出来',
    );
  });

  test('描边每一级在它自己的底上都读得出来（L* 差 ≥ 2）', () {
    for (final Brightness b in Brightness.values) {
      final ColorScheme scheme = b == Brightness.dark
          ? AppTheme.dark().colorScheme
          : AppTheme.light().colorScheme;
      // 各级的底：分隔线在纸面上、浮层边在浮层底上、面边界在内容区上。
      final List<(String what, Color edge, Color base)> cases =
          <(String, Color, Color)>[
            ('分隔线', AppTheme.divider(scheme), AppTheme.contentCanvas(b)),
            (
              '浮层边',
              AppTheme.menuBorder(scheme).color,
              AppTheme.floatSurface(b),
            ),
            (
              '面边界',
              AppTheme.panelEdge(b),
              AppTheme.panelFill(b),
            ),
          ];
      for (final (String what, Color edge, Color base) in cases) {
        final Color blended = Color.alphaBlend(edge, base);
        expect(
          (_lstar(blended) - _lstar(base)).abs(),
          greaterThanOrEqualTo(2.0),
          reason: '$b/$what：合成后与底的 L* 差不到 2 ⇒ 这道边等于没画',
        );
      }
    }
  });

  test('面板边 panelEdge：明暗都是黑半透，压在面上有可辨压暗', () {
    final Color darkEdge = AppTheme.panelEdge(Brightness.dark);
    final Color lightEdge = AppTheme.panelEdge(Brightness.light);
    expect(darkEdge.r, closeTo(0, 0.001));
    expect(darkEdge.a, closeTo(0.22, 0.001));
    expect(lightEdge.r, closeTo(0, 0.001));
    // 亮色边由 0x0F 级提到 0x1A（26/255）：原来的 α0.06 与投影同量级、两层
    // 信号一起失效，实机反馈"边有点糊"。现在层次预算全押在这道边上。
    // ⚠️ 按**通道值**断言（26/255 ≈ 0.1020）而不是十进制 0.10 —— 8-bit 量化的
    // 粒度是 1/255 ≈ 0.004，比 0.001 容差还大。
    expect(lightEdge.a, closeTo(26 / 255, 0.001));
    for (final Brightness b in Brightness.values) {
      final Color fill = AppTheme.panelFill(b);
      final Color blended = Color.alphaBlend(AppTheme.panelEdge(b), fill);
      expect(
        _lstar(blended),
        lessThan(_lstar(fill) - 1.0),
        reason: '$b：1px 边必须真的比填充**暗**，不能退化成隐形线',
      );
    }
  });

  test('呼出块 = 浮层档（它是"纸面上的一个记号"，一直与浮层同值）', () {
    expect(
      AppTheme.calloutBackground(Brightness.dark),
      AppTheme.floatSurface(Brightness.dark),
    );
  });
}
