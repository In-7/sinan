import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart';

import 'block_height_predictor.dart';
import 'editor_typography.dart';

/// **块高表**：`块 id → 高度`（px），把「块」换算成「像素」。
///
/// ## 为什么要它（2026-09-14）
/// 官方正文列表（`ScrollablePositionedList`，**锚点制**）把"可见内容的位置"
/// 挂在"锚点上方那堆块的**估计高度**"上 ⇒ 估计被修正一次，整段内容就位移一次，
/// 表现为用户报的"滚动手感和速度变一下"。
///
/// 普通 `ListView.builder` 没有这个毛病（可见内容由像素偏移决定，估计只影响
/// "能滚多远"），代价是**索引跳转不再白送**——`ListView` 没有"跳到第 N 项"
/// 的 API，于是需要本表把「块」换算成「像素」：
/// - 目录跳转：`块 id → index → offsetOf` ⇒ `ScrollController.animateTo`；
/// - 当前章节：`offsetOf → indexAt/visibleRange`；
/// - 落点高亮、查找滚动同理。
///
/// ## 取值链：实测 → 预算 → 按一行估
/// 1. **实测**（[measure]）：块只要被布局过就量真值 ⇒ 精度随浏览历史自动变好；
/// 2. **预算**（[predictor]）：文字块用 `TextPainter` 干跑一次布局，**逐像素
///    等于真实高度**（84 个块的实测：偏差 0.0px，见
///    `test/block_height_predictor_spike_test.dart`）⇒ 没见过的块也有真值级精度；
/// 3. **按一行估**（[EditorTypography.estimatedBlockHeight]）：兜底。如今只剩
///    **公式 / 表格 / 附件**走这里（数学排版、表格结构、卡片内部几何，复刻不划算）；
///    它们的真值等布局后由实测替换。代码块与图片（节点带 `height` 时）已由预算器覆盖。
///
/// ⚠️ **本表不参与滚动器的总高估计**（那仍是官方 `SliverList` 的事）。它只
/// 服务我们自己的"块 ↔ 像素"换算，因此**表不准不会影响虚拟化与滚动本身**。
class BlockHeights extends ChangeNotifier {
  final Map<String, double> _measured = <String, double>{};

  /// 文字块的**预算高度**（见 `block_height_predictor.dart`）。
  ///
  /// 由视图在 build 里按当前排版参数重建：字号 / 列宽 / 文字缩放一变，预测器
  /// 必须跟着换，否则兜底值吃的是**旧参数**（而清表只清实测值，换不掉它）。
  /// 为 null 时退回 [EditorTypography.estimatedBlockHeight]（"按一行估"）。
  BlockHeightPredictor? predictor;

  /// 已实测的块数（测试与诊断用）。
  int get measuredCount => _measured.length;

  /// 记录一次实测高度。
  ///
  /// 只在值**真的变化**时通知：块被构建后每帧都会回调一次，逐帧通知会把
  /// 订阅方（将来的滚动换算）拖进无谓重建。
  void measure(String nodeId, double height) {
    if (nodeId.isEmpty || !height.isFinite || height <= 0) return;
    // 吸附整像素：与 `EditorTypography` 的整像素口径一致，避免 0.3px 级别的
    // 抖动被当成"变了"而反复通知。
    //
    // 实测证明这条吸附**不欠债**：所有块高本来就落在整像素上（行盒吸附整像素
    // + 内边距是整数，见 spike 的"整篇 1695.0 → 吸附后 1695.0，累计偏差 0.0px"）。
    final double value = height.roundToDouble();
    if (_measured[nodeId] == value) return;
    _measured[nodeId] = value;
    notifyListeners();
  }

  /// 实测高度（没量过返回 null）。
  double? measured(String nodeId) => _measured[nodeId];

  /// 该块的高度：**实测优先，其次预算，最后按一行估**（见类文档的取值链）。
  ///
  /// [availableWidth] 是内容列的可用宽度（窗口宽减去目录面板等）。不知道时传
  /// `double.infinity`（按 `EditorStyle.maxWidth` 上限算）——**窄窗口下会偏**
  /// （列比上限窄 ⇒ 折行更多 ⇒ 真实更高），但实测一旦补上就自动纠正。
  double heightOf(
    Node node,
    EditorTypography typography, {
    double availableWidth = double.infinity,
  }) =>
      _measured[node.id] ??
      predictor?.predict(node, availableWidth: availableWidth) ??
      typography.estimatedBlockHeight(node);

  /// 整篇的高度序列（按 [nodes] 顺序）——"块 ↔ 像素"换算的输入。
  ///
  /// 顺序即滚动顺序，故 `blockOffsetOf(heightsOf(...), index)` 就是第 index 块
  /// 的顶部像素偏移。
  List<double> heightsOf(
    Iterable<Node> nodes,
    EditorTypography typography, {
    double availableWidth = double.infinity,
  }) => <double>[
    for (final Node node in nodes)
      heightOf(node, typography, availableWidth: availableWidth),
  ];

  /// 整表作废：列宽 / 字号 / 行高 / 系统文字缩放 / 排版常量变化，以及换笔记时调用。
  ///
  /// ⚠️ 漏调用比"表里没有值"更糟（会留下**过期的高度**，换算长期偏），
  /// 故调用方按"排版参数指纹"统一判变（见 `note_editor_view_appflowy.dart`）。
  void clear() {
    if (_measured.isEmpty) return;
    _measured.clear();
    notifyListeners();
  }
}

/// 逐块实测高度的探针——挂在官方的 `AppFlowyEditor.blockWrapper` 上。
///
/// 每帧后读一次自己的渲染盒高度，变化才写回 [onMeasured]（见 [BlockHeights.measure]）。
///
/// 为什么"构建即测量"够用：块只有被构建（进入视口/缓存区）才有渲染盒，而它一旦
/// 被构建就必然经过一次布局 ⇒ post-frame 读一次就是真值；没构建过的块由默认估计
/// 兜底，等用户滚到那儿自然会被量到。
class BlockHeightProbe extends StatefulWidget {
  const BlockHeightProbe({
    super.key,
    required this.nodeId,
    required this.onMeasured,
    required this.child,
  });

  /// 块 id（表按 id 存：块被移动/重排不影响命中，删除只留无害的悬空条目）。
  final String nodeId;

  final void Function(String nodeId, double height) onMeasured;

  final Widget child;

  @override
  State<BlockHeightProbe> createState() => _BlockHeightProbeState();
}

class _BlockHeightProbeState extends State<BlockHeightProbe> {
  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(BlockHeightProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 块内容变了会重建本探针 ⇒ 再量一次（文字增删、切成标题、图片解码完成等）。
    _scheduleMeasure();
  }

  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 用 findRenderObject 而不是 `context.size`：本 widget 自身没有
      // RenderObject（build 直接返回 child），这里要的是**子树的**那个盒子，
      // 即块自身的高度（列表项只额外加了水平 padding，纵向高度一致）。
      final RenderObject? renderObject = context.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) return;
      widget.onMeasured(widget.nodeId, renderObject.size.height);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// ─────────────────── 块 ↔ 像素 换算（纯函数，与滚动器无关） ───────────────────
//
// 全部只依赖"块高列表"，因此可以在没有 UI 的测试里直接验证边界行为。

/// 第 [index] 块**顶部**的像素偏移 = 前面所有块高度之和。
///
/// [index] 越界时钳制（≤0 → 0；≥长度 → 总和）。
double blockOffsetOf(List<double> heights, int index) {
  if (index <= 0 || heights.isEmpty) return 0;
  final int end = index < heights.length ? index : heights.length;
  double sum = 0;
  for (int i = 0; i < end; i++) {
    sum += heights[i];
  }
  return sum;
}

/// 像素偏移 [offset] 落在第几块。
///
/// 块数级别（几百）的线性扫描即可——每次滚动帧一次，几百次加法可以忽略；
/// 换成前缀和+二分会引入额外的缓存失效面，不值得。
/// [offset] 越界时钳到 `[0, heights.length - 1]`；空表返回 0（调用方判空）。
int blockIndexAtOffset(List<double> heights, double offset) {
  if (heights.isEmpty) return 0;
  if (offset <= 0) return 0;
  double acc = 0;
  for (int i = 0; i < heights.length; i++) {
    acc += heights[i];
    if (offset < acc) return i;
  }
  return heights.length - 1;
}

/// 视口（顶部 [offset]、高度 [viewport]）覆盖的块区间（**闭区间**）。
///
/// 空表返回 `(0, -1)`——调用方据此判"没有内容"，不要用长度判断。
(int, int) blockVisibleRangeOf(
  List<double> heights,
  double offset,
  double viewport,
) {
  if (heights.isEmpty) return (0, -1);
  // 视口底部减 1：正好落在块边界上时，下一块只是"贴着底边"，不算可见。
  final double bottom = offset + (viewport > 1 ? viewport - 1 : 0);
  return (
    blockIndexAtOffset(heights, offset),
    blockIndexAtOffset(heights, bottom),
  );
}
