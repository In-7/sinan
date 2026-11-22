import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/clipboard/block_clipboard_transport.dart';
import 'package:sinan/src/clipboard/clipboard_codec.dart';
import 'package:sinan/src/editor/keys/block_clipboard.dart';

/// 块级复制 / 剪切 / 粘贴（2026-11-22 从"仅图片"泛化到任意块）：
/// 整块选区 → 块剪贴板（系统自定义格式）；部分选区 → 官方纯文本。
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

  /// 选中整个图片块（cover 块天然是整块 0..1）。
  void selectImage(EditorState state) => select(
    state,
    Selection(
      start: Position(path: [1]),
      end: Position(path: [1], offset: 1),
    ),
  );

  /// 选中整段文字（起点 0、终点到 delta 末尾）。
  void selectWholeParagraph(EditorState state, int index) {
    final Node node = state.document.root.children[index];
    select(
      state,
      Selection(
        start: Position(path: [index]),
        end: Position(path: [index], offset: node.delta?.length ?? 0),
      ),
    );
  }

  List<Node> images(EditorState state) => state.document.root.children
      .where((Node n) => n.type == ImageBlockKeys.type)
      .toList();

  // 测试不碰真实系统剪贴板：注入"不支持"传输 ⇒ 只走内存回落。
  setUp(() {
    BlockClipboard.transport = const UnsupportedClipboardTransport();
    BlockClipboard.clear();
  });
  tearDown(BlockClipboard.clear);

  test('块剪贴板 copy/take 生成新 id，多次粘贴互不污染', () {
    final Node image = imageNode(url: img, width: 400, height: 200);
    BlockClipboard.copy(<Node>[image], cut: false);
    expect(BlockClipboard.hasContent, isTrue);
    final List<Node> first = BlockClipboard.takeForPaste();
    final List<Node> second = BlockClipboard.takeForPaste();
    expect(first.single.id, isNot(image.id));
    expect(first.single.id, isNot(second.single.id));
    expect(first.single.attributes[ImageBlockKeys.url], img);
  });

  test('整块选区判定：图片块 / 整段文字 true，部分选区与光标 false', () {
    final EditorState state = buildState();

    // 图片块（cover，0..1）。
    selectImage(state);
    expect(isWholeBlockSelection(state), isTrue);

    // 整段文字：0 .. delta.length。
    selectWholeParagraph(state, 0);
    expect(isWholeBlockSelection(state), isTrue);

    // 只选中间几个字 ⇒ 不是整块（应交给官方做纯文本复制）。
    select(
      state,
      Selection(
        start: Position(path: <int>[0], offset: 1),
        end: Position(path: <int>[0], offset: 2),
      ),
    );
    expect(isWholeBlockSelection(state), isFalse);

    // 折叠光标。
    select(state, Selection.collapsed(Position(path: <int>[0], offset: 2)));
    expect(isWholeBlockSelection(state), isFalse);
  });

  test('复制图片块 → Ctrl+V 插入新块（同 url、无副本）', () {
    final EditorState state = buildState();
    selectImage(state);
    expect(sinanBlockCopyCommand.handler(state), KeyEventResult.handled);
    expect(BlockClipboard.hasContent, isTrue);

    final int before = state.document.root.children.length;
    expect(sinanBlockPasteCommand.handler(state), KeyEventResult.handled);
    expect(state.document.root.children.length, before + 1);
    expect(images(state).length, 2);
    expect(images(state).last.attributes[ImageBlockKeys.url], img,
        reason: '粘贴块应指向同一图片文件，不落新副本');
  });

  test('整段文字也能块级复制（泛化后）：标题粘回来仍是标题', () {
    final EditorState state = EditorState(
      document: Document(
        root: pageNode(children: <Node>[
          headingNode(level: 1, text: '一级标题'),
          paragraphNode(text: '正文'),
        ]),
      ),
    );
    selectWholeParagraph(state, 0);
    expect(sinanBlockCopyCommand.handler(state), KeyEventResult.handled,
        reason: '整段标题应走块剪贴板（不是纯文本）');

    // 光标放到正文块末尾再粘贴。
    select(state, Selection.collapsed(Position(path: <int>[1], offset: 2)));
    expect(sinanBlockPasteCommand.handler(state), KeyEventResult.handled);

    final List<Node> headings = state.document.root.children
        .where((Node n) => n.type == HeadingBlockKeys.type)
        .toList();
    expect(headings.length, 2, reason: '粘贴应还原成标题块，而不是普通段落');
  });

  test('剪切整块 → 删源 → 选区落回存在的块 → Ctrl+V 还原', () {
    final EditorState state = buildState();
    selectWholeParagraph(state, 0);
    expect(sinanBlockCutCommand.handler(state), KeyEventResult.handled);

    // 剪切后选区不能悬空（否则后续粘贴/菜单判块全废）。
    final Selection? sel = state.selection;
    expect(sel, isNotNull, reason: '剪切后应重设选区');
    expect(
      state.getNodeAtPath(sel!.end.path),
      isNotNull,
      reason: '选区必须落在仍存在的块上（不能指向已删块）',
    );

    expect(sinanBlockPasteCommand.handler(state), KeyEventResult.handled);
    expect(
      state.document.root.children
          .where((Node n) => n.delta?.toPlainText() == '段落一')
          .length,
      1,
      reason: '粘贴应还原被剪切的段落',
    );
  });

  test('部分选区不接管：copy/cut 返回 ignored 且清空块剪贴板', () {
    final EditorState state = buildState();
    selectImage(state);
    expect(sinanBlockCopyCommand.handler(state), KeyEventResult.handled);
    expect(BlockClipboard.hasContent, isTrue);

    // 只选一句话的几个字按 Ctrl+C ⇒ 交回官方纯文本，且必须清掉块剪贴板。
    select(
      state,
      Selection(
        start: Position(path: <int>[0]),
        end: Position(path: <int>[0], offset: 1),
      ),
    );
    expect(sinanBlockCopyCommand.handler(state), KeyEventResult.ignored);
    expect(BlockClipboard.hasContent, isFalse,
        reason: '部分选区复制应清空块剪贴板，避免污染粘贴');

    // 剪切同理。
    selectImage(state);
    expect(sinanBlockCopyCommand.handler(state), KeyEventResult.handled);
    select(
      state,
      Selection(
        start: Position(path: <int>[2]),
        end: Position(path: <int>[2], offset: 1),
      ),
    );
    expect(sinanBlockCutCommand.handler(state), KeyEventResult.ignored);
    expect(BlockClipboard.hasContent, isFalse);

    // 无内容时粘贴回退（ignored）。
    expect(sinanBlockPasteCommand.handler(state), KeyEventResult.ignored);
  });

  test('粘贴落点越界不崩（光标在末尾块）', () {
    final EditorState state = buildState();
    selectImage(state);
    expect(sinanBlockCopyCommand.handler(state), KeyEventResult.handled);

    // 光标放到最后一个块末尾 —— end.path.next 会越过 children.length。
    final int last = state.document.root.children.length - 1;
    select(state, Selection.collapsed(Position(path: <int>[last], offset: 1)));
    expect(sinanBlockPasteCommand.handler(state), KeyEventResult.handled);
    expect(images(state).length, 2, reason: '越界落点应夹到文档末尾插成功');
  });

  group('ClipboardCodec（逻辑层协议）', () {
    test('encode → decode 往返保持类型/属性', () {
      final List<Node> nodes = <Node>[
        imageNode(url: img, width: 320, height: 180),
      ];
      final List<Node>? back = ClipboardCodec.decode(
        ClipboardCodec.encode(nodes),
      );
      expect(back, isNotNull);
      expect(back!.single.type, ImageBlockKeys.type);
      expect(back.single.attributes[ImageBlockKeys.url], img);
      expect(back.single.attributes[ImageBlockKeys.width], 320);
    });

    test('版本不匹配 / 损坏 JSON / 空数组 ⇒ null（当没有数据）', () {
      expect(ClipboardCodec.decode('{"v":999,"nodes":[]}'), isNull);
      expect(ClipboardCodec.decode('not-json'), isNull);
      expect(ClipboardCodec.decode('{"v":1,"nodes":[]}'), isNull);
    });

    test('明文兜底：图片只留文件名，不泄漏目录', () {
      final String text = ClipboardCodec.plainTextOf(<Node>[
        imageNode(url: 'D:/secret/dir/pic.png'),
      ]);
      expect(text, 'pic.png');
      expect(text.contains('secret'), isFalse);
    });

    test('只有单张本地图才附带位图路径', () {
      expect(
        ClipboardCodec.singleLocalImagePath(<Node>[imageNode(url: img)]),
        img,
      );
      expect(
        ClipboardCodec.singleLocalImagePath(<Node>[
          imageNode(url: img),
          imageNode(url: img),
        ]),
        isNull,
        reason: '多张图不放位图（剪贴板只挂得下一张）',
      );
      expect(
        ClipboardCodec.singleLocalImagePath(<Node>[
          imageNode(url: 'https://example.com/a.png'),
        ]),
        isNull,
        reason: '网络图不下载，不挂位图',
      );
    });
  });

  group('系统剪贴板通道（假 transport）', () {
    test('copy 写系统剪贴板；refresh 能从系统回填（模拟重启后粘贴）', () async {
      final _FakeTransport fake = _FakeTransport();
      BlockClipboard.transport = fake;
      BlockClipboard.clear();

      BlockClipboard.copy(
        <Node>[imageNode(url: img, width: 320, height: 180)],
        cut: false,
      );
      await Future<void>.delayed(Duration.zero);
      expect(fake.written, isNotNull, reason: 'copy 应写系统剪贴板');
      expect(fake.written!.plainText, 'pic.png');
      expect(fake.written!.imageFilePath, img);

      // 模拟重启：内存清空，只剩系统剪贴板。
      BlockClipboard.clear();
      expect(BlockClipboard.hasContent, isFalse);

      await BlockClipboard.refresh();
      expect(BlockClipboard.hasContent, isTrue, reason: 'refresh 应从系统剪贴板回填');
      expect(BlockClipboard.takeForPaste().single.type, ImageBlockKeys.type);
    });

    test('系统剪贴板被外部覆盖 ⇒ refresh 清空缓存（不粘旧内容）', () async {
      final _FakeTransport fake = _FakeTransport();
      BlockClipboard.transport = fake;
      BlockClipboard.copy(<Node>[imageNode(url: img)], cut: false);
      await Future<void>.delayed(Duration.zero);

      fake.payload = null; // 外部复制了别的东西
      await BlockClipboard.refresh();
      expect(BlockClipboard.hasContent, isFalse,
          reason: '外部复制后不应再粘出旧块');
    });
  });
}

class _FakeTransport implements BlockClipboardTransport {
  String? payload;
  _Write? written;

  @override
  bool get isSupported => true;

  @override
  Future<bool> write({
    required String payload,
    required String plainText,
    String? imageFilePath,
  }) async {
    this.payload = payload;
    written = _Write(
      payload: payload,
      plainText: plainText,
      imageFilePath: imageFilePath,
    );
    return true;
  }

  @override
  Future<String?> read() async => payload;
}

class _Write {
  const _Write({
    required this.payload,
    required this.plainText,
    required this.imageFilePath,
  });

  final String payload;
  final String plainText;
  final String? imageFilePath;
}
