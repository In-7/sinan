import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'apca.dart';
import 'surface_ladder.dart';
import 'tokens.dart';

/// 主题：严格遵循 Material 3 官方最佳实践——
/// 一颗种子色派生全套色角色。
///
/// primary / surface / primaryContainer / outline 之间的对比度与色调和谐
/// 全部交给 `ColorScheme.fromSeed` 的算法保证。换主题 = 换种子色。
///
/// 配色变体用 fidelity，而非默认的 tonalSpot：tonalSpot 会把主色压成低色度的
/// 灰蓝（种子色 #3B6FD4 → primary #465D91），fidelity 才让界面呈现种子色本身
/// （primary #1755BA，primaryContainer 即种子色原值）。
/// 不要换 expressive / rainbow / fruitSalad——它们会替换掉种子色的色相。
///
/// ## 本文件只做两件事
/// 1. **统一几何**：圆角、内边距、高度一律走 [Tokens]，不出现裸数字。
/// 2. **标定容器底色**：只有自己铺底色的"大面"容器（卡片、抽屉、底部面板、
///    菜单）才显式设 `color`，且一律取中性画布色 [contentCanvas]（刻意**不随
///    主题种子色染色**）。主题色只作为"强调色"点缀在交互/激活处（光标、列表
///    符号、激活的工具栏态、链接、选区、主按钮），不用来铺大面——否则强调感
///    会被稀释。
///
/// 前景色（文字、图标）**一律不写**——交给 M3 的 `on*` 自动配对。
/// 这是最容易出错的地方：`onPrimaryContainer` 是近白色，
/// 若全局套用会出现「白字白底」。规则见 tokens/配色说明。
/// **描边的三个层级**（2026-10-10 显式化）。
///
/// 本仓的描边**早就是三级的**，只是散在三个函数里、语义只存在于注释中。
/// 这里把它们串成一条序列，**数值一个都没动** —— 目的是让"这套边框分过层级"
/// 变成可查的事实，而不是各处心照不宣。
///
/// | 级别 | 谁在用 | 强度语义 | 色源 |
/// |---|---|---|---|
/// | [EdgeLevel.hairline] | [AppTheme.divider] 分区线、工具条分组线、画布网格 | 两侧**同层**，只需"分"不必"挑" | `outlineVariant` 六折 |
/// | [EdgeLevel.surface] | [AppTheme.panelEdge] 常驻内容区 / 卡片的边界 | 读得出"这是一块独立的面" | **黑** α（暗色 0.22 / 亮色 0.10） |
/// | [EdgeLevel.overlay] | [AppTheme.menuBorder] 菜单、气泡、浮动工具条 | 要能从内容里"**挑**"出来 | `outlineVariant` 满档 + APCA 钳制 |
///
/// ⚠️ **两套色源不是重复，是语义不同**：[EdgeLevel.surface] 那一档说的是
/// "这块面**有厚度**"（暗边 / 收影），而 [EdgeLevel.overlay] 说的是"这个东西
/// **浮在上面**"（勾轮廓）。给一个凹陷的内容区描亮轮廓会自相矛盾 —— 暗色内容
/// 区正是靠暗边读作凹陷的。
///
/// ## ⚠️ 三级**不是**严格递增的（实测，别按"越往后越强"去推理）
/// 亮色实测：[AppTheme.divider] ≈ **20.9** > [AppTheme.panelEdge] ≈ **12.1**。
/// 原因是 [AppTheme.divider] 带着 **APCA Lc≥20 的强制钳制**（2026-09-22 体检
/// 修过"暗色下 `outlineVariant@60%` 叠近黑底只剩 Lc 0.0、线**完全不可见**"），
/// 而 [AppTheme.panelEdge] 走的是黑 α0.10、没有钳制。
/// ⇒ **分隔线事实上比内容区的边更强**，与上面 [EdgeLevel.surface] 声称的
/// "读得出这是一块独立的面"（应当强于 hairline）**语义倒挂**。
///
/// 📌 这是历史修复留下的既成事实，**没有偷偷改数值**（当前视觉用户已验收）。
/// 要归位的话：把 [AppTheme.panelEdge] 的亮色档从 α0.10 提到 **≈0.16**
/// （实测约 Lc 20）即可越过 divider，而不用去动那条救过命的钳制。
/// 真要改时记得同步上面那张表与 `surface_ladder_test` 里的实测注释。
///
/// 真正被测试钉住的是两件事：① **浮层边强于分隔线**（浮层要能从内容里
/// "挑"出来）；② **每一级在它自己的底上都读得出来**（L\* 差 ≥ 2）。
enum EdgeLevel {
  /// 分隔线：两侧同层，只需"分"不必"挑"（最弱）。见 [AppTheme.divider]。
  hairline,

  /// 常驻面：读得出"这是一块独立的面"（中）。见 [AppTheme.panelEdge]。
  surface,

  /// 浮层：能从内容里"挑"出来（最强）。见 [AppTheme.menuBorder]。
  overlay,
}

class AppTheme {
  AppTheme._();

  /// 默认种子色（Tailwind Teal 500）。
  ///
  /// 2026-09-12 由蒂芙尼青 #0ABAB5 换入：绿意更足、明度略低，
  /// 强调色的存在感更强，深浅两模式色相都不失。颜色只出现在动作点。
  static const Color defaultSeed = Color(0xFF14B8A6);

  /// **主题预设**（8 个**浅色**；默认档是中性、不在此表内，见 [chromeColor]）。
  ///
  /// 亮色下 chrome（环缝 / 标题条）**直接取预设色本身** —— 所见即所得，**不走**
  /// `primaryContainer`（M3 对极浅/极深的种子会钳制，钳了就不是"所选即所见"）。
  /// 暗色由 `fromSeed(seed, dark)` 派生**同色相的暗色档**（算法给的对应值，
  /// **不是**按百分比混合）。
  ///
  /// ⚠️ 预设必须挑**中等偏浅**（约 L\* 75~88）：面板卡亮色是 L\* 99 近白，
  /// 预设越接近白 ⇒ 环缝与白卡的明度差越小 ⇒ 环缝看不出来，"跟主题"就白做了。
  static const List<Color> themePresets = <Color>[
    Color(0xFF7FB3D5), // 雾蓝
    Color(0xFF8FCFC0), // 浅松石
    Color(0xFFA8D5A2), // 浅苔绿
    Color(0xFFE8C07D), // 浅琥珀
    Color(0xFFD9A7C7), // 浅藕紫
    Color(0xFFE3A9A0), // 浅陶土
    Color(0xFFB7C4D6), // 浅雾灰蓝
    Color(0xFFCBD5B4), // 浅橄榄
  ];

  /// **底层（环缝 / 标题条）的色**：[seed] 为 null（中性默认档）走中性 ladder，
  /// 彩色档走主题色。
  static Color chromeColor(Color? seed, Brightness brightness) {
    if (seed == null) return windowBackground(brightness);
    // 亮色：**预设色本身**（所见即所得，零钳制）。
    if (brightness == Brightness.light) return seed;
    // 暗色：**同色相的暗色档**。
    // ⚠️ 不能用 fidelity 的暗色方案——它的 primaryContainer 在暗色下**仍贴近
    // 种子本色**（实测浅种子给回浅粉，压不暗，实机截图确认过）。改走默认
    // tonalSpot：暗色下 primaryContainer = 种子色相的 tone 30 ⇒ 真正的
    // "同色相暗色对应值"（算法派生，不是按百分比混）。
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    ).primaryContainer;
  }

  /// **底层上的墨色**（图标 / 文字）：按底色明度**翻转**深/浅，不是百分比混合。
  ///
  /// 亮色 chrome 是浅色 ⇒ 深墨；暗色 chrome 是暗色 ⇒ 浅墨。
  /// （不能复用 `onPrimary`：它在 `_build` 里写死成深青，只适配青色种子。）
  static Color onChrome(Color? seed, Brightness brightness) =>
      ThemeData.estimateBrightnessForColor(chromeColor(seed, brightness)) ==
              Brightness.light
          ? const Color(0xFF1A1A18)
          : const Color(0xFFF2F2EE);

  /// **暗色模式**专用种子（Dark Turquoise，2026-09-13）。
  ///
  /// 亮色模式种子为 #00B5B5（见 [light]）——两者几乎同色相（≈180° 青轴），
  /// 只有明度/彩度不同 ⇒ 明暗切换时主题"身份"不漂移。暗色档用更亮的
  /// #00CED1 在暗画布（#1A1A1A）上对比更冲、更醒目——暗色用亮种子是 M3
  /// 的通行做法（明度补偿，避免中性种子在暗色下派生出粉笔感弱青）。
  static const Color defaultDarkSeed = Color(0xFF00CED1);

  /// 内容画布色：浮在窗口底色之上的编辑区实底面板。
  ///
  /// ## 亮色：中性微降白（不纯白）——**2026-09-22 起作废，见下**
  /// 曾为 `#FAFAFA`（纯白降一档亮度，读感是白纸又不眩光）。
  ///
  /// ## ⚠️ 2026-09-22 用户定：**与窗口底同色**（不再单独一档）
  /// 直接复用 [windowBackground]（亮 chrome 灰 `#DDDDDB` / 暗 `#080806`）
  /// ⇒ 主页 chrome 与移动端纸面**同一个底**。桌面工作区浮面卡（[panelFill]）
  /// 是另一个材质：亮纯白 / 暗 `#161616`。
  ///
  /// **代价（用户已确认）**：面板与窗口底的**色差不再承担分层**——笔记页的
  /// "纸面浮起"读数归零，侧栏/主区的分界也不再由底色档差表达（那条 1px 竖线
  /// 2026-09-18 就是为了"让底色档差去分界"才撤掉的，见 `home_screen.dart`）。
  /// 分层现在只剩 [divider] 描边 + [floatSurface] 浮层。顺带：亮色侧那点余量
  /// 本来也只剩 **ΔL\*≈0.74**（低于人眼分辨阈 ≈1）⇒ 合并几乎无损，是顺水推舟。
  ///
  /// **历史（保留是为了记住几笔取舍）**：`#2B2B2B`（L\* 17.5，比亮色那侧厚十倍，
  /// 灰蒙蒙）→ `#121212` → `#161616`（L\* 7.2，"大面积黑的压迫感来自瞳孔开度"，
  /// 抬一档更舒展，与 [editorText] 的降档是同轮的两个杠杆）→ 暖纸
  /// `#FBFAF7` / `#181613`（2026-09-22，Craft / Bear 口径的纸感）→ **并入窗口底**。
  ///
  /// ⚠️ **要再分开**：只改这个函数（body 换成独立字面量即可，调用方无需动），
  /// 但必须同时看 [windowBackground]：两者的明度关系有契约测试钉着
  /// （`test/theme/app_theme_test.dart` 的"纸面与窗口底"那几条）。
  static Color contentCanvas(Brightness brightness) =>
      windowBackground(brightness);

  /// **浮层表面**：压在纸面之上的所有"短暂块"（菜单 / 面板 / 工具条）共用这一档底。
  ///
  /// ## 为什么与纸面**不同色**（2026-09-14 用户定案）
  /// 此前 6 个浮层全直接吃 [contentCanvas]（与编辑器纸面**逐像素同色**），其中
  /// 4 个连描边和投影都没有 ⇒ 浮层"只能靠内容自己看起来像个面板"，同屏还会撞出
  /// 4 种底色（画布色 / M3 表面色 / 选区色 / 反色）。现在给浮层单独一档：
  /// **同色系、明度各抬一档**——亮色 纸 → 浮 **+11.9 L\***、深色 纸 → 浮
  /// **+17.2 L\***（当前落地值：亮 `#FFFFFF` / 暗 `#2F2F2F`）——配合**三件套**
  /// （[menuBorder] 描边 + [menuElevation] 投影 + `Tokens.radiusMd` 圆角）表达"浮起"。
  /// 📌 值与档差**都不在这里写**：来自 [ladder] 的 `floating` 档（`surface_ladder.dart`，
  /// 形状是 [SurfaceShape.neutral]）。改档位请改那张表 —— 这一处只负责"谁是浮层"。
  ///
  /// ⚠️ **深色下这一档要比亮色跨得大得多**（+17.2 vs +11.9）：亮色纸面本来就在
  /// 白端、让到 11.9 就顶到纯白天花板（不能再往上）；而深色的**投影天然更弱**
  /// （黑影落在暗底上对比小），
  /// "浮起"要多靠底色差 + 描边两件 ⇒ 差距小了就分不出层次。
  /// 📌 轨迹：暗底 `#0C0C0A`(1.83) → 2026-09-22 `#171715`(7.67) →
  /// 2026-10-09 按 opencode 压回 `#080808`(2.2)。后两次浮层都保持**绝对**
  /// L\* 19.4 不动（档差随之 11.7→17.2）——只动底、浮层钉死，菜单明度不漂移。
  /// ⚠️ **它必须是中性灰**（R==G==B）：`app_theme_test` 有闸门钉着"大面不染种子色"，
  /// 别顺手把底的暖调复制过来（那条试过，测试当场报）。
  ///
  /// ## 为什么不随主题种子色
  /// 与本文件头部"大面不染种子色"同一条规则：浮层也是大面，染色会稀释强调感
  /// （M3 的 `surfaceContainerHigh` 就带色相，这里刻意不用）。要"更浮"就继续抬
  /// 明度，不要改成染色。
  ///
  /// ## 唯一入口
  /// 浮层请一律用 [AppFloatSurface]（`app_float_surface.dart`）；官方组件走不了
  /// 那个容器的（悬浮工具栏 / 斜杠菜单 / 右键菜单 / 主菜单），也取这个函数填色。
  /// **改这一处，全场浮层跟着变。**
  static Color floatSurface(Brightness brightness) =>
      ladder(brightness).floating;

  /// **主菜单（MenuAnchor）的 Layer 档**：`floatSurface` 加透明（2026-09-22 试验）。
  ///
  /// ⚠️ **只有它一处半透明**（用户定："先把菜单一个做成 Layer"）：右键菜单 /
  /// [AppFloatSurface] / 浮动工具条仍是**实色**。依据见 §5.6：菜单压在**正文**上，
  /// 透明度高了会"透出字影"（历史那次"发脏"）；压在均匀纸面上又几乎看不出
  /// （合成色只差 1~2 级）。
  ///
  /// **旋钮之一**：`0` = 全透、`1` = 实色。现值 **0.80**。
  /// 📌 吃它的是**主菜单 / 关于面板**（设置面板走**实色** [floatSurface]，不用这一档）。
  /// 2026-09-22 的历程：0.85 → 0.92 → 0.95（"字影太重"就往回收），
  /// **加上局部模糊（[floatBlurSigma]）后再降回 0.80**——因为模糊会把"清晰字影"
  /// 变成"糊开的色块"，正是 Craft 那种磨砂观感；此时底色就该更透一点才看得出来。
  /// ⚠️ 两个旋钮要**配对调**：只加模糊不降 α ⇒ 模糊被实色盖住、等于没做；
  /// 只降 α 不加模糊 ⇒ 清晰字影（难看的那个）。
  /// ⚠️ 改它之后要看两处：① 菜单压住文字时脏不脏；② 合成后的对比度——
  /// 体检表 `test/theme/apca_audit_test.dart` 会拿 [menuFillOver] 当底来量。
  static const double menuLayerAlpha = 0.80;

  /// **浮层局部模糊的半径**（`AppFloatSurface(blur: true)` 消费）。
  ///
  /// 12 ≈ macOS 菜单那档"看得出是磨砂、但读得出背后有大块色形"。
  /// ⚠️ 成本与**面积 × 重绘次数**成正比：这里只糊面板那块（约全屏 1/20~1/30），
  /// 与"全屏压在画布上"不是一回事（后者才是仓库里那条红线）。
  /// 量法：profile 构建 + `F9`（`lib/src/dev/frame_probe.dart`）看 `raster_p90_ms`。
  static const double floatBlurSigma = 12;

  /// **磨砂浮层的实际填色**（半透明纯色）；合成观感见 [menuFillOver]。
  ///
  /// **两处**共用（2026-09-22）：**主菜单 / 关于面板**（都是 `blur: true` 的磨砂）。
  /// ⚠️ **设置面板不在这两处里**：它面积大（11% 屏）且不开模糊 ⇒ 走**实色**
  /// [floatSurface]（半透没有模糊托着就是"清晰字影"，这一点在面板那档尤其要紧）。
  /// 另：关于面板背后原本是 `showDialog` 的黑色模态遮罩，2026-09-22 已改成
  /// **透明 barrier**（与设置面板一致）；生成合成色时**不需要**再算背后那层。
  static Color menuFill(Brightness brightness) =>
      floatSurface(brightness).withValues(alpha: menuLayerAlpha);

  /// [menuFill] 叠在 [bg] 上的**合成色**——描边钳制与体检表拿它当"真实底"。
  static Color menuFillOver(Brightness brightness, Color bg) =>
      Color.alphaBlend(menuFill(brightness), bg);

  // ── 面板（设置 / 关于）：底 = [floatSurface]，玻璃感全交给光泽 ───────────────
  //
  // 这里曾经有过一档 `panelFill`（0.80 → 0.88 → 0.98，2026-09-22 内的三次调整）。
  // 删掉它的理由：半透的代价是**清晰鬼影** ∝ `1 − α`，而面板**面积大**
  // （设置面板 720×560 ≈ 全屏 11%，菜单约 1/20）且**不开模糊**（见
  // [AppFloatSurface.blur] 的面积分档）⇒ 鬼影的面积与清晰度都最大；实测收到 0.98 时
  // 它已经**与实色无观感差别**（体检表两档只差 1~3 Lc）⇒ 索性删掉这一档，
  // 少一个"名不副实、又要反复纠结"的旋钮。面板口径因此回到一句话：
  // **底 = [floatSurface]（实色）+ 两层纯绘制的光（[glassSheen] / [glassRim]）**。
  // ⚠️ 想再要"透"，唯一的正解是**开模糊**（[AppFloatSurface.blur]）——
  // 没有模糊托着的半透就是"清晰字影"（本仓历史上"发脏"那个观感）。

  /// **暗色下最亮的一块面** —— 暗色文字的对比**参考底**（见 `onSurfaceVariant` 的钳制）。
  ///
  /// 组成 = 面板底（[floatSurface]）再叠**玻璃光泽**的顶端 —— 面板是实色，所以
  /// **背后是什么都影响不到它**，最亮处只由"面板色 + 光泽"决定。
  /// ⚠️ 为什么参考底不能直接取 [floatSurface]：光泽会把它**再抬亮 5%**，而暗色的文字是
  /// **浅色**的 ⇒ **面越亮、对比越差**；漏掉这一层，`onSurfaceVariant` 在实际面板顶上
  /// 就会掉出 60 档（2026-09-22 体检表当场抓过）。
  /// ⚠️ 它**只对暗色有意义**：亮色下最亮的面是浮层的白、文字是深色，方向相反。
  static Color lightestDarkSurface() => Color.alphaBlend(
    const Color(0xFFFFFFFF).withValues(alpha: glassSheenAlpha),
    floatSurface(Brightness.dark),
  );

  // ── 玻璃档的三个令牌（`AppFloatSurface(glass: true)` 消费） ──────────────
  //
  // "玻璃"在视觉上由三件构成：①镜面高光 / 光边 ②厚度（上亮下沉）③**透光 / 折射**。
  // 前两件纯绘制就能做（本组令牌），第三件只有透明度 / 模糊能提供 —— 所以纯色 +
  // 高光得到的是"**釉面 / 抛光玻璃板**"，不是"看得见背后的磨砂玻璃"。

  /// **内光泽**顶端的白度：竖向渐变从上沿最亮到 45% 处归零。
  ///
  /// 5% 是"看得出来是光、但看不出是一层白"的量级；超过 ~8% 立刻读成"塑料 / 油面"。
  static const double glassSheenAlpha = 0.05;

  /// **顶沿光边**的白度（按明暗分档）。
  ///
  /// 亮色 **50%**：面板本来就近白，这条线是它唯一的"亮"——好在它是一条**线**
  /// （不是一片面），与底色 1~2 级的差也看得见。
  /// ⚠️ 暗色只有 **8%**：近黑面板上一根白线极显眼，再加一点就成"塑料亮边"。
  static double glassRimAlpha(Brightness brightness) =>
      brightness == Brightness.light ? 0.50 : 0.08;

  /// **玻璃内光泽**：竖向，上沿最亮 → 45% 处归零。
  ///
  /// ⚠️ 两端必须**同色（都是白）只改 alpha**：写成 `Colors.transparent`
  /// （= 透明**黑**）会在渐变中段插出灰带，近黑面板上就是一道脏印。
  /// 闸门：`test/theme/glass_test.dart`（钉住"另一端是**白**的透明"）。
  ///
  /// [alphaScale]：面积很小的"玻璃片"（导航选中项）可以整体加力——默认 1
  /// 不动全局标定值；越大越亮（>2 会读成塑料）。只有要加力的调用方传。
  static LinearGradient glassSheen(
    Brightness brightness, {
    double alphaScale = 1,
  }) => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[
      const Color(0xFFFFFFFF)
          .withValues(alpha: (glassSheenAlpha * alphaScale).clamp(0.0, 1.0)),
      const Color(0xFFFFFFFF).withValues(alpha: 0),
    ],
    stops: const <double>[0, 0.45],
  );

  /// **玻璃顶沿光边**：横向（`LinearGradient` 的默认方向就是左 → 右），两端淡出、
  /// 中间一条亮线。
  ///
  /// 两端淡出有两个好处：① 圆角处不会突然断头；② 不与两侧的描边抢边界。
  /// [alphaScale] 同 [glassSheen]。
  static LinearGradient glassRim(
    Brightness brightness, {
    double alphaScale = 1,
  }) {
    final Color rim = const Color(0xFFFFFFFF).withValues(
      alpha: (glassRimAlpha(brightness) * alphaScale).clamp(0.0, 1.0),
    );
    final Color clear = const Color(0xFFFFFFFF).withValues(alpha: 0);
    return LinearGradient(
      colors: <Color>[clear, rim, rim, clear],
      stops: const <double>[0, 0.08, 0.92, 1],
    );
  }

  /// **玻璃底沿厚度边**（"玻璃片"的下缘）的黑度：按明暗分档。
  ///
  /// 玻璃片读出"厚度"要靠一对边：顶沿吃光（[glassRimAlpha]）+ 底沿投影（本值）。
  /// ⚠️ 亮色只有 **8%**：近白板上一根黑线再重就成"描边"（本仓对常驻描边一贯
  /// 否决）；暗色给到 **20%**——近黑底上黑线天然弱，靠更高 alpha 才与底分离。
  static double glassBaseAlpha(Brightness brightness) =>
      brightness == Brightness.light ? 0.08 : 0.20;

  /// **玻璃底沿厚度边**：横向渐变，两端淡出（理由同 [glassRim]）。
  ///
  /// ⚠️ 两端必须用**透明黑**（不是透明白）：这层是"影"，渐变中段插白会发灰。
  /// [alphaScale] 同 [glassSheen]。
  static LinearGradient glassBaseEdge(
    Brightness brightness, {
    double alphaScale = 1,
  }) {
    final Color base = const Color(0xFF000000).withValues(
      alpha: (glassBaseAlpha(brightness) * alphaScale).clamp(0.0, 1.0),
    );
    final Color clear = const Color(0xFF000000).withValues(alpha: 0);
    return LinearGradient(
      colors: <Color>[clear, base, base, clear],
      stops: const <double>[0, 0.08, 0.92, 1],
    );
  }

  /// **导航玻璃片的加力系数**：36px 的小面积上，全局玻璃档的标定亮度（为
  /// 大面板调的）会"显不出来"——光要跟**面积**一起缩放。1.5 = sheen 5%→7.5%、
  /// rim 亮 50%→75%、底沿 8%→12%。调手感就动这一个数（2 已是塑料临界）。
  static const double glassSheetBoost = 1.5;

  /// ⚠️ 主菜单**曾经**靠覆写 `popupMenuTheme` 来取这层底色；2026-09-22 它换成自家
  /// 锚定浮层（`AppPopover(blur: true)`）之后就不需要了——那支覆写函数随之删除。
  /// 留这条注记是为了别再走回头路：`PopupMenuButton` 的面板在路由内部，
  /// **插不进 `BackdropFilter`**，做不出模糊。

  /// **导航板的板底**（Craft 的"悬浮 sheet"语言，2026-09-22 对照实机截图定）。
  ///
  /// 值来自 [ladder] 的 `board` 档：暗色是"底 + **15.4 L\***"的 [SurfaceShape.cool] 灰
  /// 叠 95%（当前 `#2A2B2F` @95%，**绝对** L\* 17.6 钉死不跟底走）；亮色**不走
  /// 明度序**，直接用 `Color(0xF2FFFFFF)`
  /// （板底贴白端，底怎么动它都不会"陷进去"，见 `surface_ladder.dart` 的说明）。
  ///
  /// ⚠️ 为什么是**近实中性色**、而不是半透明低 alpha：上一版 `#3A3A3A`@30% 发"脏"，
  /// 根源是**半透明**——壁纸的色相混了进来。Craft 的板几乎不透却也不脏，因为它
  /// **中性 + 近实**，靠 6px 缝和周围更淡的区域把"浮起来"说清楚。
  /// **通透感 ≠ 低不透明度**；也**不要**用灰色中 alpha（那两版都踩过）。
  ///
  /// ⚠️ **方向按明暗分两种语义**（此前一律"必须比底亮"，2026-09-23 起只保住暗色那侧）：
  /// - **暗色**：板是"浮在窗口底上的 sheet" ⇒ **必须比底亮**。`#2A2B2F` = L\* 17.6，
  ///   2026-10-09 底压到 `#080808`（2.2）后差 **+15.4**；板底一直保持绝对
  ///   17.6 不跟底漂移（2026-09-22 抬底、2026-10-09 压底都只动 [windowBackground]）。
  /// - **亮色**：板底是**下沉的一列**（导航列实色 `#D5D5D3`，比 chrome 灰底
  ///   `#DDDDDB` 再深 **3.1 ΔL\***）——亮色工作区浮面已是纯白，向上没有档了。
  ///   完整理由与轨迹见 `surface_ladder.dart` 的 [boardOverride]（**值改那里，别改这里**）。
  /// 📌 暗色板底的**冷灰形状**（R, R+1, R+5）是刻意的（Craft 那种"中性 sheet"），与底的暖调不同，
  /// 别把它也改成 `R=G, B=R−2`。亮色回退档则是**与底同族**（暖调），读作"同一材质深一档"。
  static Color boardFill(Brightness brightness) => ladder(brightness).board;

  /// **内嵌浮面**：桌面外壳工作区那张圆角卡片的底色（2026-10-09 opencode 风
  /// 外壳新增，2026-10-10 晚翻转语义）。
  ///
  /// 明度序上它与窗口底的关系**明暗相反**（见 [SurfaceLadder.panelDelta]）：
  /// - **亮色 = 浮面**：底 96 → 面 99，卡片比 chrome 亮 ⇒ 靠 8px 环缝 +
  ///   [EdgeLevel.surface] 的暗边立住，**不投投影**（常驻面不该"浮"）；
  /// - **暗色 = 凹陷**：底 13 → 面 9，内容区比 chrome 暗 ⇒ 只有文字发光，
  ///   暗边读作"沉进去"。
  ///
  /// 卡片左 / 右 / 下留 [Tokens.appPanelInset]（4）环缝露出窗口底、**顶部与
  /// 标题条 0 间距**（四角仍圆角，2026-10-09 晚用户定：直角不好看），
  /// **不投分割线**。值改 `surface_ladder.dart` 的 `panelDelta`，别写死在这里。
  static Color panelFill(Brightness brightness) => ladder(brightness).panel;

  /// **内嵌面的 1px 边**：给"这块面有厚度"补的最后一道信号。
  ///
  /// ⚠️ **明暗都是暗边、但语义不同**（2026-10-10 定）：
  /// - **亮色 = 浮面**（卡片比窗口底亮）⇒ 黑 α0.10，读作卡片边缘收出一道影；
  /// - **暗色 = 凹陷**（内容区比 chrome **暗**，见 `panelDelta`）⇒ 黑 α0.22，
  ///   读作内容区"沉进去"、边缘一圈内阴影。给深井描白亮边是自相矛盾。
  ///
  /// 📌 **亮色那一档为什么从 α0.06 提到 0.10**（用户实机反馈"边有点糊"）：
  /// 原来的 0.06 与投影的 0.06/0.08 是**同一个量级**，等于两层信号一起失效——
  /// 投影是"糊的"（blur 18），边是"清的"，清的那层必须先立住。
  /// 实测：α0.10 压在 #FCFCF7 上比填充低约 10 ΔL\*，边界一眼可辨且不显脏。
  ///
  /// 外侧的暗晕不用画：内容区四周 [Tokens.appPanelInset] 露出的 chrome 就是框。
  static Color panelEdge(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0x38000000) // 黑 α0.22（0x38=56/255）
      : const Color(0x1A000000); // 黑 α0.10（0x1A=26/255）——见下

  /// **内嵌浮面的软投影**（2026-10-09 晚）：**只给亮色**——亮端没有"再提亮"
  /// 的空间，白卡的悬浮感靠深色语言（描边 + 投影）表达；暗色继续走
  /// [panelEdge] 光边语言，投影在近黑底上既画不出也不需要。
  ///
  /// 两层（macOS 窗口 / Things 3 卡的口径）：
  /// - **接触影**：黑 α0.06、模糊 4、下移 1——贴边的一圈紧实暗影，负责
  ///   "卡片边缘"读数；
  /// - **环境影**：黑 α0.08、模糊 18、下移 4——漫开的大软影，负责"离底面
  ///   有高度"。
  ///
  /// 卡片顶缝为 0，环境影会漫上标题条约十几 px——这是刻意的：读作卡片压在
  /// 标题条**前面**（z 序由投影定义，不靠分割线）。暗色返回空列表，调用处
  /// 直接展开进 `boxShadow:` 即可。
  /// **内嵌常驻面的投影：恒为空**（2026-10-10 用户实机反馈"亮色下边有点糊"）。
  ///
  /// ## 为什么**取消**了它
  /// 此前是"亮色两层软投影（α0.06/0.08）+ 暗色空列表"，现在**两个模式都空**：
  /// 1. **语义错位**：常驻内容区是"同一平面上的区域"，不是"压在上面的卡片"。
  ///    投影是给**临时浮层**（菜单 / 对话框 / 气泡）用的 —— 那些走
  ///    [floatShadows]，不受影响。
  /// 2. **两层信号互相抵消**：原投影是 α0.06 / 0.08，而 [panelEdge] 那圈边也是
  ///    α0.06 —— 同一个量级，等于两层一起失效。投影是"糊的"（blur 18），边是
  ///    "清的"；清的那层没立住，糊的那层也托不起来，于是"既不浮、也不平"。
  ///    现在把预算全押在**发丝边**上（亮 0.10 / 暗 0.22）。
  /// 3. **与暗色语义对齐**：暗色内容区已翻转成**凹陷**（比 chrome 暗）。亮色
  ///    再加投影让它"浮"，两边语义就打架了。
  ///
  /// 📌 真要"软"的悬浮感，走 [floatShadows] 那种**单方向**柔影 + 发丝边
  /// （Fluent / macOS 口径），**不要**回退到双向内阴影的新拟态 —— 那个的边界
  /// 对比只有 2–3 ΔL\*，人眼读不出，"糊"正是它的来源。
  ///
  /// 保留本函数（而不删掉）：调用处直接展开进 `boxShadow:`，返回空列表即自动
  /// 退化成"无投影"，比在每个调用处写"这里为什么没投影"更不容易漂。
  static List<BoxShadow> panelShadow(Brightness brightness) =>
      const <BoxShadow>[];

  /// **通用 hover 微镀**（阶段 0 新增）：列表行 / 卡片 / 按钮 hover 的**统一入口**。
  ///
  /// 返回**半透明叠加色**（画在原有底色之上），不是绝对色 ⇒ 同一个 hover 能用在
  /// 纸面、板底、卡片底等任何底上，不必为每种底各配一档。
  /// 量：亮 = 黑 4%，暗 = 白 12%（暗色要更大量才看得出）。
  ///
  /// ⚠️ 历史口径 boardFillHover（板底专用，亮黑 5% / 暗白 6%）已于 2026-10-08
  /// 退役收口到本函数——全应用 hover 一个口径，两种叠加色**不要**共存/叠加
  /// （叠了会比设计档重一倍）。
  static Color hoverOverlay(Brightness brightness) =>
      brightness == Brightness.dark
      ? Colors.white.withValues(alpha: 0.12)
      : Colors.black.withValues(alpha: 0.04);

  /// **凸面填充**（新拟态里"抬起来的那块"：切换器滑块 / 「+」方格）。
  ///
  /// 两种亮度的"抬起"**语言本来就不同**——这是全应用既定的，不是切换器私有的：
  /// - **亮色**："同色挖空"。凸块 = [windowBackground]（列底那档浅），井
  ///   （[boardFill]）比它深一档 ⇒ 滑块读作"从页面上切下来的一块"。
  /// - **暗色**："叠档浮起"。全家抬起都靠**在下一层上叠一档白**（[cardFill]
  ///   白 5%、历史 boardFillHover 白 6%、[cardFillHover] 白 8%），没有"比底深的
  ///   井"可挖——暗色 [boardFill] 本身就是比底亮的浮起 sheet。⇒ 凸块 =
  ///   **井上再叠一档白**（8%，与 [cardFillHover] 同档）。
  ///
  /// ⚠️ 用 `Color.lerp` 烤成**不透明色**而不是半透明填充："发脏"教训针对的是
  /// alpha 直铺会混进下层色相；这里是叠在近实中性井上再烤实，不透底。
  /// 且向中性白 lerp 会保住板底 (R, R+1, R+5) 的冷灰形状（#2A2B2F → #3B3C40）。
  ///
  /// ⚠️ 不能无脑用 [windowBackground]：暗色窗口底 `#171715` 比井**还暗**，
  /// 滑块跟列底同色就成了"井里一个更深的洞"（2026-09-26 实机截图）。
  /// 也别用绝对色硬编码（曾试 `#333438`）——那是发明全应用没有的新颜色，
  /// 破坏暗色的叠档语言（2026-09-26 用户指出）。
  static Color raisedFill(Brightness brightness) =>
      brightness == Brightness.dark
      ? Color.lerp(boardFill(brightness), Colors.white, 0.08)!
      : windowBackground(brightness);

  /// **锐利边缘 bevel 装饰**（新拟态的"无模糊阴影"替代，2026-10-12 用户定）：
  /// 顶左**亮边** + 底右**暗边**各 1px（凸起）/ 反向（凹陷），由底面色
  /// `Color.lerp` 派生 ⇒ 不发明新色、明暗两档自动成立、**无模糊、不触发离屏合成**
  /// （对比 2026 流行的软阴影双向内阴影：那条边界对比仅 2–3 ΔL\* 还要 blur）。
  ///
  /// ⚠️ 为什么是 `Decoration` 而不是 `Border`：Flutter 的 [Border] 在
  /// `borderRadius != null` 时强制四边**同色**（`A borderRadius can only be given
  /// on borders with uniform colors`），而拟态胶囊/卡片都是圆角 ⇒ 必须自绘
  /// [BevelDecoration] 才能给每条边独立上色。直接把结果传给 `Container.decoration`。
  ///
  /// [base] 不传时取 [raisedFill]（同材质抬起的块）；浮层类传 [floatSurface]、
  /// 面板类传其 panel 底，bevel 自动贴合该底面、保持同一光线方向。
  ///
  /// - [raisedBevel]：凸块（顶左受光、底右背光），读作"鼓起来"。
  /// - [sunkenBevel]：凹块（顶左背光、底右受光），读作"刻进去"。
  static Decoration raisedBevel(
    Brightness brightness, {
    Color? base,
    BorderRadius radius = BorderRadius.zero,
  }) {
    final Color c = base ?? raisedFill(brightness);
    return BevelDecoration(
      radius: radius,
      light: Color.lerp(c, Colors.white, brightness == Brightness.light ? 0.5 : 0.10)!,
      dark: Color.lerp(c, Colors.black, brightness == Brightness.light ? 0.12 : 0.35)!,
      fill: c,
    );
  }

  static Decoration sunkenBevel(
    Brightness brightness, {
    Color? base,
    BorderRadius radius = BorderRadius.zero,
  }) {
    final Color c = base ?? raisedFill(brightness);
    // 凹陷 = 受光的亮边在底右、背光的暗边在顶左 ⇒ 把 light/dark 对调传给
    // BevelDecoration（它的 light 画顶左、dark 画底右）。
    return BevelDecoration(
      radius: radius,
      light: Color.lerp(c, Colors.black, brightness == Brightness.light ? 0.12 : 0.35)!,
      dark: Color.lerp(c, Colors.white, brightness == Brightness.light ? 0.5 : 0.10)!,
      fill: c,
    );
  }

  /// 圆角安全的逐边上色 bevel：四向独立色（顶左 light / 底右 dark），无模糊。
  /// 见 [raisedBevel] / [sunkenBevel]。
  static BevelDecoration bevelOf({
    required BorderRadius radius,
    required Color light,
    required Color dark,
    Color? fill,
    double width = 1,
  }) =>
      BevelDecoration(radius: radius, light: light, dark: dark, fill: fill, width: width);

  /// **卡片/导航项的填充**（WinUI `CardBackgroundFillColorDefault` 同款）：
  /// 直接坐在窗口底上。暗色 = **白 5%（提亮）**，亮色 = 白 70%。
  ///
  /// 半透明**纯色** ⇒ 每像素一次混合、**不产生 saveLayer**（成本 ≈ 不透明纯色）。
  /// ⚠️ 想调透感就改这里的 alpha，**不要**用 `Opacity`/`AnimatedOpacity` widget
  /// （那才强制 saveLayer），也**不要**碰 `BackdropFilter`（模糊是红线）。
  ///
  /// ⚠️ **不要**给常驻内容加"面板底"：曾按 WinUI `LayerFillColorDefault` 铺过
  /// `#3A3A3A`@30%——灰罩在窗口底上显"脏"（2026-09-22 与系统设置并排对比后否决，
  /// 记录在 `docs/ui_rewrite_plan.md` §5.6）。
  static Color cardFill(Brightness brightness) => brightness == Brightness.dark
      ? Colors.white.withValues(alpha: 0.05)
      : Colors.white.withValues(alpha: 0.70);

  /// [cardFill] 的悬停/选中态：**叠在 [cardFill] 上的量**（与 [hoverOverlay]
  /// 同构——交互态一律是"再叠一档"，不是换色）。
  static Color cardFillHover(Brightness brightness) =>
      brightness == Brightness.dark
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.white.withValues(alpha: 0.80);

  /// [cardFill] 的极淡描边（读作"边缘"不是"线"）：暗 = 白 6%，亮 = 黑 6%
  /// （WinUI `CardStrokeColorDefault` 量级）。
  static Color cardStroke(Brightness brightness) =>
      brightness == Brightness.dark
      ? Colors.white.withValues(alpha: 0.06)
      : Colors.black.withValues(alpha: 0.06);

  /// **窗口渐变底**（§5.6；2026-09-22 当过半天窗口底，**当天即被纯色取代** ⇒ 现在未挂载）。
  ///
  /// 留着它是因为"想要渐变味道"的路没关——但**唯一正解是同时抖动**（`FragmentShader`
  /// 里做有序抖动，只在量化前加一次噪点），见 [WindowBase] 与 `docs/ui_rewrite_plan.md` §5.6。
  ///
  /// - 暗 = `#0D0C0A → #141310`，亮 = `#F5F4F0 → #FBFAF7`，**对角向**
  /// - **暖调一致**：明暗两侧**同向偏暖**——不做"暗冷亮暖"，那会色温断裂（切换
  ///   主题时像换了个应用）
  /// - ⚠️ 两端只差 **6~7 个 8-bit 台阶** ⇒ 铺满全屏（≈2900 逻辑 px）时
  ///   **每 ~420px 一条**能看见的色带（2026-09-22 用户实报）——**台阶数 = 色带数**，
  ///   这就是它被撤掉的原因。
  /// ⚠️ **铁律：两端每通道差 ≤ 10/255（≈4% 明度）**——淡到说不出哪里变了才对，
  /// 能看出"这是个渐变"就廉价了（有测试钉着）。窗口材质不做，这条历史留着。
  static LinearGradient windowGradient(Brightness brightness) =>
      brightness == Brightness.dark
      ? const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF0D0C0A), Color(0xFF141310)],
        )
      : const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFFF5F4F0), Color(0xFFFBFAF7)],
        );

  /// **窗口底的噪点强度**（§5.6）：暗 3% / 亮 1.5%。
  ///
  /// ⚠️ **当前未挂载**（`WindowBase` 里没有它）：撤销微渐变后**没有色带可治**——
  /// 纯色在 8-bit 下不产生色带；而"独立噪点图层"也治不了渐变的色带
  /// （2026-09-22 实测：摘掉它色带仍在、加回它更重）。留作"想要颗粒感"的现成件。
  /// ⚠️ **铁律 ≤ 5%**——超过就"脏"（与板底同一条教训），有测试钉着。
  static double windowNoiseAlpha(Brightness brightness) =>
      brightness == Brightness.dark ? 0.03 : 0.015;

  /// 噪点颗粒的颜色：暗色底用**白粒**（黑粒在近黑底上看不见），亮色底用**黑粒**。
  static Color windowNoiseGrain(Brightness brightness) =>
      brightness == Brightness.dark ? Colors.white : Colors.black;

  /// **纸面噪点强度**（2026-09-26 提亮：亮色由 `0` 提到 `2%`，与暗色一致）：
  /// 明暗**都挂 2%**。挂在 `home_screen.dart` 的 `_PaperNoise`，日历面板复用它。
  ///
  /// ## 为什么亮色原来是 `0`
  /// 2026-09-22 那次是"**先只做暗色**一版看对比"的临时设定，被留在了代码里；
  /// 后果是亮色界面**完全看不见颗粒**，被反馈"看不出颗粒感"。2026-09-26 提到
  /// `2%` 与暗色一致，仍守"≤ 5%、不脏"的铁律（见 [windowNoiseAlpha]）。
  ///
  /// ⚠️ **纯审美，不治任何东西**：纸面是纯色 ⇒ **没有色带**（色带是渐变的产物）。
  /// 效果 = 纸感/颗粒，暗色下能破掉大面纯色的死板；**代价**是纸面就是阅读面，
  /// 颗粒直接铺在字下面——字本身不糊（字画在噪点之上），但字周的局部对比被削一档。
  /// ⚠️ **≤ 2%**：比窗口底那档更保守，因为它离正文更近（有测试钉着）。
  static double paperNoiseAlpha(Brightness brightness) => 0.02;

  /// **Callout 块的底色**（`callout` 块；节点没存颜色时的回退值）。
  ///
  /// 与 [floatSurface] 同一"抬/降一档"思路，但**方向相反**：浮层要"浮起"
  /// （比纸面亮），而 callout 是**纸面上的一个记号**，要能一眼看出"这是块里
  /// 的一块"——亮色取比纸面深一档、深色取比纸面亮一档。
  ///
  /// ⚠️ 它是**懒解析**的目标：callout 节点默认**不存**颜色（`transparent`
  /// 哨兵），渲染时才来取这里 ⇒ 改这个色、切明暗，存量笔记自动跟着变，
  /// 不需要迁移文档（官方同款技巧）。
  ///
  /// ⚠️ **暗色的值也是"绝对色"、必须跟着纸面抬**：它原本是 `#222222`（L\* 13.2），
  /// 而纸面 2026-09-22 抬到了 `#232321`（L\* 13.7）⇒ 不抬就**比纸面还暗**，
  /// callout 从"纸面里的一块记号"变成"纸面上挖的坑"。现值 `#2F2F2F`（L\* 19.4，
  /// 与 [floatSurface] 同值 —— 这是它一直以来的口径），比纸面亮的关系保持不变。
  static Color calloutBackground(Brightness brightness) =>
      brightness == Brightness.light
      ? const Color(0xFFF2F2F2)
      : floatSurface(brightness);

  /// 浮层投影高度——**浮层三件套**之一（另两件：[floatSurface] 底色、
  /// [menuBorder] 描边）。
  ///
  /// 浮层底色与纸面**只差一档明度**，所以"浮起"主要由这三件套一起表达；
  /// 缺任何一件，浮层都会退化成"内容自己看起来像个面板"。
  static const double menuElevation = 6;

  /// 浮层描边——**浮层三件套**之一。
  ///
  /// ⚠️ **必须钳到 APCA Lc 22**（2026-09-22 体检出来的）：`outlineVariant` 在暗色下
  /// 压在 `floatSurface`（当时是 `#222222`）上只有 **Lc −8.2**——那不是"淡"，是**看不见**，
  /// 三件套白缺一件。钳制对亮色是空操作（实测 Lc 30.6 已达标）。
  /// ⚠️ [width] 默认 **发丝宽**（0.5 逻辑 px，见 [Tokens.hairlineWidth]）：用户实机反馈
  /// "菜单边框线再细一点"（2026-09-22）。与"看得见"不冲突——细线靠**颜色对比**兜底，
  /// 宽度只负责"薄"（所以那个 Lc 22 不能跟着降）。
  ///
  /// ⚠️ **唯一要传 1 的调用方是 [neuFloatBar]**（编辑器浮动工具条）：它的**外高按
  /// "38 + 上下各 1px"算**，宽度一变小就与预测器脱节（`fixed_toolbar_test` 与
  /// `app_theme_test` 各有一条闸门钉着"浮条描边必须 1px"）。菜单/面板不受影响。
  static BorderSide menuBorder(
    ColorScheme scheme, {
    double width = Tokens.hairlineWidth,
  }) => BorderSide(
    width: width,
    color: menuBorderColor(scheme.outlineVariant, scheme.brightness),
  );

  /// [menuBorder] 的**裸色版**（只收描边基色 + 明暗）——给走**官方 material** 的
  /// 编辑器子树用：那边是官方 `ColorScheme`，与应用侧的 `material_ui` 类型不通
  /// （背景见 `editor/widgets/float_menu_style.dart` 的文档）。
  /// 阈值与钳制**只在这一处**，别在调用点再写一个 22。
  ///
  /// ⚠️ **参考底有两个，两个都要钳**（2026-09-22 改）：
  /// - [menuFillOver]：主菜单那种**半透明**档的合成色；
  /// - [floatSurface]：**实色**浮层（面板 / 工具栏 / 卡片的那种底）。
  ///
  /// 早先只钳前者，理由是"半透明合成色更贴近窗口底 ⇒ 更严苛"——**这个判断只在暗色浮层
  /// 比底亮一点点时成立**。2026-09-22 暗底抬到 +2 档、浮层跟着抬到 `#3C3C3C`（L\* 25.3）
  /// 之后，实色浮层成了**更亮的那个** ⇒ 反而更严苛，一行当场掉到 Lc −20.9（需 22）。
  /// ⇒ 改成**两个底都钳一遍**（`withMinLc` 在已达标时是恒等操作，不会叠加过冲）。
  static Color menuBorderColor(Color outlineVariant, Brightness brightness) =>
      withMinLc(
        withMinLc(
          outlineVariant,
          menuFillOver(brightness, windowBackground(brightness)),
          22,
        ),
        floatSurface(brightness),
        22,
      );

  /// 浮层投影——**双层软阴影**（2026-09-19 起 Apple 菜单口径，替换单层
  /// Material 投影）：
  ///
  /// - **贴地影**：小 offset + 小 blur——把浮层"锚"在纸面上方一点点，没有它
  ///   大 blur 的影子会显得物体飘在半空没有接地感；
  /// - **环境影**：大 offset + 大 blur + 低不透明度——表达"悬浮高度"。
  ///
  /// 单层 Material 投影（原 [menuElevation]）只有一档硬度，观感偏"安卓"；
  /// 双层是 macOS / iOS 浮层菜单的共同做法。**只有 [AppFloatSurface] 消费**：
  /// 官方 Material 菜单的自定义阴影列表塞不进 `PopupMenuThemeData`，仍走
  /// [menuElevation] 单层（深色下 MATERIAL 单层阴影本来就偏弱，由
  /// [menuBorder] 描边与底色差补足层次）。
  static List<BoxShadow> floatShadows(Brightness brightness) =>
      brightness == Brightness.light
      ? const <BoxShadow>[
          BoxShadow(
            color: Color(0x14000000),
            offset: Offset(0, 1),
            blurRadius: 2,
          ),
          BoxShadow(
            color: Color(0x1F000000),
            offset: Offset(0, 8),
            blurRadius: 24,
          ),
        ]
      : const <BoxShadow>[
          BoxShadow(
            color: Color(0x59000000),
            offset: Offset(0, 1),
            blurRadius: 2,
          ),
          BoxShadow(
            color: Color(0x8C000000),
            offset: Offset(0, 10),
            blurRadius: 28,
          ),
        ];

  /// **发丝描边**：`outlineVariant` 打四折——[neuFloatBar] 的边界补丁。
  ///
  /// 比 [menuBorder] 淡得多是刻意的：它**不承担**"浮层三件套"那种边界职责，
  /// 只在双向柔光之外补一条底线——"压在文字上时也看得清轮廓"。
  /// 用满档 `outlineVariant` 会让轻拟态退回普通描边浮层，柔光就白做了。
  static BorderSide hairlineBorder(ColorScheme scheme) =>
      BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4));

  /// **浮动工具条**的装饰：与菜单/面板同口径的"浮层三件套"——
  /// [floatSurface] 底色 + [menuBorder] 描边 + 单向下投投影。
  ///
  /// ## 与轻拟态的取舍（2026-09-16 改）
  /// 此前工具条走"轻拟态"：特意取**纸面同色** [contentCanvas] + 双向柔光 +
  /// 极淡发丝描边，靠"受光/背光"读作浮起。问题是底色与编辑页逐像素同色、
  /// 描边又只有 `outlineVariant*0.4`，压在密集文字上时**几乎看不出边界**——
  /// 用户反馈对比度不足、像"融进纸里"。
  ///
  /// 改回浮层三件套口径（与菜单 / 查找面板一致）：
  /// - 底色 [floatSurface]：亮色 `#FFFFFF` / 深色 `#3C3C3C`，与纸面各抬一档
  ///   （亮 **+2.5 L\*** / 深 **+11.6 L\***），本身就是一道明确明度差；
  /// - 描边 [menuBorder]（满档 `outlineVariant`）：清晰勾边，不再含蓄；
  /// - 浮起感由 [floatSurface] 与这圈 1px 描边的明度差承担（无模糊柔影，
  ///   2026-10-12 用户定"拟态不用阴影"）。
  /// 三者叠加，条在亮/暗两种模式下都明显浮在纸面上。
  ///
  /// ⚠️ 用本装饰的调用方仍要把这 1px 描边算进布局（见
  /// `note_editor_view_appflowy.dart` 的 `padding` / `floatingToolbarHeight`
  /// 等量补偿）。[menuBorder] 也是 1px，与原 `hairlineBorder` 同宽 ⇒ 补偿不变。
  static BoxDecoration neuFloatBar(Brightness brightness, ColorScheme scheme) =>
      BoxDecoration(
        color: floatSurface(brightness),
        borderRadius: BorderRadius.circular(Tokens.radiusLg),
        // ⚠️ **显式 1px**（不是菜单那档发丝宽）：本条的**外高 = 38 + 上下各 1px**，
        // 宽度一改就与预测器/布局补偿脱节（两条闸门钉着）。
        // 2026-10-12：去掉 [neuShadows] 双向柔影，浮起感交给 floatSurface 与这圈
        // 1px 描边（用户定"拟态不用模糊阴影"）。
        border: Border.fromBorderSide(menuBorder(scheme, width: 1)),
      );

  /// ── 语义令牌（透明度比例收敛）────────────────────────────
  ///
  /// 业务代码一律从这三处取，不要手写 `withValues(alpha: ...)` 的比例——
  /// 颜色来自 scheme（换主题安全），但比例散在各文件会渐渐失同步。

  /// 分隔线：`outlineVariant` 打六折，但仍弱于 [menuBorder]（浮层要被"挑"出来，
  /// 分隔线只需"分"）。用于：左右分区界线、工具栏分组线、目录面板侧边线、**画布网格**。
  ///
  /// ⚠️ **必须钳到 APCA Lc 20**（2026-09-22 体检）：暗色下 `outlineVariant@60%` 叠在
  /// 当时的近黑底上只剩 **Lc 0.0**——线**完全不可见**（亮色侧 15.0，也刚踩在"任何
  /// 非文本元素的最低线"上）。钳制对亮色是轻推（15 → 20），对暗色是**从 0 救回来**。
  ///
  /// 参考底取**最严苛**的那个（同一个色压在不同的底上 Lc 不同）：
  /// 亮色的线**比底暗** ⇒ 越暗的底越苛刻 ⇒ 取**纸面**；暗色的线**比底亮** ⇒
  /// 越亮的底越苛刻 ⇒ 取 [floatSurface]。取反了就会出现"按白底算达标、
  /// 画在纸面上只有 15.9"（体检表当场抓到过一次）。
  /// ⚠️ 与 [menuBorder] 同一个机制（[withMinLc]），但阈值更低：它只需"分"，不必"挑"。
  static Color divider(ColorScheme scheme) {
    final Brightness b = scheme.brightness;
    final Color reference = b == Brightness.light
        ? contentCanvas(b)
        : floatSurface(b);
    return withMinLc(
      scheme.outlineVariant.withValues(alpha: 0.6),
      reference,
      20,
    );
  }

  /// 状态层：悬停高亮（M3 状态层同语言，`onSurfaceVariant @ 12%`）。
  /// 用于：工具栏按钮槽位等自绘交互件；IconButton 系走 M3 默认不用它。
  static Color stateLayer(Color base) => base.withValues(alpha: 0.12);

  /// 状态层（按下）：比 [stateLayer] 重一档——"按住"要比"悬停"更实，
  /// 两者同为 12% 时按下几乎看不出变化。
  static Color stateLayerPressed(Color base) => base.withValues(alpha: 0.18);

  /// **「当前项」选中药丸的底**（2026-10-08 用户拍板：全局统一换装）：
  /// `Colors.transparent`——**无底色**（2026-10-11 用户定：选中态去掉任何背景
  /// 填充，和未选中按钮完全一样，只靠前景色——图标/文字 `onSurface` vs 未选中
  /// `onSurfaceVariant`——区分"当前项"）。hover / press 由各自按钮默认叠层承担，
  /// 与未选中按钮行为一致。
  ///
  /// 用于：nav_rail 目的地行、笔记列表项、目录激活项、设置左导航、命令/
  /// 搜索面板行、视图 tab、日历选中日、跳转闪烁块、分段控件选中段
  /// ——**「当前项」选中一律用它**，不要自己挑比例（分叉的根因）。
  /// ⚠️ **开关态（开/关如实显示）不在此列**，仍走 [navSelectedTint]。
  static Color selectedPill(ColorScheme scheme) => Colors.transparent;

  /// **开关态的底**（开 = `onSurface @ 10%`）：AI 轨开关这类"开/关如实显示"
  /// 的控件用它——那是状态镜像，不是"我在哪"的选中读法。
  ///
  /// 2026-10-08 起「当前项」选中已全部改走 [selectedPill]（用户拍板全局统一），
  /// 新代码别再拿它当选中底（旧口径的分叉根因）。
  static Color navSelectedTint(Color onSurface) =>
      onSurface.withValues(alpha: 0.10);

  /// 当前主题的**明度序**（`surface_ladder.dart`）：应用里每一块"面"的底色都从它取。
  ///
  /// **抬档 = 改 `SurfaceLadder.dark.baseLstar` 一个数**（或 `light` 那份），
  /// 底 / 纸面 / 浮层 / 板底会一起动 —— 这是 2026-09-22 把"四处绝对色值"收成一张表的原因。
  /// ⚠️ 文字档**不在**明度序里（它们被对比度闸门夹住），抬完档要重验
  /// （`app_theme_test` + `apca_audit_test` 会当场报）。
  static SurfaceLadder ladder(Brightness brightness) =>
      brightness == Brightness.light ? SurfaceLadder.light : SurfaceLadder.dark;

  /// **统一焦点环**（`docs/ui_rewrite_plan.md` §5.2）：`primary`
  /// [Tokens.focusRingWidth] 描边。
  ///
  /// 取 primary 是**合法**的：§2.2 的三语义里，"我在哪"（焦点）正是其一。
  /// 画在**边界内侧**（`foregroundDecoration`）——理由见 [Tokens.focusRingWidth]
  /// 与 `theme/focus_ring.dart`。
  ///
  /// 界面统一用 [FocusRing] 这个 widget，不要各自拼 BoxDecoration。
  static BoxDecoration focusRing(
    ColorScheme scheme, {
    required BorderRadius borderRadius,
  }) => BoxDecoration(
    border: Border.all(color: scheme.primary, width: Tokens.focusRingWidth),
    borderRadius: borderRadius,
  );

  /// **窗口底**（纯色）：主页整屏铺它；笔记 / 画布页整块铺 [contentCanvas] 盖住它。
  ///
  /// 三处共用：
  /// 1. 主题的 `surface`，作为整套色板的基准；
  /// 2. `main.dart` 的 `MaterialApp.builder` ⇒ **全路由共用一层底**（主页的 6px 缝、
  ///    笔记页侧栏区都吃到它）；
  /// 3. 没铺到纸面的区域（浮层之间的缝、过渡帧）。
  ///
  /// ## 取值来自**明度序**（`surface_ladder.dart`，2026-09-22 起）
  /// 这里**不再写死 hex**：值是 [ladder] 的 `base` 档（亮 L\* 88.1 = `#DDDDDB`
  /// chrome 灰，暗 = `#080806`：CIE 分段尺 L\* 2.2，本仓连续尺 −0.33，都是
  /// [SurfaceShape.warm] 的 H=60° 极淡暖调；双尺说明见 `surface_ladder.dart`）。
  /// 2026-10-09 晚亮色两度下压：94.5 → 91.2 → **88.1**（白卡悬浮感改靠
  /// [panelShadow] 软投影 + 更深的 chrome 色阶）。
  /// ⇒ **抬/压档 = 改 `SurfaceLadder` 里的 `baseLstar` 一个数**。
  /// 注意 2026-10-09 起 [floatSurface] / [boardFill] 改成**绝对明度钉死**
  /// （不再跟随底），改底只动底与 panel 相对档。
  ///
  /// ## 暗色底的轨迹（三度定案）
  /// L\* 1.8（近黑，2026-09-22 前）→ 抬到 **7.67**（嫌太黑、想给暗侧手法留空间）
  /// → 2026-10-09 对照 opencode 实机压回 **2.2**（用户："颜色完全按照
  /// #080808 / #161616，同版也可以"）。回头看 7.67 版的问题是：工作区浮面
  /// 与底都在中间灰段，Δ 再大也发闷；近黑 chrome 一压，浮面自己就"浮"了。
  /// 近黑底下"往下走"的手法（黑影 / 凹陷）确实没空间——新外壳改用**往上**
  /// 的光边（[panelEdge]）+ 明度差 + 暗缝表达层次。
  ///
  /// ## 与 [contentCanvas] 的关系（2026-09-22 用户定：**同色**）
  /// 纸面**直接复用它** ⇒ 主页 / 笔记页同一个底。
  /// ⚠️ **改这里的值 = 同时改纸面**（两处共用一个令牌，这是刻意的：不许再漂开）。
  /// 2026-10-09 后桌面编辑区实际铺在浮面卡 [panelFill]（#161616）内，这档
  /// #080808 主要是 chrome / 缝隙与移动端纸面；近黑对正文文字对比只增不减。
  ///
  /// ## 余量（改之前先看这里）
  /// 亮 L\* 97.5 ⇒ 到纯白只剩 2.5，**亮色那一边"白侧没空间"**（白高光 / 白内边在
  /// 亮色下天然隐形，只能靠暗侧承力）；暗 L\* 2.2 ⇒ 往下到纯黑只剩 2.2
  /// （黑影 / 凹陷几乎没空间），**但往上到浮层有 17.2**——暗侧层次一律向上做
  /// （亮面 / 光边），这与 2026-10-09 的浮面外壳正好同向。
  ///
  /// 另：它是 `scheme.surface` 的基准，改它会牵动 M3 派生的 container 系列；
  /// 本项目的浮层一律走 [floatSurface] / `AppFloatSurface`，不受影响。
  ///
  /// 2026-10-09 起**明暗都走 [ladder]**：亮色不再特判 `#F7F7F5`
  ///（2026-09-26 的破例作废）——当晚三度定档：grouped 灰 `#EFEFED`（94.5）
  /// 白卡读不出悬浮 → `#E6E6E4`（91.2）→ **`#DDDDDB`（88.1）**，配白卡软投影
  ///（[panelShadow]），与暗色 #080808 / #161616 各走各的高度语言。
  ///
  /// ⚠️ 它同时是移动端纸面（[contentCanvas] 复用它）⇒ 改它 = 改移动端阅读底色
  /// （桌面编辑区在纯白 / #16 浮面卡内，不受这档影响）。
  static Color windowBackground(Brightness brightness) =>
      ladder(brightness).base;

  /// 编辑器中性色板：对标 Notion / Obsidian / Typora 文档风（GitHub-Flavored
  /// Markdown 观感），正文 / 代码 / 光标 / 选区 / 标记走中性系、不随种子色；
  /// 唯独 [editorLink] 吃 [ColorScheme.primary]（与引用块竖条同族，让链接即
  /// 品牌色，2026-09-17 由写死青色改为跟随主题）。
  /// 行内代码 / 代码块用中性灰底；光标 / 选区 / 标记 / 激活态全部走 onSurface 中性系。
  /// **编辑器正文色**（正文 / 标题 / 列表 / 引用 / 代码块里的一切内容文字）。
  ///
  /// ## 口径：**APCA**（不是 WCAG），两边落在 **Lc ±90**
  /// WCAG 的 4.5 / 7 只是**下限**，而且它**对深色严重高估**（APCA 官方口径：WCAG 的
  /// 4.5:1 在近黑底上可能实际不可读）——这正是此前"暗色 12.5 还是 13.5:1"越调越
  /// 没把握的原因：**那把尺子在深色里是失灵的**。改用 APCA 档位
  /// （`docs/ui_rewrite_plan.md` §5.6）：
  /// **正文首选 Lc 90**（≥14px / 400）、**最低 Lc 75**；**暗色上限约 −90**（初步结论，
  /// 再高就是"字在发光"）。背后是**对比恒常性**：过了临界对比，再加大对比**不会**更好读。
  ///
  /// | | 取值 | 对 [contentCanvas] | APCA |
  /// |---|---|---|---|
  /// | 亮 | `#3A3A3A` | `#F4F4EF` | **Lc ≈ +89.5** |
  /// | 暗 | `#DDDDDD` | `#222221` | **Lc ≈ −83.6** |
  ///
  /// 📌 **亮色那格是回来过的**：chrome 压到 `#DDDDDB`（L\*88.1）那版它只剩
  /// **+76**，离正文最低档 75 只差 1 —— 抬回类纸暖白（L\*96）后回到 +89.5，
  /// 正好落在首选档 90 上。这也是"别再往下压 chrome"的硬理由。
  ///
  /// ⚠️ **暗色那格是靠一次"翻转"才松绑的**（2026-10-10）：
  /// ① 第③步把底从近黑抬到 L\*13，而当时内容区是**浮面**（L\*18）⇒ 主阅读面
  ///    偏亮，Lc 只剩 **−81.8**，离闸门下界 −80 只差 **1.8**；
  /// ② 用户实机反馈"面板有点亮" ⇒ 内容区由浮面翻转为**凹陷**（L\*9）。主阅读面
  ///    变暗 ⇒ Lc 回到 **−84.7**，余量 **4.7**。
  ///
  /// 📌 **以后调暗色的杠杆是"压暗内容区"，不是"提亮正文"**：正文被"必须比
  /// `onSurface` 更柔"夹着（它现在 −86.1），往上提的空间很小；而内容区越暗，
  /// 正文对比越好、发光面积也越小 —— 两个好处同向。
  ///
  /// ⚠️ **亮色刻意不取 `onSurface`**：那档是 `#1A1A1A`（Lc **+100**），比首选档黑了
  /// 10 级，长文偏"刺"。现在与 Notion 同档（它正文默认 `#37352F`）。
  /// ⚠️ **暗色别越过 −90**：`#DDDDDD` 已到 −86，`onSurface`（≈`#E3E3E3`）是 −88.3。
  /// ⚠️ APCA 档位以 **Helvetica/Arial** 为基准，**中文笔画更细**，且我们正文 13px
  /// （低于 14px 那档）⇒ **取偏上值**（往 90 靠，别往 75 靠）。
  ///
  /// ## 只作用于编辑器内容
  /// 界面文字（侧栏 / 菜单 / 工具栏 / 字数条）继续走 `scheme.onSurface`——短文本、
  /// 小字号、不承担长文阅读，**越高越好**，不跟着收。
  ///
  /// ## 历史（看懂那几笔取舍）
  /// 2026-09-15 定的是 WCAG 口径的"纸面抬一档 + 正文降一档，14.6 → **12.5:1**"，
  /// 目的是压 halation；2026-09-22 换 APCA 后**两边都重算**：亮色往回收、暗色往上去。
  ///
  /// ⚠️ 视图里**两处**必须同时取它：`EditorStyle.textStyleConfiguration` 与
  /// `BlockHeightPredictor` 的那份（预测器复刻渲染 span，两处不同源就会脱节）。
  static Color editorText(Brightness brightness, ColorScheme scheme) =>
      brightness == Brightness.dark ? _textDark : _textLight;

  /// 暗色档正文字色（对纸面 **Lc −86**）。[editorText] 与 [canvasInk] **共用**同一个常量：
  /// 画布墨迹必须与正文一个字色，否则同一份内容在两处是两种黑。
  ///
  /// ⚠️ 它被**两条闸门同时夹住**，窗口很窄（`app_theme_test` 两条都钉在这一档上）：
  /// 1. **APCA 舒适带** `[−92, −84]`（暗色上限约 −90，越过去就是"字在发光"）；
  /// 2. **必须比 `onSurface` 更柔**（护眼取向：正文不该是界面上最亮的字）。
  /// 📌 2026-09-22 暗底抬档时试过 `#E0E0E0`（+2 档下 `#DDDDDD` 只剩 −83.5、掉出下界），
  /// 最终**回到 +1 档** ⇒ 这个值可以不动（实测 −85.5 左右，两条闸门都过）。
  static const Color _textDark = Color(0xFFDDDDDD);

  /// 亮色档正文字色（对类纸暖白 `#F4F4EF` 实测 **Lc +89.5**，正好在首选档 90 上）。
  /// **刻意不等于** `scheme.onSurface`（那是 `#1A1A1A`、Lc +100）——界面文字越高
  /// 越好，长文正文要高得**刚好**。
  static const Color _textLight = Color(0xFF3A3A3A);

  /// 画布**墨迹**色（`kThemeInk` 色的笔迹按它绘制，见
  /// `CanvasController.pictureFor` / `resolveInk`）。
  ///
  /// 画布底色随主题（[contentCanvas]：亮 `#DDDDDB` / 暗 `#161616`），墨色必须
  /// **一起走**——否则就是"黑墨画黑纸"：暗色纸面上的 `#1F1F1F` 几乎不可识别
  /// （2026-09-17 用户截图反馈"暗色下有点不可识别"）。
  ///
  /// - **亮色** `#1F1F1F`：与哨兵 `kThemeInk`（`ink_stroke.dart`）**同值**
  ///   ⇒ 亮色下渲染逐像素不变、存量画布观感零回归。这个等价性由
  ///   `test/canvas/canvas_ink_test.dart` 钉住（不靠注释约定）；
  /// - **暗色** `#E0E0E0`：与 [editorText] 暗色同值（**Lc −85.3**），对 `#232321` 约 11.9:1。
  static Color canvasInk(Brightness brightness) =>
      brightness == Brightness.dark ? _textDark : const Color(0xFF1F1F1F);

  /// 链接色：取主题 `primary` **原色**，但**钳到 APCA Lc 80**（正文档）。
  ///
  /// 取向仍是"种子即主色、不稀释"（与引用块竖条同源、明暗自动跟随）；钳制只在
  /// **不达标时**才动它 ⇒ 多数种子（如默认青 `#0ABAB5`）拿到的就是原色。
  ///
  /// ⚠️ 为什么非钳不可（2026-09-22 体检）：`primary` 是**用户可换的种子色**，
  /// 深种子（蓝 `#002FA7` / 洋红 `#990F4B`）压在近黑底上只有 **1.83:1**（Lc ≈ −20）
  /// ——链接是**正文级**内容，即使有下划线也读不了；亮色侧同样吃紧（默认种子只有
  /// **Lc 44.8**，低于正文最低档 75）。写死一个"够亮的链接色"不行：换个种子又坏了。
  static Color editorLink(ColorScheme scheme) =>
      withMinLc(scheme.primary, contentCanvas(scheme.brightness), 80);

  /// **代码块语法高亮配色**（8 个 token 类，明暗两套）。
  ///
  /// ⚠️ 色相参考 Material / One Dark 的观感，但**明度全部按 APCA 重定**
  /// （2026-09-22 体检：原表 8 色里亮色有 7 个、暗色有 5 个低于 `Lc 65`，
  /// 暗色 `comment` 更是只有 −16.9——注释等于看不见）。
  /// 消费方：`notes/services/note_code_syntax.dart`（`_tokenStyle`）与体检表
  /// `test/theme/apca_audit_test.dart`（**同一份事实，不许各留一份**）。
  ///
  /// 档位：代码是**短 token 但属正文级阅读面** ⇒ 取 **≥ 65**（正文最低 75 与
  /// 非分栏文本 60 之间）。底色是 [editorCodeBlockBg]。
  static Map<String, Color> syntaxColors(Brightness brightness) {
    final bool dark = brightness == Brightness.dark;
    return <String, Color>{
      // 关键字 / 字符串 / 数字（字面量）
      'keyword': dark ? const Color(0xFFD9B5F1) : const Color(0xFF643ECF),
      'string': dark ? const Color(0xFFC3E88D) : const Color(0xFF276A2B),
      'number': dark ? const Color(0xFFFAB19B) : const Color(0xFF914900),
      // 注释（最容易被写得太淡的一档）
      'comment': dark ? const Color(0xFFC4C7CC) : const Color(0xFF5A5E63),
      // 函数名 / 类名
      'title': dark ? const Color(0xFFA6C3FF) : const Color(0xFF016194),
      // 属性 / 变量
      'attr': dark ? const Color(0xFFFFABB9) : const Color(0xFFAD164D),
      // 内建 / 类型
      'built_in': dark ? const Color(0xFF89DDFF) : const Color(0xFF026099),
      // 元信息（预处理指令等）——沿用中性灰
      'meta': dark ? const Color(0xFF89DDFF) : const Color(0xFF5E5E5E),
    };
  }

  /// 行内代码 / 代码块底色：**纯中性灰**（R=G=B），刻意不染暖色。
  ///
  /// 之前亮色是 `#EDEBE6` / `#E6E1D8`——R>G>B 的暖米调，与代码语法的
  /// 冷色高亮（紫/蓝）叠在一起发黄。2026-09-17 用户定案改中性。
  ///
  /// 亮色明度阶梯（纸面 → callout → 行内代码 → 代码块，逐级"凹"进纸面）：
  /// `#FAFAFA` → `#F2F2F2` → `#EFEFEF` → `#E2E2E2`。
  ///
  /// 行内与块**有意拉开 13 个灰阶**：两者同色族（"代码"语义一眼认出），但
  /// 分量不同——行内是轻提示（浅、贴文字），块是重容器（深、自带圆角/复制
  /// 按钮/语法高亮）。之前只差 8 阶，肉眼分不出，用户反馈"长得一样"。
  ///
  /// 暗色原本就是中性（`#363636` / `#2E2E2E`，R=G=B），保持不动；
  /// 相对暗纸面 `#161616` 各抬约一档半，凹进关系成立。
  static Color editorInlineCodeBg(Brightness brightness) =>
      brightness == Brightness.light
      ? const Color(0xFFEFEFEF)
      : const Color(0xFF363636);
  static Color editorCodeBlockBg(Brightness brightness) =>
      brightness == Brightness.light
      ? const Color(0xFFE2E2E2)
      : const Color(0xFF2E2E2E);
  static Color editorSelection(Brightness brightness) =>
      brightness == Brightness.light
      ? const Color(0x2E1C1B1A)
      : const Color(0x4DFFFFFF);
  // 光标 / 列表标记 / 工具栏图标 → 复用既有 scheme.onSurface /
  // onSurfaceVariant（已退染色相，纯中性）。

  /// 中文回退字体链。
  ///
  /// Flutter 桌面端默认字体是打包的 Roboto，不含任何汉字；引擎逐字符
  /// 回退时可能给不同汉字挑到不同系统字体（flutter#103811），表现为
  /// 同一段文字笔画粗细不一。显式统一回退链修复：
  /// Windows 命中雅黑 UI，macOS 命中苹方，Android 命中 Noto CJK。
  static const List<String> cjkFontFallback = <String>[
    'Microsoft YaHei UI',
    'PingFang SC',
    'Noto Sans CJK SC',
  ];

  // ── 排版单一来源（Typography tokens）──────────────────────
  // quill 不继承 Ambient 样式、要求显式完整 TextStyle，编辑器相关
  // 字体/颜色必须显式给——但值要统一从这里引用，禁止散落字面量。

  /// **全应用主字体：打包的霞鹜新晰黑·屏幕阅读版**（`assets/fonts`，SIL OFL
  /// 可商用；pubspec `fonts:` 注册，字族名与声明一致）。界面的
  /// `ThemeData.fontFamily` 与编辑器正文都取它——全应用一套字形。
  ///
  /// ## 为什么从"按平台选系统字体"换成打包字体
  /// 原方案按平台选雅黑 / 苹方 / 思源（各自中英同源、基线一致），但各平台
  /// 观感不统一。屏幕阅读版自带中英全套字形 ⇒ 混排天然同源、基线恒定，
  /// 且**全平台同一份文件**，观感一致；楷黑轮廓**轻微加粗**（暗色主题笔画
  /// 不发虚）、**度量特调**（降部加大，墨迹在自然行盒内更居中），针对屏幕
  /// 长文阅读调校。
  ///
  /// 回退链 [cjkFontFallback] 仍要保留：打包字体缺字（生僻字 / emoji /
  /// 其它语种）时逐字体兜底。
  ///
  /// 编辑器正文 = **全应用主字体**（`ThemeData.fontFamily` 也取它，见 `_build`）：
  /// 界面 + 正文同一套字形，全平台观感一致；缺字走 [cjkFontFallback] 兜底。
  static const String editorFont = 'LXGWNeoXiHeiScreen';

  /// 等宽字体链（代码块/行内代码）：Windows Consolas → Cascadia。
  /// 用途不同（代码等宽是功能性要求），与正文有意分离。
  /// 末尾接 CJK 链：代码主体是英文/符号由 Consolas 保证，但中文
  /// 注释常见——没有兜底时引擎随机挑字体，观感不可控。
  static const String monoFont = 'Consolas';
  static const List<String> monoFallback = <String>[
    'Cascadia Mono',
    'Courier New',
    ...cjkFontFallback,
  ];

  /// 「待输入」占位色：`onSurface` 低浓度，**按 APCA 兜底到 Lc 30**。
  /// 用于标题 hint、编辑器占位符、查找框 hint 等一切待输入提示。
  ///
  /// ⚠️ **不能只用固定 35%**（2026-09-22 体检）：那个浓度是**亮色**口径——暗色下
  /// 浅色字压在近黑底上，35% 叠完只剩 **Lc −16.5**，占位文字基本看不见（提到 45%
  /// 也只是缓解）。所以改成"明暗各一档 + 钳到 30"（APCA 对占位符的最低档）。
  ///
  /// 参数收 `onSurface` 基础色而非 ColorScheme——material_ui 与官方 material 的
  /// ColorScheme 是两个类型，收 Color 才能两侧通用；明暗由 `onSurface` 自身明度推断
  /// （它是**浅色** ⇒ 暗主题）。
  static Color hintColor(Color onSurface) {
    final bool dark = onSurface.computeLuminance() > 0.5;
    return withMinLc(
      onSurface.withValues(alpha: dark ? 0.45 : 0.35),
      contentCanvas(dark ? Brightness.dark : Brightness.light),
      30,
    );
  }

  /// **图标与次级色"退染"**：HSL 饱和度清零、明度保留。
  ///
  /// M3 的 fromSeed 会给整套"中性色"染上种子色相（实测 C6~15，随角色与
  /// 种子而异）。两个档都退染（2026-09-11）：**图标**是识别性元素——工具栏、
  /// 列表、设置里全靠形状+灰度辨识，染上色相后部分种子下"认不出原来的图标"
  /// （用户实测反馈）；**正文**是阅读面，用户要求与图标一并统一为纯中性。
  ///
  /// 做法：取 M3 算好的明度（对比度不变），只把色度清零。HSL 的 L =
  /// (max+min)/2 与 HCT Tone 在 C≤15 时偏差可忽略，不必引入
  /// material_color_utilities。
  static Color _desaturate(Color c) =>
      HSLColor.fromColor(c).withSaturation(0).toColor();

  /// 主色上的 ink（图标 / 文字）：**按种子算**——在浅墨与深墨之间选与种子
  /// 对比更高的一档，WCAG 相对亮度法。`primary` 被钉成种子本色（见 [_build]），
  /// 故 ink 直接对准种子算对比即可，不用管 M3 派生的 primary。
  static Color _onPrimaryFor(Color seed) {
    const Color lightInk = Color(0xFFF2F2EE);
    const Color darkInk = Color(0xFF1A1A18);
    final double l = _relativeLuminance(seed);
    final double cDark = (math.max(l, _relativeLuminance(darkInk)) + 0.05) /
        (math.min(l, _relativeLuminance(darkInk)) + 0.05);
    final double cLight = (math.max(l, _relativeLuminance(lightInk)) + 0.05) /
        (math.min(l, _relativeLuminance(lightInk)) + 0.05);
    return cDark >= cLight ? darkInk : lightInk;
  }

  static double _relativeLuminance(Color c) {
    double channel(int v) {
      final double s = v / 255;
      return s <= 0.03928
          ? s / 12.92
          : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
    }
    return 0.2126 * channel(c.r.round()) +
        0.7152 * channel(c.g.round()) +
        0.0722 * channel(c.b.round());
  }

  /// 亮色默认种子 **#0D9488**（2026-10-05 由 #00B5B5 换入，决策 A）：
  /// 原档偏荧光（电光青），长时间注视刺眼；换成 Tailwind Teal 600 这一档——
  /// **同色相轴、彩度降一档、明度略低**，与暗色种子的"身份"仍一致。
  /// 只动这一处默认值（换主题 = 换种子），APCA 体检表兜底。
  static ThemeData light({Color seed = const Color(0xFF0D9488)}) =>
      _build(seed, Brightness.light);

  /// 暗色默认用专用种子 **#00CED1**（[defaultDarkSeed]）：亮青在暗画布上
  /// 更醒目，与亮色的深青同色相、不同明度档。
  static ThemeData dark({Color seed = defaultDarkSeed}) =>
      _build(seed, Brightness.dark);

  /// **界面排印档位（Apple 口径）**，见 `docs/ui_rewrite_plan.md` §9.2。
  ///
  /// 为什么不直接用 M3 默认：M3 的档位是**移动端**尺度（bodyLarge 16 /
  /// bodyMedium 14 / titleLarge 22）配松行高，在 1280 宽的桌面窗口里整体偏大偏松
  /// ——"大字号 + 大行高"正是安卓感的来源。Apple 的桌面正文是 **13**、小字 11，
  /// 标题靠**字重**分层而不是字号，大字号带轻微负字距（视觉对齐）。
  ///
  /// ⚠️ **只作用于界面**：编辑器走 `EditorTypography`（自带字体与字号，取自
  /// `AppSettings.fontSize`），**不吃这里** ⇒ 改这组值不会牵动块高预测器与滚动
  /// 几何（那是按编辑器度量逐像素标定的，见 `block_height_predictor.dart`）。
  static TextTheme typography(TextTheme base) => base.copyWith(
    bodyLarge: base.bodyLarge?.copyWith(fontSize: 14, height: 1.35),
    bodyMedium: base.bodyMedium?.copyWith(fontSize: 13, height: 1.4),
    bodySmall: base.bodySmall?.copyWith(fontSize: 11, height: 1.35),
    labelLarge: base.labelLarge?.copyWith(fontSize: 13),
    labelMedium: base.labelMedium?.copyWith(fontSize: 11),
    // 包豪斯标题层（2026-10-12）：重字重 + 紧字距 + 收紧行高，靠 scale/weight 拉
    // 层级（不靠投影）。⚠️ 打包的 LXGW 是**单字重**，w700 走合成加粗（观感有限；
    // 真·重展示字需另引粗字重/几何字体资产）；**字距是可靠杠杆**。正文/标签档不动
    // （笔记 app 长文可读性优先）。编辑器走 EditorTypography，不吃这组值。
    headlineSmall: base.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
      height: 1.2,
    ),
    headlineMedium: base.headlineMedium?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      height: 1.15,
    ),
    headlineLarge: base.headlineLarge?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
      height: 1.1,
    ),
    titleSmall: base.titleSmall?.copyWith(
      fontSize: 13,
      height: 1.2,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    titleMedium: base.titleMedium?.copyWith(
      fontSize: 15,
      height: 1.2,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
    ),
    titleLarge: base.titleLarge?.copyWith(
      fontSize: 17,
      height: 1.15,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
    ),
  );

  static ThemeData _build(Color seed, Brightness brightness) {
    final ColorScheme base = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      // 默认的 tonalSpot 会把主色压成低色度灰蓝，
      // fidelity 让色板贴合种子色本身。
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    final ColorScheme scheme = base.copyWith(
      // **种子即主色**（2026-09-13）：fromSeed 会把主色调到 Tone 40（暗青档，
      // 为"白字压主色"的对比兜底）——但两个种子的对比本就达标（亮 #00B5B5
      // 配深青字 4.9:1、暗 #00CED1 配深青字 6.2:1，均过 AA），直接用种子
      // 本色（所见即所选），其余角色照常派生。
      // onPrimary **按种子算**：在浅墨 / 深墨之间选与种子对比更高的一档
      // （WCAG 相对亮度法，见 [_onPrimaryFor]）——不再是写死深青（只适配青色种子）。
      primary: seed,
      onPrimary: _onPrimaryFor(seed),
      surface: windowBackground(brightness),
      // M3 的 `surfaceContainer` 是钉死的 neutral tone（暗 tone 12 / 亮 tone 94，
      // 配 M3 自家 surface 设计）。2026-10-09 双色底都改了（暗 #080808 /
      // 亮 #DDDDDB）后它与底的档差不再满足 hub_nav 的明暗感知差闸门。全仓 plain
      // surfaceContainer 只有休眠的 HubNav 轨道在用——新架构里导航列落在浮面卡内
      // ⇒ **明暗两档都显式钉到浮面 panelFill**（暗 #161616 对底 5.0；亮纯白
      // 对 chrome 灰底 11.9——面板钉死纯白 ⇒ chrome 每往深压一档这条就涨，
      // 亮端靠投影表达高度故 L\* 档差更大，闸门放到 13）。
      surfaceContainer: panelFill(brightness),
      // ⚠️ 图标/次级色**不随种子染色**：onSurfaceVariant 是全应用图标的
      // 默认色源（M3 默认 IconTheme、工具栏显式传参、斜杠菜单的 muted、
      // 滚动条拇指都在取它）——识别性优先，保留明度、去掉色相。
      // 正文 onSurface 同样退染（用户要求，2026-09-11）：编辑器正文/标题/
      // 列表文字全走这一档，C6~10 的染色虽淡，但正文是阅读面，统一中性。
      onSurface: _desaturate(base.onSurface),
      // ⚠️ **暗色要钳一道 60 档的下限**（参考底 = 全应用最亮的那块面，见 [lightestDarkSurface]）：
      // 面板顶上那道**玻璃光泽**会把面再抬亮 5%，而暗色的次文字是**浅色** ⇒ 面越亮对比越差。
      // 📌 当前它是**空操作**（实测那处 −62.1，本来就过）；留着是**下限保险** ——
      // `glassSheenAlpha` 或浮层色一旦被调亮，这条会先把次文字顶在 60 档上，
      // 而不是让它悄悄掉下去（2026-09-22 那次面板半透时它确实顶过一次）。
      // 亮色不需要：那边最亮的面是浮层的白、文字是深色，越亮反而越好。
      onSurfaceVariant: brightness == Brightness.dark
          ? withMinLc(
              _desaturate(base.onSurfaceVariant),
              lightestDarkSurface(),
              60,
            )
          : _desaturate(base.onSurfaceVariant),
    );

    // 统一的形状，供多处复用
    final RoundedRectangleBorder shapeSm = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Tokens.radiusSm),
    );
    final RoundedRectangleBorder shapeMd = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Tokens.radiusMd),
    );
    final RoundedRectangleBorder shapeLg = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Tokens.radiusLg),
    );

    final ThemeData theme = ThemeData(
      // 主字体 = 打包的霞鹜新晰黑·屏幕阅读版（与编辑器正文同一来源，
      // [editorFont]）：全应用（界面 + 正文）一套字形，全平台观感一致。
      // 缺字仍走下方 cjkFontFallback 兜底。
      fontFamily: editorFont,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,

      // 全应用图标的**默认色源 = `onSurfaceVariant`**（就是上面 scheme 里那条
      // "图标/次级色不随种子染色"）：识别性优先，未激活的图标是**浅**的次级色，
      // 强调态由具体调用处/组件（`IconButton` 等会自己 merge）抬色。
      //
      // ⚠️ 这里必须**显式给 color**：`IconThemeData` 的默认 color 是 null，图标会
      // 落到 `DefaultTextStyle`（`WidgetsApp` 那个恒定黑 87%）——**明暗主题下取到
      // 同一个色**，正是 2026-09-23 用户实报的"不随明暗变色、没有未激活浅色"。
      // 非 Material 组件内的 tabler 图标另经 `AppIconTheme` 桥接（见该文件）。
      //
      // `weight` 是 Material Symbols 时代的遗留（tabler 是 SVG、粗细走
      // `strokeWidth`，由 `Tokens.iconStroke` 管），留着无害——只是不再有人读它。
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant, weight: 300),
      primaryIconTheme: const IconThemeData(weight: 300),

      // ── 结构 ───────────────────────────────────────────────
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      drawerTheme: DrawerThemeData(
        // 中性画布色：大面不染种子色（主题色只作强调点）。
        backgroundColor: contentCanvas(brightness),
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(
            right: Radius.circular(Tokens.radiusLg),
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        // 中性画布色：大面不染种子色。
        backgroundColor: contentCanvas(brightness),
        elevation: 0,
        // 移动端操作面板/移动端笔记菜单
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(Tokens.radiusLg),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        elevation: 0,
        indicatorShape: shapeMd,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        elevation: 0,
        // M3 规范：Rail 的选中指示器是 Stadium 形
        indicatorShape: const StadiumBorder(),
      ),

      // ── 内容容器 ───────────────────────────────────────────
      cardTheme: CardThemeData(
        // 笔记卡片：中性画布色（大面不染种子色），靠形状/描边分层。
        color: contentCanvas(brightness),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: shapeMd,
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: ListTileThemeData(
        shape: shapeMd,
        // 6：Apple 口径的桌面密度（§9.2）。8 是 M3 的默认档，行高偏松。
        minVerticalPadding: 6,
        horizontalTitleGap: Tokens.spaceMd,
        contentPadding: const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
      ),
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        // Apple 口径（§9.2）：分隔线"只需分、不需挑出来"——取与视图层同一个
        // [divider] 令牌（60%）。此前是满档 `outlineVariant`，与浮层描边**同强度**：
        // 分隔线比浮层边界还实，主次反了。
        color: divider(scheme),
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        // 折叠分组（如按日期/文件夹归类的笔记）
        shape: Border(),
        collapsedShape: Border(),
        backgroundColor: Colors.transparent,
        collapsedBackgroundColor: Colors.transparent,
      ),

      // ── 输入与编辑 ─────────────────────────────────────────
      inputDecorationTheme: InputDecorationTheme(
        // 表单场景用描边框；笔记正文编辑器应覆盖为 InputBorder.none
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Tokens.radiusSm),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Tokens.radiusSm),
          borderSide: BorderSide(color: scheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Tokens.radiusSm),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceMd,
          vertical: Tokens.spaceMd,
        ),
        isDense: true,
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll<double>(0),
        // M3 规范：搜索栏是全圆角
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Tokens.radiusLg),
          ),
        ),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
        ),
      ),

      // ── 按钮 ───────────────────────────────────────────────
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: shapeSm,
          // 32 = [Tokens.toolbarButtonSize]（Apple 口径 §9.2：桌面控件比移动端小一档）。
          // 此前是 M3 的 40，与工具栏按钮（32）**同一个"图标按钮"两种尺寸**。
          // ⚠️ 下限仍受 a11y 约束（桌面 24×24，见 `test/a11y`），32 有余量。
          minimumSize: const Size.square(Tokens.toolbarButtonSize),
          padding: EdgeInsets.zero,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: shapeSm,
          minimumSize: const Size(56, Tokens.toolbarButtonSize),
          padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: shapeSm,
          minimumSize: const Size(56, Tokens.toolbarButtonSize),
          padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: shapeSm,
          minimumSize: const Size(56, Tokens.toolbarButtonSize),
          padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        // 新建笔记：M3 的 FAB 是圆角方形（16dp），不是圆
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: shapeLg,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        // 设置项（明暗 / 正文宽度 / 连线端点形状）的分段选择。
        //
        // 选中态走「当前项」统一读法（2026-10-08 换装）：**强调色药丸
        // [selectedPill] + 字重 w600**——分段控件形状上没有"左侧"可言，
        // 旧的 3px 指示条本就不在此族；此前还走过中性 tint 与 M3
        // `secondaryContainer`，都是历史分叉。
        // 不用 `SegmentedButton.styleFrom`：它的 `textStyle` 参数收的是**单个**
        // `TextStyle`、表达不了"选中加粗"，所以这里直接给 `ButtonStyle`
        // （`WidgetStateProperty` 才能按态取值）。
        style: ButtonStyle(
          shape: WidgetStatePropertyAll<OutlinedBorder>(shapeSm),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? selectedPill(scheme)
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith<Color>(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          ),
          // ⚠️ 必须显式带上 `fontFamily` / 回退链：裸 `TextStyle` 会丢掉打包的
          // 霞鹜新晰黑，分段控件的文字会悄悄回落到系统字体。
          // （不能从 `theme.textTheme` 派生——`theme` 正在构造中，自引用编译不过。）
          textStyle: WidgetStateProperty.resolveWith<TextStyle>(
            (Set<WidgetState> states) => TextStyle(
              fontFamily: editorFont,
              fontFamilyFallback: cjkFontFallback,
              fontSize: Tokens.fontSizeMd,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w400,
            ),
          ),
        ),
      ),

      // ── 标签与菜单 ─────────────────────────────────────────
      chipTheme: ChipThemeData(
        // 笔记标签
        shape: shapeSm,
        side: BorderSide.none,
        labelPadding: const EdgeInsets.symmetric(horizontal: Tokens.spaceSm),
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceSm,
          vertical: Tokens.spaceXs,
        ),
      ),
      // ── 浮层（与 AppFloatSurface 共用同一批令牌）──────────────
      // 三件套 = [floatSurface] 底色 + [menuBorder] 描边 + [menuElevation] 投影。
      // 官方组件各自的默认值会破坏统一（右键菜单默认无描边/无投影，主菜单默认
      // 是带色相的 surfaceContainer + elevation 3），故逐个显式补齐。
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(
          // 圆角与 AppFloatSurface 默认档一致（radiusLg，2026-09-19 起统一）。
          borderRadius: BorderRadius.circular(Tokens.radiusLg),
          side: menuBorder(scheme),
        ),
        elevation: menuElevation,
        color: floatSurface(brightness),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          // 实色。⚠️ Layer 试验**不在这一层**：本仓没有任何 `MenuAnchor`，
          // 主菜单是 `PopupMenuButton` ⇒ 覆写在它的调用点（见 [layerMenuTheme]）。
          backgroundColor: WidgetStatePropertyAll<Color>(
            floatSurface(brightness),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Tokens.radiusLg),
              side: menuBorder(scheme),
            ),
          ),
          elevation: const WidgetStatePropertyAll<double>(menuElevation),
        ),
      ),

      // ── 滚动条 ───────────────────────────────────────────────
      // M3 桌面规范：8dp 圆头拇指，悬停/拖拽加粗到 12dp。
      // thumbVisibility=false：滚动或悬浮时才出现，平时不占视线
      // （贴近 Win11 原生列表的习惯）；想常显改 true。
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: const WidgetStatePropertyAll<bool>(false),
        thickness: WidgetStateProperty.resolveWith<double>((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.dragged)) {
            return 9;
          }
          return 6;
        }),
        thumbColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.dragged)) {
            return scheme.onSurfaceVariant.withValues(alpha: 0.6);
          }
          if (states.contains(WidgetState.hovered)) {
            return scheme.onSurfaceVariant.withValues(alpha: 0.5);
          }
          return scheme.onSurfaceVariant.withValues(alpha: 0.35);
        }),
        radius: const Radius.circular(4),
        crossAxisMargin: 2,
        // ⚠️ **必须 0**：`mainAxisMargin` 是"滑块起点/终点到视口边缘的距离"
        // （Flutter 默认 0）。设成正数（曾是 4）会让滑块**永远离滚动区域顶部
        // 一段距离**、到底也差同样一段——看起来就像"滚动条不从区域顶部开始"
        // （2026-09-14 用户实机发现）。官方没自定义滚动条 ⇒ 就是 0。
        mainAxisMargin: 0,
        minThumbLength: 36,
        interactive: true,
      ),

      // ── 反馈 ───────────────────────────────────────────────
      dialogTheme: DialogThemeData(elevation: 0, shape: shapeLg),
      snackBarTheme: SnackBarThemeData(
        // 删除笔记后的「撤销」提示
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: shapeSm,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        linearMinHeight: 4,
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 400),
      ),
    );

    // 两步合流（顺序无关）：① Apple 口径的界面排印（§9.2，含包豪斯字重/字距处理）；
    // ② 统一中文回退链——消除逐字符回退导致的笔画粗细不一致。
    // 主字体已由上方 `ThemeData(fontFamily: editorFont)` 落到**全应用**（界面 + 正文）。
    // ⚠️ 排印只作用于**界面**：编辑器走 `EditorTypography`（自带字体与字号），
    // 不吃这里 ⇒ 不牵动块高预测器与滚动几何。
    return theme.copyWith(
      textTheme: typography(theme.textTheme)
          .apply(fontFamilyFallback: cjkFontFallback),
      primaryTextTheme: typography(theme.primaryTextTheme)
          .apply(fontFamilyFallback: cjkFontFallback),
    );
  }
}

/// 圆角下的逐边上色 bevel 装饰（[AppTheme.raisedBevel] / [AppTheme.sunkenBevel] 用）。
///
/// [Border] 在圆角下强制四边同色（`A borderRadius can only be given on borders
/// with uniform colors`），而拟态胶囊/卡片都是圆角 ⇒ 必须自绘才能给每条边独立上色。
/// 顶+左用 [light]、底+右用 [dark]，各 [width] px；[fill] 为圆角填充（null = 只画边）。
/// 无模糊、不触发离屏合成。
class BevelDecoration extends Decoration {
  final BorderRadius radius;
  final Color light;
  final Color dark;
  final Color? fill;
  final double width;

  const BevelDecoration({
    required this.radius,
    required this.light,
    required this.dark,
    this.fill,
    this.width = 1,
  });

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _BevelPainter(this);

  @override
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) => false;

  @override
  Decoration? lerpFrom(Decoration? a, double t) => t < 0.5 ? a : this;

  @override
  Decoration? lerpTo(Decoration? b, double t) => t < 0.5 ? this : b;
}

class _BevelPainter extends BoxPainter {
  final BevelDecoration decoration;

  _BevelPainter(this.decoration);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final Size? size = configuration.size;
    if (size == null) return;
    final Rect rect = offset & size;
    final RRect rrect =
        decoration.radius.resolve(configuration.textDirection).toRRect(rect);
    final double w = decoration.width;
    if (decoration.fill != null) {
      canvas.drawRRect(rrect, Paint()..color = decoration.fill!);
    }
    if (w <= 0) return;
    // 倒角 = 沿圆角边框一圈的**方向性渐变**（顶左 light → 底右 dark），直接作为
    // RRect 描边的 shader：弧线与直边被同一渐变覆盖 ⇒ 边跟圆角走，无直切/缺失。
    // （老版本用"矩形 clip 带 + 整圈描边"，clip 带是直的、会把圆角弧线切断 ⇒
    // 角上变形、只剩直边。）
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        // 准阶跃过渡（0.45→0.55 窄带）：左上受光、右下背光，两"侧角"沿各自
        // 对角线切开 = 物理正确的倒角；不是糊成一片的渐变。
        colors: <Color>[decoration.light, decoration.light, decoration.dark, decoration.dark],
        stops: const <double>[0.0, 0.45, 0.55, 1.0],
      ).createShader(rect);
    canvas.drawRRect(rrect, stroke);
  }
}

/// **包豪斯扁平令牌**（2026-10-12 用户定：温暖的数字极简包豪斯 = 趋势 #1 方法论
/// + #2 暖纸底 + #4 几何/原色词汇，但保持克制、不撞色、不解构；排除 #3 渐变霓虹、
/// #5 算法生成）。
///
/// 与 [AppTheme]（一颗种子派生全套的 M3）**并存**：这一套是**固定**的纸/墨/三原色，
/// 供「外壳 + 主页」这类要走包豪斯的平面使用；编辑器内部 / 对话框等仍可走 M3。
/// 全站**零投影 / 零 bevel / 零渐变**，层次只靠**色块 + 边框粗细 + 字号**。
///
/// 圆角统一 **4px 硬边**（[Bauhaus.radius]）——用户 2026-10-12 定"全硬边留 4px"。
class Bauhaus {
  const Bauhaus._();

  /// 4px 硬边圆角（全站统一）。
  static const BorderRadius radius = BorderRadius.all(Radius.circular(4));

  // ── 固定调色板（亮）──────────────────────────────────────────
  /// 暖纸底（窗口 / 页面底）。
  static const Color _paperLight = Color(0xFFF3F0EA);
  /// 浮面 / 卡片面（比纸底更亮的"纸"）。
  static const Color _surfaceLight = Color(0xFFFFFFFF);
  /// 墨色（正文 + 硬边）。
  static const Color _inkLight = Color(0xFF161513);
  /// 主色：蓝（主动作 / 选中）。
  static const Color _blueLight = Color(0xFF1B4FD8);
  /// 蓝·深一档（hover / pressed）。
  static const Color _blueDeepLight = Color(0xFF123AA8);
  /// 强调：黄（hover 高亮 / 点睛）。
  static const Color _yellow = Color(0xFFF4C300);
  /// 破坏：红（仅删除 / 错误）。
  static const Color _redLight = Color(0xFFE23A2E);

  // ── 固定调色板（暗）─────────────────────────────────────────
  static const Color _paperDark = Color(0xFF1A1917);
  static const Color _surfaceDark = Color(0xFF242320);
  static const Color _inkDark = Color(0xFFF3F0EA);
  static const Color _blueDark = Color(0xFF5B82FF);
  static const Color _blueDeepDark = Color(0xFF7E9DFF);
  static const Color _redDark = Color(0xFFE85A4E);

  // ── 取色（按明暗）──────────────────────────────────────────
  static Color paper(Brightness b) => b == Brightness.light ? _paperLight : _paperDark;
  static Color surface(Brightness b) =>
      b == Brightness.light ? _surfaceLight : _surfaceDark;
  static Color ink(Brightness b) => b == Brightness.light ? _inkLight : _inkDark;
  static Color blue(Brightness b) => b == Brightness.light ? _blueLight : _blueDark;
  static Color blueDeep(Brightness b) =>
      b == Brightness.light ? _blueDeepLight : _blueDeepDark;
  static Color yellow(Brightness b) => _yellow;
  static Color red(Brightness b) => b == Brightness.light ? _redLight : _redDark;

  /// 次级文字（墨打折）。
  static Color inkMuted(Brightness b) =>
      ink(b).withValues(alpha: b == Brightness.light ? 0.62 : 0.60);

  /// 发丝边（容器的"轻"边界：墨 14% / 暗 16%）。
  static Color line(Brightness b) =>
      ink(b).withValues(alpha: b == Brightness.light ? 0.14 : 0.16);

  /// hover 浅覆（墨 6% / 暗 8%）——不引入 saveLayer（当不透明底色用需 alphaBlend）。
  static Color hover(Brightness b) =>
      ink(b).withValues(alpha: b == Brightness.light ? 0.06 : 0.08);

  // ── 边框 ───────────────────────────────────────────────────
  /// 卡片**硬边**（墨 1.5px）：包豪斯的"响"——边界是明确的线，不是软投影。
  static Border cardBorder(Brightness b, {double width = 1.5}) =>
      Border.all(color: ink(b), width: width);

  /// 容器**发丝边**（1px line）：给大面板一个"轻"界定，不与卡片硬边抢。
  static Border hairline(Brightness b) => Border.all(color: line(b));
}

