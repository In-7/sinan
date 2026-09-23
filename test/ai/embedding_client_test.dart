import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/ai/embedding_client.dart';

/// `/api/embed` 客户端的**纯函数层**回归：请求体字段名与响应解析的校验口径。
///
/// 网络层没有可单测的逻辑（超时/非 200 已在实现里走与 `llm_client.dart` 同一
/// 套异常），这里钉的是最容易写错的两处：字段名是 `input`（不是旧接口的
/// `prompt`），以及"矩形性"校验——不齐的向量绝不能流进 `vec_chunks`。
void main() {
  test('buildOllamaEmbedRequest：model + input 数组（不是旧接口的 prompt）', () {
    final Map<String, Object?> body = buildOllamaEmbedRequest(
      model: 'bge-m3',
      inputs: <String>['第一条', '第二条'],
    );
    expect(body, <String, Object?>{
      'model': 'bge-m3',
      'input': <String>['第一条', '第二条'],
    });
  });

  test('parse：正常响应（单条输入也是二维数组）→ 等长向量列表', () {
    final List<Float32List> vectors = parseOllamaEmbedReply(
      '{"model":"m","embeddings":[[0.5,1.5],[1.0,-2.0]]}',
    );
    expect(vectors, hasLength(2));
    expect(vectors.first.toList(), <double>[0.5, 1.5]);
    expect(vectors.last.toList(), <double>[1.0, -2.0]);
  });

  test('parse：非法 JSON / 缺 embeddings / 空数组 → LlmResponseException', () {
    for (final String bad in <String>[
      'not json',
      '{"nope":1}',
      '{"embeddings":[]}',
    ]) {
      expect(
        () => parseOllamaEmbedReply(bad),
        throwsA(isA<LlmResponseException>()),
        reason: bad,
      );
    }
  });

  test('parse：维度不齐（非矩形）/ 空向量 / 非数值 → LlmResponseException', () {
    for (final String bad in <String>[
      '{"embeddings":[[1,2],[1]]}', // 维度不齐
      '{"embeddings":[[]]}', // 空向量
      '{"embeddings":[["a"]]}', // 非数值
    ]) {
      expect(
        () => parseOllamaEmbedReply(bad),
        throwsA(isA<LlmResponseException>()),
        reason: bad,
      );
    }
  });
}
