import 'package:material_ui/material_ui.dart';

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
class AppTheme {
  AppTheme._();

  /// 默认种子色（Tailwind Teal 500）。
  ///
  /// 2026-09-12 由蒂芙尼青 #0ABAB5 换入：绿意更足、明度略低，
  /// 强调色的存在感更强，深浅两模式色相都不失。颜色只出现在动作点。
  static const Color defaultSeed = Color(0xFF14B8A6);

  /// **暗色模式**专用种子（Dark Turquoise，2026-09-13）。
  ///
  /// 亮色模式种子为 #00B5B5（见 [light]）——两者几乎同色相（≈180° 青轴），
  /// 只有明度/彩度不同 ⇒ 明暗切换时主题"身份"不漂移。暗色档用更亮的
  /// #00CED1 在暗画布（#1A1A1A）上对比更冲、更醒目——暗色用亮种子是 M3
  /// 的通行做法（明度补偿，避免中性种子在暗色下派生出粉笔感弱青）。
  static const Color defaultDarkSeed = Color(0xFF00CED1);

  /// 主题预设种子色（供设置面板选择）。
  ///
  /// 2026-09-10 全量换为用户指定的 8 个色相；其中 3 个亮色种子（荧光青
  /// #00FFFF / 春绿 #00FA9A / 明黄 #FFDA03，Tone 87~91）在深色模式派生出
  /// **无色度**的主色（#FFFFFF C3 / #E1FFE7 C19 / #FFF8E9 C6）——HCT 里
  /// 这些色相在 Tone 87+ 处存不住色度，算法为保对比度只能推亮到白。
  /// 2026-09-11 已按实测把这三个换成**同色相、Tone 61~75** 的暗档种子
  /// （候选各跑过 3 个，选深色 primary 色度最高者）：
  ///
  /// - 碧青 #00BCD4：亮 #006876 / 暗 **#44D8F1（C50）**——色度完整保住；
  /// - 翠绿 #00C853：亮 #006E2A / 暗 **#3FE56C（C77）**——全场最艳；
  /// - 琥珀金 #F9A825：亮 #835400 / 暗 #FFCB8A（**C31**）——黄色相的物理
  ///   上限（#FFC107→C22、#FFB300→C26 都更低），亮 primary 仍偏橄榄
  ///   （同色相角低明度的感知漂移，换种子消不掉）；
  /// - 银灰 #DCDCDC 保留原值：中性主题本来就没有色相可失，深色主色近白
  ///   是"中性"的本性，不是缺陷。
  ///
  /// 其余四种（克莱因蓝 / 绛红 / 蒂芙尼 / 紫罗兰）种子 Tone 在 26~68、
  /// 两种模式都保色相，未动。
  ///
  /// 另：`ColorScheme.fromSeed` **产出不了真中性**——银灰的 HCT 色度只有 3，
  /// 派生出来是带一点青的灰（亮 primary #5D5F5F / H203）。要做真正的
  /// 中性主题得绕开 fromSeed，另行处理。
  static const List<Color> seedPresets = <Color>[
    Color(0xFF002FA7), // 克莱因蓝（亮色主色很深 #001E73）
    Color(0xFF990F4B), // 绛红
    Color(0xFF00C853), // 翠绿（原 #00FA9A 深色失色，换同色相暗档）
    Color(0xFF0ABAB5), // 蒂芙尼（两种模式都最稳，青系代表）
    Color(0xFF9400D3), // 紫罗兰（两种模式都最稳）
    Color(0xFFDCDCDC), // 银灰（近中性：派生带青灰、暗色主色近白是本性）
    Color(0xFFF9A825), // 琥珀金（原 #FFDA03 深色失色；亮 primary 仍偏橄榄）
  ];

  /// 内容画布色：浮在窗口底色之上的编辑区实底面板。
  ///
  /// ## 亮色：中性微降白（不纯白）
  /// `#FAFAFA`——纯白降一档亮度，与冷灰 Mica 同色系，读感是白纸又不眩光
  /// （要更"纯"可改 `0xFFFFFFFF`，要更柔可降到 `0xFFF2F2F2`）。
  ///
  /// ## 深色：**近黑深灰 `#161616`**（2026-09-15 用户定案）
  /// 演变：`#2B2B2B`（离黑 17.5 L\*；对亮色那侧的"离白 1.7 L\*"差十倍，看
  /// 着灰蒙蒙）→ `#121212`（L\* 5.1）→ **`#161616`（L\* 7.2）**。最后一步是
  /// 实机观感回退一档：**大面积黑的压迫感来自瞳孔开度**，抬一档更舒展
  /// （与 [editorText] 的降档是同一轮的两个杠杆，见其文档）。
  ///
  /// **为什么刻意不取纯黑**：底色越黑瞳孔开得越大，浅色字在近黑面上的
  /// "光晕（halation）"越明显——这是多数阅读器不用纯黑的共同原因。纯黑留给
  /// [windowBackground]，纸面留一档（与窗口底差 6.4 L\*）。
  ///
  /// ⚠️ 改纸面明度**必须连带**两处：① [windowBackground] 要更深（否则窗口底
  /// 比纸面亮 ⇒ 编辑页从"浮起"变"凹陷"，关系反转）；② [floatSurface] 要同向
  /// 抬（纸面抬一档后若浮层不动，两者只差 0.8 L\*、层次直接消失）。
  /// 本次配套：纸 `#161616` / 窗口底 `#0A0A0A` / 浮 `#222222`（纸面上方 +6.0 L\*）。
  static Color contentCanvas(Brightness brightness) =>
      brightness == Brightness.light
          ? const Color(0xFFFAFAFA)
          : const Color(0xFF161616);

  /// **浮层表面**：压在纸面之上的所有"短暂块"（菜单 / 面板 / 工具条）共用这一档底。
  ///
  /// ## 为什么与纸面**不同色**（2026-09-14 用户定案）
  /// 此前 6 个浮层全直接吃 [contentCanvas]（与编辑器纸面**逐像素同色**），其中
  /// 4 个连描边和投影都没有 ⇒ 浮层"只能靠内容自己看起来像个面板"，同屏还会撞出
  /// 4 种底色（画布色 / M3 表面色 / 选区色 / 反色）。现在给浮层单独一档：
  /// **同色系、明度各抬一档**——亮色 纸 `#FAFAFA` → 浮 `#FFFFFF`；
  /// 深色 纸 `#161616` → 浮 `#222222`——配合**三件套**（[menuBorder] 描边 +
  /// [menuElevation] 投影 + `Tokens.radiusMd` 圆角）表达"浮起"。
  ///
  /// ⚠️ **深色下这一档要比亮色跨得大**（+5.2 L\* vs +1.7）：亮色纸面本来就在
  /// 白端、只能让 5/255；而深色纸面压到近黑后**投影几乎失效**（黑影落在黑底上
  /// 不可见），"浮起"只剩底色差 + 描边两件——差距太小就分不出层次。
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
      brightness == Brightness.light
          ? const Color(0xFFFFFFFF)
          : const Color(0xFF222222);

  /// **Callout 块的底色**（`callout` 块；节点没存颜色时的回退值）。
  ///
  /// 与 [floatSurface] 同一"抬/降一档"思路，但**方向相反**：浮层要"浮起"
  /// （比纸面亮），而 callout 是**纸面上的一个记号**，要能一眼看出"这是块里
  /// 的一块"——亮色取比纸面深一档、深色取比纸面亮一档。
  ///
  /// ⚠️ 它是**懒解析**的目标：callout 节点默认**不存**颜色（`transparent`
  /// 哨兵），渲染时才来取这里 ⇒ 改这个色、切明暗，存量笔记自动跟着变，
  /// 不需要迁移文档（官方同款技巧）。
  static Color calloutBackground(Brightness brightness) =>
      brightness == Brightness.light
          ? const Color(0xFFF2F2F2)
          : const Color(0xFF222222);

  /// 浮层投影高度——**浮层三件套**之一（另两件：[floatSurface] 底色、
  /// [menuBorder] 描边）。
  ///
  /// 浮层底色与纸面**只差一档明度**，所以"浮起"主要由这三件套一起表达；
  /// 缺任何一件，浮层都会退化成"内容自己看起来像个面板"。
  static const double menuElevation = 6;

  /// 浮层描边——**浮层三件套**之一（`outlineVariant` 本身就淡，
  /// 这里不再额外降透明度，否则深色下几乎看不见）。
  static BorderSide menuBorder(ColorScheme scheme) =>
      BorderSide(color: scheme.outlineVariant);

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
  /// - 底色 [floatSurface]：亮色 `#FFFFFF` / 深色 `#222222`，与纸面各抬一档
  ///   （亮 +1.7 L\* / 深 +6 L\*），本身就是一道明确明度差；
  /// - 描边 [menuBorder]（满档 `outlineVariant`）：清晰勾边，不再含蓄；
  /// - 投影 [neuShadows]：单向下投的"抬起"实体感（非双向柔光）。
  /// 三者叠加，条在亮/暗两种模式下都明显浮在纸面上。
  ///
  /// ⚠️ 用本装饰的调用方仍要把这 1px 描边算进布局（见
  /// `note_editor_view_appflowy.dart` 的 `padding` / `floatingToolbarHeight`
  /// 等量补偿）。[menuBorder] 也是 1px，与原 `hairlineBorder` 同宽 ⇒ 补偿不变。
  static BoxDecoration neuFloatBar(Brightness brightness, ColorScheme scheme) =>
      BoxDecoration(
        color: floatSurface(brightness),
        borderRadius: BorderRadius.circular(Tokens.radiusLg),
        border: Border.fromBorderSide(menuBorder(scheme)),
        boxShadow: neuShadows(brightness),
      );

  /// 浮动工具条的投影（[neuFloatBar] 用；单独暴露给其他拟态小件复用）。
  ///
  /// 单向下投 + 左上受光提示：底色已是与纸面差一档的 [floatSurface]，
  /// 投影只负责补"实体抬起"感。亮色下白高光落在白面上基本隐形、无妨；
  /// 深色下投影最弱（黑影落黑底），故暗影加重、位移略大，配合 `#222222` 条底
  /// 与 `#161616` 纸面的明度差才读得出层次。
  static List<BoxShadow> neuShadows(Brightness brightness) =>
      brightness == Brightness.light
          ? const <BoxShadow>[
              // 左上受光提示（亮色下基本隐形，仅作语义占位）。
              BoxShadow(
                color: Color(0xFFFFFFFF),
                offset: Offset(-2, -2),
                blurRadius: 6,
              ),
              // 右下暗影：单向下投，给"抬起"的实体感。
              BoxShadow(
                color: Color(0x1A000000),
                offset: Offset(3, 4),
                blurRadius: 12,
              ),
            ]
          : const <BoxShadow>[
              BoxShadow(
                color: Color(0x12FFFFFF),
                offset: Offset(-2, -2),
                blurRadius: 6,
              ),
              // 深色下投影几乎失效，暗影加重 + 位移略大才分得清层次。
              BoxShadow(
                color: Color(0x66000000),
                offset: Offset(3, 4),
                blurRadius: 12,
              ),
            ];

  /// ── 语义令牌（透明度比例收敛）────────────────────────────
  ///
  /// 业务代码一律从这三处取，不要手写 `withValues(alpha: ...)` 的比例——
  /// 颜色来自 scheme（换主题安全），但比例散在各文件会渐渐失同步。

  /// 分隔线：`outlineVariant` 打六折。亮色下是极浅灰勾边、深色下亮一档，
  /// 但仍弱于 [menuBorder]（浮层要被"挑"出来，分隔线只需"分"）。
  /// 用于：左右分区界线、工具栏分组线、目录面板侧边线。
  static Color divider(ColorScheme scheme) =>
      scheme.outlineVariant.withValues(alpha: 0.6);

  /// 状态层：悬停高亮（M3 状态层同语言，`onSurfaceVariant @ 12%`）。
  /// 用于：工具栏按钮槽位等自绘交互件；IconButton 系走 M3 默认不用它。
  static Color stateLayer(Color base) => base.withValues(alpha: 0.12);

  /// 状态层（按下）：比 [stateLayer] 重一档——"按住"要比"悬停"更实，
  /// 两者同为 12% 时按下几乎看不出变化。
  static Color stateLayerPressed(Color base) => base.withValues(alpha: 0.18);

  /// 激活/选中底色：`onSurface @ 10%`（中性不染种子色；8% 在浅色下
  /// 几乎看不出选中态，实测 10% 是下限）。
  /// 用于：目录面板激活项、斜杠菜单选中项等"当前项"标识。
  static Color activeTint(Color onSurface) => onSurface.withValues(alpha: 0.10);

  /// 窗口底色（亮色）：Win11 系统应用的标准色（Mica 的等价纯色）。
  ///
  /// 两处共用：
  /// 1. 主题的 `surface`，作为整套色板的基准；
  /// 2. Win10 等无 Mica 的系统上，`WindowEffect.solid` 的回退底色——
  ///    与 Mica 的观感一致，切换时界面不会跳色。
  ///
  /// ## ⚠️ 深色值**故意偏离** Win11（`#0A0A0A`，原 `#1A1A1A`）
  /// 2026-09-15 随纸面一起压近黑（见 [contentCanvas] 的光晕说明）。它必须
  /// **比纸面更深**才能维持"编辑页浮在窗口底之上"的读数（亮色同理：
  /// `#F3F3F3` < `#FAFAFA`）。这一档不再等于系统 Mica 色——是刻意的取舍：
  /// 层级关系优先于"与系统底同色"。
  /// 另：它是 `scheme.surface` 的基准，改它会牵动 M3 派生的 container 系列；
  /// 本项目的浮层一律走 [floatSurface] / `AppFloatSurface`，不受影响。
  static Color windowBackground(Brightness brightness) =>
      brightness == Brightness.light
          ? const Color(0xFFF3F3F3)
          : const Color(0xFF0A0A0A);

  /// 编辑器中性色板：对标 Notion / Obsidian / Typora 文档风（GitHub-Flavored
  /// Markdown 观感），**不随 M3 种子色变化** —— 换主题 = 编辑页配色恒定。
  /// 链接用固定标准蓝（标杆编辑器的常态，只是固定色而非种子色）；行内代码 /
  /// 代码块用中性灰底；光标 / 选区 / 标记 / 激活态全部走 onSurface 中性系。
  /// **编辑器正文色**（正文 / 标题 / 列表 / 引用 / 代码块里的一切内容文字）。
  ///
  /// - **亮色**：直接取 `scheme.onSurface`（M3 中性深灰，与界面文字同源，不动）；
  /// - **暗色**：**`#D6D6D6`**（2026-09-15 用户定案）——比 `onSurface`
  ///   （派生出来 ≈ `#E3E3E3`）低一档，与纸面 `#161616` 组合成 **12.5:1**。
  ///
  /// ## 为什么"抬背景"和"降正文"各让一步
  /// 刺眼有两个来源，作用面不同：
  /// - **大面积黑的压迫感**（瞳孔开度）⇒ 靠 [contentCanvas] 抬一档
  ///   （`#121212` → `#161616`）缓解，但对比度只降 ~0.5 点（14.6 → 14.1）；
  /// - **浅字本身的发光**（halation）⇒ 靠本条降一档缓解，对比度降 ~2.6 点。
  ///
  /// 两个杠杆都只动一半：纸面抬一档 + 正文降一档，合计 14.6 → **12.5:1**。
  /// 仍远超 AA（4.5），可读性没有代价。
  ///
  /// ## 只作用于编辑器内容
  /// 界面文字（侧栏 / 菜单 / 工具栏 / 字数条）继续走 `scheme.onSurface`
  /// ——它们是小字号 UI 文字，不承担长文阅读，没必要跟着降一档。
  ///
  /// ⚠️ 视图里**两处**必须同时取它：`EditorStyle.textStyleConfiguration` 与
  /// `BlockHeightPredictor` 的那份（预测器复刻渲染 span，两处不同源就会脱节）。
  static Color editorText(Brightness brightness, ColorScheme scheme) =>
      brightness == Brightness.dark ? _textDark : scheme.onSurface;

  /// 暗色档正文字色。[editorText] 与 [canvasInk] **共用**同一个常量：画布墨迹
  /// 必须与正文一个字色，否则同一份内容在两处是两种黑。
  static const Color _textDark = Color(0xFFD6D6D6);

  /// 画布**墨迹**色（`kThemeInk` 色的笔迹按它绘制，见
  /// `CanvasController.pictureFor` / `resolveInk`）。
  ///
  /// 画布底色随主题（[contentCanvas]：亮 `#FAFAFA` / 暗 `#161616`），墨色必须
  /// **一起走**——否则就是"黑墨画黑纸"：暗色纸面上的 `#1F1F1F` 几乎不可识别
  /// （2026-09-17 用户截图反馈"暗色下有点不可识别"）。
  ///
  /// - **亮色** `#1F1F1F`：与哨兵 `kThemeInk`（`ink_stroke.dart`）**同值**
  ///   ⇒ 亮色下渲染逐像素不变、存量画布观感零回归。这个等价性由
  ///   `test/canvas/canvas_ink_test.dart` 钉住（不靠注释约定）；
  /// - **暗色** `#D6D6D6`：与 [editorText] 暗色同值，对 `#161616` 纸面约 12.7:1。
  static Color canvasInk(Brightness brightness) =>
      brightness == Brightness.dark ? _textDark : const Color(0xFF1F1F1F);

  /// 链接色：**直接取主题 primary 原色**，不削弱、不写死。
  ///
  /// 之前是写死的两套青色（亮/暗各一），既不随主题种子色、又和品牌脱节。
  /// 现在与引用块竖条一致，都吃 [ColorScheme.primary]，明暗切换自动跟随、
  /// 且用满强度（不靠 alpha 削弱）——与"主题原色直接上、不稀释"的取向一致。
  static Color editorLink(ColorScheme scheme) => scheme.primary;
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
  /// 与 UI 界面字体（`Segoe UI` + 同一回退链）有意分离：界面跟系统、
  /// 正文用打包字体，两种"纸面"观感。
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

  /// 「待输入」占位色：Material 规范浓度（onSurface 35%）。
  /// 用于标题 hint、编辑器占位符、查找框 hint 等一切待输入提示。
  /// 参数收 `onSurface` 基础色而非 ColorScheme——material_ui 与官方
  /// material 的 ColorScheme 是两个类型，收 Color 才能两侧通用。
  static Color hintColor(Color onSurface) =>
      onSurface.withValues(alpha: 0.35);

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

  /// 亮色默认种子 **#00B5B5**（2026-09-13）：同色相轴上的高彩度档，
  /// "种子即主色"后 primary 就是它本色——电光青、比 Tone 40 派生档鲜。
  static ThemeData light({Color seed = const Color(0xFF00B5B5)}) =>
      _build(seed, Brightness.light);

  /// 暗色默认用专用种子 **#00CED1**（[defaultDarkSeed]）：亮青在暗画布上
  /// 更醒目，与亮色的深青同色相、不同明度档。
  static ThemeData dark({Color seed = defaultDarkSeed}) =>
      _build(seed, Brightness.dark);

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
      // onPrimary 反向取深青字：亮青底配白字只有 2~2.5:1 不达标。
      primary: seed,
      onPrimary: const Color(0xFF003B3B),
      surface: windowBackground(brightness),
      // ⚠️ 图标/次级色**不随种子染色**：onSurfaceVariant 是全应用图标的
      // 默认色源（M3 默认 IconTheme、工具栏显式传参、斜杠菜单的 muted、
      // 滚动条拇指都在取它）——识别性优先，保留明度、去掉色相。
      // 正文 onSurface 同样退染（用户要求，2026-09-11）：编辑器正文/标题/
      // 列表文字全走这一档，C6~10 的染色虽淡，但正文是阅读面，统一中性。
      onSurface: _desaturate(base.onSurface),
      onSurfaceVariant: _desaturate(base.onSurfaceVariant),
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
        minVerticalPadding: Tokens.spaceSm,
        horizontalTitleGap: Tokens.spaceMd,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceMd,
        ),
      ),
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: scheme.outlineVariant,
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
          minimumSize: const Size.square(40),
          padding: EdgeInsets.zero,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: shapeSm,
          minimumSize: const Size(64, 40),
          padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceLg),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: shapeSm,
          minimumSize: const Size(64, 40),
          padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceLg),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: shapeSm,
          minimumSize: const Size(64, 40),
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
        // 视图切换：列表 / 网格 / 时间线
        style: SegmentedButton.styleFrom(shape: shapeSm),
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
          borderRadius: BorderRadius.circular(Tokens.radiusSm),
          side: menuBorder(scheme),
        ),
        elevation: menuElevation,
        color: floatSurface(brightness),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(
            floatSurface(brightness),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
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
      dialogTheme: DialogThemeData(
        elevation: 0,
        shape: shapeLg,
      ),
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

    // 统一中文回退链：消除逐字符回退导致的笔画粗细不一致。
    return theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamilyFallback: cjkFontFallback),
      primaryTextTheme:
          theme.primaryTextTheme.apply(fontFamilyFallback: cjkFontFallback),
    );
  }
}
