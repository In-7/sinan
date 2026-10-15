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

    test('$name：四档的形状（**冷族**底 / 浮面 / 浮层 + 冷板底）', () {
      // 2026-10-14：大面同族从暖（[SurfaceShape.warm]）反转为**中性偏微冷**
      // （[SurfaceShape.cold]，G=R+1、B=R+3）——用户定走 Linear 式冷底。
      // 层次仍只由明度承担；按整数通道精确比对（天花板 clamp 到 255）。
      for (final (String what, Color c) in <(String, Color)>[
        ('底', ladder.base),
        ('内嵌浮面', ladder.panel),
        ('浮层', ladder.floating),
      ]) {
        final int r = (c.r * 255).round();
        expect(
          (c.g * 255).round(),
          math.min(255, r + 1),
          reason: '$name/$what：冷族要求 G=R+1',
        );
        expect(
          (c.b * 255).round(),
          math.min(255, r + 3),
          reason: '$name/$what：冷族 B 应为 R+3',
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

  // ⚠️ 2026-10-15（第⑤步，用户定"对换"）：**明暗两侧一律向上**。
  // 暗色曾在 2026-10-10 翻成"凹陷"（内容区比 chrome 暗），理由是"暗色第一目的
  // 是减少发光面积、只让文字发光"——该前提已于 2026-10-14 被用户否掉
  // （"文字不需要发光，适合长时间观看、对比度清晰即可"）。对换后：
  // ① 阶梯单调向上（底 < 内容区 < 卡片 < 浮层），不再中途反转；
  // ② 明暗真正镜像（亮色 96 → 99 → 100，暗色 6.7 → 9.7 → 13.7 → 16.7）；
  // ③ 侧栏（直接坐底）成为最深一层，与 Linear 暗色语言一致。
  test('内容区相对底的方向（明暗两侧都向上）+ 都不越过浮层', () {
    for (final (String name, SurfaceLadder ladder) in <(String, SurfaceLadder)>[
      ('亮色', SurfaceLadder.light),
      ('暗色', SurfaceLadder.dark),
    ]) {
      final double delta = ladder.panelLstar - ladder.baseLstar;
      expect(
        delta,
        greaterThanOrEqualTo(2.5),
        reason: '$name：内容区只比 chrome 亮 ${delta.toStringAsFixed(2)} ΔL* '
            '⇒ 读不出"这是一块独立的面"（浮面闸门 ≥2.5）',
      );
      expect(
        ladder.panelLstar,
        lessThanOrEqualTo(ladder.floatingLstar),
        reason: '$name：菜单等浮层压在内容区上仍要有一档差',
      );
    }
  });

  test('暗色：**中性偏微冷**近黑底 #080808（2026-10-15 第⑥步）', () {
    final SurfaceLadder dark = SurfaceLadder.dark;
    // 底：连续尺 −0.33 + [SurfaceShape.cold]（B=R+3）⇒ (7,8,10)。用户定压回
    // #080808 档（实测 Linear 的 chrome 是 #09090A，同档）。
    expect((dark.base.r * 255).round(), 7);
    expect((dark.base.g * 255).round(), 8);
    expect((dark.base.b * 255).round(), 10);
    // 内容区（主阅读面）(16,17,19) —— 比 chrome **亮**（2026-10-15 第⑤步
    // "对换"：废掉凹陷，与亮色真镜像、阶梯单调向上）；第⑥步底压到 #080808 后
    // panelDelta 由 +3 提到 **+5**，CIE 感知差才回到 ≈3（Linear 实测值）。
    expect((dark.panel.r * 255).round(), 16);
    expect((dark.panel.g * 255).round(), 17);
    expect((dark.panel.b * 255).round(), 19);
    // 浮层 +17（补偿：底沉到 #080808 后仍保持 ≈16.7，**不比卡片暗** ⇒ 菜单压在
    // 笔记卡上不会读成"洞"；所有浮层观感与改前一致）/ 板底 +4.5（跟随底）。
    expect(_lstar(dark.floating), closeTo(16.7, 0.5));
    expect(_lstar(dark.board), closeTo(4.13, 0.5));
  });

  test('亮色：**冷灰白** #F3F4F6 托微差浮面（2026-10-14 转中性偏微冷）', () {
    final SurfaceLadder light = SurfaceLadder.light;
    // 纸面：L*96 + [SurfaceShape.cold]（B=R+3）⇒ (243,244,246)。原"类纸暖白"
    // #F4F4EF 已随暗色一起反转（用户 2026-10-14 定）。
    // 工作区浮面只比它亮 **3 档**（(251,252,254)），层次靠微差，不靠色阶对撞。
    expect((light.base.r * 255).round(), 243);
    expect((light.base.g * 255).round(), 244);
    expect((light.base.b * 255).round(), 246);
    expect((light.panel.r * 255).round(), 251);
    expect((light.panel.g * 255).round(), 252);
    expect((light.panel.b * 255).round(), 254);
    // 浮层仍在天花板（255 那档），与浮面差 1 档 ⇒ 菜单靠描边 / 投影分层。
    expect((light.floating.r * 255).round(), 255);
    expect(_lstar(light.base), closeTo(96, 0.5));
    expect(light.panelDelta, closeTo(3, 0.05));
  });

  // `panelShadow` / `panelEdge` 令牌已随拟态清理删除（2026-10-14）：
  // "常驻面不挂投影"的闸门移到 app 层真实外壳上钉（见
  // test/app/title_bar_nav_test.dart 的"工作区浮面卡"那条）；这里只反向
  // 确认真正的浮层**仍然有**双层柔影，别被一起删掉。
  test('浮层仍有双层柔影（floatShadows 不许被误删）', () {
    expect(AppTheme.floatShadows(Brightness.light), isNotEmpty);
    expect(AppTheme.floatShadows(Brightness.dark), isNotEmpty);
  });

  // ⚠️ 2026-10-14：描边收敛为**两级**（hairline / overlay）——常驻面那档
  // panelEdge 已删：暗色浮面零描边（明度阶梯即边界），亮色发丝边走
  // Bauhaus.hairline（app 层 home_screen 钉）。
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
      final List<(String what, Color edge, Color base)> cases =
          <(String what, Color edge, Color base)>[
            ('分隔线', AppTheme.divider(scheme), AppTheme.contentCanvas(b)),
            (
              '浮层边',
              AppTheme.menuBorder(scheme).color,
              AppTheme.floatSurface(b),
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

  test('呼出块 = 浮层档（它是"纸面上的一个记号"，一直与浮层同值）', () {
    expect(
      AppTheme.calloutBackground(Brightness.dark),
      AppTheme.floatSurface(Brightness.dark),
    );
  });
}
