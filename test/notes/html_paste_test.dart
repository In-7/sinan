import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/clipboard/clipboard_html.dart';
import 'package:sinan/src/notes/services/editor_image_paste.dart';

/// 富文本粘贴（2026-11-22）：从网页/Word 复制的内容按 sinan 的块模型还原。
///
/// 关键约定：**结构照搬、样式自己长**——标题/列表/引用/代码/表格/加粗/链接
/// 保留；字体、字号、行高、颜色一律丢弃（`enableColorParse = false`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  EditorState buildState({String text = '正文'}) => EditorState(
    document: Document(
      root: pageNode(children: <Node>[paragraphNode(text: text)]),
    ),
  );

  group('CF_HTML 剥壳（平台原始数据 → HTML 片段）', () {
    test('带 StartFragment/EndFragment 标记：只取片段，丢掉键值头', () {
      const String raw = 'Version:0.9\r\n'
          'StartHTML:0000000105\r\n'
          'EndHTML:0000000234\r\n'
          'StartFragment:0000000141\r\n'
          'EndFragment:0000000198\r\n'
          '<html><body><!--StartFragment--><h1>标题</h1><!--EndFragment--></body></html>';
      expect(extractCfHtmlFragment(raw), '<h1>标题</h1>');
    });

    test('没有 fragment 标记：从 <html 截断，绝不把 Version: 当正文', () {
      const String raw = 'Version:0.9\r\nStartHTML:0000000105\r\n'
          '<html><body><p>正文</p></body></html>';
      final String? out = extractCfHtmlFragment(raw);
      expect(out, isNotNull);
      expect(out!.startsWith('<html'), isTrue);
      expect(out.contains('Version:'), isFalse);
    });

    test('空 / 认不出的数据 ⇒ null（当作没有富文本）', () {
      expect(extractCfHtmlFragment(''), isNull);
      expect(extractCfHtmlFragment('   '), isNull);
      expect(extractCfHtmlFragment('Version:0.9\r\nStartHTML:1\r\n'), isNull);
    });
  });

  group('HTML → sinan 块模型（结构照搬、样式丢弃）', () {
    setUp(() => DocumentHTMLDecoder.enableColorParse = false);

    test('h1 / ul / blockquote 映射为对应块类型（每个 li 一个列表块）', () {
      final Document doc = htmlToDocument(
        '<h1>一级标题</h1>'
        '<ul><li>要点一</li><li>要点二</li></ul>'
        '<blockquote>引用</blockquote>',
      );
      final List<Node> nodes = doc.root.children;
      expect(nodes[0].type, HeadingBlockKeys.type);
      expect(nodes[0].attributes[HeadingBlockKeys.level], 1);
      // 官方把每个 <li> 解析成一个独立的 bulleted_list 块（不是一层容器）。
      expect(nodes[1].type, BulletedListBlockKeys.type);
      expect(nodes[2].type, BulletedListBlockKeys.type);
      expect(nodes[3].type, QuoteBlockKeys.type);
    });

    test('official decoder 不认 <pre>（会丢内容）⇒ 归一化降级成段落', () {
      // 先钉住上游行为：裸 <pre> 解析出 0 个节点（内容被丢弃）。
      expect(htmlToDocument('<pre>code()</pre>').root.children, isEmpty,
          reason: '官方 decoder 无 code 块解析器，<pre> 会被丢弃');

      // 归一化后文字保住（降级为段落 + 行内 code 样式）。
      final Document doc = htmlToDocument(
        normalizeHtmlForPaste('<pre><code>code()</code></pre>'),
      );
      final List<Node> nodes = doc.root.children;
      expect(nodes, isNotEmpty, reason: '归一化后不该丢内容');
      expect(nodes.first.delta?.toPlainText(), 'code()');
    });

    test('strong / a[href] 保留为行内属性', () {
      final Document doc = htmlToDocument(
        '<p>前<strong>加粗</strong>后<a href="https://a.com">链接</a></p>',
      );
      final List<Map<String, dynamic>> ops = _opsOf(doc);
      final bool hasBold = ops.any(
        (Map<String, dynamic> op) =>
            _attrsOf(op)?[AppFlowyRichTextKeys.bold] == true,
      );
      final bool hasHref = ops.any(
        (Map<String, dynamic> op) =>
            _attrsOf(op)?[AppFlowyRichTextKeys.href] != null,
      );
      expect(hasBold, isTrue, reason: '加粗应保留');
      expect(hasHref, isTrue, reason: '链接应保留');
    });

    test('外部颜色被丢弃（按 sinan 自己的排版渲染）', () {
      final Document doc = htmlToDocument(
        '<p><span style="color: rgb(255,0,0)">红字</span></p>',
      );
      final List<Map<String, dynamic>> ops = _opsOf(doc);
      final bool anyColor = ops.any(
        (Map<String, dynamic> op) =>
            _attrsOf(op)?[AppFlowyRichTextKeys.textColor] != null,
      );
      expect(anyColor, isFalse, reason: 'enableColorParse=false 时不该带入外部颜色');
    });
  });

  group('粘贴插入行为', () {
    test('多块 HTML：标题与列表按块插入，光标块保留', () async {
      final EditorState state = buildState(text: '原来的段落');
      state.selection = Selection.collapsed(Position(path: <int>[0]));
      final bool ok = await pasteHtmlText(
        state,
        '<h2>小节</h2><ul><li>一</li></ul>',
      );
      expect(ok, isTrue);
      final List<Node> nodes = state.document.root.children;
      expect(nodes.any((Node n) => n.type == HeadingBlockKeys.type), isTrue);
      expect(
        nodes.any((Node n) => n.type == BulletedListBlockKeys.type),
        isTrue,
      );
    });

    test('单个段落：合并进光标处，不新起块', () async {
      final EditorState state = buildState(text: '前半');
      state.selection = Selection.collapsed(
        Position(path: <int>[0], offset: 2),
      );
      final bool ok = await pasteHtmlText(state, '<p>插入</p>');
      expect(ok, isTrue);
      expect(state.document.root.children.length, 1, reason: '不该新增块');
      expect(
        state.document.root.children.first.delta?.toPlainText(),
        '前半插入',
      );
    });

    test('空 HTML / 只有空段落 ⇒ false（不破坏现有内容）', () async {
      final EditorState state = buildState(text: '内容');
      state.selection = Selection.collapsed(Position(path: <int>[0]));
      expect(await pasteHtmlText(state, ''), isFalse);
      expect(await pasteHtmlText(state, '<p></p>'), isFalse);
      expect(
        state.document.root.children.first.delta?.toPlainText(),
        '内容',
        reason: '失败时不该动原文',
      );
    });
  });
}

/// 取第一个块的 delta JSON（类型化，避免 avoid_dynamic_calls）。
List<Map<String, dynamic>> _opsOf(Document doc) =>
    doc.root.children.first.delta!.toJson().cast<Map<String, dynamic>>();

/// 取某个 delta op 的 attributes（没有则为 null）。
Map<dynamic, dynamic>? _attrsOf(Map<String, dynamic> op) {
  final Object? attrs = op['attributes'];
  return attrs is Map ? attrs : null;
}
