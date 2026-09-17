import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/editor/toolbar/link_toolbar_item.dart';

/// 链接条目的纯逻辑回归：**粘贴 URL 自动转链**与**自定义名称**。
///
/// 这两条是官方实现没有的（官方：光标态空转 + 裸域名静默拒绝），
/// 且都不依赖 widget 树，直接对 [EditorState] 断言文档数据。
void main() {
  group('链接：粘贴 URL 自动转链（Notion 式）', () {
    test('选中文字 + 粘贴网址 → 变链接，显示文字不变', () {
      final (EditorState state, Node node) = _stateWith('你好世界');
      state.selection = _selection(0, 4);

      expect(tryPasteAsLink(state, 'baidu.com'), isTrue);
      expect(_hrefOf(node), 'https://baidu.com', reason: '裸域名应补 https://');
      expect(node.delta!.toPlainText(), '你好世界', reason: '显示文字不该被替换');
    });

    test('非网址 / 含空白 / 光标态 → 不接管（交还官方粘贴）', () {
      final (EditorState state, Node node) = _stateWith('你好世界');
      state.selection = _selection(0, 4);

      expect(tryPasteAsLink(state, '普通文字'), isFalse);
      // 含空白的句子里的网址不能把整句误判成链接。
      expect(tryPasteAsLink(state, '看这个 baidu.com 很好'), isFalse);

      state.selection = Selection.collapsed(Position(path: <int>[0], offset: 2));
      expect(tryPasteAsLink(state, 'baidu.com'), isFalse);

      expect(_hrefOf(node), isNull, reason: '以上都不该写入 href');
      expect(node.delta!.toPlainText(), '你好世界');
    });
  });

  group('链接：自定义名称', () {
    test('名称与选中文字不同 → 连文字一起替换并加链', () {
      final (EditorState state, Node node) = _stateWith('你好世界');
      state.selection = _selection(0, 4);

      applyLink(
        state,
        state.selection!,
        url: 'https://baidu.com',
        displayText: '百度',
      );

      expect(node.delta!.toPlainText(), '百度');
      expect(_hrefOf(node), 'https://baidu.com');
    });

    test('名称留空（有选区）→ 保留原文字，只打 href', () {
      final (EditorState state, Node node) = _stateWith('你好世界');
      state.selection = _selection(0, 4);

      applyLink(state, state.selection!, url: 'https://baidu.com');

      expect(node.delta!.toPlainText(), '你好世界');
      expect(_hrefOf(node), 'https://baidu.com');
    });

    test('光标态：名称留空则插入网址文本并加链（官方此处空转）', () {
      final (EditorState state, Node node) = _stateWith('');
      state.selection = Selection.collapsed(Position(path: <int>[0]));

      applyLink(state, state.selection!, url: 'https://baidu.com');

      expect(node.delta!.toPlainText(), 'https://baidu.com');
      expect(_hrefOf(node), 'https://baidu.com');
    });

    test('光标态：给了名称则插入名称并加链', () {
      final (EditorState state, Node node) = _stateWith('');
      state.selection = Selection.collapsed(Position(path: <int>[0]));

      applyLink(
        state,
        state.selection!,
        url: 'https://baidu.com',
        displayText: '百度',
      );

      expect(node.delta!.toPlainText(), '百度');
      expect(_hrefOf(node), 'https://baidu.com');
    });
  });
}

/// 建一个单段落文档的编辑器状态，返回状态与首块（便于断言 delta）。
(EditorState, Node) _stateWith(String text) {
  final Document document = Document(
    root: pageNode(children: <Node>[paragraphNode(text: text)]),
  );
  final EditorState state = EditorState(document: document);
  addTearDown(state.dispose);
  return (state, document.root.children.first);
}

Selection _selection(int start, int end) => Selection(
  start: Position(path: <int>[0], offset: start),
  end: Position(path: <int>[0], offset: end),
);

/// 取首个带 attributes 的文本 op 里的 href（没有则 null）。
String? _hrefOf(Node node) {
  for (final Object? op in node.delta?.toJson() ?? const <Object?>[]) {
    if (op is Map) {
      final Object? attributes = op['attributes'];
      if (attributes is Map && attributes['href'] != null) {
        return attributes['href'] as String?;
      }
    }
  }
  return null;
}
