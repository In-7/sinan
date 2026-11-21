import 'dart:ui' as ui;

/// 轻量 markdown 解析器（Phase 4）：支持粗体/斜体/行内代码/链接。
///
/// 设计目标：
/// - **零依赖**：不引第三方包，保持画布内核轻量
/// - **快速**：单遍扫描，无正则
/// - **安全**：只支持行内格式，不支持块级（标题/列表等）
///
/// 支持的语法：
/// - `**bold**` → 粗体
/// - `*italic*` 或 `_italic_` → 斜体
/// - `` `code` `` → 行内代码（等宽字体）
/// - `[text](url)` → 链接（蓝色 + 下划线）
///
/// 不支持（保持简单）：
/// - 标题（#）
/// - 列表（- / 1.）
/// - 代码块（```）
/// - 图片（![...](...)）
class RichTextParser {
  RichTextParser._();

  /// 解析 markdown 文本为 [ui.Paragraph]。
  ///
  /// [text] 原始文本（可能包含 markdown 标记）
  /// [style] 基础文本样式（颜色等）
  /// [width] 排版宽度
  static ui.Paragraph parse(
    String text,
    ui.TextStyle style,
    double width, {
    ui.ParagraphStyle? paragraphStyle,
  }) {
    final ui.ParagraphBuilder builder = ui.ParagraphBuilder(
      paragraphStyle ??
          ui.ParagraphStyle(
            height: 1.4,
            textAlign: ui.TextAlign.left,
          ),
    );

    _parseInline(builder, text, style);

    final ui.Paragraph paragraph = builder.build();
    paragraph.layout(ui.ParagraphConstraints(width: width));
    return paragraph;
  }

  /// 解析行内格式（粗体/斜体/代码/链接）。
  static void _parseInline(
    ui.ParagraphBuilder builder,
    String text,
    ui.TextStyle baseStyle,
  ) {
    int i = 0;
    final int n = text.length;

    while (i < n) {
      // 粗体：**text**
      if (i + 1 < n && text[i] == '*' && text[i + 1] == '*') {
        final int end = text.indexOf('**', i + 2);
        if (end != -1) {
          final String boldText = text.substring(i + 2, end);
          builder.pushStyle(
            ui.TextStyle(
              fontWeight: ui.FontWeight.bold,
            ),
          );
          builder.addText(boldText);
          builder.pop();
          i = end + 2;
          continue;
        }
      }

      // 斜体：*text* 或 _text_
      if (i < n && (text[i] == '*' || text[i] == '_')) {
        final String marker = text[i];
        final int end = text.indexOf(marker, i + 1);
        if (end != -1 && end > i + 1) {
          final String italicText = text.substring(i + 1, end);
          builder.pushStyle(
            ui.TextStyle(
              fontStyle: ui.FontStyle.italic,
            ),
          );
          builder.addText(italicText);
          builder.pop();
          i = end + 1;
          continue;
        }
      }

      // 行内代码：`text`
      if (text[i] == '`') {
        final int end = text.indexOf('`', i + 1);
        if (end != -1) {
          final String codeText = text.substring(i + 1, end);
          builder.pushStyle(
            ui.TextStyle(
              fontFamily: 'monospace',
              background: ui.Paint()..color = const ui.Color(0x14000000),
            ),
          );
          builder.addText(codeText);
          builder.pop();
          i = end + 1;
          continue;
        }
      }

      // 链接：[text](url)
      if (text[i] == '[') {
        final int closeBracket = text.indexOf(']', i + 1);
        if (closeBracket != -1 &&
            closeBracket + 1 < n &&
            text[closeBracket + 1] == '(') {
          final int closeParen = text.indexOf(')', closeBracket + 2);
          if (closeParen != -1) {
            final String linkText = text.substring(i + 1, closeBracket);
            // final String url = text.substring(closeBracket + 2, closeParen);
            builder.pushStyle(
              ui.TextStyle(
                color: const ui.Color(0xFF1B4FD8), // 包豪斯蓝
                decoration: ui.TextDecoration.underline,
                decorationColor: const ui.Color(0xFF1B4FD8),
              ),
            );
            builder.addText(linkText);
            builder.pop();
            i = closeParen + 1;
            continue;
          }
        }
      }

      // 普通文本：累积到下一个特殊字符
      int j = i;
      while (j < n && text[j] != '*' && text[j] != '_' && text[j] != '`' && text[j] != '[') {
        j++;
      }
      if (j == i) j++; // 至少前进一个字符（避免死循环）
      builder.pushStyle(baseStyle);
      builder.addText(text.substring(i, j));
      builder.pop();
      i = j;
    }
  }
}
