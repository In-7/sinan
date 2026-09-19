import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/ai/llm_client.dart';
import 'package:sinan/src/canvas/ai/ai_run.dart';
import 'package:sinan/src/canvas/kernel/canvas_document.dart';
import 'package:sinan/src/canvas/kernel/canvas_item.dart';

/// 全链路（A5，2026-09-19）：**上下文 → 模型 → 解析 → 净化 → 应用**。
///
/// 用一个假的 [LlmClient] 就能把整条链路跑通，不必起 Ollama —— 这正是把
/// [runCanvasAi] 抽成独立函数（而不是写进 widget）的回报。
///
/// 用例覆盖三类关键行为：
/// ① 正常一轮：模型说要什么，画布上就出现什么，且**一条撤销命令**；
/// ② 修复重试：模型先吐脏包装，重试一次后成功；
/// ③ 后端问题原样抛（宿主才知道怎么提示），而"解析不出来"不抛（只是没听懂）。
void main() {
  const Rect viewport = Rect.fromLTWH(0, 0, 1000, 800);

  String? blockTextOf(String blockId) => switch (blockId) {
    'blk-1' => '番茄工作法',
    'blk-2' => '间隔重复',
    _ => null,
  };

  test('正常一轮：摆两块 + 连线，落地成引用卡片与连线', () async {
    final CanvasDocument doc = CanvasDocument();
    final _FakeLlm llm = _FakeLlm(<String>[
      '{"actions":['
          '{"op":"reference_block","blockId":"blk-1","at":[0.3,0.3]},'
          '{"op":"reference_block","blockId":"blk-2","at":[0.7,0.3]},'
          '{"op":"connect","from":"blk-1","to":"blk-2"}'
          ']}',
    ]);

    final AiRunOutcome outcome = await runCanvasAi(
      llm: llm,
      document: doc,
      viewportWorld: viewport,
      instruction: '把这两块摆上来并连起来',
      candidateBlocks: const <String, String>{
        'blk-1': '「学习法」番茄工作法',
        'blk-2': '「学习法」间隔重复',
      },
      blockTextOf: blockTextOf,
    );

    expect(outcome.applied, 3);
    expect(outcome.created, hasLength(2));
    expect(doc.items, hasLength(2));
    expect(doc.edges, hasLength(1));
    expect((doc.items.first as CardItem).text, '番茄工作法');
    expect(llm.calls, 1, reason: '一次就解出来了，不该重试');
  });

  test('**整轮只产生一条撤销命令**（用户按一次 Ctrl+Z 全回滚）', () async {
    final CanvasDocument doc = CanvasDocument();
    final _FakeLlm llm = _FakeLlm(<String>[
      '{"actions":['
          '{"op":"add_shape","kind":"ellipse","rect":[0.1,0.1,0.3,0.3]},'
          '{"op":"add_shape","kind":"rectangle","rect":[0.4,0.1,0.6,0.3]}'
          ']}',
    ]);

    await runCanvasAi(
      llm: llm,
      document: doc,
      viewportWorld: viewport,
      instruction: '加两个形状',
      blockTextOf: blockTextOf,
    );

    expect(doc.items, hasLength(2));
    doc.undo();
    expect(doc.items, isEmpty);
    expect(doc.canUndo, isFalse, reason: '整批一条命令，不该还剩历史');
  });

  test('模型先吐脏包装 ⇒ 自动修复重试一次后成功', () async {
    final CanvasDocument doc = CanvasDocument();
    final _FakeLlm llm = _FakeLlm(<String>[
      '好的，我来帮你：\n```json\n{"actions":[{"op":"delete","ids":["item-1"]}]}\n```', // 围栏：能剥
      '这次也用不上',
    ]);
    // 第一条其实能解出来（围栏可剥），所以这里验证的是"不该白白重试"。
    await runCanvasAi(
      llm: llm,
      document: doc,
      viewportWorld: viewport,
      instruction: 'x',
      blockTextOf: blockTextOf,
    );
    expect(llm.calls, 1);
  });

  test('完全不是 JSON ⇒ 重试一次；再失败则当作"没听懂"（不抛）', () async {
    final CanvasDocument doc = CanvasDocument();
    final _FakeLlm llm = _FakeLlm(<String>['抱歉，我做不到', '还是做不到']);

    final AiRunOutcome outcome = await runCanvasAi(
      llm: llm,
      document: doc,
      viewportWorld: viewport,
      instruction: 'x',
      blockTextOf: blockTextOf,
    );

    expect(llm.calls, 2, reason: '必须重试一次（把坏输出回传）');
    expect(outcome.applied, 0);
    expect(outcome.warnings, isEmpty, reason: '这不是"被忽略"，是"没听懂"');
    expect(
      llm.lastUser,
      contains('抱歉，我做不到'),
      reason: '修复重试要把上一轮的坏输出回传，模型才知道错在哪',
    );
  });

  test('重试后成功 ⇒ 正常落地', () async {
    final CanvasDocument doc = CanvasDocument();
    final _FakeLlm llm = _FakeLlm(<String>[
      '这不是 JSON',
      '{"actions":[{"op":"add_shape","rect":[0.1,0.1,0.2,0.2]}]}',
    ]);

    final AiRunOutcome outcome = await runCanvasAi(
      llm: llm,
      document: doc,
      viewportWorld: viewport,
      instruction: '加个形状',
      blockTextOf: blockTextOf,
    );

    expect(llm.calls, 2);
    expect(outcome.applied, 1);
  });

  test('后端不可达 ⇒ 原样抛出（宿主才知道怎么提示）', () async {
    final CanvasDocument doc = CanvasDocument();
    final _FakeLlm llm = _FakeLlm(<String>[])
      ..error = const LlmUnavailableException('Ollama 没启动');

    await expectLater(
      runCanvasAi(
        llm: llm,
        document: doc,
        viewportWorld: viewport,
        instruction: 'x',
        blockTextOf: blockTextOf,
      ),
      throwsA(isA<LlmUnavailableException>()),
    );
    expect(doc.items, isEmpty);
  });

  test('模型引用了白名单外的块 ⇒ 被净化丢弃，但整批仍然落地', () async {
    final CanvasDocument doc = CanvasDocument();
    final _FakeLlm llm = _FakeLlm(<String>[
      '{"actions":['
          '{"op":"reference_block","blockId":"blk-1","at":[0.3,0.3]},'
          '{"op":"reference_block","blockId":"blk-编的","at":[0.7,0.3]}'
          ']}',
    ]);

    final AiRunOutcome outcome = await runCanvasAi(
      llm: llm,
      document: doc,
      viewportWorld: viewport,
      instruction: '把第一个摆上来',
      candidateBlocks: const <String, String>{'blk-1': '「学习法」番茄工作法'},
      blockTextOf: blockTextOf,
    );

    expect(outcome.applied, 1);
    expect(doc.items, hasLength(1));
    expect(outcome.warnings, hasLength(1));
    expect(outcome.warnings.single, contains('不在可引用范围内'));
  });

  test('视口尺寸未知（Rect.zero）也不崩：坐标会被钳到 0', () async {
    final CanvasDocument doc = CanvasDocument();
    final _FakeLlm llm = _FakeLlm(<String>[
      '{"actions":[{"op":"add_shape","rect":[0.1,0.1,0.2,0.2]}]}',
    ]);

    final AiRunOutcome outcome = await runCanvasAi(
      llm: llm,
      document: doc,
      viewportWorld: Rect.zero,
      instruction: 'x',
      blockTextOf: blockTextOf,
    );

    // 视口为 0 ⇒ 世界矩形也是 0 尺寸；净化层会把退化矩形补到默认比例后仍为 0。
    // 这里只要求"不抛且不产生越界崩溃"——真正的视口在真实链路里由控制器保证。
    expect(outcome.applied, 1);
  });
}

/// 按脚本逐条返回的假后端。
///
/// 比 mock 框架更适合这里：要断言的是"**调用了几次**、每次 user 是什么"
/// （重试逻辑的全部证据），手写一个 20 行的队列最直白。
class _FakeLlm implements LlmClient {
  _FakeLlm(this._replies);

  final List<String> _replies;
  int calls = 0;
  String lastUser = '';
  Object? error;

  @override
  Future<String> complete({
    required String system,
    required String user,
    Map<String, Object?>? schema,
  }) async {
    lastUser = user;
    final Object? failure = error;
    if (failure != null) throw failure;
    // 脚本用完就重复最后一条（多调一次不会炸，便于断言调用次数）。
    final String reply = _replies.isEmpty
        ? '{"actions":[]}'
        : _replies[calls.clamp(0, _replies.length - 1)];
    calls++;
    return reply;
  }
}
