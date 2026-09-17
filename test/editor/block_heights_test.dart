import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sinan/src/editor/core/block_height_predictor.dart';
import 'package:sinan/src/editor/core/block_heights.dart';
import 'package:sinan/src/editor/blocks/code_block_component.dart';
import 'package:sinan/src/editor/blocks/formula_block_component.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';

/// **块高表 + 块↔像素换算**（见 `block_heights.dart`）。
///
/// 这层是"普通 `ListView` 下把块换算成像素"的唯一依据（目录跳转 / 当前章节
/// / 落点），所以边界行为必须钉死：越界钳制、空表、边界落在哪一块。
///
/// 排版用一个好算的组合：**16px / 1.5 行高**
/// ⇒ 正文行盒 = snap(16×1.5) = **24**；h1 = snap(16×1.75) = 28
/// ⇒ 标题行盒 = snap(28×1.4) = **39**，上间距 = snap(16×2.0) = **32**。
const EditorTypography _typography = EditorTypography(
  fontSize: 16,
  lineHeight: 1.5,
);

/// 预算器（`TextPainter` 干跑布局）。精度与它 vs 真实渲染的逐块对比见
/// `test/block_height_predictor_spike_test.dart`（84 个块偏差 0.0px）。
BlockHeightPredictor _predictor({
  double maxWidth = 720,
  double? Function(String src)? imageAspectRatioOf,
}) => BlockHeightPredictor(
  typography: _typography,
  // 必须与编辑器同一份配置：行内加粗 / 斜体 / 等宽 / 链接都会改行盒。
  textStyleConfiguration: _typography.toTextStyleConfiguration(
    text: const Color(0xFF000000),
    link: const Color(0xFF1565C0),
    codeBackground: const Color(0xFFEEEEEE),
    muted: const Color(0xFF757575),
  ),
  maxWidth: maxWidth,
  blockPadding: EditorTypography.blockPadding,
  imageAspectRatioOf: imageAspectRatioOf,
);

void main() {
  // 预算走 `TextPainter`：没有绑定就没有测试字体。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('默认块高估计（按排版参数算，只按一行估）', () {
    test('段落 = 正文行盒 + 块上下内边距(8)', () {
      expect(_typography.estimatedBlockHeight(paragraphNode(text: '正文')), 32);
    });

    test('标题 = 标题行盒 + headingPadding（上间距 / 下 4）；首块不给上间距', () {
      final Node first = headingNode(level: 1, text: '首块标题');
      // 39 + 0（首块不给上间距）+ 4（下边距）
      expect(_typography.estimatedBlockHeight(first), 43);

      // 放进文档里 ⇒ 有 previous ⇒ 吃上间距（h1 = 2.0em = 32）。
      final Document document = Document(
        root: pageNode(
          children: <Node>[paragraphNode(text: '前言'), headingNode(level: 1, text: '第一章')],
        ),
      );
      final Node heading = document.root.children[1];
      expect(heading.previous, isNotNull);
      // 39 + 32 + 4——**下边距只有 4**，不是"上下各 4"的 8（那会每档多算 4px，
      // 是 2026-09-14 预算器 vs 真实渲染的对比抓出来的）。
      expect(_typography.estimatedBlockHeight(heading), 75);
    });

    test('标题档位越高，估计越高（h1 > h2 > h3）', () {
      final Document document = Document(
        root: pageNode(
          children: <Node>[
            paragraphNode(text: '前言'),
            headingNode(level: 1, text: '一'),
            headingNode(level: 2, text: '二'),
            headingNode(level: 3, text: '三'),
          ],
        ),
      );
      final List<double> heights = <double>[
        for (final Node node in document.root.children.skip(1))
          _typography.estimatedBlockHeight(node),
      ];
      expect(heights[0], greaterThan(heights[1]));
      expect(heights[1], greaterThan(heights[2]));
    });

    test('字号变大 ⇒ 估计跟着变大（不是写死的常数）', () {
      const EditorTypography bigger = EditorTypography(
        fontSize: 20,
        lineHeight: 1.5,
      );
      expect(
        bigger.estimatedBlockHeight(paragraphNode(text: '正文')),
        greaterThan(_typography.estimatedBlockHeight(paragraphNode(text: '正文'))),
      );
    });
  });

  group('BlockHeights：实测优先、默认兜底', () {
    test('没有实测值时用默认估计', () {
      final BlockHeights heights = BlockHeights();
      addTearDown(heights.dispose);
      final Node node = paragraphNode(text: '正文');
      expect(heights.heightOf(node, _typography), 32);
      expect(heights.measuredCount, 0);
    });

    test('实测值覆盖默认值，并且只在真的变化时通知', () {
      final BlockHeights heights = BlockHeights();
      addTearDown(heights.dispose);
      final Node node = paragraphNode(text: '正文');

      int notified = 0;
      heights.addListener(() => notified++);

      heights.measure(node.id, 120.4);
      expect(heights.heightOf(node, _typography), 120); // 吸附整像素
      expect(notified, 1);

      heights.measure(node.id, 120.2); // 吸附后相同 ⇒ 不通知
      expect(notified, 1);

      heights.measure(node.id, 96);
      expect(heights.heightOf(node, _typography), 96);
      expect(notified, 2);
    });

    test('非法输入直接忽略（0 / 负数 / NaN / 空 id）', () {
      final BlockHeights heights = BlockHeights();
      addTearDown(heights.dispose);
      heights.measure('', 100);
      heights.measure('n1', 0);
      heights.measure('n1', -5);
      heights.measure('n1', double.nan);
      expect(heights.measuredCount, 0);
      expect(heights.measured('n1'), isNull);
    });

    test('clear 清空并通知；空表时 clear 不通知', () {
      final BlockHeights heights = BlockHeights();
      addTearDown(heights.dispose);
      int notified = 0;
      heights.addListener(() => notified++);

      heights.clear(); // 空表
      expect(notified, 0);

      heights.measure('n1', 40);
      heights.clear();
      expect(heights.measuredCount, 0);
      expect(notified, 2); // measure 一次 + clear 一次
    });
  });

  group('文字块预算：取值链 实测 → 预算 → 按一行估', () {
    test('多行段落不再按"一行"低估（预算落在行盒整数倍上）', () {
      final BlockHeights heights = BlockHeights()..predictor = _predictor();
      addTearDown(heights.dispose);

      // 单行：预算与"按一行估"一致（行盒 24 + 块内边距 8）。
      expect(heights.heightOf(paragraphNode(text: '正文'), _typography), 32);

      // 多行：预算按**行数**给（24 × n + 8），不再是常数 32。
      final double long = heights.heightOf(
        paragraphNode(text: '汉' * 100),
        _typography,
      );
      expect(long, greaterThan(64), reason: '长段落显然不止一行');
      expect((long - 8) % 24, 0, reason: '预算必须落在行盒的整数倍上（多一行 = +24）');
    });

    test('列被挤窄 ⇒ 预算变高（availableWidth 真的参与计算）', () {
      final BlockHeights heights = BlockHeights()..predictor = _predictor();
      addTearDown(heights.dispose);
      final Node node = paragraphNode(text: '汉' * 100);

      final double wide = heights.heightOf(node, _typography);
      final double narrow = heights.heightOf(
        node,
        _typography,
        availableWidth: 300,
      );
      expect(
        narrow,
        greaterThan(wide),
        reason: '列窄 ⇒ 折行更多 ⇒ 块更高；不传 availableWidth 会退回"按上限算"',
      );
    });

    test('标题：预算含档位字号、标题行高与上间距', () {
      final BlockHeights heights = BlockHeights()..predictor = _predictor();
      addTearDown(heights.dispose);

      // 放进文档 ⇒ 有 previous ⇒ 吃 h1 上间距 32；下边距 4。
      // 单行 h1 = 行盒 39 + 上间距 32 + 下边距 4 = 75（与 estimatedBlockHeight 一致）。
      final Document one = Document(
        root: pageNode(
          children: <Node>[
            paragraphNode(text: '前言'),
            headingNode(level: 1, text: '第一章'),
          ],
        ),
      );
      expect(heights.heightOf(one.root.children[1], _typography), 75);

      // 多行 h1：多出来的部分按**标题**行盒（39，不是正文的 24）累加。
      final Document many = Document(
        root: pageNode(
          children: <Node>[
            paragraphNode(text: '前言'),
            headingNode(level: 1, text: '汉' * 100),
          ],
        ),
      );
      final double predicted = heights.heightOf(
        many.root.children[1],
        _typography,
      );
      expect(predicted, greaterThan(75));
      expect(
        (predicted - 36) % 39,
        0,
        reason: '预算必须落在**标题**行盒的整数倍上'
            '（h1 = 39，不是正文的 24；36 = 上间距 32 + 下边距 4）',
      );
    });

    test('分隔线：预算给出官方真实几何（"按一行估"在这块是错的）', () {
      final BlockHeights heights = BlockHeights()..predictor = _predictor();
      addTearDown(heights.dispose);
      final Node divider = dividerNode();

      // 官方标准注册表给分隔线单独配了上下各 8 的内边距（不是默认的各 4），
      // 加上线高 10 ⇒ 26；"按一行估"给的是正文行盒 + 8 = 32。
      expect(heights.heightOf(divider, _typography), 26);
      expect(_typography.estimatedBlockHeight(divider), 32);
    });

    test('图片：节点带 height 时精确；否则取官方"未解码"态高度', () {
      final BlockHeights heights = BlockHeights()..predictor = _predictor();
      addTearDown(heights.dispose);

      // 带高度：节点里的 height + 官方默认的上下各 4 内边距。
      expect(
        heights.heightOf(
          imageNode(url: 'a.png', width: 300, height: 200),
          _typography,
        ),
        208,
      );
      // 没带高度 = 图片还没解码（官方 `SizedBox(height: 150)`）⇒ 158。
      // 比"按一行估"（32）准得多：打开笔记那一刻总高就是对的。
      final Node unsized = imageNode(url: 'a.png');
      expect(heights.heightOf(unsized, _typography), 158);
      expect(_typography.estimatedBlockHeight(unsized), 32);
    });

    test('图片：没存 height 但有宽高比 ⇒ 按比例算（不是"加载中"高度）', () {
      // 4:3 的图（高/宽 = 0.75）。
      // 列宽 720 − 块水平内边距 32 − **块手柄 48** ⇒ 文字区 640
      // ⇒ 640 × 0.75 = 480，+ 块上下内边距 8 = 488。
      // （手柄那条 48 见 `EditorTypography.blockHandleWidth`：动作槽常驻
      //  占位，图片同样被它让掉一段宽度。）
      final BlockHeights heights = BlockHeights()
        ..predictor = _predictor(imageAspectRatioOf: (String src) => 0.75);
      addTearDown(heights.dispose);

      expect(heights.heightOf(imageNode(url: 'a.png'), _typography), 488);
      // 图片自带 width 时以它为准（小者优先）。
      expect(
        heights.heightOf(
          imageNode(url: 'a.png', width: 200),
          _typography,
        ),
        200 * 0.75 + 8,
      );
    });

    test('代码块：等宽文字 + 内外两层内边距（不再退回"按一行估"）', () {
      final BlockHeights heights = BlockHeights()..predictor = _predictor();
      addTearDown(heights.dispose);

      final double one = heights.heightOf(
        codeBlockNode(delta: Delta()..insert('void main() {}')),
        _typography,
      );
      final double two = heights.heightOf(
        codeBlockNode(delta: Delta()..insert('a;\nb;')),
        _typography,
      );
      // 16px 正文下等宽字号 = 16 × 0.9 = 14.4、行盒倍数 1.5 ⇒ 每行约 21.6。
      expect(two - one, closeTo(14.4 * 1.5, 1.5));
      // 明显高于"按一行估"（正文行盒 + 8），因为多了内层容器的上下 16。
      expect(
        one,
        greaterThan(_typography.estimatedBlockHeight(paragraphNode(text: 'x'))),
      );
    });

    test('预算器不负责的块（公式）退回按一行估；实测始终压过预算', () {
      final BlockHeights heights = BlockHeights()..predictor = _predictor();
      addTearDown(heights.dispose);

      final Node formula = formulaBlockNode(latex: r'x^2 + y^2');
      expect(
        heights.heightOf(formula, _typography),
        _typography.estimatedBlockHeight(formula),
        reason: '公式高度取决于数学排版，预算器不猜',
      );

      final Node node = paragraphNode(text: '正文');
      heights.measure(node.id, 500);
      expect(heights.heightOf(node, _typography), 500);
    });

    test('heightsOf：整篇高度序列（顺序即滚动顺序）', () {
      final BlockHeights heights = BlockHeights()..predictor = _predictor();
      addTearDown(heights.dispose);

      final List<Node> children = <Node>[
        paragraphNode(text: '正文'),
        dividerNode(),
        paragraphNode(text: '汉' * 100),
      ];
      final List<double> list = heights.heightsOf(children, _typography);

      expect(list, hasLength(3));
      expect(list[0], 32);
      expect(list[1], 26);
      expect((list[2] - 8) % 24, 0);
      // 顺序即滚动顺序 ⇒ 直接能喂给纯函数换算。
      expect(blockOffsetOf(list, 2), list[0] + list[1]);
      expect(blockIndexAtOffset(list, list[0]), 1);
    });
  });

  group('块 ↔ 像素换算', () {
    // 四块：40 + 80 + 120 + 60 = 300
    final List<double> heights = <double>[40, 80, 120, 60];

    test('offsetOf：块顶偏移 = 前面块高之和（越界钳制）', () {
      expect(blockOffsetOf(heights, 0), 0);
      expect(blockOffsetOf(heights, 1), 40);
      expect(blockOffsetOf(heights, 3), 240);
      expect(blockOffsetOf(heights, 4), 300); // = 总和
      expect(blockOffsetOf(heights, 99), 300);
      expect(blockOffsetOf(heights, -3), 0);
      expect(blockOffsetOf(const <double>[], 2), 0);
    });

    test('indexAtOffset：落在哪一块（边界归下一块、越界钳制）', () {
      expect(blockIndexAtOffset(heights, 0), 0);
      expect(blockIndexAtOffset(heights, 39), 0);
      expect(blockIndexAtOffset(heights, 40), 1); // 正好是第 1 块顶
      expect(blockIndexAtOffset(heights, 119), 1);
      expect(blockIndexAtOffset(heights, 120), 2);
      expect(blockIndexAtOffset(heights, 299), 3);
      expect(blockIndexAtOffset(heights, 300), 3); // 末尾之外钳到末块
      expect(blockIndexAtOffset(heights, -10), 0);
      expect(blockIndexAtOffset(const <double>[], 50), 0);
    });

    test('visibleRange：视口覆盖的闭区间；空表给 (0, -1)', () {
      expect(blockVisibleRangeOf(const <double>[], 0, 400), (0, -1));
      // 视口 100 从 0 起：块0(40) + 块1(80) 的头部 ⇒ (0, 1)
      expect(blockVisibleRangeOf(heights, 0, 100), (0, 1));
      // 视口 1：只算当前块（底部减 1 的边界处理）
      expect(blockVisibleRangeOf(heights, 40, 1), (1, 1));
      // 从 100 起、视口 100 ⇒ 100~199：块1 尾 + 块2 头 ⇒ (1, 2)
      expect(blockVisibleRangeOf(heights, 100, 100), (1, 2));
      // 整篇一屏 ⇒ 全覆盖
      expect(blockVisibleRangeOf(heights, 0, 300), (0, 3));
    });
  });
}
