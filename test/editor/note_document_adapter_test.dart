import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/editor/core/note_document_adapter.dart';

/// Phase 1 数据层适配的单元测试：存量 quill Delta → appflowy Document。
/// 这些是纯函数，无需 UI 即可验证——迁移期最有性价比的回归保障。
void main() {
  group('Delta → Document', () {
    test('标题 / 正文 / 行内标记 / 列表 / 图片 / 分隔线 全链路', () {
      final String content = jsonEncode(<String, dynamic>{
        'ops': <dynamic>[
          <String, dynamic>{'insert': '标题一'},
          <String, dynamic>{
            'insert': '\n',
            'attributes': <String, dynamic>{'header': 1},
          },
          <String, dynamic>{'insert': '正文'},
          <String, dynamic>{
            'insert': '加粗',
            'attributes': <String, dynamic>{'bold': true},
          },
          <String, dynamic>{'insert': '\n'},
          <String, dynamic>{'insert': '项目'},
          <String, dynamic>{
            'insert': '\n',
            'attributes': <String, dynamic>{'list': 'bullet'},
          },
          <String, dynamic>{
            'insert': <String, dynamic>{'image': r'C:\media\1.png'},
          },
          <String, dynamic>{'insert': '\n'},
          <String, dynamic>{
            'insert': <String, dynamic>{'hr': ''},
          },
          <String, dynamic>{'insert': '\n'},
        ],
      });

      final Document doc = NoteDocumentAdapter.documentFromStoredContent(
        content,
      );
      final List<String> types = doc.root.children
          .map((Node node) => node.type)
          .toList();

      expect(types, <String>[
        'heading',
        'paragraph',
        'bulleted_list',
        'image',
        'divider',
      ]);

      // 标题级别与文本
      final Node heading = doc.root.children.first;
      expect(heading.attributes['level'], 1);
      expect(heading.delta!.toPlainText(), '标题一');

      // 行内标记：粗体段落里应带 bold 属性
      final Node paragraph = doc.root.children[1];
      expect(
        paragraph.delta!.toJson().any(
              (Object? op) =>
                  op is Map &&
                  (op['attributes'] as Map?)?[AppFlowyRichTextKeys.bold] ==
                      true,
            ),
        isTrue,
      );

      // 图片 URL 保留（appflowy 的键为 ImageBlockKeys.url = 'url'）
      final Node image = doc.root.children[3];
      expect(image.attributes[ImageBlockKeys.url], r'C:\media\1.png');
    });

    test('待办列表（checked / unchecked）', () {
      final String content = jsonEncode(<String, dynamic>{
        'ops': <dynamic>[
          <String, dynamic>{'insert': '已完成'},
          <String, dynamic>{
            'insert': '\n',
            'attributes': <String, dynamic>{'list': 'checked'},
          },
          <String, dynamic>{'insert': '未完成'},
          <String, dynamic>{
            'insert': '\n',
            'attributes': <String, dynamic>{'list': 'unchecked'},
          },
        ],
      });

      final Document doc = NoteDocumentAdapter.documentFromStoredContent(
        content,
      );
      expect(doc.root.children.length, 2);
      expect(doc.root.children[0].type, 'todo_list');
      expect(doc.root.children[0].attributes['checked'], isTrue);
      expect(doc.root.children[1].attributes['checked'], isFalse);
    });

    test('公式与附件 → 自定义节点（待 Phase 4 注册块组件）', () {
      final String content = jsonEncode(<String, dynamic>{
        'ops': <dynamic>[
          <String, dynamic>{
            'insert': <String, dynamic>{'formula': r'E=mc^2'},
          },
          <String, dynamic>{'insert': '\n'},
          <String, dynamic>{
            'insert': <String, dynamic>{'attachment': '{"name":"a.pdf"}'},
          },
          <String, dynamic>{'insert': '\n'},
        ],
      });

      final Document doc = NoteDocumentAdapter.documentFromStoredContent(
        content,
      );
      expect(doc.root.children[0].type, 'formula');
      expect(doc.root.children[0].attributes['latex'], r'E=mc^2');
      expect(doc.root.children[1].type, 'attachment');
      expect(doc.root.children[1].attributes['meta'], '{"name":"a.pdf"}');
    });
  });

  group('格式识别与往返', () {
    test('空内容 → 空文档（不抛）', () {
      expect(
        NoteDocumentAdapter.documentFromStoredContent(null).root.children,
        isNotEmpty,
      );
      expect(
        NoteDocumentAdapter.documentFromStoredContent('   ').root.children,
        isNotEmpty,
      );
    });

    test('脏数据 → 兜底空文档（不抛，内容仍在库中）', () {
      final Document doc = NoteDocumentAdapter.documentFromStoredContent(
        '{ this is not json',
      );
      expect(doc.root.children, isNotEmpty);
    });

    test('新格式往返：Document → 字符串 → Document', () {
      final Document original = Document.blank(withInitialText: true);
      final String stored = NoteDocumentAdapter.storedContentFromDocument(
        original,
      );
      final Document back = NoteDocumentAdapter.documentFromStoredContent(
        stored,
      );
      expect(back.root.children.length, original.root.children.length);
    });

    test('落库格式为 v2 块树（format=blocks），结构照抄 appflowy 原生', () {
      final Document document = NoteDocumentAdapter.documentFromStoredContent(
        jsonEncode(<String, dynamic>{
          'ops': <dynamic>[
            <String, dynamic>{'insert': '你好'},
            <String, dynamic>{'insert': '\n'},
          ],
        }),
      );
      final Map<String, dynamic> stored =
          jsonDecode(NoteDocumentAdapter.storedContentFromDocument(document))
              as Map<String, dynamic>;
      expect(stored['v'], 2);
      expect(stored['format'], 'blocks');
      // 不再是 Delta
      expect(stored.containsKey('ops'), isFalse);

      final Map<String, dynamic> doc =
          stored['document'] as Map<String, dynamic>;
      // 根节点是 page（appflowy 的 Document.blank 亦然；写成 document 会整页空白）
      expect(doc['type'], 'page');
      // 结构键与 appflowy 原生一致：type / data / children，另加 id
      final Map<String, dynamic> block =
          (doc['children'] as List<dynamic>).first as Map<String, dynamic>;
      expect(block['type'], 'paragraph');
      expect(block['data'], isA<Map<String, dynamic>>());
      expect(block['id'], isA<String>());
      expect((block['id'] as String).isNotEmpty, isTrue);
    });

    test('块 id 持久化：往返后 id 不变（AI 增量索引 / 块级引用的锚点）', () {
      final Document original = Document.blank(withInitialText: true);
      final String originalId = original.root.children.first.id;
      final Document back = NoteDocumentAdapter.documentFromStoredContent(
        NoteDocumentAdapter.storedContentFromDocument(original),
      );
      expect(back.root.children.first.id, originalId);
    });

    test('appflowy 原生 JSON（无 id）可读，现场补发且互不重复', () {
      final String native = jsonEncode(<String, dynamic>{
        'document': <String, dynamic>{
          'type': 'document',
          'children': <dynamic>[
            <String, dynamic>{
              'type': 'paragraph',
              'data': <String, dynamic>{
                'delta': <dynamic>[
                  <String, dynamic>{'insert': '原生一'},
                ],
              },
            },
            <String, dynamic>{
              'type': 'paragraph',
              'data': <String, dynamic>{
                'delta': <dynamic>[
                  <String, dynamic>{'insert': '原生二'},
                ],
              },
            },
          ],
        },
      });
      final Document doc = NoteDocumentAdapter.documentFromStoredContent(native);
      expect(doc.root.children.length, 2);
      final Set<String> ids = doc.root.children.map((Node n) => n.id).toSet();
      expect(ids.length, 2);
    });

    test('根节点必须是 page（写成 document 会让编辑器整页空白）', () {
      // ① 存量 Delta 读入路径
      final Document fromDelta = NoteDocumentAdapter.documentFromStoredContent(
        jsonEncode(<String, dynamic>{
          'ops': <dynamic>[
            <String, dynamic>{'insert': '你好'},
            <String, dynamic>{'insert': '\n'},
          ],
        }),
      );
      expect(fromDelta.root.type, 'page');

      // ② 块树路径：根被写成非 page（脏数据/历史数据）→ 读取时归一化
      final String dirtyRoot = jsonEncode(<String, dynamic>{
        'v': 2,
        'format': 'blocks',
        'document': <String, dynamic>{
          'id': 'r1',
          'type': 'document',
          'children': <dynamic>[
            <String, dynamic>{
              'id': 'b1',
              'type': 'paragraph',
              'data': <String, dynamic>{
                'delta': <dynamic>[
                  <String, dynamic>{'insert': '内容'},
                ],
              },
            },
          ],
        },
      });
      final Document normalized = NoteDocumentAdapter.documentFromStoredContent(
        dirtyRoot,
      );
      expect(normalized.root.type, 'page');
      expect(normalized.root.children.length, 1);

      // ③ 往返：块树写→读，根类型稳定为 page
      final Document back = NoteDocumentAdapter.documentFromStoredContent(
        NoteDocumentAdapter.storedContentFromDocument(fromDelta),
      );
      expect(back.root.type, 'page');
    });

    test('块 id 重复（脏数据）→ 去重，文档仍完整', () {
      Map<String, dynamic> block(String text) => <String, dynamic>{
            'id': 'dup',
            'type': 'paragraph',
            'data': <String, dynamic>{
              'delta': <dynamic>[
                <String, dynamic>{'insert': text},
              ],
            },
          };
      final String dirty = jsonEncode(<String, dynamic>{
        'v': 2,
        'format': 'blocks',
        'document': <String, dynamic>{
          'id': 'root',
          'type': 'document',
          'children': <dynamic>[block('a'), block('b')],
        },
      });
      final Document doc = NoteDocumentAdapter.documentFromStoredContent(dirty);
      expect(doc.root.children.length, 2);
      expect(doc.root.children[0].id, 'dup');
      expect(doc.root.children[1].id, isNot('dup'));
    });

    test('语义往返：块类型 / 行内标记 / 嵌入全部保留', () {
      final String content = jsonEncode(<String, dynamic>{
        'ops': <dynamic>[
          <String, dynamic>{'insert': '标题'},
          <String, dynamic>{
            'insert': '\n',
            'attributes': <String, dynamic>{'header': 2},
          },
          <String, dynamic>{'insert': '加粗'},
          <String, dynamic>{
            'insert': '链接',
            'attributes': <String, dynamic>{
              'bold': true,
              'link': 'https://example.com',
            },
          },
          <String, dynamic>{'insert': '\n'},
          <String, dynamic>{'insert': '待办项'},
          <String, dynamic>{
            'insert': '\n',
            'attributes': <String, dynamic>{'list': 'checked'},
          },
          <String, dynamic>{
            'insert': <String, dynamic>{'image': '/media/a.png'},
          },
          <String, dynamic>{'insert': '\n'},
          <String, dynamic>{
            'insert': <String, dynamic>{'hr': ''},
          },
          <String, dynamic>{'insert': '\n'},
          <String, dynamic>{
            'insert': <String, dynamic>{'formula': r'a^2+b^2'},
          },
          <String, dynamic>{'insert': '\n'},
        ],
      });

      // 存量 Delta → Document → Delta → Document：语义应完全一致。
      final Document first = NoteDocumentAdapter.documentFromStoredContent(
        content,
      );
      final String roundTripped = NoteDocumentAdapter.storedContentFromDocument(
        first,
      );
      final Document second = NoteDocumentAdapter.documentFromStoredContent(
        roundTripped,
      );

      List<String> types(Document d) =>
          d.root.children.map((Node n) => n.type).toList();
      expect(types(second), types(first));
      expect(second.root.children[0].attributes['level'], 2);

      // 块 id 全程不变：往返不产生新身份（AI 索引的锚点稳定性）。
      List<String> ids(Document d) =>
          d.root.children.map((Node n) => n.id).toList();
      expect(ids(second), ids(first));

      final Node todo = second.root.children.firstWhere(
        (Node n) => n.type == 'todo_list',
      );
      expect(todo.attributes['checked'], isTrue);

      // 行内标记与嵌入仍在
      final String text = second.root.children
          .map((Node n) => n.delta?.toPlainText() ?? '')
          .join('\n');
      expect(text, contains('链接'));
      expect(
        second.root.children.any((Node n) => n.type == 'image'),
        isTrue,
      );
      expect(
        second.root.children.any((Node n) => n.type == 'divider'),
        isTrue,
      );
      final Node formula = second.root.children.firstWhere(
        (Node n) => n.type == 'formula',
      );
      expect(formula.attributes['latex'], r'a^2+b^2');
    });
  });

  group('读入保真度：align / indent / 行内颜色', () {
    test('align 同名同值透传（含 quill 独有的 justify，不丢数据）', () {
      final Document doc = NoteDocumentAdapter.documentFromStoredContent(
        jsonEncode(<String, dynamic>{
          'ops': <dynamic>[
            ..._line('居中', align: 'center'),
            ..._line('右对齐', align: 'right'),
            // quill 独有的两端对齐：官方 align mixin 不认，但原值必须保住
            ..._line('两端', align: 'justify'),
          ],
        }),
      );
      expect(doc.root.children[0].attributes[blockComponentAlign], 'center');
      expect(doc.root.children[1].attributes[blockComponentAlign], 'right');
      expect(doc.root.children[2].attributes[blockComponentAlign], 'justify');
    });

    test('indent → 嵌套 children（同级连续缩进挂同一个父节点）', () {
      final Document doc = NoteDocumentAdapter.documentFromStoredContent(
        jsonEncode(<String, dynamic>{
          'ops': <dynamic>[
            ..._line('一级'),
            ..._line('二级 A', indent: 1),
            ..._line('二级 B', indent: 1),
            ..._line('回到一级'),
          ],
        }),
      );

      expect(doc.root.children.length, 2, reason: '顶层应只剩两条');
      final Node first = doc.root.children[0];
      expect(first.delta!.toPlainText(), '一级');
      expect(first.children.length, 2, reason: '两条缩进行应是它的子节点');
      expect(first.children[0].delta!.toPlainText(), '二级 A');
      expect(first.children[1].delta!.toPlainText(), '二级 B');
      expect(doc.root.children[1].delta!.toPlainText(), '回到一级');
    });

    test('三级缩进逐层嵌套', () {
      final Document doc = NoteDocumentAdapter.documentFromStoredContent(
        jsonEncode(<String, dynamic>{
          'ops': <dynamic>[
            ..._line('A'),
            ..._line('B', indent: 1),
            ..._line('C', indent: 2),
          ],
        }),
      );
      final Node a = doc.root.children.single;
      final Node b = a.children.single;
      final Node c = b.children.single;
      expect(a.delta!.toPlainText(), 'A');
      expect(b.delta!.toPlainText(), 'B');
      expect(c.delta!.toPlainText(), 'C');
    });

    test('缩进跳级（0 → 2）挂到可用的最深父节点，不丢内容', () {
      final Document doc = NoteDocumentAdapter.documentFromStoredContent(
        jsonEncode(<String, dynamic>{
          'ops': <dynamic>[
            ..._line('一级'),
            ..._line('跳级', indent: 2),
          ],
        }),
      );
      final Node first = doc.root.children.single;
      expect(first.children.single.delta!.toPlainText(), '跳级');
    });

    test('行内字体颜色 / 背景高亮 1:1 透传（hex 格式两边一致）', () {
      final Document doc = NoteDocumentAdapter.documentFromStoredContent(
        jsonEncode(<String, dynamic>{
          'ops': <dynamic>[
            <String, dynamic>{
              'insert': '彩色',
              'attributes': <String, dynamic>{
                'color': '#FF0000',
                'background': '#80FFFF00',
              },
            },
            <String, dynamic>{'insert': '\n'},
          ],
        }),
      );
      final Map<String, dynamic> attrs =
          ((doc.root.children.first.delta!.toJson().first as Map)['attributes']
                  as Map)
              .cast<String, dynamic>();
      expect(attrs[AppFlowyRichTextKeys.textColor], '#FF0000');
      expect(attrs[AppFlowyRichTextKeys.backgroundColor], '#80FFFF00');
    });
  });
}

/// 构造一行 Delta（可带 align / indent 等行级属性）。
List<Map<String, dynamic>> _line(
  String text, {
  String? align,
  int? indent,
}) => <Map<String, dynamic>>[
  <String, dynamic>{'insert': text},
  <String, dynamic>{
    'insert': '\n',
    if (align != null || indent != null)
      'attributes': <String, dynamic>{
        'align': ?align,
        'indent': ?indent,
      },
  },
];
