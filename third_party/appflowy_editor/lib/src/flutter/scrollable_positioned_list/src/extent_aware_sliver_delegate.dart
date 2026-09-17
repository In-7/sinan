// **sinan 补丁**（非上游文件）：见 third_party/appflowy_editor/PATCHES.md
// 的「补丁 10 — 把精确块高喂给滚动器」。

import 'package:flutter/widgets.dart';

/// 逐 item 的**已知高度**来源（px）。index 与 `itemBuilder` 的 index 一致。
///
/// 返回 `null` 表示"这一项还不知道"——调用方对这种情况**一律退回官方行为**
/// （按已布局块的平均高度外推），不给一个看起来合理的错值。
typedef ItemExtentProvider = double? Function(int index);

/// [SliverChildBuilderDelegate] + **直接给出本段内容总长**。
///
/// ## 为什么需要它（2026-09-14）
/// 官方正文列表把文档切成三段 sliver（锚点前 / 锚点项 / 锚点后），每段都是
/// `SliverList` + `SliverChildBuilderDelegate`。Flutter 对"还没布局的块"一律
/// **外推**：`SliverChildBuilderDelegate.estimateMaxScrollOffset` 返回 null ⇒
/// `_extrapolateMaxScrollOffset` 用「**已布局块的平均高度 × 剩余块数**」
/// （`flutter/lib/src/widgets/sliver.dart`）。于是：
///
/// - 局部平均 ≠ 全篇平均时（三行标题 / 图片 / 代码块扎堆），总高被抬高 ⇒
///   锚点制的内容整体位移一次（用户手感"滚到中间像加速了一下"）；
/// - 滚到末尾时外推项消失、总高回落到真值 ⇒ **滚动条滑块变长**。
///
/// 本类把"猜测的平均值"换成"逐个 item 的已知高度"（实测优先、预算兜底；
/// 预算器对文字块的精度是**逐像素**的，见应用侧 `block_height_predictor.dart`），
/// 于是总高从第一帧起就接近真值。
///
/// ## 不变量
/// 返回值必须不小于本段**已布局**部分的长度：Flutter 在
/// `RenderSliverList.performLayout` 里有断言
/// （`estimatedMaxScrollOffset >= endScrollOffset - childScrollOffset(firstChild)`），
/// 且小于它会让 sliver 的 `scrollExtent` 小于实际内容（内容被裁）。
/// 高度被低估时（例如图片还没量到）由这里钳住。
///
/// `extentProvider` 为 null 时行为与上游 [SliverChildBuilderDelegate] **逐字相同**。
class ExtentAwareSliverChildBuilderDelegate extends SliverChildBuilderDelegate {
  // 与父类同形：`builder` 是**位置**参数（其余为命名参数），直接透传。
  ExtentAwareSliverChildBuilderDelegate(
    NullableIndexedWidgetBuilder builder, {
    super.childCount,
    super.addSemanticIndexes,
    super.addRepaintBoundaries,
    super.addAutomaticKeepAlives,
    super.findChildIndexCallback,
    required this.extentProvider,
    required this.firstItem,
    required this.endItem,
  }) : super(builder);

  /// 逐 item 的高度来源（全局 index）。null ⇒ 完全走官方外推。
  final ItemExtentProvider? extentProvider;

  /// 本段覆盖的 item 区间：`[firstItem, endItem)`（**全局** index）。
  ///
  /// ⚠️ 用全局区间而不是"本段的相对 index"：`PositionedList` 的**锚点前那段是
  /// 倒序构建的**（相对 index `i` → 全局 `positionedIndex - 1 - i`），相对 index
  /// 与全局 index 不成线性对应。求总长只关心"哪些 item"，故按全局区间最稳。
  final int firstItem;
  final int endItem;

  @override
  double? estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) {
    final ItemExtentProvider? provider = extentProvider;
    if (provider == null) {
      return super.estimateMaxScrollOffset(
        firstIndex,
        lastIndex,
        leadingScrollOffset,
        trailingScrollOffset,
      );
    }

    double sum = 0;
    for (int i = firstItem; i < endItem; i++) {
      final double? extent = provider(i);
      if (extent == null || !extent.isFinite || extent < 0) {
        // 只要有一项不知道 ⇒ **整段**退回官方外推：宁可少赚，不要给错。
        return super.estimateMaxScrollOffset(
          firstIndex,
          lastIndex,
          leadingScrollOffset,
          trailingScrollOffset,
        );
      }
      sum += extent;
    }

    final double laidOut = trailingScrollOffset - leadingScrollOffset;
    return sum < laidOut ? laidOut : sum;
  }
}
