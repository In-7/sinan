import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:file_picker/file_picker.dart';

import '../canvas/kernel/canvas_bundle.dart'
    show encodeCanvasBundle, importCanvasBundleText;
import '../canvas/kernel/canvas_controller.dart';
import '../canvas/kernel/canvas_media.dart' show MediaResolver;
import '../domain/note.dart';
import '../editor/core/note_document_adapter.dart';
import 'providers.dart' show NotesNotifier;

/// 一次拾取的结果：文本 + 文件名（标题要用它）。用户取消 = text 为 null。
typedef ImportPick = ({String? text, String? fileName});

/// 导入结果（2026-10-21）：成功带回新笔记，失败带回一句实话。
///
/// 为什么不抛异常、也不在这里弹提示：调用方在列表头托盘里，手里有
/// `BuildContext`（SnackBar 要它），而 service 层拿不到。返回记录让 UI 自己决定
/// 怎么报，测试也只需断言记录，不必挂 ScaffoldMessenger。
typedef ImportOutcome = ({Note? note, String? error});

/// 标题兜底：取首个非空行、去掉 md 的 `#` 前缀、截到 20 字。
///
/// 与 `NoteStore._titleFromText`（灵感转笔记那条）同口径——同一个产品里
/// "从文本建笔记"的标题规则只有一套。
String importTitleFromText(String text) {
  for (final String raw in text.split('\n')) {
    final String line = raw
        .trim()
        .replaceFirst(RegExp(r'^#+\s*'), '')
        .trim();
    if (line.isEmpty) continue;
    return line.length <= 20 ? line : line.substring(0, 20);
  }
  return '导入的笔记';
}

/// 选一个 **Markdown / 文本**文件并读成文本（用户取消返回 text = null）。
///
/// 支持 `.md` / `.markdown` / `.txt`：后两者按纯文本进同一链路（md 解析器对
/// 无标记文本就是逐行成段）。
Future<ImportPick> pickMarkdownText() async {
  final List<PlatformFile> files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const <String>['md', 'markdown', 'txt'],
  );
  final String? path = files.isEmpty ? null : files.first.path;
  if (path == null) return (text: null, fileName: null);
  return (text: await File(path).readAsString(), fileName: _stemOf(path));
}

/// 选一个 **`.canvas.json`** 并读成文本（用户取消返回 text = null）。
Future<ImportPick> pickCanvasText() async {
  final List<PlatformFile> files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const <String>['json'],
  );
  final String? path = files.isEmpty ? null : files.first.path;
  if (path == null) return (text: null, fileName: null);
  return (text: await File(path).readAsString(), fileName: _stemOf(path));
}

/// 导入 **Markdown / 文本文件**为**新笔记**（2026-10-21 用户定：导入 = 新建）。
///
/// 链路：选文件 → 读文本 → `markdownToDocument`（vendored appflowy 的 md 解析器，
/// 标题 / 列表 / 代码块 / 引用都保结构）→ `storedContentFromDocument`（v2 块树
/// JSON）→ `NotesNotifier.importNote`。**不覆盖当前笔记**。
///
/// [pickText] 可注入（测试用它绕开文件对话框；默认走真实拾取器）。
Future<ImportOutcome> importMarkdownNote(
  NotesNotifier notes, {
  Future<ImportPick> Function()? pickText,
}) async {
  final ImportPick picked = await (pickText ?? pickMarkdownText)();
  final String? text = picked.text;
  if (text == null) return (note: null, error: null); // 用户取消
  if (text.trim().isEmpty) return (note: null, error: '这个文件是空的');

  try {
    // md → appflowy Document → 入库 JSON。
    final Document document = markdownToDocument(text);
    final String content = NoteDocumentAdapter.storedContentFromDocument(
      document,
    );
    final Note note = await notes.importNote(
      kind: NoteKind.note,
      title: importTitleFromText(text),
      content: content,
      plainText: text,
    );
    return (note: note, error: null);
  } on Object catch (e) {
    return (note: null, error: '导入失败：$e');
  }
}

/// 导入 **`.canvas.json`** 为**新画布**（导入 = 新建，不替换当前画布）。
///
/// 链路与笔记导入同构，只换中段：选文件 → `importCanvasBundleText`（把 bundle 里
/// 内联的 base64 媒体**物化回本地**再反序列化成控制器）→ `encodeCanvasBundle`
/// （控制器 → 自包含 bundle，图片重新内联）→ `importNote(kind: canvas)`。
/// 于是一篇导入的画布与"导出的画布"一样可整包带走。
///
/// 与 `CanvasNoteView._import`（画布页里那个"替换当前画布"的导入）**刻意分开**：
/// 那边是覆盖语义、要确认框；这边是新建语义，不需要确认。
Future<ImportOutcome> importCanvasNote(
  NotesNotifier notes, {
  Future<ImportPick> Function()? pickText,
  required MediaResolver media,
}) async {
  final ImportPick picked = await (pickText ?? pickCanvasText)();
  final String? text = picked.text;
  if (text == null) return (note: null, error: null); // 用户取消

  try {
    final CanvasController controller = await importCanvasBundleText(
      text,
      media: media,
    );
    final Map<String, dynamic> bundle = await encodeCanvasBundle(
      controller,
      media: media,
    );
    final Note note = await notes.importNote(
      kind: NoteKind.canvas,
      // 标题 = 文件名去扩展名（画布正文没有"首行"可借）。
      title: (picked.fileName?.trim().isNotEmpty ?? false)
          ? picked.fileName!
          : '导入的画布',
      content: jsonEncode(bundle),
      plainText: '',
    );
    return (note: note, error: null);
  } on Object catch (e) {
    return (note: null, error: '导入失败：$e');
  }
}

/// 路径 → 文件名去扩展名（空则空串）。
String _stemOf(String path) {
  final String name = path.split(RegExp(r'[\\/]')).last;
  if (!name.contains('.')) return name;
  return name.substring(0, name.lastIndexOf('.'));
}
