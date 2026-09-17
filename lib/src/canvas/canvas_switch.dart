import 'package:flutter/widgets.dart';

import 'canvas_note_view.dart';

/// 画布笔记视图的**唯一入口**（与 `editor/core/editor_switch.dart` 的
/// [buildNoteEditorView] 对称）：右侧内容区据此挂载画布，而不直接依赖
/// 具体实现类——将来换实现（或加卡片/思维导图变体）只改这里。
Widget buildNoteCanvasView({Key? key, required String noteId}) =>
    CanvasNoteView(key: key, noteId: noteId);
