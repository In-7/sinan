import 'package:flutter_quill/flutter_quill.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'formula_render.dart';

/// 公式嵌入（type = "formula"）：data = LaTeX 源串。
///
/// **渲染与对话框已抽到 [renderFormula] / [showFormulaDialog]**
/// （与 appflowy 的 `FormulaBlockComponent` 共用，避免迁移期两份实现漂移）；
/// 本类只负责 quill 侧的接线。
///
/// 交互：
/// - 插入：「插入」菜单 → 对话框（LaTeX 实时预览）→ 确定；
/// - 编辑：**双击**公式重新打开对话框（预填源码），确定即替换。
class NoteFormulaEmbedBuilder extends EmbedBuilder {
  const NoteFormulaEmbedBuilder();

  /// embed 类型标识（Delta 里的 key）。
  static const String embedType = 'formula';

  @override
  String get key => embedType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final String latex = (embedContext.node.value.data as String?) ?? '';

    return GestureDetector(
      onDoubleTap: embedContext.readOnly
          ? null
          : () async {
              final String? next = await showFormulaDialog(
                context,
                initial: latex,
              );
              if (next == null || next == latex) return;
              embedContext.controller.replaceText(
                embedContext.node.documentOffset,
                1,
                BlockEmbed(embedType, next),
                TextSelection.collapsed(
                  offset: embedContext.node.documentOffset + 1,
                ),
              );
            },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceXxs),
          child: renderFormula(context, latex, embedContext.textStyle),
        ),
      ),
    );
  }
}

/// 公式 builder 的静态实例：编辑器 `embedBuilders` 注册用。
const NoteFormulaEmbedBuilder noteFormulaEmbedBuilder =
    NoteFormulaEmbedBuilder();
