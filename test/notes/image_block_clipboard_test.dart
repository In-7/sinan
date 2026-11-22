import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/editor/keys/image_block_clipboard.dart';
import 'package:sinan/src/editor/widgets/editor_context_menu.dart';

/// 图片块级复制 / 剪切 / 粘贴（飞书/Notion 语义）：
/// 应用内块剪贴板存 Node 快照，粘回来是**新块指向同一文件**，零文件副本。
///
/// 用纯 `EditorState`（无 widget 树）测命令处理器：避开假图源解码、
/// provider 保存 flush、卸载竞态——那些是脚手架噪音，与块剪贴板逻辑无关。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const String img = 'D:/sinan/media/pic.png';

  EditorState buildState() => EditorState(
    document: Document(
      root: pageNode(children: <Node>[
        paragraphNode(text: '段落一'),
        imageNode(url: img, width: 400, height: 200),
        paragraphNode(text: '段落二'),
      ]),
    ),
  );

  void select(EditorState state, Selection selection) =>
      state.selection = selection;

  void selectImage(EditorState state) => select(
    state,
    Selection(
      start: Position(path: [1]),
      end: Position(path: [1], offset: 1),
    ),
  );

  List<Node> images(EditorState state) => state.document.root.children
      .where((Node n) => n.type == ImageBlockKeys.type)
      .toList();

  setUp(ImageBlockClipboard.clear);
  tearDown(ImageBlockClipboard.clear);

  test('块剪贴板 copy/take 生成新 id，多次粘贴互不污染', () {
    final Node image = imageNode(url: img, width: 400, height: 200);
    ImageBlockClipboard.copy(<Node>[image], cut: false);
    expect(ImageBlockClipboard.hasContent, isTrue);
    final List<Node> first = ImageBlockClipboard.takeForPaste();
    final List<Node> second = ImageBlockClipboard.takeForPaste();
    expect(first.single.id, isNot(image.id));
    expect(first.single.id, isNot(second.single.id));
    expect(first.single.attributes[ImageBlockKeys.url], img);
  });

  test('纯图片选区判定：图片块 true / 文本块 false', () async {
    final EditorState state = buildState();
    selectImage(state);
    expect(isImageOnlySelection(state), isTrue);
    select(state, Selection.collapsed(Position(path: [0], offset: 2)));
    expect(isImageOnlySelection(state), isFalse);
  });

  test('复制图片块 → Ctrl+V 插入新块（同 url、无副本）', () async {
    final EditorState state = buildState();
    selectImage(state);
    expect(sinanImageCopyCommand.handler(state), KeyEventResult.handled);
    expect(ImageBlockClipboard.hasContent, isTrue);

    final int before = state.document.root.children.length;
    expect(sinanImagePasteCommand.handler(state), KeyEventResult.handled);
    expect(state.document.root.children.length, before + 1);
    expect(images(state).length, 2);
    expect(images(state).last.attributes[ImageBlockKeys.url], img,
        reason: '粘贴块应指向同一图片文件，不落新副本');
  });

  test('剪切图片块 → 删源 → 选区落回存在的块 → Ctrl+V 还原', () async {
    final EditorState state = buildState();
    selectImage(state);
    expect(sinanImageCutCommand.handler(state), KeyEventResult.handled);
    expect(images(state), isEmpty, reason: '剪切应删源图片块');

    // BUG2：剪切后选区不能悬空（否则后续粘贴/菜单判块全废）。
    final Selection? sel = state.selection;
    expect(sel, isNotNull, reason: '剪切后应重设选区');
    expect(
      state.getNodeAtPath(sel!.end.path),
      isNotNull,
      reason: '选区必须落在仍存在的块上（不能指向已删块）',
    );

    expect(sinanImagePasteCommand.handler(state), KeyEventResult.handled);
    expect(images(state).length, 1, reason: '粘贴应还原图片块');
  });

  test('文本块不接管：copy/cut 返回 ignored 且清空块剪贴板', () async {
    final EditorState state = buildState();
    selectImage(state);
    // 先复制图片块，块剪贴板有内容。
    expect(sinanImageCopyCommand.handler(state), KeyEventResult.handled);
    expect(ImageBlockClipboard.hasContent, isTrue);

    // 再选中文本按 Ctrl+C —— BUG1：必须清掉图片块剪贴板，否则后续 Ctrl+V 粘图片。
    select(state, Selection.collapsed(Position(path: [0], offset: 2)));
    expect(sinanImageCopyCommand.handler(state), KeyEventResult.ignored);
    expect(ImageBlockClipboard.hasContent, isFalse,
        reason: '文本复制应清空图片块剪贴板，避免污染粘贴');

    // 剪切同理。
    selectImage(state);
    expect(sinanImageCopyCommand.handler(state), KeyEventResult.handled);
    select(state, Selection.collapsed(Position(path: [2], offset: 1)));
    expect(sinanImageCutCommand.handler(state), KeyEventResult.ignored);
    expect(ImageBlockClipboard.hasContent, isFalse);

    // 无内容时粘贴回退官方（ignored）。
    expect(sinanImagePasteCommand.handler(state), KeyEventResult.ignored);
  });

  test('粘贴落点越界不崩（光标在末尾块）', () async {
    final EditorState state = buildState();
    selectImage(state);
    expect(sinanImageCopyCommand.handler(state), KeyEventResult.handled);

    // 光标放到最后一个块末尾 —— end.path.next 会越过 children.length。
    final int last = state.document.root.children.length - 1;
    select(state, Selection.collapsed(Position(path: [last], offset: 1)));
    expect(sinanImagePasteCommand.handler(state), KeyEventResult.handled);
    expect(images(state).length, 2, reason: '越界落点应夹到文档末尾插成功');
  });

  test('base64 图片不显示「复制图片」（File(data:) 必然读失败）', () {
    expect(shouldShowCopyImageItem('D:/photos/pic.png'), isTrue);
    expect(shouldShowCopyImageItem('https://example.com/pic.png'), isFalse);
    expect(shouldShowCopyImageItem('data:image/png;base64,iVBORw0KGgo='), isFalse);
    expect(shouldShowCopyImageItem(''), isFalse);
  });
}
