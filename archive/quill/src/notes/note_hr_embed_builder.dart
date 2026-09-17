import 'package:material_ui/material_ui.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// 分隔线嵌入（type = "divider"）：一条主题色浅横线，独占一行。
///
/// quill 主包没有 hr 常量（horizontal rule 在 extensions 包里，
/// 不值得为此加依赖），type/data 自定义——Delta 落盘为
/// `{"divider": "divider"}`，随笔记内容持久化与撤销栈走。
///
/// 插入逻辑在工具栏的「插入」菜单（保证 hr 前后都有换行、独占行）。
class NoteHrEmbedBuilder extends EmbedBuilder {
  const NoteHrEmbedBuilder();

  /// embed 类型标识（Delta 里的 key）。
  static const String embedType = 'divider';

  @override
  String get key => embedType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 垂直留白与段落间距节奏一致；Divider 高 1px 取 outlineVariant
    // （浅色深色下都可见，引用块边线同源）。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Divider(
        height: 1,
        thickness: 1,
        color: scheme.outlineVariant,
      ),
    );
  }
}
