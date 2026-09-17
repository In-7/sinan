import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/note_content.dart';
import 'package:sinan/src/editor/core/note_document_adapter.dart';

/// 数据层解耦（quill → appflowy）的第一半：**读入侧不再依赖 flutter_quill**。
///
/// 本文件验证 `NoteContent` 的三件事：
/// 1. 三种存储形态都能识别（v2 块树 / Quill Delta / 历史纯文本）；
/// 2. 纯文本提取走 `NoteDocumentAdapter`（appflowy）——按块分行、字不丢；
/// 3. 给过渡期 quill 的 Delta 输出仍然合法（不空、以换行收尾）；
/// 4. 脏数据永不丢字（最坏情况按纯文本原样保留）。
void main() {
  group('格式识别', () {
    test('裸数组 Delta（quill 写出的形态）→ delta 格式', () {
      final NoteContent c = NoteContent.decode(
        jsonEncode(<dynamic>[
          <String, dynamic>{'insert': '正文'},
          <String, dynamic>{'insert': '\n'},
        ]),
      );
      expect(c.format, NoteContentFormat.delta);
      expect(c.wasRichText, isTrue);
      expect(c.plainText, '正文');
    });

    test('包装形态 {"ops":[...]} → delta 格式', () {
      final NoteContent c = NoteContent.decode(
        jsonEncode(<String, dynamic>{
          'ops': <dynamic>[
            <String, dynamic>{'insert': '包装'},
            <String, dynamic>{'insert': '\n'},
          ],
        }),
      );
      expect(c.format, NoteContentFormat.delta);
      expect(c.plainText, '包装');
    });

    test('v2 块树 → blocks 格式，纯文本按块分行', () {
      final String stored = _blockTreeOf(<Node>[
        headingNode(level: 1, text: '标题'),
        paragraphNode(text: '第一段'),
        paragraphNode(text: '第二段'),
      ]);
      final NoteContent c = NoteContent.decode(stored);

      expect(c.format, NoteContentFormat.blocks);
      expect(c.wasRichText, isTrue);
      expect(c.plainText, '标题\n第一段\n第二段');
    });

    test('历史纯文本 → plainText 格式（无损）', () {
      const String legacy = '一行旧文字\n第二行';
      final NoteContent c = NoteContent.decode(legacy);
      expect(c.format, NoteContentFormat.plainText);
      expect(c.wasRichText, isFalse);
      expect(c.plainText, legacy);
      // 单段 Delta，且以换行收尾（quill 要求）
      expect(c.delta.length, 1);
      expect((c.delta.first as Map<String, dynamic>)['insert'], '$legacy\n');
    });

    test('空内容 → 合法空文档（单个换行）', () {
      final NoteContent c = NoteContent.decode('');
      expect(c.format, NoteContentFormat.plainText);
      expect(c.plainText, '');
      expect((c.delta.first as Map<String, dynamic>)['insert'], '\n');
    });

    test('脏数据（不是 JSON）→ 按纯文本原样保留，绝不丢字', () {
      const String dirty = '{ this is not json';
      final NoteContent c = NoteContent.decode(dirty);
      expect(c.format, NoteContentFormat.plainText);
      expect(c.plainText, dirty);
    });
  });

  group('纯文本提取语义', () {
    test('段落之间换行分隔，不黏成一坨', () {
      final NoteContent c = NoteContent.decode(
        jsonEncode(<dynamic>[
          <String, dynamic>{'insert': '标题'},
          <String, dynamic>{
            'insert': '\n',
            'attributes': <String, dynamic>{'header': 1},
          },
          <String, dynamic>{'insert': '正文'},
          <String, dynamic>{'insert': '\n'},
        ]),
      );
      expect(c.plainText, '标题\n正文');
      expect(c.plainText.contains('标题正文'), isFalse);
    });

    test('无文字的块（图片/分隔线）不占行', () {
      final NoteContent c = NoteContent.decode(
        jsonEncode(<dynamic>[
          <String, dynamic>{
            'insert': <String, dynamic>{'image': r'C:\media\a.png'},
          },
          <String, dynamic>{'insert': '\n'},
          <String, dynamic>{'insert': '图注'},
          <String, dynamic>{'insert': '\n'},
          <String, dynamic>{
            'insert': <String, dynamic>{'hr': ''},
          },
          <String, dynamic>{'insert': '\n'},
        ]),
      );
      expect(c.plainText, '图注');
    });
  });

  group('过渡期 quill 的 Delta 输出', () {
    test('Delta 内容：清洗 header:0（旧版正文按钮写入的非法值）', () {
      final NoteContent c = NoteContent.decode(
        jsonEncode(<dynamic>[
          <String, dynamic>{'insert': '正文'},
          <String, dynamic>{
            'insert': '\n',
            'attributes': <String, dynamic>{'header': 0, 'bold': true},
          },
        ]),
      );
      final Map<String, dynamic> line =
          c.delta.last as Map<String, dynamic>;
      final Map<String, dynamic> attributes =
          line['attributes'] as Map<String, dynamic>;
      expect(attributes.containsKey('header'), isFalse, reason: '非法 header 应被移除');
      expect(attributes['bold'], isTrue, reason: '其他属性必须原样保留');
    });

    test('块树内容在 quill 侧以纯文本兜底（不丢字、不喂非法输入）', () {
      final String stored = _blockTreeOf(<Node>[
        paragraphNode(text: '块树里的字'),
      ]);
      final NoteContent c = NoteContent.decode(stored);
      final String quillText = c.delta
          .map((dynamic op) => (op as Map<String, dynamic>)['insert'])
          .whereType<String>()
          .join();
      expect(quillText.trim(), '块树里的字');
    });
  });
}

/// 用适配器生成一段真实的 v2 块树内容（而不是手写 JSON），
/// 保证测试与落库格式同源。
String _blockTreeOf(List<Node> children) => NoteDocumentAdapter
    .storedContentFromDocument(Document(root: pageNode(children: children)));
