import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/markdown/block_serializer.dart';

/// 块树 → Markdown 序列化器（单向导出的纯函数核心）。
///
/// 钉住：块型映射、delta 内联格式不丢、转义不误伤、嵌套缩进、存量回退。
/// ⚠️ ops 用 **Map** 形态（`{'insert': …}`）——与 v2 块树真实格式一致
/// （`NoteDocumentAdapter` 的 `data.delta` 就是 ops 数组）。
void main() {
  int seq = 0;

  Map<String, Object?> node(
    String type,
    Object? data, [
    List<Object?>? children,
  ]) => <String, Object?>{
    'id': 'b${seq++}',
    'type': type,
    // null-aware spread（老语法、无 lint 噪声）：null ⇒ 整个键不出现。
    ...?data == null ? null : <String, Object?>{'data': data},
    ...?children == null ? null : <String, Object?>{'children': children},
  };

  /// 一个 delta op（对齐真实形态：Map，不是 list）。
  Map<String, Object?> ins(String text, [Map<String, Object?>? attrs]) =>
      <String, Object?>{
        'insert': text,
        ...?attrs == null ? null : <String, Object?>{'attributes': attrs},
      };

  /// delta 文本节点的 data。
  Map<String, Object?> deltaOf(List<Object?> ops) =>
      <String, Object?>{'delta': ops};

  String md(Map<String, Object?>? document, {String title = '测试'}) =>
      noteToMarkdown(
        noteId: 'n1',
        title: title,
        createdAt: 0,
        revisedAt: 0,
        document: document,
      );

  Map<String, Object?> page(List<Object?> children) =>
      <String, Object?>{'type': 'page', 'children': children};

  group('块型映射', () {
    test('YAML 头 + H1 + 空标题落「无标题」', () {
      final String out = md(null, title: '');
      expect(out, startsWith('---\nid: n1\n'));
      // 日期只钉格式（TZ 无关）：本地时区输出，测试机在哪个时区都过。
      expect(out, contains(RegExp(r'created: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')));
      expect(out, contains(RegExp(r'updated: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')));
      expect(out, contains('# 无标题'));
      final String out2 = md(null, title: '  我的笔记  ');
      expect(out2, contains('# 我的笔记'));
    });

    test('段落 / 各级标题 / 分割线', () {
      final String out = md(
        page(<Object?>[
          node('heading', deltaOf(<Object?>[ins('一级')])..['level'] = 1),
          node('heading', deltaOf(<Object?>[ins('三级')])..['level'] = 3),
          node('paragraph', deltaOf(<Object?>[ins('正文')])),
          node('divider', null),
        ]),
      );
      expect(out, contains('# 一级'));
      expect(out, contains('### 三级'));
      expect(out, contains('\n正文'));
      expect(out, contains('\n---\n'));
    });

    test('三类列表紧凑相连（项间无空行）、有序一律 1.', () {
      final String out = md(
        page(<Object?>[
          node('bulleted_list', deltaOf(<Object?>[ins('甲')])),
          node('bulleted_list', deltaOf(<Object?>[ins('乙')])),
          node('numbered_list', deltaOf(<Object?>[ins('丙')])),
          node('todo_list', deltaOf(<Object?>[ins('丁')])..['checked'] = true),
        ]),
      );
      expect(out, contains('- 甲\n- 乙\n1. 丙\n- [x] 丁'));
    });

    test('待办未勾选 = [ ]', () {
      final String out = md(
        page(<Object?>[
          node('todo_list', deltaOf(<Object?>[ins('买牛奶')])),
        ]),
      );
      expect(out, contains('- [ ] 买牛奶'));
    });

    test('代码块：语言围栏 + 纯文本不转义', () {
      final String out = md(
        page(<Object?>[
          node(
            'code',
            deltaOf(<Object?>[ins('const a = "*not em*";')])..['language'] = 'dart',
          ),
        ]),
      );
      expect(out, contains('```dart\nconst a = "*not em*";\n```'));
    });

    test('引用块多行每行冠 >', () {
      final String out = md(
        page(<Object?>[
          node('quote', deltaOf(<Object?>[ins('第一行\n第二行')])),
        ]),
      );
      expect(out, contains('> 第一行\n> 第二行'));
    });

    test('图片块 → ![](url)', () {
      final String out = md(
        page(<Object?>[
          node('image', <String, Object?>{'url': 'assets/a.png'}),
        ]),
      );
      expect(out, contains('![](assets/a.png)'));
    });

    test('提示块 → 引用块 + emoji 冠首', () {
      final String out = md(
        page(<Object?>[
          node(
            'callout',
            deltaOf(<Object?>[ins('注意这里')])..['emoji'] = '💡',
          ),
        ]),
      );
      expect(out, contains('> 💡 注意这里'));
    });
  });

  group('delta 内联格式不丢', () {
    test('粗体 / 斜体 / 删除线 / 行内码 / 下划线', () {
      final String out = md(
        page(<Object?>[
          node(
            'paragraph',
            deltaOf(<Object?>[
              ins('粗', <String, Object?>{'bold': true}),
              ins('斜', <String, Object?>{'italic': true}),
              ins('删', <String, Object?>{'strikethrough': true}),
              ins('码', <String, Object?>{'code': true}),
              ins('下', <String, Object?>{'underline': true}),
            ]),
          ),
        ]),
      );
      expect(out, contains('**粗***斜*~~删~~`码`<u>下</u>'));
    });

    test('链接 → [text](href)，可叠粗体', () {
      final String out = md(
        page(<Object?>[
          node(
            'paragraph',
            deltaOf(<Object?>[
              ins('官网', <String, Object?>{
                'href': 'https://example.com',
                'bold': true,
              }),
            ]),
          ),
        ]),
      );
      expect(out, contains('**[官网](https://example.com)**'));
    });

    test('行内码内的星号不转义（码优先）', () {
      final String out = md(
        page(<Object?>[
          node('paragraph', deltaOf(<Object?>[ins('a*b', <String, Object?>{'code': true})])),
        ]),
      );
      expect(out, contains('`a*b`'));
    });

    test(r'公式块 → $$latex$$', () {
      final String out = md(
        page(<Object?>[
          node('formula', <String, Object?>{'formula': 'E=mc^2'}),
        ]),
      );
      expect(out, contains(r'$$E=mc^2$$'));
    });
  });

  group('转义', () {
    test('星号/方括号/反引号处处转义；词内下划线不转义', () {
      final String out = md(
        page(<Object?>[
          node(
            'paragraph',
            deltaOf(<Object?>[ins('a*b[c]`d` snake_case')]),
          ),
        ]),
      );
      expect(out, contains(r'a\*b\[c\]\`d\` snake_case'));
    });

    test('段首 # 与 1. 被防成排版符', () {
      final String out = md(
        page(<Object?>[
          node('paragraph', deltaOf(<Object?>[ins('# 不是标题')])),
          node('paragraph', deltaOf(<Object?>[ins('1. 不是列表')])),
        ]),
      );
      expect(out, contains(r'\# 不是标题'));
      expect(out, contains(r'1\. 不是列表'));
    });
  });

  group('嵌套与回退', () {
    test('子块缩进一级（列表嵌套）', () {
      final String out = md(
        page(<Object?>[
          node('bulleted_list', deltaOf(<Object?>[ins('父')]), <Object?>[
            node('bulleted_list', deltaOf(<Object?>[ins('子')])),
          ]),
        ]),
      );
      expect(out, contains('- 父\n  - 子'));
    });

    test('未知块类型有文本按段落导出（不丢内容）', () {
      final String out = md(
        page(<Object?>[
          node('sub_page', deltaOf(<Object?>[ins('神秘块')])),
        ]),
      );
      expect(out, contains('神秘块'));
    });

    test('无块行的存量笔记 → 纯文本段', () {
      final String out = noteToMarkdown(
        noteId: 'n1',
        title: '老笔记',
        createdAt: 0,
        revisedAt: 0,
        document: null,
        plainFallback: '第一段\n第二段',
      );
      expect(out, contains('# 老笔记'));
      expect(out, contains('第一段\n第二段'));
    });

    test('data 只有 text 键（画布卡片形态）也能导出', () {
      final String out = md(
        page(<Object?>[
          node('paragraph', <String, Object?>{'text': '纯文本块'}),
        ]),
      );
      expect(out, contains('纯文本块'));
    });

    test('附件块：meta 里取到 path 落链接，取不到落占位', () {
      final String withPath = md(
        page(<Object?>[
          node('attachment', <String, Object?>{
            'attachment': '{"name":"报表.pdf","path":"D:/docs/报表.pdf"}',
          }),
        ]),
      );
      expect(withPath, contains('[报表.pdf](D:/docs/报表.pdf)'));
      final String broken = md(
        page(<Object?>[
          node('attachment', <String, Object?>{'attachment': '不是 json'}),
        ]),
      );
      expect(broken, contains('📎 附件'));
    });
  });
}
