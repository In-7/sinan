import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
// 与 appflowy 内部同一套 material（官方 material 同名类型是**另一套**，
// 两边同时导入会 ambiguous，见 `editor_spike_verification_test.dart` 的说明）。
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/domain/settings.dart';
import 'package:sinan/src/editor/core/block_height_predictor.dart';
import 'package:sinan/src/editor/core/block_heights.dart';
import 'package:sinan/src/editor/blocks/attachment_block_component.dart';
import 'package:sinan/src/editor/blocks/callout_block_component.dart';
import 'package:sinan/src/editor/blocks/code_block_component.dart';
import 'package:sinan/src/editor/blocks/formula_block_component.dart';
import 'package:sinan/src/editor/blocks/custom_block_components.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// **块高预测器（spike）的精度实测**：预测值 vs 真实渲染高度，逐块对比。
///
/// ## 为什么要有这个脚本
/// 滚动器（官方 `ScrollablePositionedList`）的总高 =
/// 已布局部分的**实测**高度 + 已布局块的**平均**高度 × 剩余块数
/// （Flutter SDK `widgets/sliver.dart` 的 `_extrapolateMaxScrollOffset`）。
/// 那个"平均 × 剩余"是外推：一个明显高出正文的块（三行标题 / 图片 /
/// 代码块）被实测进来，基准就被抬高一次 ⇒ 内容位移一次、滑块长度变一次
/// —— 这就是用户报的"滚动到中间会滑一下、快到底时滑块变长"。
///
/// 要消掉它，唯一的正解是让**总高从第一帧起就接近真值**：给滚动器喂
/// "每个块的真实高度"，而不是让它从局部平均外推。能不能喂准，取决于
/// `BlockHeightPredictor` 的算术——本脚本就是量它。
///
/// ## 口径
/// - **预测**：`BlockHeightPredictor.predict(node)`，纯算术、不建 widget；
/// - **实测**：挂官方的 `AppFlowyEditor.blockWrapper`（**与生产同一处口子**，
///   见 `note_editor_view_appflowy.dart` 的 `_flashWrapper`）+ `BlockHeightProbe`，
///   读每个块的渲染盒高度。实测值不给 `BlockHeights`：那一层按设计**吸附整
///   像素**（`measure` 里的 `roundToDouble`），会把 ±0.5px 的量化误差混进来，
///   而本脚本要量的是原始真值。
/// - **字体**：加载**打包的真实字体**（`assets/fonts/LXGWNeoXiHeiScreen.ttf`）。
///   不加载的话走 Flutter 测试字体（每个字符都是 1em 方格），CJK 反而"碰巧
///   对"，拉丁/标点全错——那测出来的精度**不能外推到生产**。
///
/// ## 这个脚本会守住什么
/// 官方一改 `AppFlowyRichText.getTextSpan` / `adjustTextSpan`，或各块组件的
/// `Container(padding: ...)` 几何，预测就会偏——本脚本会**红**，不会静默偏。
/// 这是刻意的（预测器的精度本来就建立在这两处的复刻上）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // 真实字体：不加载就只能测"测试字体"，测出来的精度外推不到生产。
    final FontLoader loader = FontLoader(AppTheme.editorFont)
      ..addFont(rootBundle.load('assets/fonts/LXGWNeoXiHeiScreen.ttf'));
    await loader.load();
  });

  testWidgets('真实字体已加载（否则本文件的精度数字外推不到生产）', (
    WidgetTester tester,
  ) async {
    _reportFontInUse(const EditorTypography(fontSize: 17, lineHeight: 1.5));
  });

  // 三个维度都要对：默认档（17 / 1.5）、滑杆另一档（14 / 1.75）、
  // 系统"文字大小"（125%）。预测器只要有一处理错（吸附、行盒、标记宽度、
  // TextScaler），对应组合就会红。
  for (final (String label, double fontSize, double lineHeight, double scale)
      in <(String, double, double, double)>[
        (
          '默认 17px / 1.5 / 100%',
          AppSettings.defaultFontSize,
          AppSettings.defaultLineHeight,
          1,
        ),
        ('小字 14px / 1.75 / 100%', 14, 1.75, 1),
        ('默认字号 + 系统文字缩放 125%', AppSettings.defaultFontSize, 1.5, 1.25),
      ]) {
    testWidgets('文字块：预测高度 vs 实测高度（$label）', (
      WidgetTester tester,
    ) async {
      await _verifyPrediction(
        tester,
        fontSize: fontSize,
        lineHeight: lineHeight,
        textScaleFactor: scale,
      );
    });
  }

  // ⚠️ 表格**单独一套闸门**（不进上面那条 0.0px 的）：它的高度只能"近似"。
  //
  // 反推记录（2026-09-14 探针实测）：
  //
  // | 表 | 节点 colsHeight | 实测块高 | 差 |
  // |---|---|---|---|
  // | 2×2 | 90 | 136 | 90 + 46 |
  // | 1×1 | 46 | 94 | 46 + 48 |
  // | 2×2 长单元格 | 350 | **312** | 350 **− 38** |
  //
  // 第三行**渲染比"节点存的总高"还矮 38px** —— 而单元格是 `minHeight` 约束、
  // 只会更高，所以唯一解释是：实测量到的是官方 `updateRowHeight` **异步写回之前**
  // 那一帧。也就是说表格的"属性 ↔ 渲染"本来就有时序差。
  //
  // 结论：用 `colsHeight` 估算**比"按一行估"准得多**（量级 1/3 以内 vs 1/10），
  // 但到不了文字块那种逐像素——所以只钉"别退回一行估、别差一个量级"。
  testWidgets('表格：按属性估算（近似；量级正确即可）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const EditorTypography typography = EditorTypography(
      fontSize: AppSettings.defaultFontSize,
      lineHeight: AppSettings.defaultLineHeight,
    );
    final ThemeData theme = AppTheme.light();
    final TextStyleConfiguration config = typography.toTextStyleConfiguration(
      text: theme.colorScheme.onSurface,
      link: theme.colorScheme.primary,
      codeBackground: theme.colorScheme.surfaceContainerHighest,
      muted: theme.colorScheme.onSurfaceVariant,
    );

    final List<(String, Node)> tables = <(String, Node)>[
      ('2×2', TableNode.fromList(<List<String>>[
        <String>['甲一', '乙一'],
        <String>['甲二', '乙二'],
      ]).node),
      ('1×1', TableNode.fromList(<List<String>>[
        <String>['唯一单元格'],
      ]).node),
      ('2×2 长', TableNode.fromList(<List<String>>[
        <String>['汉' * 60, '短'],
        <String>['短', '汉' * 30],
      ]).node),
    ];

    final Map<String, double> measured = <String, double>{};
    await _pumpEditor(
      tester,
      children: <Node>[for (final (_, Node n) in tables) n],
      typography: typography,
      textStyleConfiguration: config,
      textScaleFactor: 1,
      theme: theme,
      onMeasured: (String id, double h) => measured[id] = h,
    );

    final BlockHeightPredictor predictor = BlockHeightPredictor(
      typography: typography,
      textStyleConfiguration: config,
      maxWidth: const AppSettings().contentWidth,
      blockPadding: EditorTypography.blockPadding,
    );

    final List<String> failures = <String>[];
    for (final (String label, Node node) in tables) {
      final double? predicted = predictor.predict(node);
      final double actual = measured[node.id] ?? 0;
      final double oneLine = typography.estimatedBlockHeight(node);
      // ignore: avoid_print
      print(
        '表格 $label：colsHeight=${node.attributes['colsHeight']} '
        '预算=${predicted?.toStringAsFixed(1)} 实测=${actual.toStringAsFixed(1)} '
        '（"按一行估"=${oneLine.toStringAsFixed(1)}）',
      );
      if (predicted == null) {
        failures.add('$label：预算器返回 null（应该按 colsHeight 估）');
        continue;
      }
      // 别退回"按一行估"：单行表格也有约 2.8 倍（1×1 实测 94 vs 34），多行的更多。
      if (predicted < oneLine * 2) {
        failures.add('$label：预算 ${predicted.toStringAsFixed(1)} 退回了"按一行估"的量级');
      }
      // 量级正确：不显著低估、也不离谱地高估（见类文档里的三例反推）。
      if (predicted < actual * 0.7 || predicted > actual + 120) {
        failures.add(
          '$label：预算 ${predicted.toStringAsFixed(1)} 与实测 '
          '${actual.toStringAsFixed(1)} 不在同一量级',
        );
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  // ⚠️ 公式 / 附件**单独一套闸门**（不进上面那条 0.0px 的）：它们的高度只能"近似"
  // —— 公式靠未渲染的 LaTeX 复杂度估算、附件是固定卡片几何——到不了文字块那种
  // 逐像素。所以只钉"别退回一行估、别差一个量级"（量级误差由 `BlockHeightProbe`
  // 实测补回，见 `note_editor_view_appflowy.dart` 的 `_adjustScrollForExtentChange`）。
  //
  // embed 块**不在这里**：它的高度依赖远程预览（URL/文件预览），headless 测试里
  // 取不到稳定真值，且生产由上面的实测 + 锚定纠偏闭环兜底，故不纳入自动校验。
  testWidgets('非文字块（公式/附件）：预测估值（量级正确即可）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const EditorTypography typography = EditorTypography(
      fontSize: AppSettings.defaultFontSize,
      lineHeight: AppSettings.defaultLineHeight,
    );
    final ThemeData theme = AppTheme.light();
    final TextStyleConfiguration config = typography.toTextStyleConfiguration(
      text: theme.colorScheme.onSurface,
      link: theme.colorScheme.primary,
      codeBackground: theme.colorScheme.surfaceContainerHighest,
      muted: theme.colorScheme.onSurfaceVariant,
    );

    final List<(String, Node)> blocks = <(String, Node)>[
      ('公式·单行', formulaBlockNode(latex: 'E=mc^2')),
      ('公式·分式', formulaBlockNode(latex: r'\frac{a}{b}+\sqrt{c}')),
      (
        '附件·pdf',
        attachmentBlockNode(
          metaJson: '{"path":"C:/x.pdf","name":"x.pdf","size":1234}',
        ),
      ),
    ];

    final Map<String, double> measured = <String, double>{};
    await _pumpEditor(
      tester,
      children: <Node>[for (final (_, Node n) in blocks) n],
      typography: typography,
      textStyleConfiguration: config,
      textScaleFactor: 1,
      theme: theme,
      onMeasured: (String id, double h) => measured[id] = h,
    );

    final BlockHeightPredictor predictor = BlockHeightPredictor(
      typography: typography,
      textStyleConfiguration: config,
      maxWidth: const AppSettings().contentWidth,
      blockPadding: EditorTypography.blockPadding,
    );

    final List<String> failures = <String>[];
    for (final (String label, Node node) in blocks) {
      final double? predicted = predictor.predict(node);
      final double actual = measured[node.id] ?? 0;
      final double oneLine = typography.estimatedBlockHeight(node);
      // ignore: avoid_print
      print(
        '$label：预算=${predicted?.toStringAsFixed(1)} 实测=${actual.toStringAsFixed(1)} '
        '（"按一行估"=${oneLine.toStringAsFixed(1)}）',
      );
      if (predicted == null) {
        failures.add('$label：预算器返回 null（应该按结构估）');
        continue;
      }
      // 别退回"按一行估"的量级（公式/附件都比一行高）。
      if (predicted < oneLine * 0.6) {
        failures.add('$label：预算 ${predicted.toStringAsFixed(1)} 退回了"按一行估"的量级');
      }
      if (actual <= 0) {
        // 个别块在 headless 下拿不到实测（如依赖远程预览的 embed），跳过量级校验。
        continue;
      }
      // 量级正确：启发式估值与实测在同一量级（±~1.5×），不差一个数量级。
      if (predicted < actual * 0.4 || predicted > actual * 2.5) {
        failures.add(
          '$label：预算 ${predicted.toStringAsFixed(1)} 与实测 '
          '${actual.toStringAsFixed(1)} 不在同一量级',
        );
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  group('成本：整篇预算要多少时间', () {
    // ⚠️ 读法：`flutter test` 跑的是 **JIT/debug**，没有 AOT 优化，比 release
    // 慢一截 ⇒ 下面的数字是**上界**。有意义的是**量级**与**对比基准**
    // （同一环境下"按一行估"要多少、单块要多少）。
    test('预测整篇（300 / 1000 块）', () {
      // ignore: prefer_const_constructors
      final EditorTypography typography = EditorTypography(
        fontSize: AppSettings.defaultFontSize,
        lineHeight: AppSettings.defaultLineHeight,
      );
      final BlockHeightPredictor predictor = BlockHeightPredictor(
        typography: typography,
        textStyleConfiguration: typography.toTextStyleConfiguration(
          text: const Color(0xFF000000),
          link: const Color(0xFF1565C0),
          codeBackground: const Color(0xFFEEEEEE),
          muted: const Color(0xFF757575),
        ),
        maxWidth: const AppSettings().contentWidth,
        blockPadding: EditorTypography.blockPadding,
      );

      for (final int blocks in <int>[300, 1000]) {
        final List<Node> document = _longDocument(blocks);
        final int textBlocks = document
            .where((Node n) => BlockHeightPredictor.textBlockTypes.contains(n.type))
            .length;

        // 预热：JIT + 字体/段落缓存，避免第一轮被算进"稳定值"。
        for (int i = 0; i < 3; i++) {
          for (final Node node in document) {
            predictor.predict(node);
          }
        }

        // 取 5 轮最小值（其余轮次可能被 GC / 别的测试打扰）。
        int bestPredict = 1 << 62;
        int bestEstimate = 1 << 62;
        for (int i = 0; i < 5; i++) {
          final Stopwatch predictWatch = Stopwatch()..start();
          for (final Node node in document) {
            predictor.predict(node);
          }
          predictWatch.stop();
          bestPredict = math.min(bestPredict, predictWatch.elapsedMicroseconds);

          final Stopwatch estimateWatch = Stopwatch()..start();
          for (final Node node in document) {
            typography.estimatedBlockHeight(node);
          }
          estimateWatch.stop();
          bestEstimate = math.min(
            bestEstimate,
            estimateWatch.elapsedMicroseconds,
          );
        }

        final double totalMs = bestPredict / 1000;
        // ignore: avoid_print
        print(
          '[成本] 块数 $blocks（文字块 $textBlocks）：'
          '整篇预算 ${totalMs.toStringAsFixed(1)}ms'
          '（${(bestPredict / blocks).toStringAsFixed(0)}µs/块）'
          ' · 对照"按一行估" ${(bestEstimate / 1000).toStringAsFixed(1)}ms'
          '（慢 ${(bestPredict / bestEstimate).toStringAsFixed(0)} 倍）'
          ' · 一帧 16.7ms 的 ${(totalMs / 16.7 * 100).toStringAsFixed(0)}%',
        );
      }
    });
  });
}

/// 造一份**贴近真实笔记**的长文档（混合块型 + 长短不一的文字）。
List<Node> _longDocument(int blocks) {
  final List<Node> children = <Node>[];
  for (int i = 0; i < blocks; i++) {
    final int kind = i % 8;
    if (kind == 0) {
      children.add(headingNode(level: i % 3 + 1, text: '第 $i 节${'汉' * (i % 15)}'));
    } else if (kind <= 3) {
      children.add(paragraphNode(text: '汉' * (10 + i % 60)));
    } else if (kind == 4) {
      children.add(bulletedListNode(text: '汉' * (5 + i % 40)));
    } else if (kind == 5) {
      children.add(todoListNode(checked: i.isEven, text: '汉' * (5 + i % 30)));
    } else if (kind == 6) {
      children.add(quoteNode(delta: Delta()..insert('汉' * (10 + i % 30))));
    } else {
      children.add(dividerNode());
    }
  }
  return children;
}

/// 跑一遍全部用例，逐块比"预测 vs 实测"，并把表打印出来。
Future<void> _verifyPrediction(
  WidgetTester tester, {
  required double fontSize,
  required double lineHeight,
  required double textScaleFactor,
}) async {
  // 视口给得比整篇高：**每个块都被布局**才有实测真值可比。
  tester.view.physicalSize = const Size(1400, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final EditorTypography typography = EditorTypography(
    fontSize: fontSize,
    lineHeight: lineHeight,
  );
  final ThemeData theme = AppTheme.light();
  final TextStyleConfiguration textStyleConfiguration = typography
      .toTextStyleConfiguration(
        text: theme.colorScheme.onSurface,
        link: theme.colorScheme.primary,
        codeBackground: theme.colorScheme.surfaceContainerHighest,
        muted: theme.colorScheme.onSurfaceVariant,
      );

  final List<(String, Node)> cases = _cases();
  final Map<String, double> measured = <String, double>{};
  await _pumpEditor(
    tester,
    children: <Node>[for (final (_, Node node) in cases) node],
    typography: typography,
    textStyleConfiguration: textStyleConfiguration,
    textScaleFactor: textScaleFactor,
    theme: theme,
    onMeasured: (String id, double height) => measured[id] = height,
  );

  final BlockHeightPredictor predictor = BlockHeightPredictor(
    typography: typography,
    textStyleConfiguration: textStyleConfiguration,
    maxWidth: _contentWidth,
    blockPadding: EditorTypography.blockPadding,
    textScaleFactor: textScaleFactor,
  );

  final StringBuffer log = StringBuffer();
  log.writeln(
    '预测器精度（字号 $fontSize / 行高 $lineHeight / 文字缩放 $textScaleFactor '
    '/ 列宽 ${_contentWidth.toStringAsFixed(0)} / '
    '文字宽度 ${predictor.textWidthOf(cases.first.$2).toStringAsFixed(1)}）',
  );
  log.writeln(
    '${"用例".padRight(26)}${"预测".padLeft(9)}${"实测".padLeft(9)}'
    '${"Δ".padLeft(8)}',
  );

  double worst = 0;
  String worstLabel = '';
  double rawTotal = 0;
  double roundedTotal = 0;
  final List<String> failures = <String>[];

  for (final (String label, Node node) in cases) {
    final double? predicted = predictor.predict(node);
    final double? actual = measured[node.id];
    if (actual == null) {
      failures.add('$label：没有被布局（视口太小或块未构建），拿不到实测值');
      continue;
    }
    rawTotal += actual;
    roundedTotal += actual.roundToDouble();
    if (predicted == null) {
      // 非文字块（分隔线之外）本预测器不负责——只记录，不判失败。
      log.writeln(
        '${label.padRight(26)}${"—".padLeft(9)}'
        '${actual.toStringAsFixed(1).padLeft(9)}${"（预测器不负责）".padLeft(8)}',
      );
      continue;
    }
    final double delta = predicted - actual;
    if (delta.abs() > worst.abs()) {
      worst = delta;
      worstLabel = label;
    }
    log.writeln(
      '${label.padRight(26)}'
      '${predicted.toStringAsFixed(1).padLeft(9)}'
      '${actual.toStringAsFixed(1).padLeft(9)}'
      '${delta.toStringAsFixed(1).padLeft(8)}',
    );
  }

  log.writeln(
    '最差：$worstLabel  Δ=${worst.toStringAsFixed(1)}px'
    '（$fontSize px 字号下 ${(worst.abs() / fontSize).toStringAsFixed(2)} 行）',
  );
  // 整像素吸附的累计代价：C 要把实测高度喂给滚动器当 extent，
  // 若沿用 `BlockHeights` 的整像素吸附（`roundToDouble`），整篇会累积这么多。
  log.writeln(
    '整篇实测总高 ${rawTotal.toStringAsFixed(1)}px；'
    '若按整像素吸附 = ${roundedTotal.toStringAsFixed(1)}px '
    '（累计偏差 ${(roundedTotal - rawTotal).toStringAsFixed(1)}px）',
  );
  // ignore: avoid_print
  print(log.toString());

  expect(failures, isEmpty, reason: failures.join('\n'));
  expect(
    worst.abs(),
    lessThan(1),
    reason:
        '预测与实测差 ${worst.toStringAsFixed(2)}px（$worstLabel）：'
        '预测器与渲染的复刻已经脱节——官方多半改了 span 构造或块的 padding 几何，'
        '去比对 `AppFlowyRichText.getTextSpan` / `adjustTextSpan` 与各块组件的 '
        '`Container(padding: ...)`',
  );
}

// ─────────────────────────── 用例 ───────────────────────────

/// 全部用例。**顺序有意义**：列表首块会被标题的"文档首块不给上间距"规则命中，
/// 所以第一条就是标题（顺带验证那条规则没被官方改掉）。
List<(String, Node)> _cases() {
  // 17px 正文 / 688px 文字宽 → 约 40 汉字一行；标题随档位变宽（h1 约 22 字）。
  String cjk(int chars) => '汉' * chars;

  return <(String, Node)>[
    ('标题h1·首块（不给上间距）', headingNode(level: 1, text: '文档首块标题')),
    ('段落·空（占位符一行）', paragraphNode(text: '')),
    ('段落·1行', paragraphNode(text: cjk(10))),
    ('段落·整行边界(40字)', paragraphNode(text: cjk(40))),
    ('段落·跨行边界(41字)', paragraphNode(text: cjk(41))),
    ('段落·2行', paragraphNode(text: cjk(45))),
    ('段落·3行', paragraphNode(text: cjk(85))),
    ('段落·中英数标点混排', paragraphNode(text: 'Flutter 编辑器 v6.2.0，测试（2026-09-14）' * 3)),
    ('标题h1·3行（真实事故形态）', headingNode(level: 1, text: cjk(50))),
    ('标题h2·1行', headingNode(level: 2, text: '二级标题')),
    ('标题h2·2行', headingNode(level: 2, text: cjk(35))),
    ('标题h3·1行', headingNode(level: 3, text: '三级标题')),
    ('标题h4·1行（与正文同号）', headingNode(level: 4, text: '四级标题')),
    ('标题h5·2行', headingNode(level: 5, text: cjk(45))),
    ('标题h6·1行', headingNode(level: 6, text: '六级标题')),
    ('无序·1行', bulletedListNode(text: '无序项')),
    ('无序·2行', bulletedListNode(text: cjk(45))),
    ('有序·1行', numberedListNode(delta: Delta()..insert('有序项'))),
    ('待办·1行', todoListNode(checked: false, text: '待办项')),
    ('待办·已勾·2行', todoListNode(checked: true, text: cjk(45))),
    ('引用·1行', quoteNode(delta: Delta()..insert('引用一行'))),
    ('引用·2行', quoteNode(delta: Delta()..insert(cjk(45)))),
    ('分隔线', dividerNode()),
    // Callout：扁平（图标 + 正文）。预测器已扣掉图标列 + 内层内边距 ⇒ 逐像素精确
    // （与段落同一套文字度量，见 `block_height_predictor.dart`）。
    ('callout·1行', calloutNode(delta: Delta()..insert('callout 一行内容'))),
    ('callout·2行', calloutNode(delta: Delta()..insert(cjk(45)))),
    // 代码块：等宽 + 内外两层内边距，几何抽在组件同文件（预算器复用它）。
    ('代码块·空（占位一行）', codeBlockNode(delta: Delta())),
    ('代码块·1行', codeBlockNode(delta: Delta()..insert('void main() {}'))),
    (
      '代码块·2行',
      codeBlockNode(delta: Delta()..insert('final a = 1;\nprint(a);')),
    ),
    (
      '代码块·8行',
      codeBlockNode(
        delta: Delta()
          ..insert(
            <String>[
              'import "package:flutter/material.dart";',
              '',
              'void main() {',
              '  final result = compute();',
              '  if (result > 0) {',
              '    print(result);',
              '  }',
              '}',
            ].join('\n'),
          ),
      ),
    ),
    (
      '代码块·长行折行',
      codeBlockNode(
        delta: Delta()
          ..insert(
            'final value = someVeryLongFunctionName(argumentOne, argumentTwo, '
            'argumentThree, argumentFour, argumentFive);',
          ),
      ),
    ),
    // 图片：节点里存了高度 ⇒ 官方 `SizedBox(height:)` 直接决定块高。
    (
      '图片·带高度(200)',
      imageNode(url: 'https://example.com/a.png', width: 300, height: 200),
    ),
    // 表格**不在这里**：它的高度只能"近似"（见下面单独那条 + 预算器的说明）。
    ('段落·加粗', paragraphNode(delta: _rich(<(String, Attributes?)>[
      ('加粗片段', <String, dynamic>{'bold': true}),
      ('普通片段', null),
    ]))),
    ('段落·斜体', paragraphNode(delta: _rich(<(String, Attributes?)>[
      ('斜体片段', <String, dynamic>{'italic': true}),
      ('普通片段', null),
    ]))),
    ('段落·行内代码', paragraphNode(delta: _rich(<(String, Attributes?)>[
      ('code_span()', <String, dynamic>{'code': true}),
      ('和普通文字', null),
    ]))),
    ('段落·链接', paragraphNode(delta: _rich(<(String, Attributes?)>[
      ('链接文字', <String, dynamic>{'href': 'https://example.com'}),
      ('后续文字', null),
    ]))),
    ('段落·混排3行', paragraphNode(delta: _rich(<(String, Attributes?)>[
      (cjk(30), <String, dynamic>{'bold': true}),
      (cjk(30), <String, dynamic>{'code': true}),
      (cjk(30), null),
    ]))),
    ('标题h1·加粗2行', headingNode(
      level: 1,
      delta: _rich(<(String, Attributes?)>[
        (cjk(25), <String, dynamic>{'bold': true}),
        (cjk(25), null),
      ]),
    )),
  ];
}

/// 按 (文本, 属性) 拼一个 Delta。
Delta _rich(List<(String, Attributes?)> inserts) {
  final Delta delta = Delta();
  for (final (String text, Attributes? attributes) in inserts) {
    delta.insert(text, attributes: attributes);
  }
  return delta;
}

// ─────────────────────────── 脚手架 ───────────────────────────

/// 与生产同一份列宽（默认为 `AppSettings.widthMode = standard` ⇒ 720）。
final double _contentWidth = const AppSettings().contentWidth;

/// 打印真实字体是否生效：测试字体（Flutter 的 `FlutterTest`）把**每个**字符
/// 都画成 1em 方格，所以「i 与 M 同宽」就说明真实字体没加载 ✓（真实字体的
/// 拉丁是比例的）。CJK 在两种字体下都是 1em，**单看中文测不出这个**。
void _reportFontInUse(EditorTypography typography) {
  double width(String text) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: typography.body()),
      textDirection: TextDirection.ltr,
    )..layout();
    final double w = painter.width;
    painter.dispose();
    return w;
  }

  final double i = width('iiii');
  final double m = width('MMMM');
  final double cjk = width('汉' * 4);
  // ignore: avoid_print
  print(
    '[字体] ${AppTheme.editorFont}：iiii=${i.toStringAsFixed(1)} '
    'MMMM=${m.toStringAsFixed(1)} 汉汉汉汉=${cjk.toStringAsFixed(1)} '
    '（真实字体加载成功 ⇒ 前两者不同；相同 ⇒ 还在用测试字体）',
  );
  expect(
    i,
    isNot(m),
    reason:
        '真实字体（${AppTheme.editorFont}）没有生效：任意字符都成了 1em 方格，'
        '说明走的还是 Flutter 测试字体——那样测出的精度不能外推到生产',
  );
}

Future<void> _pumpEditor(
  WidgetTester tester, {
  required List<Node> children,
  required EditorTypography typography,
  required TextStyleConfiguration textStyleConfiguration,
  required double textScaleFactor,
  required ThemeData theme,
  required void Function(String nodeId, double height) onMeasured,
}) async {
  final EditorState state = EditorState(
    document: Document(root: pageNode(children: children)),
  );
  final EditorScrollController scroll = EditorScrollController(
    editorState: state,
  );
  addTearDown(() {
    scroll.dispose();
    state.dispose();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        ...GlobalMaterialLocalizations.delegates,
        AppFlowyEditorLocalizations.delegate,
      ],
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      builder: (BuildContext context, Widget? child) =>
          // ignore: deprecated_member_use
          MaterialUiCompatibilityBridge(child: child!),
      home: Scaffold(
        body: AppFlowyEditor(
          editorState: state,
          editorScrollController: scroll,
          editorStyle: EditorStyle.desktop(
            // 与生产同一来源（**按块**生效的内边距）。
            padding: EditorTypography.blockPadding,
            maxWidth: _contentWidth,
            textStyleConfiguration: textStyleConfiguration,
            // 生产是 `MediaQuery.textScalerOf(context).scale(1.0)`。
            textScaleFactor: textScaleFactor,
          ),
          blockComponentBuilders: sinanBlockComponentBuilders(
            typography: typography,
            markerColor: theme.colorScheme.primary,
          ),
          // 生产就是在这里挂的（`_flashWrapper` 里的 `BlockHeightProbe`）。
          blockWrapper:
              (BuildContext context, {required Node node, required Widget child}) =>
                  BlockHeightProbe(
                    nodeId: node.id,
                    onMeasured: onMeasured,
                    child: child,
                  ),
          characterShortcutEvents: const <CharacterShortcutEvent>[],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
