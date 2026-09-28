import 'package:flutter_math_fork/flutter_math.dart' as math;
import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

// 公式的**渲染 + 编辑对话框**：quill 的 EmbedBuilder 与 appflowy 的块组件
// 共用（同 AttachmentMeta 的抽取动机——迁移期两份实现必然漂移）。
//
// 本文件不依赖任何编辑器库：调用方负责"改文档"（quill 用
// controller.replaceText，appflowy 用 editorState.transaction）。

/// 渲染 LaTeX：`textStyle` 决定字号与颜色（调用方传入正文/块样式）。
///
/// **双重兜底**：flutter_math_fork 声明的错误类型是 FlutterMathException
/// （onErrorFallback 可拦），但其解析器遇到残缺输入（孤立的 `^`、`=` 等）
/// 会抛**原生 FormatException**——不是 FlutterMathException 的子类，直接
/// 逃逸会崩渲染。外层再包 try/catch 兜住一切异常，回退为等宽错误色源码。
Widget renderFormula(BuildContext context, String latex, TextStyle? textStyle) {
  Widget onErrorFallback(math.FlutterMathException error) => Text(
    latex,
    style: TextStyle(
      fontFamily: AppTheme.monoFont,
      fontFamilyFallback: AppTheme.monoFallback,
      fontSize: 13,
      color: Theme.of(context).colorScheme.error,
    ),
  );
  try {
    return math.Math.tex(
      latex,
      textStyle: textStyle,
      onErrorFallback: onErrorFallback,
    );
  } on Object catch (_) {
    return onErrorFallback(const _FormulaParseError());
  }
}

/// 打开公式编辑对话框；确定返回 LaTeX 源，取消返回 null。
Future<String?> showFormulaDialog(
  BuildContext context, {
  String initial = '',
}) => showDialog<String>(
  context: context,
  builder: (BuildContext dialogContext) => _FormulaDialog(initial: initial),
);

/// 渲染兜底用的解析异常占位（FlutterMathException 是抽象类，需最小实现）。
class _FormulaParseError implements math.FlutterMathException {
  const _FormulaParseError();

  @override
  String get message => '解析失败';

  @override
  String get messageWithType => 'FormatException: $message';
}

/// 公式输入对话框：LaTeX 源码多行输入 + 下方实时预览。
class _FormulaDialog extends StatefulWidget {
  const _FormulaDialog({required this.initial});

  final String initial;

  @override
  State<_FormulaDialog> createState() => _FormulaDialogState();
}

class _FormulaDialogState extends State<_FormulaDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return AlertDialog(
      title: Text(widget.initial.isEmpty ? '插入公式' : '编辑公式'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .stretch,
          children: <Widget>[
            TextField(
              controller: _controller,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              style: const TextStyle(
                fontFamily: AppTheme.monoFont,
                fontFamilyFallback: AppTheme.monoFallback,
                fontSize: 13,
              ),
              decoration: const InputDecoration(
                hintText: r'\frac{a}{b} + \sqrt{c}',
                labelText: 'LaTeX',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Tokens.spaceMd),
            // 实时预览：输入即渲染；预览区固定高度避免拖动时抖动。
            Container(
              height: 72,
              padding: const EdgeInsets.all(Tokens.spaceMd),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(Tokens.radiusSm),
                border: Border.all(color: scheme.outlineVariant),
              ),
              alignment: Alignment.center,
              child: SingleChildScrollView(
                child: _controller.text.isEmpty
                    ? Text(
                        '预览',
                        style: text.bodySmall?.copyWith(
                          color: AppTheme.hintColor(scheme.onSurface),
                        ),
                      )
                    : renderFormula(context, _controller.text, text.bodyLarge),
              ),
            ),
            const SizedBox(height: Tokens.spaceXs),
            Text(
              '支持 KaTeX 语法，双击公式可再次编辑',
              style: text.bodySmall?.copyWith(
                color: AppTheme.hintColor(scheme.onSurface),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final String latex = _controller.text.trim();
            if (latex.isEmpty) return;
            Navigator.of(context).pop(latex);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
