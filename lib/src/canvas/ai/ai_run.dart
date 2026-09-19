import 'dart:ui' show Rect;

import '../../ai/llm_client.dart';
import '../kernel/canvas_document.dart';
import '../kernel/canvas_item.dart';
import 'ai_action.dart';
import 'ai_apply.dart';
import 'ai_inventory.dart';
import 'ai_prompt.dart';
import 'ai_sanitize.dart';

/// 一次 AI 指令跑完的结果（供 UI 汇报）。
class AiRunOutcome {
  const AiRunOutcome({
    required this.applied,
    required this.created,
    required this.actions,
    required this.warnings,
  });

  /// 真正落地的动作条数。
  final int applied;

  /// 本批新建的元素（宿主据此选中它们，让用户"看见 AI 动了什么"）。
  final List<CanvasItem> created;

  /// 实际应用的动作。
  final List<AiAction> actions;

  /// 净化层丢弃的原因 + 应用期跳过的原因，合在一起给用户看（不静默）。
  final List<String> warnings;

  bool get isEmpty => applied == 0;
}

/// 跑完整链路：**上下文 → 模型 → 解析 → 净化 → 应用**。
///
/// ## 为什么抽成独立函数而不是写进 widget
/// 整条链路里除了 [LlmClient] 全是纯逻辑 ⇒ 传一个假 client 就能在测试里跑通
/// 全链路（见 `ai_run_test.dart`）。写进 widget 就只能靠端到端手点了。
///
/// ## 失败语义（两条，刻意不同）
/// - **后端问题**（[LlmUnavailableException] / [LlmResponseException]）**原样抛**：
///   只有宿主知道该怎么提示（"去设置里填模型名" / "Ollama 没启动"）。
/// - **解析不出来**：**自动修复重试一次** —— 把上一轮的坏输出原样回传给模型、
///   要求只输出 JSON。再失败就当"没听懂"（空结果），**不抛**：用户该看到的是
///   "这次没产生改动"，而不是一串技术异常。
Future<AiRunOutcome> runCanvasAi({
  required LlmClient llm,
  required CanvasDocument document,
  required Rect viewportWorld,
  required String instruction,
  required String? Function(String blockId) blockTextOf,
  Map<String, String> candidateBlocks = const <String, String>{},
  bool allowTextRewrite = false,
}) async {
  final String context = buildCanvasContext(
    document,
    viewportWorld: viewportWorld,
    candidateBlocks: candidateBlocks,
  );

  final String raw = await llm.complete(
    system: kAiSystemPrompt,
    user: '$context\n## 用户指令\n$instruction',
    schema: kAiActionSchema,
  );
  List<AiAction>? parsed = AiAction.parseReply(raw);

  if (parsed == null) {
    // 修复重试：把坏输出回传（比只说"你错了"有效得多——模型能看到自己错在哪）。
    final String repair = await llm.complete(
      system: kAiSystemPrompt,
      user:
          '你上一条回复无法解析成 JSON：\n${_clip(raw)}\n\n'
          '请**只**输出符合要求的 JSON 对象，不要任何解释文字。',
      schema: kAiActionSchema,
    );
    parsed = AiAction.parseReply(repair);
  }
  final List<AiAction> actions = parsed ?? const <AiAction>[];

  // 净化与应用的**同一份**快照：中途文档变了就会出现"净化时合法、应用时找不到"。
  final AiInventory inventory = AiInventory.of(
    document,
    viewportWorld: viewportWorld,
    // 白名单 = 我们主动喂给模型的那批候选块（它不能凭记忆编一个 id 出来）。
    blockIds: candidateBlocks.keys.toSet(),
  );
  final AiSanitizeResult sanitized = sanitizeAiActions(
    actions,
    inv: inventory,
    allowTextRewrite: allowTextRewrite,
  );
  final AiApplyResult applied = applyAiActions(
    document,
    sanitized.actions,
    viewportWorld: viewportWorld,
    blockTextOf: blockTextOf,
  );

  return AiRunOutcome(
    applied: applied.applied,
    created: applied.created,
    actions: sanitized.actions,
    warnings: <String>[...sanitized.warnings, ...applied.notes],
  );
}

String _clip(String s, {int max = 400}) =>
    s.length <= max ? s : '${s.substring(0, max)}…';
