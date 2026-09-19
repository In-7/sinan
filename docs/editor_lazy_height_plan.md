# 编辑器首帧块高：懒预测（延后升级方案）

状态：**DEFERRED（未实现，按需启用）**。2026-09-19 立项记录，当前编辑器走精确模式即可，无需此变更。

## 一、结论

超大文档（几千块以上）的首帧冷启动，可把"全量同步预测"改为"**首屏 K 块精确 + 其余用 `BlockHeights` 类型默认估计 + 帧末异步补全 + 批量锚定**"。

**当前（典型笔记）不需要做**：预测器成本 `TextPainter` 干跑 300 块 ≈ 7ms（`note_editor_view_appflowy.dart:263`），冷启动总时实测 1.18s（其中 897ms / 76% 发生在 `runApp` 之前，`main.dart`）。典型笔记几百块时预测遍历占冷启动 <2%，优化的是错的瓶颈；且引入的状态机复杂度换不来可感知收益。

**仅在**出现几千块以上的导入长文/书类文档、且实测首帧因块高计算变慢时，才按本方案升级，且只在大文档分支启用。

## 二、现状核实（已读代码确认）

`lib/src/notes/note_editor_view_appflowy.dart`：

- 首帧走**同步全量重建**：`_rebuildItemExtents` 逐块调 `_blockHeights.heightOf`（`:1096-1111`）；冷启动 `measuredCount==0` 时该重建**同步塞进第一帧**（`:997-1000`）。
- 预测器成本模型：`TextPainter` 干跑一次布局，文字块逐像素（spike 实测 0.0px，`block_height_predictor.dart:33`）。
- **锚定闭环已存在**：`_adjustScrollForExtentChange`（`:1125-1131`）在上方块高度变化时把滚动偏移同步 `+= delta`，顶部块钉在原处；官方 `scrollable_positioned_list` 无此能力。
- **回填已存在**：`_onBlockMeasured`（`:1137-1149`）逐块实测后 O(1) 增量喂回；`_prefetchImageRatios`（`:1027-1074`）在图片解码前先读头拿宽高比，滚动器拿真高度而非等解码。
- **类型默认估计已存在**：`BlockHeights` 本身就是"实测高度 + 按块类型的默认估计"（`:241`），预测器对公式/附件返回 `null` 时"退回按一行估"——即现成的"便宜估计"来源，免 `TextPainter`。
- **异步守卫已存在**：`_extentsGeneration`（`:279`）在 `_rebuildItemExtents`（`:1091`）+1、`_prefetchImageRatios`（`:1057`）用 `if (generation != _extentsGeneration) return` 判过期。帧末补全复用同一守卫即可。
- **无滚动位置还原**：全文件搜 `initialScrollIndex / scrollToIndex / restoreScroll / initialScrollOffset` 仅命中无关项 → 编辑器打开即在顶部（offset 0），第一屏固定是 `index 0`。未来若加滚动还原，首屏窗口判定需改判"还原位置附近"，非恒为 0。

## 三、安全变体设计（落地步骤）

1. **首帧**：前 `K` 块（K 超过一屏块数，建议 60）仍走精确预测器（~1.5ms）；`K` 之后的块用 `BlockHeights` 类型默认（纯查表，免 `TextPainter`）填 `_itemExtents`。→ 挡掉风险 A。
2. **帧末**：`WidgetsBinding.instance.addPostFrameCallback` 里对 `K` 之后的块用预测器补全，复用 `_extentsGeneration` 守卫（同 `_prefetchImageRatios` 模式）。→ 挡掉风险 C。
3. **批量锚定**：帧末补全算一次 `topIndex` 之上所有块的累计 `delta`，**只 `jumpTo` 一次**（勿逐块调 `_adjustScrollForExtentChange`）。→ 挡掉风险 D。
4. **只在大文档分支启用**：以块数阈值（如 > 1000）或首帧预算耗时探测决定是否走懒路径，典型笔记继续走现有同步精确路径。

## 四、风险评估

| 风险 | 说明 | 缓解 |
|---|---|---|
| A 首屏内容跳 | 锚定补丁在 `changedIndex >= topIndex` 早退（`:1129`）；打开在顶部时第一屏变化不纠偏 → 帧末补全会位移首屏 | 首屏前 K 块首帧即精确（步骤 1） |
| B 滚动条滑块动一次 | K 之后块补全改总高，视口下方不牵内容但滑块长度/位置更新一次 | 不可避免代价，仅动滑块不动内容，仅超大文档可见；属可接受的权衡 |
| C 重入/双重重建 | 布局变化会重入 `_syncBlockHeights` | `_extentsGeneration` 守卫（现状已验证安全） |
| D 锚定需批量 | `_onBlockMeasured` 逐块跳，几百次补全会几百次 `jumpTo` | 帧末算累计 delta 只跳一次（步骤 3） |

**性质**：方案非"零风险"，四类风险全部可缓解；B 是延迟全量预测的固有代价（只动滑块），典型笔记无所谓。

## 五、不在本次范围

- 不切换成"盲平均估计"：那是退化——会丢失当前锁定的"滚动条从第一帧就精确不跳"，且 sinan 预测器是逐像素级、远准于网页盲平均。
- 不改为普通 `ListView`：当前 `ScrollablePositionedList` + 补丁 10 的逐块高度 + 锚定闭环已满足，迁移无收益。
