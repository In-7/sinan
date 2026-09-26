import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// 编辑器中文排版——全应用**唯一**的文字样式来源（标题 / 正文 / 链接 /
/// 行内代码 / 自动补全；quill 版的对照实现已随视图归档）�?
///
/// ## 为什么非要有这么一�?
/// appflowy（与 quill 同样�?*不继�?Ambient 文字样式**：每个文�?span 的基样式
/// 只来�?`EditorStyle.textStyleConfiguration.text`（见 `appflowy_rich_text.dart`
/// �?`getTextSpan`：`text.copyWith(height: lineHeight)`）。而官方默认值是
/// **按拉丁文标定**的，直接用在中文上有三处系统性偏差：
///
/// | 偏差 | 官方默认 | 中文口径 | 原因 |
/// |---|---|---|---|
/// | 标题档位 | 写死 32/28/24（`heading_block_component.dart`�?| base×1.75/1.4/1.2/1/1/1 | 西文大标题对汉字过大，且档位不随正文字号缩放 |
/// | 标题行高 | 跟随正文行高 | 1.4 | 汉字是满 em 方块，行盒不留白会上下粘连（西文标题 1.08~1.15 + 负字距会直接压笔画） |
/// | 字体回退 | 单字体，无回退�?| [AppTheme.editorFont] + [AppTheme.cjkFontFallback] | 引擎逐字符回退会给同一段汉字挑到不同字体（flutter#103811），表现为笔画粗细不一、甚至缺字形方框 |
///
/// 另有三条�?**Flutter 桌面渲染的黄金标�?*（quill 版已实跑验证过一轮）�?
///
/// - 字距 **0**：汉字是等宽方块字，西文标题惯例的负字距会让笔画相碰�?
/// - 字重 **w400（Regular�?*�?*对齐 Apple 与鸿蒙两家的正文规范**（都写明正文�?
///   Regular）。曾�?w500 来补�?桌面灰度抗锯齿下 w400 偏淡"，那属本机经验值，
///   按规范回退；标题用 w600（Semibold）覆盖，�?[heading]�?
/// - `leadingDistribution: even` + `applyHeightToFirstAscent/LastDescent:
///   true`：行高余量均分到字形的上下，�?末行与中间行同一套几何——字形在
///   行盒�?*居中**�?026-09-11 换霞鹜新晰黑后校准，�?
///   `toTextStyleConfiguration` 内注释）�?
///
/// ## 两条取舍准则�?026-09-10 定，**不追 markdown**�?
/// 1. **中文显示与输入的最佳尺�?*：正�?�?4px（汉字识别下限，Apple/鸿蒙�?
///    Body 分别�?17pt / 14vp）、行�?�?.5（汉字满 em�?.2~1.3 会粘连）�?
///    字距 0、正�?w400 / 标题 w600——都已体现在下面的取值里�?
/// 2. **Impeller 下的整像�?*：字号、行盒、行距、块间距全部落在**整数像素**�?
///    （见 [snap] �?[lineBox]）。Flutter 不做字体 hinting、文字是线性度�?+
///    亚像素抗锯齿 �?落在半像素上就是"按半个像素取�?，笔画边缘发灰（汉字
///    笔画密，比拉丁文更明显）�?*这是我们能控制的锐度杠杆**；剩下那点亚像素
///    取样由引擎决定，控制不了、也不该�?改字�?去凑�?
///
/// **有意不动**：每块的 `padding` 保持官方 `BlockComponentConfiguration`
/// 默认值（上下�?4）——块间距按官方来，见 `custom_block_components.dart`�?
///
/// 改这里的值时留意：quill 版视图（及它�?`_chineseStyles`）已�?2026-09-10
/// 退役归档（`archive/quill/src/notes/note_editor_view.dart`），本类是唯一来源�?
class EditorTypography {
  const EditorTypography({
    required this.fontSize,
    required this.lineHeight,
  });

  /// 正文基准字号（来�?`AppSettings.fontSize`，默�?17）�?
  final double fontSize;

  /// 正文行高倍数（来�?`AppSettings.lineHeight`，默�?1.5；新几何下即
  /// 真实行距倍数，见 [lineBox]）�?
  final double lineHeight;

  // ───────────────────────── 整像素（Impeller 锐度杠杆�?─────────────────────────

  /// 把计算出来的尺寸**吸附到整像素**�?
  ///
  /// Flutter 的文字是线性度�?+ 亚像素抗锯齿（不做字�?hinting），字号、行盒�?
  /// 间距只要落在半像素上，字形就�?半个像素"取样，笔画边缘出现灰边——汉�?
  /// 笔画密，比拉丁文明显。让所有派生尺寸落在整数像素上�?*我们能控�?*�?
  /// 那一半�?
  ///
  /// 只吸�?字号 × 比例"这类**算出来的**值；比例常量本身仍是设计�?
  /// （好读、好调、换字号时自动跟着缩放）�?
  static double snap(double px) => px.roundToDouble();

  /// 行盒（px）：字号 × 倍数，吸附整数�?
  ///
  /// 几何（`applyHeightToFirstAscent/LastDescent: true` + `leadingDistribution:
  /// even`，实测见 `test/line_height_metrics_test.dart`）：每行**同构**—�?
  /// 行盒 = 字号 × 倍数（吸附后），**行距（首行顶 �?次行顶）= 行盒**�?
  /// 滑杆值即视觉倍数。旧几何（官方默�?false）的
  /// 「行�?=（盒+字号)/2」与"行盒须与字号同奇�?约束已随之废弃：
  /// 现在只要行盒是整数，每一行都落在像素栅格上�?
  ///
  /// 行盒整数是锐度前提：Flutter 不做字体 hinting，行�?行距落在半像素上
  /// 时每行依次偏移半个像素，长段落越往下越糊（旧默�?1.7 �?16px �?
  /// �?27.2 就是这个病）�?
  static double lineBox(double fontSizePx, double multiple) =>
      snap(fontSizePx * multiple);

  // ───────────────────────────── 档位与间�?─────────────────────────────

  /// 代码块字号相对正文的比例：等宽字形视觉上比汉字大，收一档�?
  ///
  /// ⚠️ **算出来的字号�?[snap] 吸附**（见 [code]）—�?7px 正文�?0.9 倍是
  /// 15.3px，不吸附就落半像素，代码里的中文注释笔画会发灰�?
  static const double codeFontScale = 0.9;

  /// 标题档位比例（乘正文字号）�?
  ///
  /// **基准**�?Apple HIG 与鸿�?PC 两家规范的共识：
  ///
  /// | �?| Apple HIG（÷Body 17�?| 鸿蒙 PC（÷Body 14�?| 两家共识 |
  /// |---|---|---|---|
  /// | h1 | Large Title 34 �?2.0 | Title_L 28 �?2.0 | 2.0（一致） |
  /// | h2 | Title1 28 �?1.65 | Title_M 22 �?1.57 | 1.6（取中值） |
  /// | h3 | Title2 22 �?1.29 | Title_S 18 �?1.29 | 1.29（一致） |
  /// | h4 | Title3 20 �?1.18 | Subtitle_L 16 �?1.14 | 1.16（取中值） |
  /// | h5/h6 | Headline = Body | Subtitle_M = Body | 1.0（两家都同号�?|
  ///
  /// **采用值比共识整体收一档（�?×0.875�?*�?6px 正文�?
  /// **28 / 22 / 19 / 16 / 16 / 16 px**（吸附后的实际像素）�?
  /// 理由有两条：
  /// - 按共识原值观感偏大：h1�?2 已是 Word 级大标题，笔记场景偏重；
  /// - h4 �?**1.0**（与正文同号、靠 w600 区分）：这正是两家共识的第四�?
  ///   （Apple �?Headline、鸿蒙的 Subtitle_M 都与 Body 同号）。原 1.1 �?
  ///   16px 下算�?17.6px，吸附后�?h3�?9px）只�?1px—�?*层级不可�?*�?
  ///   �?半像素档"留下的问题，顺势解决�?
  ///
  /// **h5/h6 也与正文同号**：两家规范里这一层都�?同号不同字重"；比正文更小
  /// �?标题"在中文里没有语义（鸿蒙的 Subtitle_S 12vp 小于正文，此处钳�?1.0）�?
  ///
  /// 官方默认是写死的 32/28/24/18/18/18（拉丁标定，不随正文字号缩放）�?
  /// 想回到共识原值：本表换成 2 / 1.6 / 1.29 / 1.16 / 1 / 1�?
  static const List<double> headingScales = <double>[
    1.75,
    1.4,
    1.2,
    1.0,
    1.0,
    1.0,
  ];

  /// 标题档位�?*上间�?*（乘正文字号）—�?*按级别递增**�?
  /// h1 **2.0** / h2 **1.5** / h3 及以�?**1.25**（em）�?
  ///
  /// 官方标题与正文的块内边距**完全一�?*（都是上下各 4），�?不靠间距
  /// 区分标题"；这里补�?标题前留�?�?
  ///
  /// 基准取中文生态通行�?markdown 排版（GitHub markdown CSS，语雀/掘金/
  /// CSDN 等渲染都贴它）：那里 h1~h6 **统一** `margin-top: 1.5rem`�?4px
  /// �?6px 正文下）。⚠�?**换算要打�?*：CSS �?`margin` 相邻�?*折叠**
  /// （取较大者），而块�?`padding` **不折�?*（相邻两块相加）。上一块的
  /// `bottom: 4` 已经占掉 4px，故 h3 �?**1.25em**�?6px 正文�?20px），
  /// 渲染出来正好 �?4px�?
  ///
  /// ## 为什么改�?按级别递增"�?026-09-14�?
  /// GitHub 那份 CSS 的上间距�?*统一�?*——它区分层级靠的是字�?+ **只给
  /// h1/h2 的下边框**，不靠间距。我们当时只抄了间距、没有下边框，于是三�?
  /// 之间**只剩字号一个维�?*（h2 �?h3 只差 4px、前面留白一模一样），读�?
  /// 看不�?这是新的一�?还是"新的一小点"�?
  ///
  /// 上间距是**唯一不占横向空间**的层级杠杆（正文列宽固定�?
  /// `AppSettings.contentWidth`），
  /// 也符合印刷排版通则：级别越高，前面的断点越大�?
  ///
  /// 取值在 h3 �?markdown 基准�?.25em�?*往上加**——不�?h3 的基准，免得
  /// 与既有观感脱节：h2 = 1.5em、h1 = 2.0em�?6px 正文�?20 / 24 / 32px�?
  /// 17px（默认）�?21 / 26 / 34px（都吸附整像素）�?
  /// **h4~h6 �?h3 同档**：它们本就与正文同号，是"加粗的正�?，不该抢结构�?
  ///
  /// ⚠️ 只给上间距，�?*文档首块不给**（见 [headingPadding]）——对�?GitHub �?
  /// `.markdown-body > *:first-child { margin-top: 0 }`�?
  ///
  /// 想恢�?统一 1.25em"（GitHub 原样）：本表全填 1.25�?
  static const List<double> headingTopSpacings = <double>[
    2,
    1.5,
    1.25,
    1.25,
    1.25,
    1.25,
  ];

  /// 标题行高：汉字需要呼吸空间，全局正文行高�?.75）对标题太散�?
  static const double headingLineHeight = 1.4;

  /// 笔记标题相对正文的字号倍数（标题输入框用）�?
  ///
  /// �?**1.4**（＝与正�?**h2** 同号�?026-09-14 用户定案，原�?1.75 �?h1）：
  /// 17px（默认）正文下吸附后 **24px**�?6px �?22px�?0px �?28px），
  /// 与正文里的二级标�?*完全同号**�?
  ///
  /// ⚠️ **已知且有意的取舍**：标题因�?*小于**正文里的 h1（[headingScales]
  /// �?1.75 �?30px）。原注释"不得小于 h1，否则层级倒挂"随这条定案作废—�?
  /// 笔记标题�?一篇的名字"，不是文档里的一级标题；
  /// `test/editor_typography_test.dart` 那条断言已改为锁"�?h2"
  /// （档位表一改，标题跟着改，两处不漂移）�?
  ///
  /// 修正记录�?.25（quill 口径）→ 1.75 �?2.25（h1 �?Apple 共识 2.0 时）
  /// �?2.0（h1 收一档到 1.75 后同步收）→ 1.75（＝ h1）→ **1.4（＝ h2�?*�?
  static const double titleScale = 1.4;

  /// 笔记标题与正文之间的**结构间距**（乘正文字号）——加在标题输入框下方�?
  ///
  /// 基准 = markdown 的标题下间距 `margin-bottom: 1rem`�?6px 正文�?16px�?
  /// 它的上间�?1.5rem�?4px �?[headingTopSpacings] �?1.25em�?0px 同源折扣）�?
  ///
  /// �?**0.75em**：结构间距会�?首个块自带的 4px 上内边距"**相加**（CSS �?
  /// margin 是折叠语义、只取较大者），相加后 �?6px。改之前�?0——标题行�?
  /// 余量�?4px 内边距加起来只有 ~10px�?8px 的标题贴着正文，观�?太近"�?
  static const double titleBottomSpacing = 0.75;

  /// 标题 �?正文�?*实际下留�?*（px）：字号 × [titleBottomSpacing]，吸附整像素�?
  double get titleBottomGap => snap(fontSize * titleBottomSpacing);

  /// 编辑器内容的四周内边距—�?*注意它按"每一�?生效**�?
  ///
  /// 官方 `EditorStyle.padding` 不是编辑器外框的内边距：`page_block_component.dart`
  /// 把它包在 `items.map(...)` 里，**每个块各吃一�?*。所以这�?*只能放水平�?*
  /// （竖直方向交给块�?4px 默认内边距与标题的上间距）�?
  ///
  /// 实际踩过：把 quill 版的「左�?16 / �?4 / �?96（末尾留白）」原样搬过来�?
  /// 结果**每个�?*都多�?`4 + 96 = 100px` 竖直空白——表现为"一行按一下回车，
  /// 间距是行距的 4 �?，看起来像行高出了问题（实测 dump�? 个单行段落之�?
  /// �?~120px，而正确的值应�?行盒 + 官方块内边距 8）。quill �?`padding`
  /// 是编辑器外框语义，只算一次，两者不是一回事�?
  static const EdgeInsets blockPadding = EdgeInsets.symmetric(horizontal: 16);

  /// **块手柄占掉的内容宽度**（px）：块的动作�?
  /// （`BlockComponentActionWrapper` �?`Row[手柄, 正文]`）用
  /// `Visibility(maintainSize: true)` **常驻占位**，所以每个块的文字列都被
  /// 它吃掉这一段——不�?悬浮时才�?�?
  ///
  /// 任何**复刻渲染几何**的地方都必须扣掉它（最要紧�?
  /// `BlockHeightPredictor.textWidthOf`）：不扣就会按更宽的列算折行 �?
  /// 整行边界�?*少算一整行**�?026-09-15 实测：预�?688 vs 渲染 640�?
  /// 40 字段落预�?1 行、实�?2 行，Δ �?6px）�?
  ///
  /// 口径 = 手柄自身：`Padding(right: 6)` + 两个 20×20 按钮 + 间距 2�?
  /// 改手柄尺寸必须同步改这里，否则预测器与渲染再次脱节�?
  ///
  /// �?026-09-15 曾试�?零宽动作�?+ OverflowBox 侧绘"来免掉这笔占位，
  /// 因命中测试限制回滚——见同日对话�?`block_handle_layout_test.dart`
  /// 的文件头注释。）
  static const double blockHandleWidth = 6 + 20 + 2 + 20;

  /// **默认块高估计**（px）：块还没被布局过时的兜底值�?
  ///
  /// 只服务于我们自己�?�?�?像素"换算（见 `block_heights.dart`），
  /// **不参�?*滚动器的总高外推——官方那套外推与本函数无关�?
  ///
  /// 口径�?*默认�?一�?�?*（正文类块）—�?
  /// - 标题：该档标题行盒（字号 × [headingLineHeight]�? [headingPadding]
  ///   （上间距按级别、文档首块不给；下边�?4）；
  /// - 其余（段�?/ 列表 / 待办 / 引用 / 代码�?/ 公式 / 图片 / 表格 / 附件）：
  ///   正文行盒 + 官方默认的上下各 4�?
  ///
  /// 多行段落与非文本块会�?*低估**，这是有意的取舍：换算落偏只影响"跳转落点"�?
  /// 落地后按实测修正一次即可（表本身会在浏览中不断被真值替换）�?
  ///
  /// **文字�?*不必再走这里：`block_height_predictor.dart` �?`TextPainter` 干跑
  /// 一次布局就能给出**逐像素等于真实高�?*的预算（84 个块的实测偏�?0.0px），
  /// 它已接进 `BlockHeights.heightOf` 的取值链。本函数现在只为"预测器不负责�?
  /// �?（图�?/ 表格 / 代码�?/ 公式 / 附件）兜底�?
  double estimatedBlockHeight(Node node) {
    final bool isHeading = node.type == HeadingBlockKeys.type;
    final int level = isHeading
        ? (node.attributes[HeadingBlockKeys.level] as int? ?? 1).clamp(
            1,
            headingScales.length,
          )
        : 0;
    final double textSize = isHeading
        ? snap(fontSize * headingScales[level - 1])
        : fontSize;
    final double lineBoxHeight = lineBox(
      textSize,
      isHeading ? headingLineHeight : lineHeight,
    );
    // 竖直内边�?*复用 [headingPadding]**，不再另写一遍公式：
    // 标题�?上间�?+ �?4"（曾在这里写�?上下�?4"�?每档多算 4px�?
    // 2026-09-14 由预算器与真实渲染的对比抓出）�?
    final EdgeInsets verticalPadding = isHeading
        ? headingPadding(node)
        : const EdgeInsets.symmetric(vertical: 4);
    return lineBoxHeight + verticalPadding.vertical;
  }

  /// 正文基样式：**段落 / 列表 / 待办 / 引用 / 标题 / 代码�?/ 公式**都从这里派生�?
  ///
  /// 字重 **w400（Regular�?*：Apple 与鸿蒙两家的正文规范都写�?Regular
  /// （本项目曾用 w500 补偿桌面灰度抗锯齿下的偏淡观感，属经验值，已按规范回退）�?
  ///
  /// ## ⚠️ 这里**不设 color**，但调用�?*必须**补上
  /// 曾经的理由是"颜色交给 Ambient 样式"—�?*那个假设在编辑器里不成立**�?
  /// 官方 `AppFlowyRichText` 最终用 **`RichText`** 渲染，�?`RichText`
  /// **不继�?`DefaultTextStyle`**，span 没有 color 时就落到引擎默认�?
  /// （`dart:ui` �?`TextStyle`：color 缺省 = **白色**）�?
  ///
  /// 后果（实测，2026-09-10）：亮色画布 `#FAF9F6` 上是**白底白字、正文几�?
  /// 隐形**（widget 测试里渲�?span �?`color` 就是 `null`），而深�?`#2B2B2B`
  /// 上的白字**侥幸正常**——所以这�?bug 只在亮色下暴露�?
  ///
  /// 正确接法：基样式�?color �?[toTextStyleConfiguration] �?`text` 参数注入
  /// �?*标题不许自己写死颜色**——写死会顶掉行内"文字颜色"属性，它靠 `combine`
  /// 继承基样式的前景色）；代码块 / 公式直接派生样式的组件读的也是同一�?
  /// `editorStyle.textStyleConfiguration.text`，所�?*一处生效、全编辑器统一**�?
  ///
  /// **整像�?*：字号与行盒都会�?[snap] / [lineBox] 吸附（传进来�?[size]
  /// 视同"设计�?，最终以吸附值为准；`height` 回填吸附后的行盒 / 字号�?
  /// 所以行盒恰好是整数像素）�?
  TextStyle body({double? size, double? height}) {
    final double effectiveSize = snap(size ?? fontSize);
    final double box = lineBox(effectiveSize, height ?? lineHeight);
    return TextStyle(
      fontSize: effectiveSize,
      height: box / effectiveSize,
      letterSpacing: 0,
      fontFamily: AppTheme.editorFont,
      fontFamilyFallback: AppTheme.cjkFontFallback,
      fontWeight: .w400,
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  /// 标题档位样式（挂到官�?`HeadingBlockComponentBuilder.textStyleBuilder`）�?
  ///
  /// 官方是在 span 基样�?*之后**�?`TextStyle.combine` 合并进来�?
  /// （`heading_block_component.dart` �?`textSpanDecorator`），所以这�?
  /// 只需给差异项即可�?*字色有意不设**——继承基样式，这样行�?文字颜色"
  /// 属性不会被标题档顶掉�?
  TextStyle heading(int level) => body(
    size: fontSize * headingScale(level),
    height: headingLineHeight,
  ).copyWith(fontWeight: .w600);

  /// 代码块的等宽文字样式�?*字号与行盒都吸附整像�?*（与 [body] / [heading]
  /// 同一口径）�?
  ///
  /// [base] 是编辑器正文基样式（提供颜色与基准字号）；字族换成等宽链�?
  /// 字号 = 正文 × [codeFontScale] **吸附取整**，行�?= [lineBox](该字�?
  /// [lineHeight])，再回填 `height = 行盒 / 字号` �?行盒恰好是整数�?
  ///
  /// 为什么必须吸附（2026-09-14）：0.9 倍算出来�?15.3px�?*行盒 22.94** 是小�?
  /// ——既让汉字注释落半像素（[snap] 的文档说的那个病），又让"�?span 与单�?
  /// 正文的行盒取�?�?1px（表现为单行代码块比预算�?1px，见
  /// `block_height_predictor.dart`）。吸附后行盒 = 23 整，两件事一起消失�?
  ///
  /// ⚠️ **组件与块高预算器必须共用本方�?*，各算一遍就会漂移�?
  TextStyle code(TextStyle base) {
    final double size = snap((base.fontSize ?? fontSize) * codeFontScale);
    return base.copyWith(
      fontFamily: AppTheme.monoFont,
      fontFamilyFallback: AppTheme.monoFallback,
      fontSize: size,
      height: lineBox(size, lineHeight) / size,
    );
  }

  /// 标题块的块内边距（官�?`BlockComponentConfiguration.padding` 的口子）�?
  ///
  /// - 上间距按 [headingTopSpacings] 给（吸附整像素）�?
  /// - 下间距与左右保持官方默认（下 4、左�?0）——标题与紧随其后的正�?
  ///   不该被拉开�?
  /// - **文档首个块不给上间距**（对�?GitHub �?
  ///   `.markdown-body > *:first-child { margin-top: 0 }`），否则正文开�?
  ///   会凭空多一段空白�?
  EdgeInsets headingPadding(Node node) {
    final int level = (node.attributes[HeadingBlockKeys.level] as int?) ?? 1;
    return EdgeInsets.only(
      top: node.previous == null
          ? 0
          : snap(fontSize * headingTopSpacing(level)),
      bottom: 4,
    );
  }

  /// 某档标题的字号倍数（越界一律钳�?1~6，官�?`headingNode` 也是钳过的）�?
  static double headingScale(int level) =>
      headingScales[level.clamp(1, headingScales.length) - 1];

  /// 某档标题的上间距倍数（同样钳�?1~6）�?
  static double headingTopSpacing(int level) =>
      headingTopSpacings[level.clamp(1, headingTopSpacings.length) - 1];

  /// 组装 `EditorStyle` 的文字配置�?
  ///
  /// [text] = 正文（及标题、列表、引用、代码块、公式）�?*前景�?*——编辑器�?
  /// 继承 Ambient 样式�?*必须显式�?*，否则亮色下正文是白字（�?[body]）�?
  /// [link] = 链接色（[AppTheme.editorLink]：直接吃主题 primary 原色，与引用�?
  /// 竖条同族，明暗切换跟随、不写死）；[codeBackground] = 行内代码
  /// 的灰底（标杆编辑器观感，中性）；[muted] = 自动补全提示�?
  /// （收 `Color` 而非 `ColorScheme`：material_ui 与官�?flutter/material
  /// �?ColorScheme 是两个类型，只有 `Color` 两侧通用）�?
  TextStyleConfiguration toTextStyleConfiguration({
    required Color text,
    required Color link,
    required Color codeBackground,
    required Color muted,
  }) => TextStyleConfiguration(
    text: body().copyWith(color: text),
    // 链接：只加色与下划线，字�?回退链沿用基样式（`combine` 是合并语义）�?
    href: TextStyle(
      color: link,
      decoration: TextDecoration.underline,
      fontFamilyFallback: AppTheme.cjkFontFallback,
      letterSpacing: 0,
    ),
    // 行内代码：等宽链 + 主色；字号继承正文（官方无法对行�?span 单独缩放）�?
    code: TextStyle(
      fontFamily: AppTheme.monoFont,
      fontFamilyFallback: AppTheme.monoFallback,
      color: text,
      backgroundColor: codeBackground,
      letterSpacing: 0,
    ),
    autoComplete: TextStyle(color: muted),
    // 段落级行高倍数：与 [body] 同一套吸附（回填"整数行盒 / 字号"），
    // 否则正文 span 的行盒还是半像素�?
    lineHeight: lineBox(snap(fontSize), lineHeight) / snap(fontSize),
    // ⚠️ 官方默认 `applyHeightToFirstAscent/LastDescent: false`——首行升部�?
    // 末行降部**不乘行高**（保持字体自然度量）。雅黑自然升�?1.058em，贴�?
    // 程度轻；换霞鹜新晰黑后自然升部只�?0.88~0.916em �?首行基线被顶�?
    // 行盒上部，字�?贴行盒顶"、下部空 8~9px�?026-09-11 用户实测截图）�?
    // 全部�?true：首/末行与中间行同一�?height 缩放 + even 均分"几何 �?
    // 每行字形按度量盒在行盒内**居中**，且行距恒等于行盒（�?[lineBox]）�?
    applyHeightToFirstAscent: true,
    applyHeightToLastDescent: true,
  );
}
