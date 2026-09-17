import 'package:material_ui/material_ui.dart';

import '../../notes/note_editor_view_appflowy.dart';

// 笔记编辑器的**唯一入口**。
//
// 历史：这里原本是 quill / appflowy 两个视图的开关（`kUseAppFlowyEditor`），
// 两个视图分别按 **Delta** 与 **v2 块树** 落库。2026-09-10 quill 视图退役：
// 源文件整体归档到 `archive/quill/src/notes/`（**保留未删**，恢复步骤见
// `docs/editor_migration_spike.md` 的「quill 归档」一节），依赖也已摘除。
//
// 于是落库格式**只剩块树一种**。存量笔记存的还是 Delta：读入时由
// `NoteDocumentAdapter` 转成块树，编辑保存后即改写为块树——**不可逆**
// （打开不编辑不会动它，判据见 `NoteEditorViewAppFlowy.dispose` 的兜底保存）。
//
// 保留这个函数、而不让调用方直接依赖具体类：将来换实现只改这里。

/// 构造当前笔记编辑器（调用方只依赖它，不关心具体实现）。
Widget buildNoteEditorView({Key? key, required String noteId}) =>
    NoteEditorViewAppFlowy(key: key, noteId: noteId);
