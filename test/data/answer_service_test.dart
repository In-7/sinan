import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/ai/llm_client.dart';
import 'package:sinan/src/data/answer_service.dart';
import 'package:sinan/src/data/database.dart';
import 'package:sinan/src/data/index_job.dart';
import 'package:sinan/src/data/retriever.dart';
import 'package:sqlite3/sqlite3.dart';

/// 假 LLM：返回预置答案，并记录收到的提示词（问答层只关心"编号 ↔ block"，
/// 生成质量属于模型侧，不该在单测里断言）。
class _FakeLlm implements LlmClient {
  _FakeLlm({this.reply = '答案 [1]', this.unavailable = false});

  final String reply;
  final bool unavailable;
  final List<({String system, String user})> calls =
      <({String system, String user})>[];

  @override
  Future<String> complete({
    required String system,
    required String user,
    Map<String, Object?>? schema,
  }) async {
    calls.add((system: system, user: user));
    if (unavailable) throw const LlmUnavailableException('连不上模型服务（测试）');
    return reply;
  }
}

void main() {
  Database openMigrated() {
    final Database db = sqlite3.openInMemory();
    addTearDown(db.close);
    AppDatabase.migrateForTesting(db);
    db.execute('PRAGMA foreign_keys = ON;');
    return db;
  }

  void insertNote(Database db, String id, String title) {
    db.execute(
      'INSERT INTO notes (id, kind, title, content, content_hash, plain_text, '
      "created_at, revised_at) VALUES (?, 'note', ?, '', 'fp1:0:0', '', 1, 1)",
      <Object?>[id, title],
    );
  }

  void insertBlock(Database db, String id, String noteId, String text) {
    db.execute(
      'INSERT INTO blocks (id, note_id, type, props_json, ord, created_at, '
      'updated_at, fingerprint) VALUES (?, ?, ?, ?, 0, 1, 1, ?)',
      <Object?>[
        id,
        noteId,
        'paragraph',
        jsonEncode(<String, Object?>{'text': text}),
        'fp1:$id',
      ],
    );
  }

  /// 两个含"番茄"的块（只建关键词路，够了：问答层不关心召回细节）。
  Future<Retriever> buildRetriever(Database db) async {
    insertNote(db, 'n1', '种植笔记');
    insertBlock(db, 'b1', 'n1', '番茄要搭架子');
    insertBlock(db, 'b2', 'n1', '番茄喜光');
    insertBlock(db, 'b3', 'n1', '黄瓜要爬藤');
    await IndexJob(db: db).run(onProgress: (IndexProgress _) {});
    return Retriever(db: db);
  }

  group('纯函数', () {
    test('buildUserPrompt：编号从 1 起、与命中顺序一一对应、提问在最后', () {
      final String prompt = AnswerService.buildUserPrompt('问题？', <RetrievalHit>[
        (
          blockId: 'b1',
          noteId: 'n1',
          snippet: '第一段',
          score: 1,
          fromKeyword: true,
          fromVector: false,
        ),
        (
          blockId: 'b2',
          noteId: 'n1',
          snippet: '第二\n段',
          score: 0.5,
          fromKeyword: true,
          fromVector: false,
        ),
      ]);
      expect(prompt, contains('[1] 第一段'));
      // 摘要里的换行压成单行，保住"一行一条"的结构。
      expect(prompt, contains('[2] 第二 段'));
      expect(prompt.trimRight().endsWith('问题？'), isTrue);
    });

    test('systemPrompt 明确要求编号引用（引用还原的前提）', () {
      expect(AnswerService.systemPrompt, contains('[1]'));
      expect(AnswerService.systemPrompt, contains('编号'));
    });

    test('parseCitationIndexes：按出现顺序抽取（不去重，去重在 ask）；只认 [数字]', () {
      expect(AnswerService.parseCitationIndexes('A [1] B [3][1] C'), <int>[
        1,
        3,
        1,
      ]);
      expect(AnswerService.parseCitationIndexes('没有引用'), isEmpty);
      // 宁可漏认也不能错认：这些一律不认。
      expect(AnswerService.parseCitationIndexes('【1】 (2) [a] [1,2]'), isEmpty);
    });
  });

  group('问答（真检索 + 假 LLM）', () {
    test('引用编号还原成正确的块（一一对应，不是让模型吐 id）', () async {
      final Database db = openMigrated();
      final Retriever retriever = await buildRetriever(db);
      final List<RetrievalHit> hits = (await retriever.search(
        '番茄',
        limit: 5,
      )).hits;
      expect(hits.length, greaterThanOrEqualTo(2), reason: '本用例需要至少两条资料');

      final _FakeLlm llm = _FakeLlm(reply: '结论 [1]，补充 [2]。');
      final Answer answer = await AnswerService(
        retriever: retriever,
        llm: llm,
      ).ask('番茄怎么种？');

      expect(answer.citations, hasLength(2));
      expect(answer.citations[0].index, 1);
      expect(
        answer.citations[0].blockId,
        hits[0].blockId,
        reason: '编号 1 必须指回 prompt 里第 1 条资料的那个块',
      );
      expect(answer.citations[1].blockId, hits[1].blockId);
      expect(answer.citations[0].noteId, 'n1');
      expect(answer.unknownCitations, isEmpty);

      // prompt 里确实带了资料（不是空手问模型）。
      expect(llm.calls.single.user, contains('[1]'));
      expect(llm.calls.single.user, contains(hits[0].snippet));
    });

    test('模型编出越界编号：不进引用、单独记录（绝不指错块）', () async {
      final Database db = openMigrated();
      final Retriever retriever = await buildRetriever(db);
      final _FakeLlm llm = _FakeLlm(reply: '看 [1] 和 [99]。');

      final Answer answer = await AnswerService(
        retriever: retriever,
        llm: llm,
      ).ask('番茄');

      expect(answer.citations, hasLength(1));
      expect(answer.unknownCitations, <int>[99]);
    });

    test('重复引用同一编号只留一条', () async {
      final Database db = openMigrated();
      final Retriever retriever = await buildRetriever(db);
      final Answer answer = await AnswerService(
        retriever: retriever,
        llm: _FakeLlm(reply: '先说 [1]，再强调 [1]。'),
      ).ask('番茄');
      expect(answer.citations, hasLength(1));
    });

    test('一条资料都没检索到 ⇒ 不调模型，直接说明没有相关内容', () async {
      final Database db = openMigrated();
      final Retriever retriever = await buildRetriever(db);
      final _FakeLlm llm = _FakeLlm();

      final Answer answer = await AnswerService(
        retriever: retriever,
        llm: llm,
      ).ask('量子纠缠');

      expect(llm.calls, isEmpty, reason: '没资料还问模型 = 请它编');
      expect(answer.text, contains('没有相关内容'));
      expect(answer.citations, isEmpty);
    });

    test('降级信息透传（语义路缺席要能传到 UI）', () async {
      final Database db = openMigrated();
      final Retriever retriever = await buildRetriever(db);
      final Answer answer = await AnswerService(
        retriever: retriever,
        llm: _FakeLlm(),
      ).ask('番茄');
      expect(answer.vectorUsed, isFalse);
      expect(answer.vectorFallbackReason, isNotNull);
    });

    test('模型不可达 ⇒ 异常继续往上传（由 UI 给可操作提示）', () async {
      final Database db = openMigrated();
      final Retriever retriever = await buildRetriever(db);
      expect(
        () => AnswerService(
          retriever: retriever,
          llm: _FakeLlm(unavailable: true),
        ).ask('番茄'),
        throwsA(isA<LlmUnavailableException>()),
      );
    });
  });
}
