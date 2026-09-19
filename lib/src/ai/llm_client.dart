import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// LLM 通道的抽象。A 阶段只需要"给一段提示、拿一段文本回来"。
///
/// ## 为什么先有接口再有实现
/// 结构轨对后端的要求只有两条：**能返回 JSON**、**能离线跑**。本地 Ollama 满足，
/// 但它不是唯一解 —— 小模型吐不出合规 JSON 时就得换更大的本地模型或云端 API。
/// 把接口立在这里，换实现不动上层（`applyAiActions` / 净化层 / UI 一点都不改）。
abstract class LlmClient {
  /// 一次补全。[schema] 非空时要求后端以该 JSON Schema 约束输出。
  Future<String> complete({
    required String system,
    required String user,
    Map<String, Object?>? schema,
  });
}

/// LLM **不可达**（没起服务 / 网络不通 / 没配模型）——给用户看的可操作信息。
class LlmUnavailableException implements Exception {
  const LlmUnavailableException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// LLM **答得不对**（非 200 / 空内容 / 不是合法 JSON）。
class LlmResponseException implements Exception {
  const LlmResponseException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Ollama 原生 API 客户端（`POST /api/chat`）。
///
/// ## 为什么走 `/api/chat` 而不是 OpenAI 兼容的 `/v1/chat/completions`
/// 因为 **`format` 字段**：`/api/chat` 接受 `"json"` **或一个 JSON Schema 对象**，
/// 能直接把动作契约钉进请求里。这是本阶段可靠性的一半来源 —— 不靠"请只输出 JSON"
/// 这种祈祷式提示词。（已核实：<https://docs.ollama.com/api/chat>）
///
/// ## 两个容易写错的点（都在 [buildOllamaChatRequest] 里钉住）
/// ① `stream` **默认是 true** ⇒ 必须显式传 `false`，否则拿到的是 NDJSON 流，
///    直接 `jsonDecode` 会炸；
/// ② 想让 schema 生效必须走 `format`，别写进提示词里就算。
class OllamaLlmClient implements LlmClient {
  OllamaLlmClient({
    required this.endpoint,
    required this.model,
    this.timeout = const Duration(seconds: 120),
  });

  /// Ollama 的**根**地址（如 `http://localhost:11434`），不带 `/api`。
  final String endpoint;

  /// 模型名（Ollama tag，如 `qwen3.5`）。空 = 未配置。
  final String model;

  final Duration timeout;

  @override
  Future<String> complete({
    required String system,
    required String user,
    Map<String, Object?>? schema,
  }) async {
    if (model.trim().isEmpty) {
      throw const LlmUnavailableException('未配置模型：请到「设置 → AI」填写模型名');
    }
    final Uri uri = Uri.parse('${endpoint.trim()}/api/chat');
    final Map<String, Object?> body = buildOllamaChatRequest(
      model: model,
      system: system,
      user: user,
      format: schema ?? 'json',
    );

    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final HttpClientRequest req = await client.postUrl(uri);
      req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      req.write(jsonEncode(body));
      final HttpClientResponse res = await req.close();

      // 必须按 UTF-8 解码：中文提示词的回应用 latin1 会全成乱码。
      final String text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw LlmResponseException(
          '模型服务返回 HTTP ${res.statusCode}（${_snippet(text)}）',
        );
      }
      return parseOllamaChatReply(text);
    } on LlmResponseException {
      rethrow;
    } on SocketException catch (e) {
      throw LlmUnavailableException(
        '连不上模型服务（$endpoint）：${e.osError?.message ?? e.message}。'
        '请确认 Ollama 已启动。',
      );
    } on HttpException catch (e) {
      throw LlmUnavailableException('访问模型服务失败：${e.message}');
    } on TimeoutException {
      throw LlmUnavailableException('模型服务超时（${timeout.inSeconds}s）');
    } finally {
      client.close(force: true);
    }
  }
}

/// 构造 `/api/chat` 的请求体。
///
/// **纯函数**：请求体是本模块最容易写错的东西（`stream` 的默认值、`format` 的
/// 位置），单独拎出来才能不碰网络就把它钉进单测。
Map<String, Object?> buildOllamaChatRequest({
  required String model,
  required String system,
  required String user,
  Object? format = 'json',
}) => <String, Object?>{
  'model': model,
  'messages': <Map<String, String>>[
    <String, String>{'role': 'system', 'content': system},
    <String, String>{'role': 'user', 'content': user},
  ],
  // ⚠️ Ollama 的 `stream` **默认 true**：不显式关掉拿到的是 NDJSON 流。
  'stream': false,
  // `format` 可以是一个 JSON Schema 对象（不是只能填字符串 'json'）。
  'format': ?format,
};

/// 从 `/api/chat` 的响应体里取出回答文本。
///
/// **纯函数**：只认一次返回一条完整 JSON（`stream:false`）的形态。
/// 空内容视为失败 —— 让调用方能走"修复重试"而不是把空串当答案。
String parseOllamaChatReply(String body) {
  // 把 jsonDecode 的 FormatException 收成自家异常：调用方在**一个**类型上做
  // 错误分支就够了，不该同时 catch FormatException 与 HttpException。
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw LlmResponseException('模型服务返回的不是合法 JSON：${e.message}');
  }
  if (decoded is! Map) {
    throw const LlmResponseException('模型返回的不是 JSON 对象');
  }
  final Object? message = decoded['message'];
  if (message is! Map) {
    throw const LlmResponseException('模型返回里没有 message 字段');
  }
  final Object? content = message['content'];
  if (content is! String || content.trim().isEmpty) {
    throw const LlmResponseException('模型返回了空内容');
  }
  return content;
}

String _snippet(String body) {
  final String flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 120 ? flat : '${flat.substring(0, 120)}…';
}
