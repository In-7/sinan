import 'dart:async';
import 'dart:ui' as ui;

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/app_float_surface.dart';
import '../../theme/tokens.dart';

/// 超链接工具栏条目/?*自研，替换官/?`linkItem`**）/?
///
/// ## 为什么不用官方的（实测两无?静默失败"`?
///    `onlyShowInSingleSelectionAndTextType`�?*不要求非折叠选区**；于�?
///    "光标处加链接"必然�?href 写到一个空区间�?�?回车后毫无反应，
///    连提示都没有（用户实测：`添加链接 按回车什么也没有`）�?
///    连提示都没有（用户实测：`添加链接 按回车什么也没有`）要?
/// 2. **无协议域名被静默拒绝**：官判?`isUri` 要求 TLD 或自定义 scheme—?
///    输入 `baidu.com` 判定不过/?`onSubmitted` 直接 return —/?同样无反馈/?
///
/// ## 自研版的行为
/// - 掉?scheme 自动掉?`https://`（`baidu.com` 掉?`https://baidu.com`）；
/// - 非法输入**就地显示错误**，不再静默吞掉；
/// - **自定义名文?*：菜单是「名文?+ 链接」两个字段（Notion/Word ；?
///   "要显示的文字"），名称与选中文字不同时连文字一起替换；
/// - **粘贴 URL 自动转链**（Notion 式）：选中文字后直；?Ctrl+V 一个网址；?
///   选中文字就地变成该链接（W?[sinanPasteCommand] / [tryPasteAsLink]）；
/// - 光标态（无选区）→ 在光标处**插入名称/网址文本并带上链 ?*（Word 行为）；
/// - 选区已是链接时，菜单里额外给「打开 / 复制 / 移除」（同官方能力）/?
///
/// 菜单浮层的保焦沿用颜t?对齐条目同一套机制（`keepEditorFocusNotifier`）(?
final ToolbarItem sinanLinkItem = ToolbarItem(
  id: 'sinan.link',
  group: 4,
  isActive: onlyShowInSingleSelectionAndTextType,
  builder: (context, editorState, highlightColor, iconColor, tooltipBuilder) {
    final Selection selection = editorState.selection!;
    final List<Node> nodes = editorState.getNodesInSelection(selection);
    final bool isHref = nodes.allSatisfyInSelection(
      selection,
      (Delta delta) => delta.everyAttributes(
        (Attributes attributes) =>
            attributes[AppFlowyRichTextKeys.href] != null,
      ),
    );
    final String? currentHref = isHref
        ? editorState.getDeltaAttributeValueInSelection(
            AppFlowyRichTextKeys.href,
            selection,
          )
        : null;

    final Widget child = _SinanLinkButton(
      editorState: editorState,
      selection: selection,
      currentHref: currentHref,
      isHref: isHref,
      iconColor: iconColor,
      highlightColor: highlightColor,
    );
    if (tooltipBuilder != null) {
      return tooltipBuilder(context, 'sinan.link', '链接', child);
    }
    return child;
  },
);

/// 归一化输/?/?可用/?URL；非法返/?null（调用方据此报错）/?
///
/// 规则（比官方 `isUri` 宽容一档，覆盖"粘贴裸域必?这个最常见的输入）h?
/// - `scheme://...`：显式带授权段，必须；?host；?
/// - `mailto:` / `file:`：原样放行；
/// - 其余（含 `baidu.com`、`localhost:8080`）：�?`https://`，host 需�?`.`
///   或是 localhost/?
///
/// ⚠️ `localhost:8080` 这种"主机:端口"**不能**当成 scheme——判�?scheme �?
/// 会走"必须n?host"那条而失败（踩过）。故只有 `://` 才算显式 scheme{?
String? normalizeLinkInput(String raw) {
  final String text = raw.trim();
  if (text.isEmpty) return null;
  // URL 里不含字面空白（含空白的必然是句子，�?看这�?x.com 很好"）—�""?
  // 拦在这里，粘贴转链才不会把整句话误判成网址;?
  if (RegExp(r'\s').hasMatch(text)) return null;

  final RegExp authorityPattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');
  if (authorityPattern.hasMatch(text)) {
    final Uri? uri = Uri.tryParse(text);
    return (uri != null && uri.host.isNotEmpty) ? text : null;
  }

  final String lower = text.toLowerCase();
  if (lower.startsWith('mailto:') || lower.startsWith('file:')) return text;

  final String withScheme = 'https://$text';
  final Uri? uri = Uri.tryParse(withScheme);
  if (uri == null) return null;
  final String host = uri.host;
  if (host == 'localhost' || host.contains('.')) return withScheme;
  return null;
}

/// 给选区（或光标处）加链接；菜单/?粘贴 URL 自动转链"共用这一条实现/?
///
/// - 光标态：在光标处插入文字并带链接（文+?= [displayText]，空则用 URL）；
///   **连同文字一起替�?*（Notion �?自定义名�?）；
/// - 其余情况只打 href（保留原文字与行内样式）�?
/// - 其余情况只打 href（保留原文字与行内样式）(?
void applyLink(
  EditorState editorState,
  Selection selection, {
  required String url,
  String? displayText,
}) {
  final String? name = displayText?.trim();

  if (selection.isCollapsed) {
    final Node? node = editorState.getNodeAtPath(selection.start.path);
    if (node?.delta == null) return;
    final String label = (name != null && name.isNotEmpty) ? name : url;
    unawaited(
      editorState.apply(
        editorState.transaction..insertText(
          node!,
          selection.startIndex,
          label,
          attributes: <String, dynamic>{AppFlowyRichTextKeys.href: url},
        ),
      ),
    );
    return;
  }

  if (name != null && name.isNotEmpty && selection.isSingle) {
    final String current = editorState.getTextInSelection(selection).join('\n');
    if (current != name) {
      final Node? node = editorState.getNodeAtPath(selection.start.path);
      if (node?.delta == null) return;
      unawaited(
        editorState.apply(
          editorState.transaction..replaceText(
            node!,
            selection.startIndex,
            selection.length,
            name,
            attributes: <String, dynamic>{AppFlowyRichTextKeys.href: url},
          ),
        ),
      );
      return;
    }
  }

  unawaited(
    editorState.formatDelta(selection, <String, dynamic>{
      AppFlowyRichTextKeys.href: url,
    }),
  );
}

/// 「选中文字 }?粘贴 URL」自动转链（Notion / Word 行为）}?
///
/// 成功返回 true，调用方据此**不再回退官方粘贴**；返d?false 时应回退/?
/// 拆成同步函数是为了可测（[sinanPasteCommand] 只负责读剪贴板）/?
bool tryPasteAsLink(EditorState editorState, String? clipboardText) {
  final Selection? selection = editorState.selection;
  if (selection == null || selection.isCollapsed) return false;
  final String text = clipboardText?.trim() ?? '';
  final String? url = normalizeLinkInput(text);
  if (url == null) return false;
  // 选中文字保持为显示名（不g?displayText ;?只打 href）;?
  applyLink(editorState, selection, url: url);
  return true;
}

/// Ctrl / Cmd + V}?*优先**}?粘贴 URL 自动转链"处理，否则回退官方粘贴}?
///
/// ⚠️ 必须排在官方 `pasteCommand` **之前**（先命中先赢），并把官方那条/?
/// 标准表里摘掉（见 `note_editor_view_appflowy.dart` 的组装处）/?
final CommandShortcutEvent sinanPasteCommand = CommandShortcutEvent(
  key: 'sinan.paste',
  getDescription: () => '粘贴',
  command: 'ctrl+v',
  macOSCommand: 'cmd+v',
  handler: (EditorState editorState) {
    final Selection? selection = editorState.selection;
    if (selection == null) return KeyEventResult.ignored;
    // 光标态（无选区）：没有"被替换的文字"，交给官方粘贴n?
    if (selection.isCollapsed) return pasteCommand.execute(editorState);

    unawaited(() async {
      final AppFlowyClipboardData data = await AppFlowyClipboard.getData();
      if (!tryPasteAsLink(editorState, data.text)) {
        // 不是网址 t?保持官方粘贴（富文本 / 纯文本）;?
        pasteCommand.execute(editorState);
      }
    }());

    return KeyEventResult.handled;
  },
);

class _SinanLinkButton extends StatefulWidget {
  const _SinanLinkButton({
    required this.editorState,
    required this.selection,
    required this.currentHref,
    required this.isHref,
    required this.iconColor,
    required this.highlightColor,
  });

  final EditorState editorState;
  final Selection selection;
  final String? currentHref;
  final bool isHref;
  final Color? iconColor;
  final Color highlightColor;

  @override
  State<_SinanLinkButton> createState() => _SinanLinkButtonState();
}

class _SinanLinkButtonState extends State<_SinanLinkButton> {
  OverlayEntry? _overlay;

  @override
  void dispose() {
    _dismiss();
    super.dispose();
  }

  void _showOverlay() {
    keepEditorFocusNotifier.increase();
    final RenderBox box = context.findRenderObject()! as RenderBox;
    final Offset offset = box.localToGlobal(Offset.zero);
    final Size size = box.size;

    _overlay = OverlayEntry(
      builder: (BuildContext context) => _LinkOverlay(
        editorState: widget.editorState,
        selection: widget.selection,
        currentHref: widget.currentHref,
        isHref: widget.isHref,
        anchorOffset: offset,
        anchorSize: size,
        onDismiss: _dismiss,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }

  void _dismiss() {
    if (_overlay != null) {
      _overlay!.remove();
      _overlay = null;
      keepEditorFocusNotifier.decrease();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SVGIconItemWidget(
      iconBuilder: (BuildContext context) => tabler.Link(
        height: Tokens.iconSm,
        width: Tokens.iconSm,
        strokeWidth: 1.5,
        colorFilter: ui.ColorFilter.mode(
          widget.iconColor ?? Theme.of(context).colorScheme.onSurfaceVariant,
          ui.BlendMode.srcIn,
        ),
      ),
      isHighlight: widget.isHref,
      highlightColor: widget.highlightColor,
      iconColor: widget.iconColor,
      onPressed: _showOverlay,
    );
  }
}

class _LinkOverlay extends StatefulWidget {
  const _LinkOverlay({
    required this.editorState,
    required this.selection,
    required this.currentHref,
    required this.isHref,
    required this.anchorOffset,
    required this.anchorSize,
    required this.onDismiss,
  });

  final EditorState editorState;
  final Selection selection;
  final String? currentHref;
  final bool isHref;
  final Offset anchorOffset;
  final Size anchorSize;
  final VoidCallback onDismiss;

  @override
  State<_LinkOverlay> createState() => _LinkOverlayState();
}

class _LinkOverlayState extends State<_LinkOverlay> {
  static const double _panelWidth = 300;

  /// 显示名称：有选区时预填选中文字（Notion/Word (?要显示的文字"），
  /// 已是链接时预填原名称=? 选中文字）(?
  late final TextEditingController _nameController = TextEditingController(
    text: _initialName,
  );

  /// 地址：已是链接时预填{?URL，便于就地修改{?
  late final TextEditingController _urlController = TextEditingController(
    text: widget.currentHref ?? '',
  );
  String? _error;

  String get _initialName {
    final Selection selection = widget.selection;
    if (selection.isCollapsed) return '';
    return widget.editorState.getTextInSelection(selection).join('\n');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _submit() {
    final String? url = normalizeLinkInput(_urlController.text);
    if (url == null) {
      // 关键修复：非法输l?*就地报错**，而不是像官方那样静默 return,?
      setState(() => _error = '请输入有效网址，如 example.com');
      return;
    }
    applyLink(
      widget.editorState,
      widget.selection,
      url: url,
      // 名称留空 {?用网址当文字（光标态）/ 保留原选中文字（选区态）{?
      displayText: _nameController.text,
    );
    widget.onDismiss();
  }

  void _removeLink() {
    final Node? node = widget.editorState.getNodeAtPath(
      widget.selection.end.path,
    );
    if (node == null) return;
    final int index = widget.selection.normalized.startIndex;
    final int length = widget.selection.length;
    unawaited(
      widget.editorState.apply(
        widget.editorState.transaction..formatText(
          node,
          index,
          length,
          <String, dynamic>{AppFlowyRichTextKeys.href: null},
        ),
      ),
    );
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double screenWidth = MediaQuery.of(context).size.width;
    final double left =
        (widget.anchorOffset.dx + _panelWidth + Tokens.spaceMd) > screenWidth
        ? screenWidth - _panelWidth - Tokens.spaceMd
        : widget.anchorOffset.dx;

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: .translucent,
            onTap: widget.onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: left,
          top: widget.anchorOffset.dy + widget.anchorSize.height + 4,
          child: AppFloatSurface(
            // 浮层令牌[?026-09-14）：链接面板是弹出浮层，走三件套[?
            child: Padding(
              padding: const EdgeInsets.all(Tokens.spaceMd),
              child: SizedBox(
                width: _panelWidth - Tokens.spaceMd * 2,
                child: Column(
                  mainAxisSize: .min,
                  crossAxisAlignment: .stretch,
                  children: <Widget>[
                    Text(
                      widget.currentHref == null ? '添加链接' : '编辑链接',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: Tokens.spaceSm),
                    TextField(
                      controller: _nameController,
                      autofocus: true,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: '名称',
                        hintText: '留空则用网址',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: Tokens.spaceSm),
                    TextField(
                      controller: _urlController,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      onChanged: (_) {
                        if (_error != null) setState(() => _error = null);
                      },
                      decoration: InputDecoration(
                        labelText: '链接',
                        hintText: 'URL',
                        isDense: true,
                        errorText: _error,
                        suffixIcon: IconButton(
                          tooltip: '清空',
                          icon: const tabler.X(
                            height: Tokens.iconSm,
                            width: Tokens.iconSm,
                            strokeWidth: 1.5,
                          ),
                          onPressed: () => setState(() {
                            _urlController.clear();
                            _error = null;
                          }),
                        ),
                      ),
                    ),
                    const SizedBox(height: Tokens.spaceSm),
                    Row(
                      mainAxisAlignment: .end,
                      children: <Widget>[
                        TextButton(
                          onPressed: widget.onDismiss,
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: Tokens.spaceXs),
                        FilledButton(
                          onPressed: _submit,
                          child: const Text('确定'),
                        ),
                      ],
                    ),
                    if (widget.isHref &&
                        widget.currentHref != null) ...<Widget>[
                      const SizedBox(height: Tokens.spaceXs),
                      const Divider(height: 1),
                      _action(
                        context,
                        icon: const tabler.ExternalLink(
                          height: Tokens.iconSm,
                          width: Tokens.iconSm,
                          strokeWidth: 1.5,
                        ),
                        label: '打开链接',
                        onPressed: () async {
                          await editorLaunchUrl(widget.currentHref);
                          widget.onDismiss();
                        },
                      ),
                      _action(
                        context,
                        icon: const tabler.Copy(
                          height: Tokens.iconSm,
                          width: Tokens.iconSm,
                          strokeWidth: 1.5,
                        ),
                        label: '复制链接',
                        onPressed: () {
                          unawaited(
                            AppFlowyClipboard.setData(text: widget.currentHref),
                          );
                          widget.onDismiss();
                        },
                      ),
                      _action(
                        context,
                        icon: const tabler.Trash(
                          height: Tokens.iconSm,
                          width: Tokens.iconSm,
                          strokeWidth: 1.5,
                        ),
                        label: '移除链接',
                        onPressed: _removeLink,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _action(
    BuildContext context, {
    required Widget icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: icon,
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          padding: const EdgeInsets.symmetric(
            horizontal: Tokens.spaceSm,
            vertical: Tokens.spaceXs,
          ),
        ),
      ),
    );
  }
}
