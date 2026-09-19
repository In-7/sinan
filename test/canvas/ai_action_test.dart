import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/canvas/ai/ai_action.dart';
import 'package:sinan/src/canvas/ai/ai_prompt.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart'
    show InkPoint, InkStroke, kThemeInk;

/// 模型回复 → 动作列表的解析，以及给模型的上下文文本（A5，2026-09-19）。
///
/// 这两个纯函数是**整个链路最靠不住的一环**（对面是概率模型），所以容错规则要
/// 逐条钉住：脏包装要能剥、坏条目要丢一条而不是丢一批、而"整体不可用"必须与
/// "解析出来但一条都没有"区分开——前者该重试，后者只是模型没想改。
void main() {
  group('AiAction.parseReply：模型回复 → 动作列表', () {
    test('裸 JSON 正常解析', () {
      final List<AiAction>? actions = AiAction.parseReply(
        '{"actions":[{"op":"delete","ids":["item-1"]}]}',
      );
      expect(actions, hasLength(1));
      expect(actions!.single, isA<DeleteAction>());
    });

    test('带 ```json 围栏与前后闲话也能解出来', () {
      final List<AiAction>? actions = AiAction.parseReply(
        '好的，这是结果：\n```json\n{"actions":[{"op":"delete","ids":["item-1"]}]}\n```\n希望有帮助。',
      );
      expect(actions, hasLength(1));
    });

    test('坏条目**丢一条**而不是丢一批', () {
      final List<AiAction>? actions = AiAction.parseReply('''{"actions":[
        {"op":"delete","ids":["item-1"]},
        {"op":"不存在的动作"},
        {"op":"move_item","id":"item-2"},
        {"op":"move_item","id":"item-2","at":[0.5,0.5]}
      ]}''');
      expect(
        actions,
        hasLength(2),
        reason: '未知 op 与缺字段的两条被丢，其余照做',
      );
      expect(actions![0], isA<DeleteAction>());
      expect(actions[1], isA<MoveItemAction>());
    });

    test('非 JSON ⇒ null（与"空结果"区分：这种该重试）', () {
      expect(AiAction.parseReply('抱歉，我做不到'), isNull);
      expect(AiAction.parseReply('<html>502</html>'), isNull);
    });

    test('没有 actions 数组 ⇒ null', () {
      expect(AiAction.parseReply('{"foo":1}'), isNull);
      expect(AiAction.parseReply('{"actions":"不是数组"}'), isNull);
    });

    test('actions 是空数组 ⇒ 空列表（模型没想改，重试也没用）', () {
      expect(AiAction.parseReply('{"actions":[]}'), isEmpty);
    });
  });

  group('extractJsonObject：剥掉模型"答对了但包装不对"的三种脏输出', () {
    test('裸 JSON 原样通过', () {
      expect(extractJsonObject('{"a":1}'), '{"a":1}');
    });

    test('剥掉 ```json 围栏', () {
      expect(extractJsonObject('```json\n{"a":1}\n```'), '{"a":1}');
      expect(extractJsonObject('```\n{"a":1}\n```'), '{"a":1}');
    });

    test('前后带说明文字时抠出对象', () {
      expect(extractJsonObject('好的，这是结果：{"a":1}\n希望有帮助。'), '{"a":1}');
    });

    test('没有对象时原样返回（交给 jsonDecode 去报错）', () {
      expect(extractJsonObject('抱歉，我不能这么做'), '抱歉，我不能这么做');
    });
  });

  group('buildCanvasContext：给模型的上下文', () {
    const Rect viewport = Rect.fromLTWH(0, 0, 1000, 800);

    test('空文档明说"无"，不留空白让模型瞎猜', () {
      final String text = buildCanvasContext(
        CanvasDocument(),
        viewportWorld: viewport,
      );
      expect(text, contains('元素：无'));
      expect(text, contains('连线：无'));
      expect(text, contains('（无）'), reason: '候选块为空时也要明说');
    });

    test('每个元素给 id / 类型 / 摘要 / **归一化**矩形', () {
      final CanvasDocument doc = CanvasDocument()
        ..addItem(
          CardItem(
            rect: const Rect.fromLTWH(100, 80, 300, 240),
            blockId: 'blk-1',
            text: '番茄工作法',
          ),
        );

      final String text = buildCanvasContext(doc, viewportWorld: viewport);

      expect(text, contains('card "番茄工作法"'));
      // fromLTWH(100, 80, 300, 240) ⇒ 右下角是 (400, 320) ⇒ 归一化 0.400。
      // （若谁把"宽高"当成"右下角"写进归一化，这里就会变成 0.300 而被逮住。）
      expect(
        text,
        contains('rect=[0.100, 0.100, 0.400, 0.400]'),
        reason: '归一化口径必须与要求模型输出的口径一致（不换算两次）',
      );
      expect(text, contains('视口：宽 1000 × 高 800'));
    });

    test('形状带 kind，多行文本压成一行（清单不能被文本撑爆）', () {
      final CanvasDocument doc = CanvasDocument()
        ..addItem(
          ShapeItem(
            rect: const Rect.fromLTWH(0, 0, 100, 100),
            kind: CanvasShapeKind.ellipse,
            color: kThemeInk,
          ),
        )
        ..addItem(
          CardItem(
            rect: const Rect.fromLTWH(0, 0, 100, 100),
            blockId: 'blk-1',
            text: '第一行\n第二行\n第三行',
          ),
        );

      final String text = buildCanvasContext(doc, viewportWorld: viewport);
      expect(text, contains('shape:ellipse'));
      expect(text, contains('"第一行 第二行 第三行"'));
    });

    test('笔迹只报条数（没有语义，逐条列只是噪声）', () {
      final CanvasDocument doc = CanvasDocument()
        ..addStroke(
          InkStroke(
            color: kThemeInk,
            baseWidth: 4,
            points: const <InkPoint>[
              InkPoint(Offset(0, 0), 0),
              InkPoint(Offset(10, 0), 0),
            ],
          ),
        );

      final String text = buildCanvasContext(doc, viewportWorld: viewport);
      expect(text, contains('手绘笔迹：1 条'));
    });

    test('候选块逐个列出（模型只能从这里选 blockId）', () {
      final String text = buildCanvasContext(
        CanvasDocument(),
        viewportWorld: viewport,
        candidateBlocks: const <String, String>{
          'blk-7': '"间隔重复"（来自「学习法」）',
        },
      );
      expect(text, contains('blk-7  "间隔重复"'));
    });

    test('视口尺寸未知时不编坐标', () {
      final String text = buildCanvasContext(
        CanvasDocument(),
        viewportWorld: Rect.zero,
      );
      expect(text, contains('视口尺寸未知'));
    });
  });
}
