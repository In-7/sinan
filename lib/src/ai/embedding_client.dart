import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'llm_client.dart';

export 'llm_client.dart' show LlmResponseException, LlmUnavailableException;

/// 嵌入通道抽象（与 [LlmClient] 同一依赖倒置手法，理由也相同：本地 Ollama 是
/// 主路径不是唯一解，云端 OpenAI 兼容接口是既有备选——换实现不动上层）。
abstract interface class EmbeddingClient {
  /// 嵌入身份串的 **provider 段**（如 `ollama`）。与模型、维度拼成
  /// `provider:model:dim`（6.6①），写进 `index_state.model`——换 provider 或
  /// 换维度都自动全量失效，防止"同名不同向量空间"的隐性脏数据。
  String get provider;

  /// 模型 tag（如 `bge-m3`）。空 = 未配置。
  String get model;

  /// 批量嵌入。返回向量数与 [inputs] 一一对应、维度全部相等。
  Future<List<Float32List>> embed(List<String> inputs);
}

/// Ollama 原生 API 客户端（`POST /api/embed`）。
///
/// ## 为什么是 `/api/embed` 而不是旧版 `/api/embeddings`
/// 旧接口只吃单条 `prompt`、回单条 `embedding`，官方已标 deprecated；新接口的
/// `input` 支持**字符串数组**——6.5 的分批策略（一次 32~64 条）靠它，一次请求
/// 拿一批向量，响应与输入顺序一一对应。
/// （已核实：<https://docs.ollama.com/api/embed>）
class OllamaEmbeddingClient implements EmbeddingClient {
  OllamaEmbeddingClient({
    required this.endpoint,
    required this.model,
    this.timeout = const Duration(seconds: 120),
  });

  /// Ollama 的**根**地址（如 `http://localhost:11434`），不带 `/api`。
  final String endpoint;

  @override
  final String model;

  @override
  String get provider => 'ollama';

  final Duration timeout;

  @override
  Future<List<Float32List>> embed(List<String> inputs) async {
    if (model.trim().isEmpty) {
      throw const LlmUnavailableException('未配置嵌入模型：请到「设置 → AI」填写嵌入模型名');
    }
    if (inputs.isEmpty) return const <Float32List>[];
    final Uri uri = Uri.parse('${endpoint.trim()}/api/embed');
    final Map<String, Object?> body = buildOllamaEmbedRequest(
      model: model,
      inputs: inputs,
    );

    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final HttpClientRequest req = await client.postUrl(uri);
      req.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      req.write(jsonEncode(body));
      final HttpClientResponse res = await req.close();
      final String text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw LlmResponseException(
          '嵌入模型返回 HTTP ${res.statusCode}（${_snippet(text)}）',
        );
      }
      final List<Float32List> vectors = parseOllamaEmbedReply(text);
      if (vectors.length != inputs.length) {
        throw LlmResponseException(
          '嵌入数量与输入不符：${inputs.length} 条输入得到 ${vectors.length} 条向量',
        );
      }
      return vectors;
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
      throw LlmUnavailableException('嵌入模型服务超时（${timeout.inSeconds}s）');
    } finally {
      client.close(force: true);
    }
  }
}

/// 构造 `/api/embed` 的请求体。
///
/// **纯函数**（与 [buildOllamaChatRequest] 同口径）：契约里容易写错的点是字段名
/// ——批量输入是 `input`（数组），不是旧接口的 `prompt`。
Map<String, Object?> buildOllamaEmbedRequest({
  required String model,
  required List<String> inputs,
}) => <String, Object?>{'model': model, 'input': inputs};

/// 从 `/api/embed` 的响应体里取出向量。
///
/// **纯函数**。响应是 `{"embeddings": [[...], ...]}`（即使单条输入也是二维数组）。
/// 校验三条：非空、元素全是数、**矩形**（同一批向量维度必须一致——不齐说明模型
/// 行为异常，宁可报错也不能把脏向量写进 `vec_chunks`）。
List<Float32List> parseOllamaEmbedReply(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw LlmResponseException('嵌入服务返回的不是合法 JSON：${e.message}');
  }
  if (decoded is! Map) {
    throw const LlmResponseException('嵌入服务返回的不是 JSON 对象');
  }
  final Object? embeddings = decoded['embeddings'];
  if (embeddings is! List || embeddings.isEmpty) {
    throw const LlmResponseException('嵌入服务返回里没有 embeddings 数组');
  }
  final List<Float32List> out = <Float32List>[];
  int dim = -1;
  for (final Object? vector in embeddings) {
    if (vector is! List || vector.isEmpty) {
      throw const LlmResponseException('embeddings 里出现了空向量');
    }
    if (dim == -1) dim = vector.length;
    if (vector.length != dim) {
      throw const LlmResponseException('embeddings 内维度不一致（非矩形）');
    }
    final Float32List v = Float32List(vector.length);
    for (int i = 0; i < vector.length; i++) {
      final Object? n = vector[i];
      if (n is! num) {
        throw const LlmResponseException('embeddings 里出现了非数值元素');
      }
      v[i] = n.toDouble();
    }
    out.add(v);
  }
  return out;
}

String _snippet(String body) {
  final String flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 120 ? flat : '${flat.substring(0, 120)}…';
}
