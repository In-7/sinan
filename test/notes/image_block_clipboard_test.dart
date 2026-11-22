import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/editor/keys/image_block_clipboard.dart';

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

  test('剪切图片块 → 删源 → Ctrl+V 还原', () async {
    final EditorState state = buildState();
    selectImage(state);
    expect(sinanImageCutCommand.handler(state), KeyEventResult.handled);
    expect(images(state), isEmpty, reason: '剪切应删源图片块');

    select(state, Selection.collapsed(Position(path: [0], offset: 4)));
    expect(sinanImagePasteCommand.handler(state), KeyEventResult.handled);
    expect(images(state).length, 1, reason: '粘贴应还原图片块');
  });

  test('文本块不接管：copy/cut/paste 命令返回 ignored', () async {
    final EditorState state = buildState();
    select(state, Selection.collapsed(Position(path: [0], offset: 2)));
    expect(sinanImageCopyCommand.handler(state), KeyEventResult.ignored);
    expect(sinanImageCutCommand.handler(state), KeyEventResult.ignored);
    expect(sinanImagePasteCommand.handler(state), KeyEventResult.ignored);
  });
}
