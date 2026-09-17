import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/editor/core/note_save.dart';

/// 落盘编排的回归（2026-09-17 抽离自编辑器的巨型 State）。
///
/// 钉住两条**业务规则**，它们此前都埋在视图里、只能靠 widget test 间接观察：
/// 1. 长文的 JSON **编码走后台 isolate**，短文同步编码（避免白付 isolate 冷启动）；
/// 2. [NoteSaver.capture] **同步**取好快照 —— 这是 dispose 兜底落盘的前提
///    （编辑器马上销毁，异步阶段只能持有纯值）。
void main() {
  /// 造一个最小 Document（一个段落）。
  Document docWith(String text) =>
      Document(root: pageNode(children: <Node>[paragraphNode(text: text)]));

  group('NoteSavePolicy', () {
    test('阈值是"大于"而非"大于等于"（边界不多绕一次 isolate）', () {
      const NoteSavePolicy policy = NoteSavePolicy(isolateEncodeThreshold: 10);
      expect(policy.shouldEncodeInIsolate('a' * 10), isFalse);
      expect(policy.shouldEncodeInIsolate('a' * 11), isTrue);
    });

    test('默认值：500ms 防抖 / 32K 阈值', () {
      const NoteSavePolicy policy = NoteSavePolicy();
      expect(policy.debounce, const Duration(milliseconds: 500));
      expect(policy.isolateEncodeThreshold, 32 * 1024);
    });
  });

  group('NoteSaver', () {
    test('短文：同步编码，不走 isolate', () async {
      final List<String> contents = <String>[];
      final List<String> plainTexts = <String>[];
      bool isolateUsed = false;

      final NoteSaver saver = NoteSaver(
        save: (String content, {required String plainText}) async {
          contents.add(content);
          plainTexts.add(plainText);
        },
        isolateEncode: (Map<String, Object> json) async {
          isolateUsed = true;
          return 'ISOLATE';
        },
      );

      final NoteSavePayload payload = saver.capture(docWith('hello 世界'));
      expect(payload.plainText, 'hello 世界');

      await saver.write(payload);

      expect(isolateUsed, isFalse);
      expect(contents.single, jsonEncode(payload.json));
      expect(plainTexts.single, 'hello 世界');
    });

    test('长文：编码走注入的 isolate 钩子，写库拿到的是它的结果', () async {
      bool isolateUsed = false;
      String? savedContent;

      final NoteSaver saver = NoteSaver(
        // 阈值压到 3：本用例的正文一定超。
        policy: const NoteSavePolicy(isolateEncodeThreshold: 3),
        save: (String content, {required String plainText}) async {
          savedContent = content;
        },
        isolateEncode: (Map<String, Object> json) async {
          isolateUsed = true;
          // 真·isolate 里也是 jsonEncode，这里替换成可识别的实现即可。
          return jsonEncode(json);
        },
      );

      final NoteSavePayload payload = saver.capture(docWith('一段足够长的中文正文'));
      await saver.write(payload);

      expect(isolateUsed, isTrue, reason: '超过阈值却没走 isolate 编码');
      expect(savedContent, jsonEncode(payload.json));
    });

    test('capture 同步返回快照（类型上就不是 Future）', () {
      final NoteSaver saver = NoteSaver(
        save: (String content, {required String plainText}) async {},
      );
      final NoteSavePayload payload = saver.capture(docWith('x'));
      expect(payload.json, isNotEmpty);
      expect(payload.plainText, 'x');
    });

    test('快照与后续文档改动解耦（异步阶段读的是快照，不是活文档）', () async {
      final NoteSaver saver = NoteSaver(
        save: (String content, {required String plainText}) async {},
      );
      final Document doc = docWith('改之前');
      final NoteSavePayload payload = saver.capture(doc);
      final String jsonBefore = jsonEncode(payload.json);

      // 快照取完后再改文档：落盘用的必须还是老内容。
      doc.insert([0], [paragraphNode(text: '改之后')]);

      expect(jsonEncode(payload.json), jsonBefore);
      expect(payload.plainText, '改之前');
    });
  });
}
