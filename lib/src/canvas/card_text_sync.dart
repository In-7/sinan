/// 双链多视图（块可迁移 #5）里"**库里的文本该不该覆盖内存里那份**"的决策。
///
/// 抽成独立纯函数只有一个理由：这条规则短、但**极易写反**，而写反的两种后果
/// 都是静默吃数据 ——
/// - 判成"该覆盖"却其实是用户的输入 ⇒ 抹掉用户刚敲的字；
/// - 判成"不该覆盖"却其实是别人改的 ⇒ 把旧快照写回库，吃掉文档侧的修改。
///
/// ## 规则
/// 卡片文本的真身在 `blocks`，画布内存里那份只是**快照**；[baseline] 是"上次与库
/// 一致时"的文本（见 `CanvasNoteView._syncedCardTexts`）：
///
/// - `current == baseline`：内存这份**没被本地改过** ⇒ 与库不一致只能是**别人
///   改的**（文档侧编辑、另一个视图）⇒ 采纳 [latest]；
/// - `current != baseline`：本地**有未落盘的编辑** ⇒ 一律不采纳 —— 用户的输入
///   优先，等落盘时由 `CanvasStore._replaceCardBlocks` 写回真身。
///
/// 返回要写回内存的新文本；`null` = 保持不动。
String? pullCardText({
  required String current,
  required String? baseline,
  required String? latest,
}) {
  if (latest == null || latest == current) return null;
  if (baseline != current) return null;
  return latest;
}
