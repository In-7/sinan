import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../../theme/app_popover.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'editor_typography.dart';
import 'emoji_picker.dart';

/// 笔记标题输入框（**左对齐**、随正文字号联动）。
///
/// ## 左对齐 + 左侧表情钮槽（2026-11-19 用户定案，推翻「居中封面」）
/// 标题改**左对齐**（Notion / 飞书原生），左缘与正文文字对齐；左侧让出一条
/// **与正文块手柄同槽同宽**的 48px 槽（`EditorTypography.blockHandleWidth`），
/// hover 标题行时露出「加表情」钮（[AppPopover] → [EmojiPickerPanel]）。
/// 与正文的 `BlockComponentActionWrapper` 的 `Row[手柄槽, 正文]` **同构**：
/// - 槽 `Visibility(maintainSize: true)` 常驻占位 ⇒ 按钮显隐**不推挤**标题文字；
/// - 标题文字列 = 列宽 − 左右内距 − 48 槽，与正文文字列同宽同左缘。
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
class NoteTitleField extends StatefulWidget {
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
  State<NoteTitleField> createState() => _NoteTitleFieldState();
}

class _NoteTitleFieldState extends State<NoteTitleField> {
  /// 标题行 hover 态：露出左侧「加表情」钮。
  bool _hover = false;

  /// 表情弹层开着（[AppPopover] 的 isOpen）：期间按钮**保持显形**，
  /// 免得鼠标移进弹层、离开标题行时按钮消失（弹层还挂在它身上）。
  bool _pickerOpen = false;

  /// 把表情插到标题光标处，并触发防抖落盘。
  ///
  /// ⚠️ 程序化改 `controller.value` **不走** `TextField.onChanged` ⇒ 必须
  /// 显式回调 [NoteTitleField.onChanged] 才会 bump 标题防抖。
  void _insertEmoji(String emoji) {
    insertEmojiAtCursor(widget.controller, emoji);
    widget.onChanged(widget.controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 整像素：字号吸附，行盒按 [EditorTypography.lineBox] 吸附后再回填成倍数
    // （与编辑器正文/标题同一套规则——标题半像素同样是笔画发灰的来源）。
    final double size = EditorTypography.snap(
      widget.typography.fontSize * EditorTypography.titleScale,
    );
    final double height =
        EditorTypography.lineBox(size, NoteTitleField.lineHeight) / size;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
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
          EditorTypography.blockPadding.left,
          Tokens.spaceMd,
          EditorTypography.blockPadding.right,
          widget.typography.titleBottomGap,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 左槽：与正文块手柄同槽同宽（`BlockComponentActionWrapper` 的
            // `Row[手柄槽, 正文]` 同构）。`maintainSize` 常驻占位 ⇒ 按钮显隐
            // 不推挤标题文字（正文手柄同款约定）。
            SizedBox(
              width: EditorTypography.blockHandleWidth,
              child: Visibility(
                visible: _hover || _pickerOpen,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: AppPopover(
                    panelWidth: EmojiPickerPanel.width,
                    anchorBuilder:
                        (
                          BuildContext context,
                          VoidCallback toggle,
                          bool isOpen,
                        ) {
                          // 弹层开合同步到 [_pickerOpen]：开着期间按钮保持显形
                          // （鼠标移进弹层会离开标题行 ⇒ 不同步就会"按钮消失、
                          // 面板还在"）。build 期不能 setState ⇒ 帧末回调。
                          if (isOpen != _pickerOpen) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                setState(() => _pickerOpen = isOpen);
                              }
                            });
                          }
                          return IconButton(
                            key: const ValueKey<String>('editor.emoji'),
                            onPressed: toggle,
                            tooltip: '加表情',
                            iconSize: Tokens.iconSm,
                            style:
                                IconButton.styleFrom(
                                  minimumSize: const Size.square(
                                    Tokens.headerActionSize,
                                  ),
                                  maximumSize: const Size.square(
                                    Tokens.headerActionSize,
                                  ),
                                  padding: EdgeInsets.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      Tokens.radiusButton,
                                    ),
                                  ),
                                ).copyWith(
                                  // 极简留白三态（与编辑页按钮带同口径）：
                                  // 弹层开着转 primary，悬停/聚焦明确，常驻淡。
                                  foregroundColor:
                                      WidgetStateProperty.resolveWith((
                                        Set<WidgetState> states,
                                      ) {
                                        if (isOpen) {
                                          return theme.colorScheme.primary;
                                        }
                                        if (states.contains(
                                              WidgetState.hovered,
                                            ) ||
                                            states.contains(
                                              WidgetState.focused,
                                            )) {
                                          return theme.colorScheme.onSurface;
                                        }
                                        return theme
                                            .colorScheme
                                            .onSurfaceVariant
                                            .withValues(alpha: 0.5);
                                      }),
                                ),
                            icon: const tabler.MoodSmile(strokeWidth: 1.5),
                          );
                        },
                    builder: (BuildContext context, VoidCallback close) =>
                        EmojiPickerPanel(
                          onPick: (String emoji) {
                            _insertEmoji(emoji);
                            close();
                          },
                        ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                onChanged: widget.onChanged,
                // 左对齐（2026-11-19 用户定案，推翻「居中封面」）：与正文同左缘，
                // Notion / 飞书原生观感。表情钮占左侧那条 48px 槽。
                // `textAlign` 默认即 `TextAlign.start`（左对齐），故不显式写。
                style: TextStyle(
                  fontSize: size,
                  // Semibold 而非 Bold：Apple 的中文要求——苹方没有 Bold 真字重，
                  // w700 会合成加粗（笔画糊边）；Semibold 两侧都是真实字重。
                  fontWeight: FontWeight.w600,
                  // 可变字体才需要（静态字体收到 null ⇒ 无副作用）。
                  fontVariations: AppTheme.weightVariation(600),
                  // 与正文同口径的标点压缩（见 EditorTypography.body()）。
                  fontFeatures: const <FontFeature>[FontFeature.enable('palt')],
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
                    fontFeatures: const <FontFeature>[
                      FontFeature.enable('palt'),
                    ],
                    color: AppTheme.hintColor(theme.colorScheme.onSurface),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
