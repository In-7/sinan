import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'attachment_meta.dart';
import 'formula_render.dart';
import 'note_attachment_embed_builder.dart';
import 'note_formula_embed_builder.dart';
import 'note_hr_embed_builder.dart';
import 'note_link_dialog.dart';
import 'note_media_service.dart';

/// Lucide 图标的本文件统一别名（将来换图标库只改这里）。
abstract final class _I {
  static const undo = LucideIcons.undo2;
  static const redo = LucideIcons.redo2;
  static const search = LucideIcons.search;
  static const bold = LucideIcons.bold;
  static const italic = LucideIcons.italic;
  static const underline = LucideIcons.underline;
  // 编辑链接（选中已有链接时移除）的入口暂收起，恢复时用。
  // ignore: unused_field
  static const unlink = LucideIcons.unlink;
  static const strike = LucideIcons.strikethrough;
  static const code = LucideIcons.code;
  static const link = LucideIcons.link;
  static const image = LucideIcons.image;
  static const bulletList = LucideIcons.list;
  static const numberList = LucideIcons.listOrdered;
  static const checkList = LucideIcons.listTodo;
  static const quote = LucideIcons.quote;
  static const codeBlock = LucideIcons.squareCode;
  // 字色主按钮不用图标库，直接渲染字母 A（Word/WPS 惯例）。
  static const highlight = LucideIcons.highlighter;
  static const clearFormat = LucideIcons.removeFormatting;
  static const more = LucideIcons.ellipsis;
  static const toc = LucideIcons.listTree;
  // 插入菜单：触发钮 + 分隔线/公式/附件菜单项。
  static const insert = LucideIcons.plus;
  static const divider = LucideIcons.minus;
  static const sigma = LucideIcons.sigma;
  static const attachment = LucideIcons.paperclip;
  static const alignLeft = LucideIcons.alignLeft;
  static const alignCenter = LucideIcons.alignCenter;
  static const alignRight = LucideIcons.alignRight;
  static const indentIncrease = LucideIcons.indentIncrease;
  static const indentDecrease = LucideIcons.indentDecrease;
  static const check = LucideIcons.check;
}

/// 自绘 M3 格式工具栏：对齐 Word/飞书的常驻工具栏形态——
/// 无选区时行内样式进入「待输入样式」（quill toggledStyle，
/// 激活态同步显示），块级样式作用于光标所在行，均不禁用；
/// 撤销/重做随使用条件启用（无可撤销历史时禁用）。
class NoteFormatToolbar extends StatelessWidget {
  const NoteFormatToolbar({
    super.key,
    required this.controller,
    this.contentFocus,
    this.onSearch,
    this.tocActive = false,
    this.onToggleToc,
  });

  final QuillController controller;

  /// 打开编辑器内搜索条（Ctrl+F 同入口），由编辑器视图负责挂载。
  final VoidCallback? onSearch;

  /// 目录面板开关状态（按钮激活态）与切换回调——面板由编辑器视图
  /// 挂载，工具栏只负责开关。
  final bool tocActive;
  final VoidCallback? onToggleToc;

  /// 正文焦点节点：工具栏动作前确保光标已在正文——
  /// quill 的 toggledStyle 在光标移动（点击页面）时会被清空，
  /// 若不先聚焦，用户点完工具栏还得再点页面，样式就丢了。
  final FocusNode? contentFocus;

  /// 确保光标在正文后执行动作。
  void _act(VoidCallback action) {
    _ensureFocus();
    action();
  }

  void _ensureFocus() {
    if (contentFocus != null && !contentFocus!.hasFocus) {
      contentFocus!.requestFocus();
    }
  }

  /// 与官方 QuillToolbarToggleStyleButton 同语义的切换：
  /// 已激活 → `Attribute.clone(attr, null)` **移除**属性；
  /// 未激活 → 应用属性。缺了前者就是「点了取消不掉」的根因。
  ///
  /// 块级属性（标题/列表/引用等）切换时置 skipRequestKeyboard，
  /// 避免编辑器重新抢键盘焦点导致选区跳动（官方行为一致）。
  void _toggle(Attribute attribute) {
    // 先确保光标在正文：toggledStyle 依赖「光标已就位」。
    _ensureFocus();
    final Map<String, Attribute> attrs =
        controller.getSelectionStyle().attributes;
    // list/header/script/align 同 key 多值（H1≠H2），比 value；
    // 其余（bold 等）同 key 单值，containsKey 即可。
    final bool active = (attribute.key == Attribute.list.key ||
            attribute.key == Attribute.header.key ||
            attribute.key == Attribute.script.key ||
            attribute.key == Attribute.align.key)
        ? attrs[attribute.key]?.value == attribute.value
        : attrs.containsKey(attribute.key);
    controller
      ..skipRequestKeyboard = !attribute.isInline
      ..formatSelection(
        active ? Attribute.clone(attribute, null) : attribute,
      );
  }

  /// 待办列表切换（官方 Ctrl+Shift+C 同语义）：
  /// 非待办行（含 bullet/ordered）→ 打上 unchecked 待办；
  /// 已是待办（checked/unchecked）→ 移除列表属性回正文。
  void _toggleCheckList() {
    _ensureFocus();
    final Map<String, Attribute> attrs =
        controller.getSelectionStyle().attributes;
    final Object? listValue = attrs[Attribute.list.key]?.value;
    final bool isCheckList =
        listValue == Attribute.checked.value ||
        listValue == Attribute.unchecked.value;
    controller
      ..skipRequestKeyboard = true
      ..formatSelection(
        isCheckList
            ? Attribute.clone(Attribute.unchecked, null)
            : Attribute.unchecked,
      );
  }

  @override
  Widget build(BuildContext context) {
    // 与 controller 状态**无关**的部件在 AnimatedBuilder 外层构建一次：
    // 每次 controller 通知（= 每次击键）重建时，这些实例仍是同一个
    // （identical），Flutter 会跳过其 element 更新——整棵子树不参与重建。
    // 只有真正依赖选区状态的部分（激活态/撤销可用）留在 builder 内。
    final Widget insertMenu = _InsertMenu(
      controller: controller,
      contentFocus: contentFocus,
    );
    final Widget moreMenu = _MoreMenu(
      controller: controller,
      contentFocus: contentFocus,
    );
    final Widget? searchButton = onSearch == null
        ? null
        : _FormatButton(
            icon: _I.search,
            tooltip: '搜索（Ctrl+F）',
            onTap: onSearch!,
          );
    final Widget? tocButton = onToggleToc == null
        ? null
        : _FormatButton(
            icon: _I.toc,
            tooltip: '目录',
            active: tocActive,
            onTap: onToggleToc!,
          );

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final Map<String, Attribute> attrs =
            controller.getSelectionStyle().attributes;
        final String? align = attrs[Attribute.align.key]?.value as String?;
        return Container(
          // minHeight 而非固定 height：窄窗口（如 Win+方向键半屏分屏、
          // 目录展开时内容列仅剩 ~500px）下方自动折成两行——不隐藏
          // 功能、不需横向滚动；宽窗口下仍是单行 40 高，观感不变。
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(
            horizontal: Tokens.spaceSm,
            vertical: 4,
          ),
          alignment: Alignment.centerLeft,
          child: Wrap(
            // 按钮间统一 8px 间距；分隔线自身不再带边距（否则双重间隔）。
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _FormatButton(icon: _I.undo, tooltip: '撤销（Ctrl+Z）', enabled: controller.hasUndo, onTap: () => _act(controller.undo)),
              _FormatButton(icon: _I.redo, tooltip: '重做（Ctrl+Y）', enabled: controller.hasRedo, onTap: () => _act(controller.redo)),
              const _ToolbarDivider(),
              // 样式选择器（M3 MenuAnchor）：块样式是第一高频决策，
              // 对表飞书/Notion 排在最前；触发钮显示当前样式名 + 箭头。
              _StylePicker(controller: controller, contentFocus: contentFocus, ),
              const _ToolbarDivider(),
              _FormatButton(icon: _I.bold, tooltip: '加粗（Ctrl+B）', active: attrs.containsKey(Attribute.bold.key), onTap: () => _toggle(Attribute.bold)),
              _FormatButton(icon: _I.italic, tooltip: '斜体（Ctrl+I）', active: attrs.containsKey(Attribute.italic.key), onTap: () => _toggle(Attribute.italic)),
              _FormatButton(icon: _I.underline, tooltip: '下划线（Ctrl+U）', active: attrs.containsKey(Attribute.underline.key), onTap: () => _toggle(Attribute.underline)),
              _FormatButton(icon: _I.strike, tooltip: '删除线（Ctrl+Shift+S）', active: attrs.containsKey(Attribute.strikeThrough.key), onTap: () => _toggle(Attribute.strikeThrough)),
              _FormatButton(icon: _I.code, tooltip: '行内代码（Ctrl+`）', active: attrs.containsKey(Attribute.inlineCode.key), onTap: () => _toggle(Attribute.inlineCode)),
              const _ToolbarDivider(),
              // ul/ol 共用 key 'list'（value 才区分 bullet/ordered），
              // 激活态必须按 value 比较——containsKey 会让两键同亮。
              _FormatButton(icon: _I.bulletList, tooltip: '无序列表（Ctrl+Shift+L）', active: attrs[Attribute.list.key]?.value == Attribute.ul.value, onTap: () => _toggle(Attribute.ul)),
              _FormatButton(icon: _I.numberList, tooltip: '有序列表（Ctrl+Shift+O）', active: attrs[Attribute.list.key]?.value == Attribute.ol.value, onTap: () => _toggle(Attribute.ol)),
              // 待办列表：checked/unchecked 同属待办态（value 比较，
              // 与 bullet/ordered 区分）；复选框点击切换为编辑器内置。
              _FormatButton(
                icon: _I.checkList,
                tooltip: '待办列表（Ctrl+Shift+C）',
                active: attrs[Attribute.list.key]?.value == Attribute.checked.value ||
                    attrs[Attribute.list.key]?.value == Attribute.unchecked.value,
                onTap: () => _toggleCheckList(),
              ),
              const _ToolbarDivider(),
              _FormatButton(icon: _I.quote, tooltip: '引用（Ctrl+Shift+B）', active: attrs.containsKey(Attribute.blockQuote.key), onTap: () => _toggle(Attribute.blockQuote)),
              _FormatButton(icon: _I.codeBlock, tooltip: '代码块（Ctrl+Shift+`）', active: attrs.containsKey(Attribute.codeBlock.key), onTap: () => _toggle(Attribute.codeBlock)),
              const _ToolbarDivider(),
              _ColorButton(controller: controller, contentFocus: contentFocus, tooltip: '字体颜色', isBackground: false, ),
              _ColorButton(controller: controller, contentFocus: contentFocus, icon: _I.highlight, tooltip: '背景高亮', isBackground: true, ),
              const _ToolbarDivider(),
              // 对齐下拉（Word 高频动作，从更多菜单升级为独立按钮）。
              _AlignPicker(controller: controller, align: align, contentFocus: contentFocus, ),
              // 「插入」下拉：对象类操作（图片/链接/分隔线）统一入口
              // （Word 的插入选项卡同理念——对象类与格式类分组）。
              // 复用外层实例 → 击键重建时本子树不参与。
              insertMenu,
              const _ToolbarDivider(),
              // 右端工具兜底区：搜索 + 目录 + 更多（Word/浏览器惯例——
              // 查找替换与低频收纳动作都在最右端）。
              ?searchButton,
              // 目录按钮的激活态来自 widget 参数（非 controller），
              // 同样复用外层实例。
              ?tocButton,
              moreMenu,
            ],
          ),
        );
      },
    );
  }

}

/// 工具栏内按钮组的细分隔线。
///
/// 区域分区的「无分割线」原则不适用于工具栏内部——
/// 功能分组线是成熟应用（AppFlowy/AFFiNE/Office 系）工具栏的标配。
class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 1,
      height: 18,
      // 左右间隔由外层 Row 的 spacing(8) 提供，自身不再加边距。
      color: scheme.outlineVariant.withValues(alpha: 0.6),
    );
  }
}

/// 清除选区（或光标处）的全部格式：遍历当前样式属性逐个置 null
/// （行内样式与块级样式都清）。工具栏「更多」菜单与 Ctrl+\ 快捷键
/// 共用此实现——单一来源，行为天然一致。
void clearSelectionFormatting(QuillController controller) {
  controller
      .getSelectionStyle()
      .attributes
      .values
      .forEach((Attribute attr) {
    controller.formatSelection(Attribute.clone(attr, null));
  });
}

/// 「更多」菜单：低频操作（清除格式 / 缩进）。
/// 对齐已升级为独立的 _AlignPicker（Word 高频动作）。
class _MoreMenu extends StatefulWidget {
  const _MoreMenu({
    required this.controller,
    this.contentFocus,
  });

  final QuillController controller;

  /// 正文焦点：动作前确保光标已在正文。
  final FocusNode? contentFocus;

  @override
  State<_MoreMenu> createState() => _MoreMenuState();
}

class _MoreMenuState extends State<_MoreMenu> {
  final MenuController _menu = MenuController();
  final ValueNotifier<bool> _hover = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _hover.dispose();
    super.dispose();
  }

  void _run(VoidCallback action) {
    final FocusNode? focus = widget.contentFocus;
    if (focus != null && !focus.hasFocus) {
      focus.requestFocus();
    }
    action();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return MenuAnchor(
      controller: _menu,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
        elevation: const WidgetStatePropertyAll(3),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: Tokens.spaceXs),
        ),
        // 200 宽：容纳「减少缩进 + Ctrl+Shift+M」同排不溢出。
        minimumSize: const WidgetStatePropertyAll(Size(200, 0)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Tokens.radiusMd),
          ),
        ),
      ),
      menuChildren: <Widget>[
        _item(
          scheme,
          textTheme,
          _I.clearFormat,
          '清除格式',
          shortcut: 'Ctrl+\\',
          onPressed: () => _run(() {
            clearSelectionFormatting(widget.controller);
          }),
        ),
        _divider(scheme),
        _item(
          scheme,
          textTheme,
          _I.indentIncrease,
          '增加缩进',
          shortcut: 'Ctrl+M',
          onPressed: () => _run(() => widget.controller.indentSelection(true)),
        ),
        _item(
          scheme,
          textTheme,
          _I.indentDecrease,
          '减少缩进',
          shortcut: 'Ctrl+Shift+M',
          onPressed: () =>
              _run(() => widget.controller.indentSelection(false)),
        ),
      ],
      builder: (BuildContext context, MenuController controller, Widget? _) {
        return Tooltip(
          message: '更多',
          child: MouseRegion(
            onEnter: (_) => _hover.value = true,
            onExit: (_) => _hover.value = false,
            child: GestureDetector(
              onTap: () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                }
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Tokens.radiusSm),
                child: ValueListenableBuilder<bool>(
                  valueListenable: _hover,
                  builder: (context, hovered, _) => Container(
                    height: Tokens.formatButtonHeight,
                    width: Tokens.formatButtonWidth,
                    color: hovered
                        ? scheme.surfaceContainerHighest
                        : Colors.transparent,
                    alignment: Alignment.center,
                    child: Icon(
                      _I.more,
                      size: Tokens.iconSm,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _item(
    ColorScheme scheme,
    TextTheme textTheme,
    IconData icon,
    String label, {
    String? shortcut,
    required VoidCallback onPressed,
  }) {
    return MenuItemButton(
      onPressed: onPressed,
      style: MenuItemButton.styleFrom(
        minimumSize: const Size(200, 40),
        maximumSize: const Size(200, 40),
        padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
      ),
      // label 用 Expanded：宽度的富余全给文字与快捷键之间，
      // 快捷键右对齐且任何字串长度都不会溢出。
      child: Row(
        children: <Widget>[
          Icon(icon, size: Tokens.iconSm, color: scheme.onSurfaceVariant),
          const SizedBox(width: Tokens.spaceMd),
          Expanded(
            child: Text(
              label,
              style: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (shortcut != null)
            Text(
              shortcut,
              style: textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Widget _divider(ColorScheme scheme) => Container(
        height: 1,
        margin: const EdgeInsets.symmetric(vertical: Tokens.spaceXxs),
        color: scheme.outlineVariant.withValues(alpha: 0.6),
      );
}

/// 「插入」下拉：对象类操作（图片 / 链接 / 分隔线）统一入口。
///
/// Word 的插入选项卡同理念——对象类与格式类操作分组；点击菜单项
/// 前先聚焦正文（与工具栏其他动作同语义），动作完成后菜单即关。
class _InsertMenu extends StatefulWidget {
  const _InsertMenu({required this.controller, this.contentFocus});

  final QuillController controller;

  /// 正文焦点：插入对象前确保光标已在正文。
  final FocusNode? contentFocus;

  @override
  State<_InsertMenu> createState() => _InsertMenuState();
}

class _InsertMenuState extends State<_InsertMenu> {
  final MenuController _menu = MenuController();
  final ValueNotifier<bool> _hover = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _hover.dispose();
    super.dispose();
  }

  /// 动作前聚焦正文（与工具栏 _act 同语义）。
  void _run(VoidCallback action) {
    final FocusNode? focus = widget.contentFocus;
    if (focus != null && !focus.hasFocus) {
      focus.requestFocus();
    }
    action();
  }

  /// 插入图片：多选拾取 → 逐张复制进数据目录 → 官方同款方式
  /// 顺序写进 Delta（replaceText + BlockEmbed.image，嵌入占 1 位，
  /// 插入点逐张后移）。取消/失败静默不动文档。
  Future<void> _insertImage() async {
    final List<String> paths = await NoteMediaService.pickAndStoreImages();
    if (paths.isEmpty) return;
    int index = widget.controller.selection.end;
    for (final String path in paths) {
      widget.controller.replaceText(index, 0, BlockEmbed.image(path), null);
      index += 1;
    }
  }

  /// 链接对话框（M3 自绘版，提交语义对齐官方 LinkDialog）。
  Future<void> _showLinkDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => NoteLinkDialog(controller: widget.controller),
    );
  }

  /// 插入公式：对话框输入 LaTeX（实时预览），确定后写入文档。
  /// 取消/空串静默不动文档。
  Future<void> _insertFormula() async {
    final String? latex = await showFormulaDialog(context);
    if (latex == null || latex.isEmpty) return;
    final TextSelection selection = widget.controller.selection;
    final int index = selection.isValid ? selection.end : 0;
    widget.controller.replaceText(
      index,
      0,
      BlockEmbed(NoteFormulaEmbedBuilder.embedType, latex),
      TextSelection.collapsed(offset: index + 1),
    );
  }

  /// 插入附件：拾取任意文件 → 复制进数据目录 → 写入文档。
  Future<void> _insertAttachment() async {
    final AttachmentMeta? meta = await NoteMediaService.pickAndStoreAttachment();
    if (meta == null) return;
    final TextSelection selection = widget.controller.selection;
    final int index = selection.isValid ? selection.end : 0;
    widget.controller.replaceText(
      index,
      0,
      BlockEmbed(
        NoteAttachmentEmbedBuilder.embedType,
        jsonEncode(meta.toJson()),
      ),
      TextSelection.collapsed(offset: index + 1),
    );
  }

  /// 插入分隔线：hr 前后必须都有换行（独占一行）——光标在行中时
  /// 先补换行把原行拆开；光标在行首/行尾则直接插入。
  /// 两次 replaceText 进两步撤销，操作低频可接受。
  void _insertDivider() {
    final QuillController controller = widget.controller;
    final TextSelection selection = controller.selection;
    final int index = selection.isValid ? selection.end : 0;
    final Document doc = controller.document;
    final String before = index > 0 ? doc.getPlainText(index - 1, 1) : '\n';

    int cursor = index;
    if (before != '\n') {
      // 光标在行中：先换行，hr 落到新行。
      controller.replaceText(index, 0, '\n', null);
      cursor += 1;
    }
    controller.replaceText(
      cursor,
      0,
      const BlockEmbed(NoteHrEmbedBuilder.embedType, NoteHrEmbedBuilder.embedType),
      TextSelection.collapsed(offset: cursor + 1),
    );
    cursor += 1;
    // hr 后补换行收尾（原行剩余文字落到下一行）。
    controller.replaceText(
      cursor,
      0,
      '\n',
      TextSelection.collapsed(offset: cursor),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return MenuAnchor(
      controller: _menu,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
        elevation: const WidgetStatePropertyAll(3),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: Tokens.spaceXs),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(180, 0)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Tokens.radiusMd),
          ),
        ),
      ),
      menuChildren: <Widget>[
        MenuItemButton(
          onPressed: () => _run(_insertImage),
          style: _itemStyle,
          child: _itemRow(_I.image, '图片', null, scheme, textTheme),
        ),
        MenuItemButton(
          onPressed: () => _run(_showLinkDialog),
          style: _itemStyle,
          child: _itemRow(_I.link, '链接', 'Ctrl+K', scheme, textTheme),
        ),
        MenuItemButton(
          onPressed: () => _run(_insertDivider),
          style: _itemStyle,
          child: _itemRow(_I.divider, '分隔线', null, scheme, textTheme),
        ),
        MenuItemButton(
          onPressed: () => _run(_insertFormula),
          style: _itemStyle,
          child: _itemRow(_I.sigma, '公式', null, scheme, textTheme),
        ),
        MenuItemButton(
          onPressed: () => _run(_insertAttachment),
          style: _itemStyle,
          child: _itemRow(_I.attachment, '附件', null, scheme, textTheme),
        ),
      ],
      builder: (BuildContext context, MenuController controller, Widget? _) {
        return Tooltip(
          message: '插入',
          child: MouseRegion(
            onEnter: (_) => _hover.value = true,
            onExit: (_) => _hover.value = false,
            child: GestureDetector(
              onTap: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Tokens.radiusSm),
                child: ValueListenableBuilder<bool>(
                  valueListenable: _hover,
                  builder: (context, hovered, _) => Container(
                    height: Tokens.formatButtonHeight,
                    width: Tokens.formatButtonWidth,
                    color: hovered
                        ? scheme.surfaceContainerHighest
                        : Colors.transparent,
                    alignment: Alignment.center,
                    child: Icon(
                      _I.insert,
                      size: Tokens.iconSm,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static const ButtonStyle _itemStyle = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(180, 40)),
    maximumSize: WidgetStatePropertyAll(Size(180, 40)),
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
    ),
  );

  Widget _itemRow(
    IconData icon,
    String label,
    String? shortcut,
    ColorScheme scheme,
    TextTheme textTheme,
  ) {
    return Row(
      children: <Widget>[
        Icon(icon, size: Tokens.iconSm, color: scheme.onSurfaceVariant),
        const SizedBox(width: Tokens.spaceMd),
        Expanded(
          child: Text(
            label,
            style: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
          ),
        ),
        if (shortcut != null)
          Text(
            shortcut,
            style: textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
      ],
    );
  }
}

/// 对齐选择器（M3 Menus）：左/中/右/两端，触发钮显示当前对齐图标。
/// 从「更多」菜单升级为独立按钮——对齐是 Word 级高频动作。
class _AlignPicker extends StatefulWidget {
  const _AlignPicker({
    required this.controller,
    required this.align,
    this.contentFocus,
  });

  final QuillController controller;

  /// 当前对齐值（null = 默认左对齐），用于触发钮图标与选中勾。
  final String? align;

  /// 正文焦点：动作前确保光标已在正文。
  final FocusNode? contentFocus;

  @override
  State<_AlignPicker> createState() => _AlignPickerState();
}

class _AlignPickerState extends State<_AlignPicker> {
  final MenuController _menu = MenuController();
  final ValueNotifier<bool> _hover = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _hover.dispose();
    super.dispose();
  }

  // 只有左/中/右三种：迁移目标（appflowy）没有两端对齐的实现，
  // 已从菜单下线（历史数据里的 justify 会落到默认左对齐，值仍保留在文档里）。
  IconData get _currentIcon => switch (widget.align) {
        'center' => _I.alignCenter,
        'right' => _I.alignRight,
        _ => _I.alignLeft,
      };

  void _apply(Attribute alignment) {
    final FocusNode? focus = widget.contentFocus;
    if (focus != null && !focus.hasFocus) {
      focus.requestFocus();
    }
    widget.controller
      ..skipRequestKeyboard = true
      ..formatSelection(alignment);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return MenuAnchor(
      controller: _menu,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
        elevation: const WidgetStatePropertyAll(3),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: Tokens.spaceXs),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(148, 0)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Tokens.radiusMd),
          ),
        ),
      ),
      menuChildren: <Widget>[
        _item(
          scheme,
          _I.alignLeft,
          '左对齐',
          Attribute.leftAlignment,
          checked: widget.align == null,
        ),
        _item(
          scheme,
          _I.alignCenter,
          '居中',
          Attribute.centerAlignment,
          checked: widget.align == 'center',
        ),
        _item(
          scheme,
          _I.alignRight,
          '右对齐',
          Attribute.rightAlignment,
          checked: widget.align == 'right',
        ),
      ],
      builder: (BuildContext context, MenuController controller, Widget? _) {
        return Tooltip(
          message: '对齐',
          child: MouseRegion(
            onEnter: (_) => _hover.value = true,
            onExit: (_) => _hover.value = false,
            child: GestureDetector(
              // 开/关切换：点按钮本身也能收起菜单。
              onTap: () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                }
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Tokens.radiusSm),
                child: ValueListenableBuilder<bool>(
                  valueListenable: _hover,
                  builder: (context, hovered, _) => Container(
                    height: Tokens.formatButtonHeight,
                    width: Tokens.formatButtonWidth + 4,
                    color: hovered
                        ? scheme.surfaceContainerHighest
                        : Colors.transparent,
                    // 图标在上、小箭头在下（颜色下拉同款堆叠）。
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Icon(
                          _currentIcon,
                          size: Tokens.iconSm,
                          color: scheme.onSurfaceVariant,
                        ),
                        Icon(
                          LucideIcons.chevronDown,
                          size: 8,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _item(
    ColorScheme scheme,
    IconData icon,
    String label,
    Attribute alignment, {
    required bool checked,
  }) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return MenuItemButton(
      onPressed: () {
        _apply(alignment);
        _menu.close();
      },
      style: MenuItemButton.styleFrom(
        minimumSize: const Size(148, 40),
        maximumSize: const Size(148, 40),
        backgroundColor:
            checked ? scheme.secondaryContainer : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 16,
            child: checked ? Icon(_I.check, size: 14, color: scheme.primary) : null,
          ),
          const SizedBox(width: Tokens.spaceSm),
          Icon(icon, size: Tokens.iconSm, color: scheme.onSurfaceVariant),
          const SizedBox(width: Tokens.spaceMd),
          Text(
            label,
            style: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
          ),
        ],
      ),
    );
  }
}

/// 单个格式按钮：悬浮/激活双态，ValueNotifier 只重建颜色层
/// （与 _NoteTile 同一防闪烁模式）。
class _FormatButton extends StatefulWidget {
  const _FormatButton({
    required this.icon,
    required this.tooltip,
    this.active = false,
    this.enabled = true,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool active;

  /// AppFlowy 式：无选区时禁用——灰显、无悬浮反馈、不可点。
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_FormatButton> createState() => _FormatButtonState();
}

class _FormatButtonState extends State<_FormatButton> {
  final ValueNotifier<bool> _hover = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _hover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) {
          _hover.value = true;
        },
        onExit: (_) => _hover.value = false,
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
            child: ValueListenableBuilder<bool>(
              valueListenable: _hover,
              builder: (context, hovered, _) {
                final Color background = !widget.enabled
                    ? Colors.transparent
                    : widget.active
                        ? scheme.secondaryContainer
                        : hovered
                            ? scheme.surfaceContainerHighest
                            : Colors.transparent;
                final Color foreground = !widget.enabled
                    // 禁用：降到 35% 灰，与激活态明确区分。
                    ? scheme.onSurfaceVariant.withValues(alpha: 0.35)
                    : widget.active
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant;
                return Container(
                  width: Tokens.formatButtonWidth,
                  height: Tokens.formatButtonHeight,
                  color: background,
                  child: Icon(
                    widget.icon,
                    size: Tokens.iconSm,
                    color: foreground,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 色板基色（列）：白、黑、蓝、青、绿、红、黄、金、紫、洋红。
const List<Color> _baseColors = <Color>[
  Color(0xFFFFFFFF),
  Color(0xFF1F1F1F),
  Color(0xFF1C7DFF),
  Color(0xFF0DC8C8),
  Color(0xFF34C724),
  Color(0xFFF5222D),
  Color(0xFFFFD60A),
  Color(0xFFF5A623),
  Color(0xFF7B61FF),
  Color(0xFFF0479C),
];

/// 每列按亮度派生 6 档（浅 → 深），构成 6 行 × 10 列色板。
/// 第一行（-1）用基色原值。
final List<Color> _palette = <Color>[
  for (final double l in <double>[-1, 0.85, 0.70, 0.55, 0.40, 0.25])
    for (final Color base in _baseColors)
      l < 0 ? base : HSLColor.fromColor(base).withLightness(l).toColor(),
];

/// 颜色按钮：图标下方一条当前色带；点击弹出 M3 色板。
/// 写入与 flutter_quill 官方一致：`ColorAttribute(hex)` / `BackgroundAttribute(hex)`。
class _ColorButton extends StatefulWidget {
  const _ColorButton({
    required this.controller,
    this.contentFocus,
    this.icon,
    required this.tooltip,
    required this.isBackground,
  });

  final QuillController controller;

  /// 正文焦点：上色前确保光标已在正文（toggledStyle 依赖它）。
  final FocusNode? contentFocus;

  /// 高亮按钮的线性图标；字色按钮不使用（渲染字母 A）。
  final IconData? icon;
  final String tooltip;
  final bool isBackground;

  @override
  State<_ColorButton> createState() => _ColorButtonState();
}

class _ColorButtonState extends State<_ColorButton> {
  /// 悬浮分区状态：-1 未悬浮 / 0 主钮 / 1 下拉钮。
  /// 整组共享一块悬浮背景（split button 惯例），指针所在半区色重、
  /// 另一半区色轻——视觉上是一个功能，点击仍分区。
  final ValueNotifier<int> _hoverZone = ValueNotifier<int>(-1);

  /// 色板下拉（M3 MenuAnchor，与样式/对齐/更多菜单同一架构）：
  /// 色板浮在按钮正下方（智能翻转避屏幕边），不再居中弹窗。
  final MenuController _menu = MenuController();

  /// 未选过颜色时的缺省施加色（主按钮点击直接用）。
  static const Color _defaultText = Color(0xFFF5222D);
  static const Color _defaultHighlight = Color(0xFFFFD60A);

  /// 记忆上次用色：跨选区保持「点了就上这个色」的连续体验。
  Color? _lastUsed;

  @override
  void dispose() {
    _hoverZone.dispose();
    super.dispose();
  }

  /// 本地 hex 转换（quill 的 colorToHex 未从包导出）。
  /// 不透明色返回 #RRGGBB，带透明度返回 #AARRGGBB。
  String _toHex(Color color) {
    final String full =
        color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();
    return full.startsWith('FF') ? '#${full.substring(2)}' : '#$full';
  }

  Color? _parseHex(String? hex) {
    if (hex == null || !hex.startsWith('#')) return null;
    var v = hex.replaceFirst('#', '');
    if (v.length == 6) v = 'FF$v';
    final int? value = int.tryParse(v, radix: 16);
    return value == null ? null : Color(value);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Map<String, Attribute> attrs =
        widget.controller.getSelectionStyle().attributes;
    final String? colorStr = attrs[
            widget.isBackground
                ? Attribute.background.key
                : Attribute.color.key
        ]?.value as String?;
    final Color? selectionColor = _parseHex(colorStr);
    // 生效色：选区已有色 > 上次用色 > 缺省色。
    // 主按钮点击即施加它，色条同步显示——所见即所施。
    final Color effective = selectionColor ??
        _lastUsed ??
        (widget.isBackground ? _defaultHighlight : _defaultText);
    final bool hasPicked = selectionColor != null || _lastUsed != null;

    // split button：整组一块悬浮背景（指针所在半区色重、另一半色轻），
    // 圆角在组级裁切；两个半区各自命中、各自点击。
    Color halfColor(bool isDropdownHalf) {
      final int zone = _hoverZone.value;
      if (zone < 0) return Colors.transparent;
      final bool hoveredHalf = zone == (isDropdownHalf ? 1 : 0);
      return hoveredHalf
          ? scheme.surfaceContainerHighest
          : scheme.surfaceContainerHighest.withValues(alpha: 0.45);
    }

    // 色板挂在 MenuAnchor 上：点下拉钮后**浮在按钮正下方**（Word/
    // WPS/飞书同款交互），与工具栏其他菜单（样式/对齐/更多）同一架构。
    return MenuAnchor(
      controller: _menu,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
        elevation: const WidgetStatePropertyAll(3),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.all(Tokens.spaceMd),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Tokens.radiusMd),
          ),
        ),
      ),
      menuChildren: <Widget>[_palettePanel(context)],
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Tokens.radiusSm),
        child: ValueListenableBuilder<int>(
          valueListenable: _hoverZone,
          builder: (context, _, _) => Row(
            mainAxisSize: MainAxisSize.min,
            // 主按钮与下拉零间距：视觉上是一个整体控件（主点击区+下拉区）。
            children: <Widget>[
              // 主按钮：与其他格式按钮同尺寸，点击直接给选区上当前色。
              Tooltip(
                message: widget.tooltip,
                child: MouseRegion(
                  onEnter: (_) => _hoverZone.value = 0,
                  onExit: (_) {
                    if (_hoverZone.value == 0) _hoverZone.value = -1;
                  },
                  child: GestureDetector(
                    onTap: () => _apply(effective),
                    child: Container(
                      width: Tokens.formatButtonWidth,
                      height: Tokens.formatButtonHeight,
                      color: halfColor(false),
                      // 字色主图标用字母 A（Word/WPS 惯例），
                      // 高亮笔保留线性图标。
                      child: Center(
                        child: widget.isBackground
                            ? Icon(
                                widget.icon,
                                size: Tokens.iconSm,
                                color: scheme.onSurfaceVariant,
                              )
                            : Text(
                                'A',
                                style: TextStyle(
                                  fontSize: Tokens.iconSm - 1,
                                  fontWeight: FontWeight.w700,
                                  height: 1,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              // 下拉按钮：独立命中区（不占主按钮的空间），点击开/收色板。
              Tooltip(
                message: '选择颜色',
                child: MouseRegion(
                  onEnter: (_) => _hoverZone.value = 1,
                  onExit: (_) {
                    if (_hoverZone.value == 1) _hoverZone.value = -1;
                  },
                  child: GestureDetector(
                    onTap: () =>
                        _menu.isOpen ? _menu.close() : _menu.open(),
                    child: Container(
                      // 下拉钮：宽度减半（9），高度与主按钮一致（30）。
                      // 内容微缩：色条 7×2 / 箭头 9。
                      width: 9,
                      height: Tokens.formatButtonHeight,
                      color: halfColor(true),
                      alignment: Alignment.center,
                      // 状态条置于下拉顶部：色条在上（当前生效色）、
                      // 箭头在下——主按钮图标不被挤压。
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          Container(
                            width: 7,
                            height: 2,
                            decoration: BoxDecoration(
                              color: hasPicked
                                  ? effective
                                  : scheme.outlineVariant,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Icon(
                            LucideIcons.chevronDown,
                            size: 9,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 色板面板（MenuAnchor 的 menuChildren）：默认颜色 + 6×10 色网格，
  /// 当前生效色高亮。选色即关菜单并上色（Word 同款一步到位）。
  Widget _palettePanel(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final Map<String, Attribute> attrs =
        widget.controller.getSelectionStyle().attributes;
    final String? colorStr = attrs[
            widget.isBackground
                ? Attribute.background.key
                : Attribute.color.key
        ]?.value as String?;
    final Color? selected = _parseHex(colorStr) ?? _lastUsed;

    return SizedBox(
      width: 330,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 「默认颜色」整行：一键回到无色。
          Material(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
            child: InkWell(
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
              onTap: () {
                _menu.close();
                widget.controller.formatSelection(
                  widget.isBackground
                      ? const BackgroundAttribute(null)
                      : const ColorAttribute(null),
                );
                // 回到无色后，主按钮再次点击施加缺省色。
                _lastUsed = null;
              },
              child: Container(
                height: 32,
                alignment: Alignment.center,
                child: Text('默认颜色', style: text.bodyMedium),
              ),
            ),
          ),
          SizedBox(height: Tokens.spaceMd),
          // 用 Wrap 而非 GridView(shrinkWrap)：MenuAnchor 内部用
          // IntrinsicWidth 测菜单宽度，viewport 不支持 intrinsic 测量
          // （崩 "RenderShrinkWrappingViewport does not support
          // returning intrinsic dimensions"）。色块定尺寸后 Wrap 的
          // 视觉与网格完全一致。
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: <Widget>[
              for (final Color color in _palette)
                InkWell(
                  onTap: () {
                    _menu.close();
                    _apply(color);
                  },
                  borderRadius: BorderRadius.circular(Tokens.spaceXxs),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(Tokens.spaceXxs),
                      border: selected == color
                          ? Border.all(color: scheme.primary, width: 2)
                          : Border.all(color: scheme.outlineVariant),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 上色前确保光标已在正文（toggledStyle 依赖它）。
  void _ensureFocus() {
    final FocusNode? focus = widget.contentFocus;
    if (focus != null && !focus.hasFocus) {
      focus.requestFocus();
    }
  }

  /// 主按钮点击（Word 式语义）：
  ///
  /// - **背景高亮是开关**：选区已带高亮 → 再点一次移除；未带 → 施加
  ///   当前生效色并记忆（再点移除，再选色板换色）。
  /// - **字体颜色是取值不是开关**：再点重复施加同一颜色（无变化）；
  ///   清除只能走色板「默认颜色」——与 Word/WPS 一致。
  void _apply(Color color) {
    _ensureFocus();
    if (widget.isBackground) {
      final Map<String, Attribute> attrs =
          widget.controller.getSelectionStyle().attributes;
      final bool highlighted =
          attrs.containsKey(Attribute.background.key);
      if (highlighted) {
        // 主按钮的生效色优先取选区现有色，走到这里必然同色 → 取消。
        // _lastUsed 不动：再点一次可原色重刷。
        widget.controller.formatSelection(const BackgroundAttribute(null));
        return;
      }
    }
    final String hex = _toHex(color);
    widget.controller.formatSelection(
      widget.isBackground ? BackgroundAttribute(hex) : ColorAttribute(hex),
    );
    _lastUsed = color;
  }
}

/// 样式选择器：M3 Menus 组件（MenuAnchor + MenuItemButton）——
/// 触发钮显示当前样式名 + 下拉箭头（飞书同形态）；
/// 菜单项用真实文字样式预览，当前项高亮 + 打勾。
class _StylePicker extends StatefulWidget {
  const _StylePicker({required this.controller, this.contentFocus});

  final QuillController controller;

  /// 正文焦点：施加样式前确保光标已在正文。
  final FocusNode? contentFocus;

  @override
  State<_StylePicker> createState() => _StylePickerState();
}

class _StylePickerState extends State<_StylePicker> {
  final MenuController _menu = MenuController();
  final ValueNotifier<bool> _hover = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _hover.dispose();
    super.dispose();
  }

  /// 当前 header 级别：null = 正文。
  int? get _level {
    final Map<String, Attribute> attrs =
        widget.controller.getSelectionStyle().attributes;
    final Object? value = attrs[Attribute.header.key]?.value;
    return value is int && value > 0 ? value : null;
  }

  String get _label => switch (_level) {
        1 => '标题 1',
        2 => '标题 2',
        3 => '标题 3',
        _ => '正文',
      };

  void _apply(int? level) {
    final FocusNode? focus = widget.contentFocus;
    if (focus != null && !focus.hasFocus) {
      focus.requestFocus();
    }
    final Map<String, Attribute> attrs =
        widget.controller.getSelectionStyle().attributes;
    final Attribute? current = attrs[Attribute.header.key];
    // 不能写 header:0——Quill 渲染 level 0 会抛 Invalid level 0；
    // 清除标题的正确做法是把属性置 null。块级属性切换不重抢键盘焦点。
    if (level == null) {
      if (current != null) {
        widget.controller
          ..skipRequestKeyboard = true
          ..formatSelection(Attribute.clone(current, null));
      }
      return;
    }
    if (current?.value == level) return;
    final Attribute header = switch (level) {
      1 => Attribute.h1,
      2 => Attribute.h2,
      _ => Attribute.h3,
    };
    widget.controller
      ..skipRequestKeyboard = true
      ..formatSelection(header);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return MenuAnchor(
      controller: _menu,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
        elevation: const WidgetStatePropertyAll(3),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: Tokens.spaceXs),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(148, 0)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Tokens.radiusMd),
          ),
        ),
      ),
      menuChildren: <Widget>[
        _item(scheme, '正文', null, textTheme.bodyMedium),
        _item(
          scheme,
          '标题 1',
          1,
          textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        _item(
          scheme,
          '标题 2',
          2,
          textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        _item(
          scheme,
          '标题 3',
          3,
          textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
      builder: (BuildContext context, MenuController controller, Widget? _) {
        return Tooltip(
          message: '样式（Ctrl+1/2/3）',
          child: MouseRegion(
            onEnter: (_) {
              _hover.value = true;
            },
            onExit: (_) => _hover.value = false,
            child: GestureDetector(
              // 开/关切换：点按钮本身也能收起菜单（点外部关闭之外
              // 的第二条关闭路径）。MenuController 只有 open/close，
              // 按 isOpen 手动 toggle。
              onTap: () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                }
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Tokens.radiusSm),
                child: ValueListenableBuilder<bool>(
                  valueListenable: _hover,
                  builder: (context, hovered, _) => Container(
                    height: Tokens.formatButtonHeight,
                    padding: const EdgeInsets.symmetric(
                      horizontal: Tokens.spaceXs,
                    ),
                    color: hovered
                        ? scheme.surfaceContainerHighest
                        : Colors.transparent,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          _label,
                          style: textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurface),
                        ),
                        const SizedBox(width: Tokens.spaceXxs),
                        Icon(
                          LucideIcons.chevronDown,
                          size: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _item(
    ColorScheme scheme,
    String label,
    int? level,
    TextStyle? style,
  ) {
    final bool checked = _level == level;
    return MenuItemButton(
      onPressed: () {
        _apply(level);
        _menu.close();
      },
      style: MenuItemButton.styleFrom(
        minimumSize: const Size(148, 40),
        maximumSize: const Size(148, 40),
        backgroundColor:
            checked ? scheme.secondaryContainer : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
      ),
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: style?.copyWith(
              color: checked ? scheme.primary : scheme.onSurface,
            ),
          ),
          const Spacer(),
          if (checked) Icon(_I.check, size: 14, color: scheme.primary),
        ],
      ),
    );
  }
}
