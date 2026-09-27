import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

import '../blocks/attachment_block_component.dart';
import '../blocks/callout_block_component.dart';
import '../blocks/code_block_component.dart';
import '../blocks/formula_block_component.dart';
import '../blocks/ref_block_component.dart';
import '../blocks/toggle_block_component.dart';
import 'editor_typography.dart';

/// **块高预测�?*：不构建 widget，只用排版参数算出块的高度（px）�?
///
/// ## 它要解决什么（2026-09-14�?
/// 滚动器（官方 `ScrollablePositionedList`）的总高 =
/// **已布局部分的实测高�?* + **已布局块的平均高度 × 剩余块数**
/// （Flutter SDK `widgets/sliver.dart` �?`_extrapolateMaxScrollOffset`）�?
/// 那个"平均 × 剩余"�?*外推**：只要有一个明显高出正文的块（三行标题�?
/// 图片、代码块）被实测进来，基准就被抬高，总高被改写一�?�?
/// 内容瞬时位移一次（用户手感"滚动速度变一�"?）、滑块长度变一次�"?
///
/// 本预测器�?还没布局的块"�"?按平均外�?升级�?按排版参数算"�"?
/// 预测够准的话，滚动器从第一帧起就接近真值，修正量与随之而来的位移都�?
/// 消掉。这�?CodeMirror 6 �?`HeightMap`、VS Code 的做法同源—�?
/// **对没见过的东西用估计，见过的一律记�?*�?
///
/// ## 覆盖范围：能算的都算，算不了的明�?
///
/// | �?| 精度 | 依据 |
/// |---|---|---|
/// | 段落 / 标题 / 列表 / 待办 / 引用 | **逐像�?*（spike 实测 0.0px�?| `TextPainter` 干跑一次布局 |
/// | 分隔�?| 精确 | 线高 + 官方单独配的上下�?8 |
/// | 代码�?| 精确 | 等宽字体布局 + 内外两层内边距（几何与组件同源） |
/// | 图片 | 节点�?`height` 时精确；否则读图片头部拿宽高比；再不然取官方加载期高�?150 | `image_metrics.dart` + `resizable_image.dart` |
/// | **表格** | **近似**（同量级，非逐像素） | 读节点里�?`colsHeight`——见 [_tableHeightOf] 的说�?|
/// | 公式 / 附件 | `null`（退�?按一行估"�""?| 数学排版 / 卡片内部几何，复刻不划算 |
///
/// 返回 `null` 的块由调用方继续用实测�?/ 类型默认估计（见 `BlockHeights`）—�?
/// 它们**被布局到时会自动被实测替换**，偏差只存在�?还没滚到�?的那段时间�?
///
/// ## 精度�"?复刻"，所以要盯住官方升级
/// 这里复刻的是�?
/// 1. 官方 `AppFlowyRichText.getTextSpan` + `adjustTextSpan` �?span 构造；
/// 2. 官方各块组件自己�?`Container(padding: ...)` 几何（上�?4�?
///    列表 / 待办 / 引用还要让出标记宽度）；
/// 3. 我们自己块组件的几何（代码块的字体比例与内边距——抽成常量共用，
///    �?`blocks/code_block_component.dart`）�?
///
/// 因此上面任一处被改动，预测就会偏�?*这是刻意�?*�?
/// `test/block_height_predictor_spike_test.dart` 会响亮地失败（而不是静默偏），
/// 且实测值始终优先，预测只填"还没见过的块"�?
class BlockHeightPredictor {
  // �?const（下面有个按样式的占位符高度缓存；它�?key 与参数无关，只与样式有关）�?
  BlockHeightPredictor({
    required this.typography,
    required this.textStyleConfiguration,
    required this.maxWidth,
    required this.blockPadding,
    this.textScaleFactor = 1.0,
    this.imageAspectRatioOf,
  });

  /// 图片**宽高�?*（高 ÷ 宽）来源，按 `src` 查；null 或查不到时退�?加载�?高度�?
  ///
  /// 由视图喂 `blocks/image_metrics.dart` 的预解析缓存——那�?图片块在被构�?
  /// 之前就知道自己多�?的唯一途径（见 [_imageHeightOf]）�?
  final double? Function(String src)? imageAspectRatioOf;

  /// "占位符那一�"?的高度缓存（按样式字段拼 key）——见 [_placeholderHeightOf]�"?
  final Map<String, double> _placeholderHeights = <String, double>{};

  /// 排版单一来源（字�?/ 行高 / 标题档位与上间距）�?
  final EditorTypography typography;

  /// 官方的文字配置：span 基样�?+ bold / italic / href / code 的覆盖样式�?
  final TextStyleConfiguration textStyleConfiguration;

  /// `EditorStyle.maxWidth`（内容列限宽 = `AppSettings.contentWidth`）�?
  ///
  /// 官方�?`page_block_component.dart` 里把它作�?*每一�?*的最大宽�?
  /// （块在滚动器铺满的全宽里居中）�?
  final double maxWidth;

  /// **每一�?*的水平内边距（`EditorTypography.blockPadding`）�?
  ///
  /// ⚠️ 官方 `EditorStyle.padding` 是按块生效的，不是编辑器外框—�?
  /// �?[EditorTypography.blockPadding] 的说明�?
  final EdgeInsets blockPadding;

  /// `EditorStyle.textScaleFactor`（跟随系�?文字大小"）�""?
  final double textScaleFactor;

  /// 分隔线块的高度（官方 `DividerBlockComponentBuilder.height` 默认 10）�?
  static const double dividerHeight = 10;

  /// 图片**未解�?*时的渲染高度（px）：官方 `resizable_image.dart` �?
  /// `_buildLoading`（`SizedBox(height: 150)`）�?
  ///
  /// �?[dividerHeight] 同理——官方写死的值，上游一改预测就会偏（spike 会红）�?
  static const double imageLoadingHeight = 150;

  /// 表格视图�?`colsHeight` 之外�?*固定占用**（px）：
  /// 加行按钮 28 + 横向滚动视图的上下内边距 10 / 4�?
  ///
  /// 全部来自官方组件（`table_view.dart` �?`TableActionButton(height: 28)`�?
  /// `table_block_component.dart` �?`SingleChildScrollView(padding: top 10,
  /// bottom 4)`）—�?*上游一改预测就会偏**，spike 会红�?
  static const double _tableViewChromeHeight = 28 + 10 + 4;

  /// 列表 / 待办 / 引用块的标记占位宽度（px）�?
  ///
  /// 口径 = `markerBox`（`blocks/block_markers.dart`）：
  /// `Container(constraints: minWidth 26 × 文字缩放, padding: right 4)`�?
  /// ⚠️ �?4px 右留白在 `minWidth` **之内**（Container �?padding �?
  /// minWidth 兜住），所以实际占位就�?**26 × 缩放**，不�?+4—�?
  /// 2026-09-15 实测（渲染树里量到的文字列）确认等于 26�?
  ///
  /// **换成更宽的标记（如多位数序号跨过 26）时本式要跟着�?*�?
  double get markerWidth => 26 * textScaleFactor;

  /// 本预测器负责的块类型（纯文字 + 分隔线）�?
  ///
  /// �?*显式白名�?*而不�?�?delta 就算文字�?：代码块�?delta 也是文字�?
  /// 但它的几何（等宽 + 横向滚动 + 自己的内边距）与本预测器的公式不同，
  /// 宁可返回 null 交给实测 / 默认估计，也不要给个看起来合理的错值�?
  static const Set<String> textBlockTypes = <String>{
    ParagraphBlockKeys.type,
    HeadingBlockKeys.type,
    BulletedListBlockKeys.type,
    NumberedListBlockKeys.type,
    TodoListBlockKeys.type,
    QuoteBlockKeys.type,
  };

  /// 需要让出标记宽度的块类型�?
  static const Set<String> _markerBlockTypes = <String>{
    BulletedListBlockKeys.type,
    NumberedListBlockKeys.type,
    TodoListBlockKeys.type,
    QuoteBlockKeys.type,
    // 折叠块的折叠箭头：与列表圆点共用 `markerBox`�?6 × 文字缩放 + 4），
    // 所以文字可用宽度也要同样让出这一块（�?blocks/block_markers.dart）�?
    ToggleListBlockKeys.type,
  };

  /// 预测 [node] 的高度（px）�?
  ///
  /// [availableWidth] 是编辑器拿到的可用宽度（窗口宽减去目录面板等）；
  /// 不知道时�?`double.infinity`（按 [maxWidth] 算）�?
  ///
  /// 返回 `null` = 本预测器不负责该类型（见 [textBlockTypes]）�?
  double? predict(Node node, {double availableWidth = double.infinity}) {
    switch (node.type) {
      case DividerBlockKeys.type:
        return _dividerHeightOf(node);
      case ImageBlockKeys.type:
        return _imageHeightOf(node, availableWidth);
      case CodeBlockKeys.type:
        return _codeBlockHeightOf(node, availableWidth);
      case TableBlockKeys.type:
        return _tableHeightOf(node);
      case ToggleListBlockKeys.type:
        return _toggleHeightOf(node, availableWidth);
      case CalloutBlockKeys.type:
        if (node.delta == null) return null;
        return _calloutHeightOf(node, availableWidth);
      case FormulaBlockKeys.type:
        return _formulaHeightOf(node);
      case AttachmentBlockKeys.type:
        return _attachmentHeightOf();
      case RefBlockKeys.type:
        return _refHeightOf();
      // 引用（embed）走官方标准块；结构不定，给保守估值，实测补回�?
      case 'embed':
        return _embedHeightOf();
    }
    if (!textBlockTypes.contains(node.type)) return null;
    if (node.delta == null) return null;
    return _textHeightOf(node, availableWidth) + _paddingOf(node).vertical;
  }

  /// 图片块：三级取值—�?
  /// 1. 节点里存�?`height` �?直接用（官方 `SizedBox(height:)` 决定块高）；
  /// 2. 存了宽高比（[imageAspectRatioOf]，由视图从图片头部预解析）⇒
  ///    **原始比例 × 显示宽度**（显示宽�?= 列的可用宽度，图片自�?`width` 时取小者）�?
  /// 3. 都没�?�?官方�?加载�?高度（`_buildLoading` �?`SizedBox(height: 150)`）�?
  ///
  /// �?2 条是关键：没存尺寸的图片（导入的图片都不带）解码完成时高度会变，
  /// 于是滚动总高跟着变一次——预解析比例后，**块被构建之前**就能算准�?
  /// 那次变化随之消失�?
  double _imageHeightOf(Node node, double availableWidth) {
    final double verticalPadding = _paddingOf(node).vertical;
    final double? stored = (node.attributes[ImageBlockKeys.height] as num?)
        ?.toDouble();
    if (stored != null) return stored + verticalPadding;

    final String src = (node.attributes[ImageBlockKeys.url] as String?) ?? '';
    final double? ratio = imageAspectRatioOf?.call(src);
    if (ratio == null || !ratio.isFinite || ratio <= 0) {
      return imageLoadingHeight + verticalPadding;
    }
    final double column = textWidthOf(node, availableWidth: availableWidth);
    final double? storedWidth = (node.attributes[ImageBlockKeys.width] as num?)
        ?.toDouble();
    final double displayWidth = math.min(storedWidth ?? column, column);
    return displayWidth * ratio + verticalPadding;
  }

  /// 表格块：高度**写在节点属性里**——官�?`TableNode.updateRowHeight` 在单元格
  /// 内容或列宽变化时都会把总高写进 `TableBlockKeys.colsHeight`，所以直接读�?
  /// **不必建模单元格内�?*（这正是表格最省事的地方）�?
  ///
  /// 组成（全部来自官�?`table_block_component.dart` / `table_view.dart`）：
  /// - `colsHeight` = Σ(行高 + 边框) + 边框�?
  /// - 表格视图**始终占位**�?加行 / 加列"按钮 28px（`Visibility` 藏的只是图标�""?
  ///   位置照旧占着）；
  /// - 横向 `SingleChildScrollView` 的内边距（上 10 + �?4）；
  /// - 块的上下内边距（官方默认�?4）�?
  ///
  /// 属性缺失时（旧数据 / 刚插入还没被官方写过）按 `行数 × (默认行高 + 边框) + 边框`
  /// 兜底——比"按一行估"准得多；结构不合法（�?`rowsLen`）则返回 null�?
  ///
  /// ⚠️ **这是全场唯一�?近似"�"?*，别�?逐像�"?预期它（2026-09-14 实测）：
  ///
  /// | �?| 节点 colsHeight | 实测块高 | �?|
  /// |---|---|---|---|
  /// | 2×2 | 90 | 136 | 90 + 46 |
  /// | 1×1 | 46 | 94 | 46 + 48 |
  /// | 2×2 长单元格 | 350 | **312** | 350 **�?38** |
  ///
  /// 第三�?*渲染�?节点存的总高"还矮 38px**，而单元格�""?`minHeight` 约束、只可能
  /// 更高 �?实测量到的是官方 `updateRowHeight` **异步写回之前**那一帧。也就是�?
  /// 表格�?属�?�?渲染"本来就有时序差，靠属性拿不到逐像素�""?
  ///
  /// 仍然值得做：它把表格的误差从"按一行估"�?*一个数量级**压到**同量�?*
  /// （spike 里表格单独一条闸门，只钉"别退回一行估、别差一个量�"?）�"?
  double? _tableHeightOf(Node node) {
    final double borderWidth =
        (node.attributes[TableBlockKeys.borderWidth] as num?)?.toDouble() ??
        TableDefaults.borderWidth;
    final double stored =
        (node.attributes[TableBlockKeys.colsHeight] as num?)?.toDouble() ?? 0;
    final double content;
    if (stored > 0 && stored.isFinite) {
      content = stored;
    } else {
      final double rowHeight =
          (node.attributes[TableBlockKeys.rowDefaultHeight] as num?)
              ?.toDouble() ??
          TableDefaults.rowHeight;
      final int? rowsLen = (node.attributes[TableBlockKeys.rowsLen] as num?)
          ?.toInt();
      if (rowsLen == null || rowsLen <= 0) return null;
      content = rowsLen * (rowHeight + borderWidth) + borderWidth;
    }
    return content + _tableViewChromeHeight + _paddingOf(node).vertical;
  }

  /// 代码块：等宽文字的高�?+ 内外两层内边距�?
  ///
  /// 几何全部取自 `blocks/code_block_component.dart`（那里抽成了常量）：
  /// 外层是官方的块内边距（上下各 4），内层�?`codeBlockInnerPadding`�?
  ///
  /// 语法高亮�?span 只改颜色 / 字重 / 斜体�?*等宽字体下这些都不改字符步进**
  /// �?折行位置与行盒与纯文本串一致（�?`note_code_syntax.dart` �?`_tokenStyle`）�?
  double _codeBlockHeightOf(Node node, double availableWidth) {
    // 与组�?*同一�?*等宽样式（`EditorTypography.code`：字�?/ 行盒都吸附整像素）�?
    final TextStyle codeStyle = typography.code(textStyleConfiguration.text);
    final double width =
        textWidthOf(node, availableWidth: availableWidth) -
        codeBlockInnerPadding.horizontal -
        // 右侧给复制按钮让位的一条（与组件同口径，见 codeBlockCopyZone）�?
        codeBlockCopyZone;
    final String plain = node.delta?.toPlainText() ?? '';
    // 同样要与"占位符那一�"?取较高者，而且要排**那层真正会排的文�?*�"?
    // 块里有内容时那层被清空（空串）、空着时排 [codeBlockPlaceholder]�?
    // 等宽样式吸附成整数行盒后两者与正文同高�?3 = 23），max 退化成"就是�"?�"?
    // 但保留它才对得上官方 `Stack` 的语义、也免疫将来的行盒变化�?
    final double text = math.max(
      _heightOfSpan(TextSpan(text: plain, style: codeStyle), width),
      math.max(
        _cachedSpanHeight(TextSpan(text: '', style: codeStyle)),
        _cachedSpanHeight(
          TextSpan(text: codeBlockPlaceholder, style: codeStyle),
        ),
      ),
    );
    return text + codeBlockInnerPadding.vertical + _paddingOf(node).vertical;
  }

  /// 分隔线块的高度（px�? 线高 + 上下内边距�?
  ///
  /// ⚠️ 分隔�?*不吃**默认的上下各 4：官方标准注册表给它单独配了
  /// `padding: vertical 8`（见 `standard_block_components.dart`）�?
  /// 两个数都�?*官方注册表现�?*（不写死），上游一改我们跟着走�?
  double _dividerHeightOf(Node node) {
    final BlockComponentBuilder? builder =
        standardBlockComponentBuilderMap[DividerBlockKeys.type];
    final double padding = builder?.configuration.padding(node).vertical ?? 16;
    final double height = builder is DividerBlockComponentBuilder
        ? builder.height
        : dividerHeight;
    return height + padding;
  }

  /// 一行的可用宽度（px）——诊断与测试用�?
  ///
  /// 列宽 = `min(可用宽度, maxWidth)`，再减去**每一�?*的水平内边距�?
  /// 列表 / 待办 / 引用还要让出标记宽度�?
  double textWidthOf(Node node, {double availableWidth = double.infinity}) {
    final double column = math.min(availableWidth, maxWidth);
    // 水平让位三段，一个都不能少：
    // �?每块�?`EditorStyle.padding`（左右各 16）；
    // �?**块手�?*（行内常驻占位，�?`EditorTypography.blockHandleWidth`）；
    // �?列表/待办/引用的标记（仅这些类型）�?
    final double inner =
        column - blockPadding.horizontal - EditorTypography.blockHandleWidth;
    return _markerBlockTypes.contains(node.type) ? inner - markerWidth : inner;
  }

  // ───────────────────────────── 内部 ─────────────────────────────

  /// 块的上下内边距（px）——官方各块组件自己的 `Container(padding: ...)`�?
  ///
  /// 标题走我们的 [EditorTypography.headingPadding]�?*含按级递增的上间距�?
  /// 且文档首块不�?*），其余走官�?`BlockComponentConfiguration` 默认
  /// （上下各 4）�?
  EdgeInsets _paddingOf(Node node) => node.type == HeadingBlockKeys.type
      ? typography.headingPadding(node)
      : standardBlockComponentConfiguration.padding(node);

  double _textHeightOf(Node node, double availableWidth) => _textHeightAtWidth(
    node,
    textWidthOf(node, availableWidth: availableWidth),
  );

  /// �?*已给�?*的文字宽度算文字高度（供 callout 这类"还要再扣一层内边距"
  /// 的块使用——见 [_calloutHeightOf] 的坑 2）�?
  double _textHeightAtWidth(Node node, double width) {
    // 官方 `AppFlowyRichText.build` �?占位符那�?与正�?RichText 放在**同一�?
    // `Stack`** 里（取较高者），所以两层都要算——空块由占位符那层给高度�?
    return math.max(
      _heightOfSpan(_textSpanOf(node), width),
      _cachedSpanHeight(_placeholderSpanOf(node)),
    );
  }

  /// 折叠块（**容器**）：自身一�?+ 子块高度之和（折叠时子块�?0）�?
  ///
  /// 三条口径，都�?`blocks/toggle_block_component.dart` 里对应着实现�?
  /// - 子块的可用宽度要再让�?[indentWidthOf]（`NestedListWidget` 的缩进）
  ///   �?子块折行更早、更高。窄列下这条最明显�?
  /// - **展开但还没有子块**时，块内多一�"?点击添加内容"
  ///   （[togglePlaceholderPadding] + 同一字号的一行文字）——用**自身文本高度**
  ///   近似（占位文案短，恒为一行，度量盒同字号）；
  /// - 子块类型本预测器不认识时（公�?/ 表格 / 附件）退�?
  ///   [EditorTypography.estimatedBlockHeight]，否则整段高度会凭空少一块，
  ///   折叠�?*后面**的所有块�?�?�?像素"换算里全部前移�""?
  double _toggleHeightOf(Node node, double availableWidth) {
    final bool collapsed =
        (node.attributes[ToggleListBlockKeys.collapsed] as bool?) ?? false;
    final double ownText = _textHeightOf(node, availableWidth);
    final double height = ownText + _paddingOf(node).vertical;
    if (collapsed) return height;
    if (node.children.isEmpty) {
      return height + ownText + togglePlaceholderPadding.vertical;
    }

    double total = height;
    // ⚠️ `availableWidth` �?infinity 时要落到 [maxWidth] 再减缩进�?
    // `infinity - 缩进` 仍是 infinity，缩进会被吞�?�?子块按全宽预测�?
    // 比真实（已缩进）少折行�?
    final double childWidth = availableWidth.isFinite
        ? math.max(0, availableWidth - indentWidthOf(node))
        : maxWidth - indentWidthOf(node);
    for (final Node child in node.children) {
      total +=
          predict(child, availableWidth: childWidth) ??
          typography.estimatedBlockHeight(child);
    }
    return total;
  }

  /// Callout 块（扁平版）：图�?+ 一行正文。几�?= 正文高度（与段落同款
  /// `AppFlowyRichText`�? 两道内边距（外层官方块内边距 [_paddingOf] + 内层
  /// [calloutInnerPadding]）。图标与正文同行（`crossAxisAlignment.start`、用�?
  /// 字号），不额外增高；但图标列 + 内层水平内边距要从正文的可用宽度里扣掉，
  /// 否则正文会比真值少折一行（�?`callout_block_component.dart` �?Row）�?
  /// 扣掉后与组件同口�?�?预测逐像素精确（spike 实测 Δ=0）�?
  double _calloutHeightOf(Node node, double availableWidth) {
    // 正文可用宽度 = `textWidthOf`（已扣块内边距与块手柄）�?内层水平内边�?
    // �?图标列（图标字号 + 图标间距）�?
    //
    // ⚠️ 两处坑（2026-09-15 实测修掉）：
    // 1. `EdgeInsets.horizontal` **已经是左右之�?*，不要再 ×2（�? 会多�?
    //    24px，让预测比渲染少折一行）�?
    // 2. **不能**写成 `_textHeightOf(node, availableWidth - inset)`—�?
    //    `availableWidth` �?`double.infinity` 时减 inset 仍是 infinity�?
    //    扣减被整个吞掉。必须先�?`textWidthOf` 收敛成有限宽度再�?
    //    （与 [_codeBlockHeightOf] 同一模式）�?
    final double inset =
        calloutInnerPadding.horizontal + _calloutIconColumnWidth;
    final double width =
        textWidthOf(node, availableWidth: availableWidth) - inset;
    final double text = _textHeightAtWidth(node, width);
    return text + calloutInnerPadding.vertical + _paddingOf(node).vertical;
  }

  /// 图标列占宽：官方 `SizedBox(width: iconSize + calloutIconGap)`，其�?
  /// `iconSize = 正文字号 × calloutIconScale`（`textStyleWithTextSpan` 返回正文
  /// 样式，故字号�?[EditorTypography.fontSize]；callout 组件同口径）�?
  double get _calloutIconColumnWidth =>
      typography.fontSize * calloutIconScale + calloutIconGap;

  /// 公式块：渲染高度无法�?不渲�?下精确得到（MathJax/KaTeX 类），按 LaTeX
  /// 复杂度估行数——每个分�?/ 根号 / 求和 / 积分 / 矩阵约占 0.7 行。外�?
  /// `buildContent` 还有 `Padding(vertical:4)`�?8）。低估部分由实测补回�?
  double _formulaHeightOf(Node node) {
    final String latex =
        (node.attributes[FormulaBlockKeys.latex] as String?) ?? '';
    final double line = EditorTypography.lineBox(
      typography.fontSize,
      typography.lineHeight,
    );
    return line * (1 + _formulaExtraLines(latex) * 0.7) + 8;
  }

  static int _formulaExtraLines(String latex) {
    int n = 0;
    for (final String tok in const <String>[
      r'\frac',
      r'\sqrt',
      r'\sum',
      r'\int',
      r'\begin',
      r'\matrix',
      r'\over',
    ]) {
      n += latex.split(tok).length - 1;
    }
    return n;
  }

  /// 附件卡片估算高度（px）：固定几何（见 `attachment_card.dart`）≈ 外层块内边距
  /// 8 + 卡片自身（图�?/ 两行文字 + 内边距）�?48。低估由 `BlockHeightProbe`
  /// 实测精确补回�?
  static const double _attachmentHeight = 56;

  /// 引用（embed）块估算高度（px）：官方标准 URL/文件预览，结构不定，给保守估值，
  /// �?`BlockHeightProbe` 实测补回�?
  static const double _embedHeight = 160;

  double _attachmentHeightOf() => _attachmentHeight;
  double _embedHeightOf() => _embedHeight;

  /// 引用块估算高度（px）：固定几何 —�?外层块内边距 8 + 一行卡�?
  /// （图�?文字行盒 ~20 + 上下内边�?8 + 边框 2）�?
  /// 低估�?`BlockHeightProbe` 实测精确补回�?
  static const double _refHeight = 40;

  double _refHeightOf() => _refHeight;

  /// 容器块的子节点缩进（官方 `BlockComponentConfiguration.indentPadding`
  /// 的默认口径）—�?*只在水平方向**扣掉，用来估子块的折行宽度�?
  double indentWidthOf(Node node) => standardBlockComponentConfiguration
      .indentPadding(node, TextDirection.ltr)
      .horizontal;

  /// 一�?span 的高度（px），�?**文本 + 样式** 缓存�?
  ///
  /// 专供"占位符那一�"?这类**反复出现的固定文�?*（空�"?/ 占位文案）：一次预算里
  /// 它们与块无关，只与样式有关，而样式至多十来种（正�?+ 6 档标�?+ 等宽）�?
  double _cachedSpanHeight(TextSpan span) {
    final TextStyle? style = span.style;
    final String key =
        '${span.text}|${style?.fontSize}|${style?.height}|${style?.fontFamily}'
        '|${style?.fontWeight}|${style?.fontStyle}|$textScaleFactor';
    final double? cached = _placeholderHeights[key];
    if (cached != null) return cached;
    final double value = _heightOfSpan(span, double.infinity);
    _placeholderHeights[key] = value;
    return value;
  }

  /// 布局一�?span，返回高度（px）�?
  ///
  /// ## 2026-09-19 实测：这里的成本**压不下来**，别往"少分�""?使劲
  /// - **复用 `TextPainter` 实例**（而不是每�?new + dispose）：**1.00×，零收益**�?
  ///   实测每块新建 0.0641 ms / 复用 0.0642 ms —�?钱全花在真正的段落排版上�?
  ///   不花在对象分配上�?
  /// - `TextPainter.computeDryLayout()`�?*不存�?*（那�?`RenderParagraph` �?
  ///   方法，编译期就报错）。网�?用它预布局能省 60%"的说法不成立�""?
  ///
  /// �?想让块高预算更快�?*只有一条路：少算几�?*（按需 / 分帧 / 只算视口附近）�?
  /// 所�?让单次更�?的微优化在这里都已被证伪�?
  ///
  /// ⚠️ **测这个极易踩的坑**：复用实例时若传**同一�?`TextSpan` 对象**�?
  /// `TextPainter` 会认为内容没变而跳�?layout �?量出来的�?读缓�?�?
  /// 假象能到 **30×**。验证办法：交替�?2 �?/ 6 行的文本，并断言高度确实
  /// 跟着变——不变就说明测量不成立�?
  double _heightOfSpan(TextSpan span, double maxWidth) {
    final TextPainter painter = TextPainter(
      text: span,
      textDirection: .ltr,
      textScaler: TextScaler.linear(textScaleFactor),
      // 与官�?`_buildRichText` �?`TextHeightBehavior` 逐项一致：它决�?
      // �?末行的升部降部是否按行高缩放，直接影响总高�?
      textHeightBehavior: TextHeightBehavior(
        applyHeightToFirstAscent:
            textStyleConfiguration.applyHeightToFirstAscent,
        applyHeightToLastDescent:
            textStyleConfiguration.applyHeightToLastDescent,
        leadingDistribution: textStyleConfiguration.leadingDistribution,
      ),
    )..layout(maxWidth: maxWidth);
    final double height = painter.height;
    painter.dispose();
    return height;
  }

  /// 复刻官方 `AppFlowyRichText.getTextSpan`（含 `adjustTextSpan` 与块�?
  /// `textSpanDecorator`）——预测精度的全部来源�?
  TextSpan _textSpanOf(Node node) {
    final List<InlineSpan> children = <InlineSpan>[
      for (final TextInsert insert in node.delta!.whereType<TextInsert>())
        TextSpan(text: insert.text, style: _insertStyleOf(insert)),
    ];
    return _decorate(node, _withRootStyle(TextSpan(children: children)));
  }

  /// 占位符那一层的 span（官�?`getPlaceholderTextSpan` + `placeholderText`）�?
  ///
  /// 官方语义：这层样式恒为正文基样式（`height: lineHeight`），**文字**则是—�?
  /// �?*有内�?*：清�?*空串**（样式仍�?�?�?span 仍占一个行盒，两层�?
  /// 同一�?`Stack` 里取较高者，所以这层必须算）；
  /// �?*为空**：排 `placeholderText`（官方默�?**`' '`**，单空格——有字形�?
  /// 占一个正文行盒；不是空串！）�?
  ///
  /// ⚠️ 两�"?heights 不必然相等（2026-09-15 换字体实测）：引擎对"无字形的
  /// �?span"�"?有字形的�?取整路径不同——屏幕阅读版度量�"?14px/行盒 25
  /// 时，空串 = 26、空�?单行 = 25，差 1px（旧版霞鹜度量下两者恰好同高，
  /// 掩盖了这条）。按官方语义分叉后两种字体都对齐——spike 会盯着这条�?
  TextSpan _placeholderSpanOf(Node node) {
    final bool hasContent = node.delta?.isNotEmpty ?? false;
    return _decorate(
      node,
      TextSpan(
        text: hasContent ? '' : ' ',
        style: textStyleConfiguration.text.copyWith(
          height: textStyleConfiguration.lineHeight,
        ),
      ),
    );
  }

  /// 复刻官方 `adjustTextSpan`：根 span 没有样式时补�?�?span 里最大的
  /// 字号 / 行高倍数"（官方注释：不补时光标高度算错）�""?
  ///
  /// 对我们的意义：这一段决定了**行盒**——`height` 是行高倍数，`fontSize`
  /// 是档位字号，两者相乘（引擎�?字号 × 倍数"算行盒）才是每行的真实高度�""?
  TextSpan _withRootStyle(TextSpan span) {
    double height = 0;
    double fontSize = 0;
    span.visitChildren((InlineSpan child) {
      final TextStyle? style = child.style;
      if (style != null) {
        if (style.height != null) height = math.max(height, style.height!);
        if (style.fontSize != null) {
          fontSize = math.max(fontSize, style.fontSize!);
        }
      }
      return true;
    });
    if (height == 0 || fontSize == 0) return span;
    return span.copyWith(
      style: textStyleConfiguration.text.copyWith(
        height: height,
        fontSize: fontSize,
      ),
    );
  }

  /// 块级 span 装饰（官方各�?`textSpanDecorator` 里合并进来的样式）�?
  ///
  /// ⚠️ 我们的配置里**只有标题**给了样式（`custom_block_components.dart` �?
  /// `textStyleBuilder: typography.heading`）；段落 / 列表 / 待办 / 引用�?
  /// `BlockComponentConfiguration.textStyle` 都是官方默认
  /// （`const TextStyle()` �?空操作）�?
  /// **将来给某类块加了 textStyleBuilder，必须同步这�?*，否则预测会偏�?
  TextSpan _decorate(Node node, TextSpan span) {
    // 折叠标题�?*同一节点类型 + `level`**（官方口径，�?
    // `blocks/toggle_block_component.dart`），所以这里不能只看类型：
    // 标题块取 `level`（缺�?1）；折叠块有 `level` 才算折叠标题�?
    if (node.type == HeadingBlockKeys.type) {
      return span.updateTextStyle(
        typography.heading(
          (node.attributes[HeadingBlockKeys.level] as int?) ?? 1,
        ),
      );
    }
    if (node.type == ToggleListBlockKeys.type) {
      final Object? level = node.attributes[ToggleListBlockKeys.level];
      if (level is int) return span.updateTextStyle(typography.heading(level));
    }
    return span;
  }

  /// 复刻官方 `getTextSpan` 里逐条 `TextInsert` 的样式合并顺�?
  /// （只保留**影响行盒**的项：字�?/ 字族 / 字重 / 斜体 / 等宽 / 下划线；
  /// 颜色与底色不参与布局，故不合并）�?
  TextStyle _insertStyleOf(TextInsert insert) {
    TextStyle style = textStyleConfiguration.text.copyWith(
      height: textStyleConfiguration.lineHeight,
    );
    final Attributes? attributes = insert.attributes;
    if (attributes == null) return style;

    if (attributes.bold == true) {
      style = style.combine(textStyleConfiguration.bold);
    }
    if (attributes.italic == true) {
      style = style.combine(textStyleConfiguration.italic);
    }
    if (attributes.underline == true) {
      style = style.combine(textStyleConfiguration.underline);
    }
    if (attributes.strikethrough == true) {
      style = style.combine(textStyleConfiguration.strikethrough);
    }
    if (attributes.href != null) {
      style = style.combine(textStyleConfiguration.href);
    }
    if (attributes.code == true) {
      style = style.combine(textStyleConfiguration.code);
    }
    if (attributes.fontFamily != null) {
      style = style.combine(TextStyle(fontFamily: attributes.fontFamily));
    }
    if (attributes.fontSize != null) {
      style = style.combine(TextStyle(fontSize: attributes.fontSize));
    }
    return style;
  }
}
