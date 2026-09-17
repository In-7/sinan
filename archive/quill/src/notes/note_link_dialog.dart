import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../theme/tokens.dart';

/// 链接对话框：官方 LinkDialog 的 M3 自绘版。
///
/// 双输入（显示文本 + URL），提交语义对齐官方 `QuillTextLink.submit`：
/// - 选区已在链接内：范围扩展到整个链接（`getLinkRange`），编辑不残留；
/// - 显示文本与选区原文不同：替换文本再加链接（支持空选区插入新文字）；
/// - URL 缺协议头自动补 `https://`。
/// 选区已带链接时提供「移除链接」（官方同款能力）。
class NoteLinkDialog extends StatefulWidget {
  const NoteLinkDialog({super.key, required this.controller});

  final QuillController controller;

  @override
  State<NoteLinkDialog> createState() => _NoteLinkDialogState();
}

class _NoteLinkDialogState extends State<NoteLinkDialog> {
  late final TextEditingController _text;
  late final TextEditingController _link;

  /// 选区是否已带链接（决定是否显示「移除链接」）。
  bool _hasCurrentLink = false;

  @override
  void initState() {
    super.initState();
    final QuillController controller = widget.controller;
    final Object? currentLink =
        controller.getSelectionStyle().attributes[Attribute.link.key]?.value;
    _hasCurrentLink = currentLink != null;

    final int start = controller.selection.start;
    final int length = controller.selection.end - start;
    // 文本预填：已带链接时用整个链接的文字（官方 prepare 语义），
    // 否则用选区文字；空选区留给用户输入「插入新文字」。
    String text = '';
    if (_hasCurrentLink) {
      final Node? leaf =
          controller.document.querySegmentLeafNode(start).leaf;
      text = leaf?.toPlainText() ?? '';
    } else if (length > 0) {
      text = controller.document.getPlainText(start, length);
    }
    _text = TextEditingController(text: text);
    _link = TextEditingController(text: currentLink as String? ?? '');
  }

  @override
  void dispose() {
    _text.dispose();
    _link.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _text.text.trim().isNotEmpty && _link.text.trim().isNotEmpty;

  void _apply() {
    if (!_canSubmit) return;
    final QuillController controller = widget.controller;
    final String text = _text.text.trim();
    String link = _link.text.trim();
    // 缺协议头自动补 https://（`www.foo.com` 也能成为有效链接）。
    if (!link.contains('://')) {
      link = 'https://$link';
    }

    var index = controller.selection.start;
    var length = controller.selection.end - index;
    // 选区已带链接：扩展到整个链接范围（官方 submit 语义），
    // 只改部分选区时替换整个链接文字，不残留旧链接。
    if (_hasCurrentLink) {
      final Node? leaf =
          controller.document.querySegmentLeafNode(index).leaf;
      if (leaf != null) {
        final TextRange range = getLinkRange(leaf);
        index = range.start;
        length = range.end - range.start;
      }
    }
    controller
      ..replaceText(index, length, text, null)
      ..formatText(index, text.length, LinkAttribute(link));
    Navigator.of(context).pop();
  }

  void _remove() {
    widget.controller.formatSelection(const LinkAttribute(null));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text(
        _hasCurrentLink ? '编辑链接' : '添加链接',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _text,
              autofocus: !_hasCurrentLink,
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
              style: TextStyle(fontSize: 14, color: scheme.onSurface),
              decoration: const InputDecoration(
                labelText: '显示文本',
                hintText: '输入链接显示的文字',
                isDense: true,
              ),
            ),
            const SizedBox(height: Tokens.spaceMd),
            TextField(
              controller: _link,
              autofocus: _hasCurrentLink,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _apply(),
              autocorrect: false,
              style: TextStyle(fontSize: 14, color: scheme.onSurface),
              decoration: const InputDecoration(
                labelText: '链接',
                hintText: 'https://…',
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        if (_hasCurrentLink)
          TextButton(
            onPressed: _remove,
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('移除链接'),
          ),
        FilledButton(
          onPressed: _canSubmit ? _apply : null,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
