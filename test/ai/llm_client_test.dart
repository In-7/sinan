import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sinan/src/ai/llm_client.dart';

/// LLM 通道的回归（A4，2026-09-19）。
///
/// 分两层测：
/// ① **纯函数**（请求体 / 响应解析 / 抠 JSON）—— 不碰网络，覆盖最容易写错的细节；
/// ② **真起一个本地 HttpServer** —— 证明"请求确实以正确的形状发出去了"、
///    以及三种失败（非 200 / 连不上 / 没配模型）各自给出**可操作**的报错。
void main() {
  group('buildOllamaChatRequest（纯函数）', () {
    test('必须显式关掉 stream（Ollama 默认是 true）', () {
      final Map<String, Object?> body = buildOllamaChatRequest(
        model: 'qwen3.5',
        system: 'sys',
        user: 'usr',
      );
      expect(
        body['stream'],
        isFalse,
        reason: '不显式传 false 拿到的是 NDJSON 流，jsonDecode 会炸',
      );
    });

    test('默认以 "json" 约束输出；传 schema 时原样带上', () {
      expect(
        buildOllamaChatRequest(model: 'm', system: 's', user: 'u')['format'],
        'json',
      );
      const Map<String, Object?> schema = <String, Object?>{
        'type': 'object',
        'required': <String>['actions'],
      };
      expect(
        buildOllamaChatRequest(
          model: 'm',
          system: 's',
          user: 'u',
          format: schema,
        )['format'],
        same(schema),
        reason: '/api/chat 的 format 接受 JSON Schema 对象，这是可靠性的关键',
      );
    });

    test('消息顺序是 system → user（角色反了模型会答偏）', () {
      final Map<String, Object?> body = buildOllamaChatRequest(
        model: 'm',
        system: 'sys',
        user: 'usr',
      );
      final List<Object?> messages = body['messages']! as List<Object?>;
      expect((messages[0]! as Map<String, String>)['role'], 'system');
      expect((messages[0]! as Map<String, String>)['content'], 'sys');
      expect((messages[1]! as Map<String, String>)['role'], 'user');
      expect((messages[1]! as Map<String, String>)['content'], 'usr');
    });
  });

  group('parseOllamaChatReply（纯函数）', () {
    test('取出 message.content', () {
      expect(
        parseOllamaChatReply('{"message":{"role":"assistant","content":"hi"}}'),
        'hi',
      );
    });

    test('空内容视为失败（让调用方走修复重试，而不是把空串当答案）', () {
      expect(
        () => parseOllamaChatReply('{"message":{"content":"  "}}'),
        throwsA(isA<LlmResponseException>()),
      );
    });

    test('不是 JSON / 没有 message ⇒ 明确异常', () {
      expect(
        () => parseOllamaChatReply('<html>502</html>'),
        throwsA(isA<LlmResponseException>()),
      );
      expect(
        () => parseOllamaChatReply('{"done":true}'),
        throwsA(isA<LlmResponseException>()),
      );
    });
  });

  group('端到端（真起本地 HttpServer）', () {
    late HttpServer server;
    final List<Map<String, Object?>> received = <Map<String, Object?>>[];
    int status = 200;
    String responseBody = '';

    String replyWith(String content) => jsonEncode(<String, Object?>{
      'message': <String, Object?>{'role': 'assistant', 'content': content},
    });

    setUp(() async {
      // flutter_test 的 binding 会把 HttpClient 换成"永远返回 400"的假实现，
      // 这里要真发请求 ⇒ 显式清掉 overrides（本文件不初始化 binding，双保险）。
      HttpOverrides.global = null;
      received.clear();
      status = 200;
      responseBody = replyWith('{"actions":[]}');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        final String body = await utf8.decoder.bind(req).join();
        received.add(<String, Object?>{
          'method': req.method,
          'path': req.uri.path,
          'body': jsonDecode(body),
        });
        req.response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..write(responseBody);
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    OllamaLlmClient client({String model = 'qwen3.5'}) => OllamaLlmClient(
      endpoint: 'http://127.0.0.1:${server.port}',
      model: model,
    );

    test('打到 /api/chat，请求体是关掉 stream 的那个形状', () async {
      final String content = await client().complete(
        system: 'sys',
        user: '把这两块连起来',
        schema: const <String, Object?>{'type': 'object'},
      );

      expect(content, '{"actions":[]}');
      expect(received.length, 1);
      final Map<String, Object?> call = received.single;
      expect(call['method'], 'POST');
      expect(call['path'], '/api/chat');

      final Map<String, Object?> body = call['body']! as Map<String, Object?>;
      expect(body['model'], 'qwen3.5');
      expect(body['stream'], isFalse);
      expect(body['format'], <String, Object?>{'type': 'object'});
      final List<Object?> messages = body['messages']! as List<Object?>;
      expect((messages[1]! as Map<String, Object?>)['content'], '把这两块连起来');
    });

    test('非 200 ⇒ 报错里带上状态码与服务端片段（便于定位）', () async {
      status = 500;
      responseBody = 'model not found';
      await expectLater(
        client().complete(system: 's', user: 'u'),
        throwsA(
          isA<LlmResponseException>().having(
            (LlmResponseException e) => e.message,
            'message',
            allOf(contains('500'), contains('model not found')),
          ),
        ),
      );
    });

    test('连不上 ⇒ 明确的"Ollama 未运行"（而不是裸 SocketException）', () async {
      // 先借一个端口再放掉，得到一个**确定没人监听**的端口。
      final ServerSocket probe = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final int deadPort = probe.port;
      await probe.close();

      await expectLater(
        OllamaLlmClient(endpoint: 'http://127.0.0.1:$deadPort', model: 'm')
            .complete(system: 's', user: 'u'),
        throwsA(
          isA<LlmUnavailableException>().having(
            (LlmUnavailableException e) => e.message,
            'message',
            contains('Ollama'),
          ),
        ),
      );
    });

    test('没配模型 ⇒ 直接给出"去设置里填"的指引，且**不发请求**', () async {
      await expectLater(
        client(model: '  ').complete(system: 's', user: 'u'),
        throwsA(
          isA<LlmUnavailableException>().having(
            (LlmUnavailableException e) => e.message,
            'message',
            contains('设置'),
          ),
        ),
      );
      expect(received, isEmpty);
    });
  });
}
