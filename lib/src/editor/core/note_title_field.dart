import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'editor_typography.dart';

/// 笔记标题输入框（无边框、随正文字号联动）。
///
/// ## 为什么 `border` 要写四个状态
/// 主题里 `inputDecorationTheme` 显式设了 `enabledBorder` / `focusedBorder`
/// （表单场景的描边框，见 `app_theme.dart`）。而 Flutter 解析 `InputDecoration`
/// 时，这两个**优先于** `border`——只写 `border: InputBorder.none` 是盖不住的，
/// 标题会莫名其妙多出一圈表单描边（实际踩过：编辑页标题变成带圆角框的输入框）。
/// 故四个状态全部显式置空，`test/note_title_field_test.dart` 有回归断言。
///
/// ## 字体
/// 与正文同一批"中文黄金排版"项（`EditorTypography`）：雅黑 + CJK 回退链、
/// 零字距、`even` 行盒。这里**手工组装 `TextStyle`** 而非复用
/// `EditorTypography` 的方法——项目里 `material_ui`（应用侧）与
/// `flutter/material`（官方 appflowy 侧）是两套不相容的 `TextStyle` 类型，
/// 值全部引用同一批常量，不出现本地字面量。
class NoteTitleField extends StatelessWidget {
  const NoteTitleField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.typography,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final EditorTypography typography;

  /// 标题行高：比正文紧（1.35），但仍比西文标题的 1.08~1.15 留白足。
  static const double lineHeight = 1.35;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 整像素：字号吸附，行盒按 [EditorTypography.lineBox] 吸附后再回填成倍数
    // （与编辑器正文/标题同一套规则——标题半像素同样是笔画发灰的来源）。
    final double size = EditorTypography.snap(
      typography.fontSize * EditorTypography.titleScale,
    );
    final double height =
        EditorTypography.lineBox(size, lineHeight) / size;

    return Padding(
      // 左右内边距与编辑器正文列一致（同一个限宽列内才对齐）；
      // 上留白 = **顶条分隔线 → 标题**，下留白 = **标题 → 正文**。
      //
      // 上留白从 `spaceXl`(24) 收到 [Tokens.spaceMd](12)（2026-09-14）：
      // 那 24 是"标题居中当封面"时期的留白，而标题行上方现在是一条 1px
      // 分隔线（`home_screen.dart` 里右列顶条下沿那条），24 压在它下面显空。
      // 头部总高随之 69 → **57px**（12 + 行盒 32 + 下留白 13；默认 17px 正文）。
      //
      // 下留白**不能是 0**：标题行盒（[lineHeight] 1.35）余量与正文首个块
      // 自带的 4px 上内边距加起来只有 ~10px，28px 的标题贴着正文就是"太近"
      // 那个观感。取 [EditorTypography.titleBottomGap]（0.75em 吸附后的
      // 12px @16px 正文；随字号缩放），与 markdown 的标题下间距 1rem 同源。
      padding: EdgeInsets.fromLTRB(
        Tokens.spaceLg,
        Tokens.spaceMd,
        Tokens.spaceLg,
        typography.titleBottomGap,
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        // 标题在限宽列内**居中**（2026-09-12 用户定案）：文档封面感，
        // 与左对齐的正文形成层级差。占位符与光标随对齐自动居中。
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: size,
          // Semibold 而非 Bold：Apple 的中文要求——苹方没有 Bold 真字重，
          // w700 会合成加粗（笔画糊边）；Semibold 两侧都是真实字重。
          fontWeight: FontWeight.w600,
          height: height,
          letterSpacing: 0,
          fontFamily: AppTheme.editorFont,
          fontFamilyFallback: AppTheme.cjkFontFallback,
          leadingDistribution: TextLeadingDistribution.even,
          color: theme.colorScheme.onSurface,
        ),
        decoration: InputDecoration(
          // 四个状态都置空：只写 border 会被主题的 enabledBorder /
          // focusedBorder 盖掉（见类文档）。
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.zero,
          // 与列表里的空标题回退文案同词（与 quill 版同口径）。
          hintText: '无标题',
          hintStyle: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w400,
            height: height,
            letterSpacing: 0,
            fontFamily: AppTheme.editorFont,
            fontFamilyFallback: AppTheme.cjkFontFallback,
            color: AppTheme.hintColor(theme.colorScheme.onSurface),
          ),
        ),
      ),
    );
  }
}
