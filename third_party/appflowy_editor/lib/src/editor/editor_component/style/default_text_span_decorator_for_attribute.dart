import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

/// Support Desktop and Web platform
///   - customize the href text span
TextSpan defaultTextSpanDecoratorForAttribute(
  BuildContext context,
  Node node,
  int index,
  TextInsert text,
  TextSpan before,
  TextSpan after,
) {
  final attributes = text.attributes;
  if (attributes == null) {
    return before;
  }
  final editorState = context.read<EditorState>();
  final href = attributes[AppFlowyRichTextKeys.href] as String?;
  if (href != null) {
    // add a tap gesture recognizer to the text span
    Timer? timer;
    int tapCount = 0;

    final tapGestureRecognizer = TapGestureRecognizer()
      ..onTap = () async {
        // implement a simple double tap logic
        tapCount += 1;
        timer?.cancel();
        // meta / ctrl + click to open the link
        if (tapCount == 2 ||
            !editorState.editable ||
            HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed) {
          tapCount = 0;
          editorLaunchUrl(href);
          return;
        }
        timer = Timer(const Duration(milliseconds: 200), () {
          tapCount = 0;
          final selection = Selection.single(
            path: node.path,
            startOffset: index,
            endOffset: index + text.text.length,
          );
          editorState.updateSelectionWithReason(
            selection,
            reason: SelectionUpdateReason.uiEvent,
            // sinan 补丁 15：这里选中的是**整条链接**、紧接着要弹的是"链接编辑
            // 菜单"，此时不该再让浮动格式工具栏也冒出来（两个浮层会叠在一起，
            // 用户实机反馈："点击链接后浮动工具栏和链接的编辑栏都跳出来"）。
            // 与官方右键 / 查找高亮同一口径——它们都带这个标记。
            extraInfo: {
              selectionExtraInfoDisableToolbar: true,
            },
          );
          WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
            showLinkMenu(context, editorState, selection, true);
          });
        });
      };

    return TextSpan(
      style: before.style,
      text: text.text,
      recognizer: tapGestureRecognizer,
      mouseCursor: SystemMouseCursors.click,
    );
  }
  return before;
}
