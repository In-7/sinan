import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
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
      expect(_lstar(ladder.base), closeTo(ladder.baseLstar, 0.3));
      expect(_lstar(ladder.panel), closeTo(ladder.panelLstar, 0.3));
      expect(_lstar(ladder.board), closeTo(ladder.boardLstar, 0.3));
      expect(_lstar(ladder.floating), closeTo(ladder.floatingLstar, 0.3));
    });

    test('$name：四档的形状（暖底 / 中性浮面 / 中性浮层 / 冷板底）', () {
      // 底：H=60° 的极淡暖调（R=G、B 低 2）——"明暗同色相"那条决定的机器形式。
      expect(ladder.base.r, ladder.base.g);
      expect(ladder.base.b, closeTo(ladder.base.r - 2 / 255, 0.005));
      // 内嵌浮面：纯中性（R=G=B）——大面积常驻面不染种子色。
      expect(ladder.panel.r, ladder.panel.g);
      expect(ladder.panel.g, ladder.panel.b);
      // 浮层：纯中性（R=G=B）——"大面不染种子色"。
      expect(ladder.floating.r, ladder.floating.g);
      expect(ladder.floating.g, ladder.floating.b);
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
      if (ladder.boardOverride == null) {
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

  test('内嵌浮面夹在底与浮层之间（暗亮都成立）：base < panel ≤ floating', () {
    for (final (String name, SurfaceLadder ladder) in <(String, SurfaceLadder)>[
      ('亮色', SurfaceLadder.light),
      ('暗色', SurfaceLadder.dark),
    ]) {
      expect(
        ladder.panelLstar,
        greaterThan(ladder.baseLstar),
        reason: '$name：浮面必须比窗口底亮，否则缝隙分层失效',
      );
      expect(
        ladder.panelLstar,
        lessThanOrEqualTo(ladder.floatingLstar),
        reason: '$name：菜单等浮层压在浮面上仍要有一档差',
      );
    }
  });

  test('暗色底 / 浮面精确锚定 opencode 值（2026-10-09 用户拍板）', () {
    final SurfaceLadder dark = SurfaceLadder.dark;
    // 底 #080808（暖形 B 低 2 ⇒ #080806，与纯中性差不可见）；浮面 #161616。
    expect((dark.base.r * 255).round(), 8);
    expect((dark.base.g * 255).round(), 8);
    expect((dark.base.b * 255).round(), 6);
    expect((dark.panel.r * 255).round(), 22);
    expect((dark.panel.g * 255).round(), 22);
    expect((dark.panel.b * 255).round(), 22);
    // 浮层与板底**绝对**明度钉死，不跟底一起沉。
    expect(_lstar(dark.floating), closeTo(19.4, 0.3));
    expect(_lstar(dark.board), closeTo(17.6, 0.3));
  });

  test('亮色：chrome 深灰 #DDDDDB 托纯白浮面 + 软投影（2026-10-09 晚定案）', () {
    final SurfaceLadder light = SurfaceLadder.light;
    // chrome（暖形 B 低 2 ⇒ #DDDDDB）；工作区浮面 = 纯白卡片。
    expect((light.base.r * 255).round(), 221);
    expect((light.base.g * 255).round(), 221);
    expect((light.base.b * 255).round(), 219);
    expect((light.panel.r * 255).round(), 255);
    expect((light.panel.g * 255).round(), 255);
    expect((light.panel.b * 255).round(), 255);
    // 浮层同白（菜单靠描边 + 投影分层）；板底比灰底再沉 3.1 档。
    expect(light.floating, light.panel);
    expect(light.board, const Color(0xFFD5D5D3));
    // sRGB 221→255 = 34 级色阶；白端 L* 差 11.9（比暗端 5.0 大，亮端靠
    // 软投影 AppTheme.panelShadow 补足悬浮感）。
    expect(_lstar(light.base), closeTo(88.1, 0.3));
    expect(light.panelDelta, closeTo(11.9, 0.05));
  });

  test('亮色浮面有软投影、暗色没有（两种高度语言各走各的）', () {
    expect(AppTheme.panelShadow(Brightness.light), isNotEmpty);
    expect(AppTheme.panelShadow(Brightness.dark), isEmpty);
    for (final BoxShadow s in AppTheme.panelShadow(Brightness.light)) {
      expect(s.color.a, lessThanOrEqualTo(0.09), reason: '软投影必须轻，不允许脏边');
      expect(s.blurRadius, greaterThanOrEqualTo(4));
    }
  });

  test('浮面光边 panelEdge：暗=白半透 / 亮=黑半透，压在面上有可辨提亮', () {
    final Color darkEdge = AppTheme.panelEdge(Brightness.dark);
    final Color lightEdge = AppTheme.panelEdge(Brightness.light);
    expect(darkEdge.r, closeTo(1, 0.001));
    expect(darkEdge.a, closeTo(0.08, 0.001));
    expect(lightEdge.r, closeTo(0, 0.001));
    expect(lightEdge.a, closeTo(0.06, 0.001));
    final Color darkBlended = Color.alphaBlend(
      darkEdge,
      AppTheme.panelFill(Brightness.dark),
    );
    expect(
      _lstar(darkBlended),
      greaterThan(_lstar(AppTheme.panelFill(Brightness.dark)) + 1.0),
      reason: '1px 光边必须真的比填充亮（新拟态受光边），不能退化成隐形线',
    );
  });

  test('呼出块 = 浮层档（它是"纸面上的一个记号"，一直与浮层同值）', () {
    expect(
      AppTheme.calloutBackground(Brightness.dark),
      AppTheme.floatSurface(Brightness.dark),
    );
  });
}
