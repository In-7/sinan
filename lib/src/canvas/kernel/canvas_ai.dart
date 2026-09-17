import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// AI 生成状态机：异步乐观 UI（loading → done/error）。
///
/// [stale] = 结果仍在，但**输入已变**（被引用的节点/选区内容改过）⇒
/// "可重算"。由 [CanvasController.refreshStaleness] 依据
/// [GenRecipe.inputFingerprint] 推导，见 `canvas_raster.dart`。
enum GenStatus { loading, done, error, stale }

/// 生成配方：存"怎么生成的参数"而非只存像素，从而可非破坏性重算 / 分支比较。
class GenRecipe {
  const GenRecipe({
    required this.model,
    this.prompt = '',
    this.negativePrompt = '',
    this.seed,
    this.steps,
    this.inputs = const <String, String>{},
    this.inputFingerprint,
    this.status = GenStatus.loading,
    this.createdAt,
  });

  final String model;
  final String prompt;
  final String negativePrompt;
  final int? seed;
  final int? steps;

  /// 引用的输入节点/选区，按角色映射，如
  /// `{'image': 'node-3', 'mask': 'region-2'}`。
  final Map<String, String> inputs;

  /// 生成时**输入内容**的结构指纹（见 `canvas_raster.dart` 的
  /// [inputFingerprint]）。null = 该次生成没有输入（纯文生图）⇒ 永不 stale。
  ///
  /// 存"是什么输入做的"而不是只存结果，才能事后判断**该不该重算**——
  /// 这就是非破坏性重算的判定依据。
  final String? inputFingerprint;
  final GenStatus status;
  final DateTime? createdAt;

  GenRecipe copyWith({
    GenStatus? status,
    String? prompt,
    int? seed,
    String? inputFingerprint,
  }) =>
      GenRecipe(
        model: model,
        prompt: prompt ?? this.prompt,
        negativePrompt: negativePrompt,
        seed: seed ?? this.seed,
        steps: steps,
        inputs: inputs,
        inputFingerprint: inputFingerprint ?? this.inputFingerprint,
        status: status ?? this.status,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'model': model,
        'prompt': prompt,
        'negativePrompt': negativePrompt,
        'seed': seed,
        'steps': steps,
        'inputs': inputs,
        'inputFingerprint': inputFingerprint,
        'status': status.name,
        'createdAt': createdAt?.toIso8601String(),
      };

  factory GenRecipe.fromJson(Map<String, dynamic> j) => GenRecipe(
        model: j['model'] as String,
        prompt: j['prompt'] as String? ?? '',
        negativePrompt: j['negativePrompt'] as String? ?? '',
        seed: j['seed'] as int?,
        steps: j['steps'] as int?,
        inputs: (j['inputs'] as Map?)?.cast<String, String>() ?? const {},
        inputFingerprint: j['inputFingerprint'] as String?,
        status: GenStatus.values.byName(j['status'] as String? ?? 'loading'),
        createdAt: j['createdAt'] == null
            ? null
            : DateTime.parse(j['createdAt'] as String),
      );
}

/// 选区即数据：框选 → 序列化成 [Region] → 喂给模型 → 产出 [AiImageItem]。
class Region {
  Region({
    required this.id,
    required this.bbox,
    this.nodeRef,
    this.maskRef,
    this.prompt,
  });

  final String id;
  final ui.Rect bbox;
  final String? nodeRef;
  final String? maskRef;
  final String? prompt;

  static int _counter = 0;
  static String nextId() => 'region-${_counter++}';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'bbox': <double>[bbox.left, bbox.top, bbox.right, bbox.bottom],
        'nodeRef': nodeRef,
        'maskRef': maskRef,
        'prompt': prompt,
      };

  factory Region.fromJson(Map<String, dynamic> j) {
    // 先定类型再取下标：直接 `j['bbox'][0]` 是 **dynamic 调用**（绕过类型
    // 检查、运行时才炸），lint `avoid_dynamic_calls` 会拦。
    final List<Object?> bbox = j['bbox'] as List;
    return Region(
      id: j['id'] as String,
      bbox: ui.Rect.fromLTRB(
        (bbox[0] as num).toDouble(),
        (bbox[1] as num).toDouble(),
        (bbox[2] as num).toDouble(),
        (bbox[3] as num).toDouble(),
      ),
      nodeRef: j['nodeRef'] as String?,
      maskRef: j['maskRef'] as String?,
      prompt: j['prompt'] as String?,
    );
  }
}

/// 生成结果：要么直接给内存图像（本地 stub / 已解码），要么给文件路径
/// （网络后端落盘）。两者都被 [GeneratedResult.applyTo] 统一注入到 item。
class GeneratedResult {
  const GeneratedResult({this.image, this.path});
  final ui.Image? image;
  final String? path;

  void applyTo(ImageSink item, {required void Function() onLoaded}) {
    if (image != null) {
      item.setImage(image!);
    } else if (path != null) {
      item.setSrc(path!);
      unawaited(item.load(onLoaded: onLoaded));
    }
  }
}

/// 图像注入接口：让 [GeneratedResult] 既能注入内存图也能注入路径，解耦具体 item。
abstract class ImageSink {
  void setImage(ui.Image img);
  void setSrc(String src);
  Future<void> load({required void Function() onLoaded});
}

/// AI 生成器抽象（依赖倒置：画布不直接依赖某种后端）。
///
/// [inputImages] 为可选输入图字节（图生图 / inpaint 时由调用方栅格化选区
/// 引用的节点后传入）；纯文生图可为 null。
abstract class AiGenerator {
  Future<GeneratedResult> generate(
    GenRecipe recipe, {
    required Region region,
    Map<String, Uint8List>? inputImages,
  });
}

/// 本地桩：不接后端，用 [ui.Picture.toImage] 画一张纯色图（带描边），让
/// "选区 → 生成层" 闭环在离线环境也能完整跑通、可见。接真模型时换成网络
/// 实现（返回 [GeneratedResult.path] 指向落盘文件）即可，画布侧无需改动。
class LocalStubGenerator implements AiGenerator {
  const LocalStubGenerator();

  @override
  Future<GeneratedResult> generate(GenRecipe recipe,
      {required Region region, Map<String, Uint8List>? inputImages}) async {
    await Future<void>.delayed(const Duration(milliseconds: 600)); // 模拟推理耗时
    final int w = math.max(1, region.bbox.width.round());
    final int h = math.max(1, region.bbox.height.round());
    final ui.Color color = _colorFromPrompt(recipe.prompt);
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..color = color,
    );
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()
        ..color = const ui.Color(0xFF000000)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = math.max(2, w / 100),
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image img = await picture.toImage(w, h);
    picture.dispose();
    return GeneratedResult(image: img);
  }

  static ui.Color _colorFromPrompt(String prompt) {
    int hash = 0;
    for (final int c in prompt.codeUnits) {
      hash = (hash * 31 + c) & 0xFFFFFFFF;
    }
    return ui.Color(0xFF000000 | (hash & 0x00FFFFFF));
  }
}

/// 远端 HTTP 后端骨架：把配方 POST 给推理服务，拿回 PNG 字节落盘，
/// 返回 [GeneratedResult.path]。画布侧（[CanvasController.generateFromRegion]）
/// 无需任何改动——只要注入此生成器即可把"本地桩"切到"真模型"。
///
/// 约定（示例，按你的后端调整）：
/// - 纯文生图：`POST endpoint`，JSON `{prompt, negative_prompt, seed, steps,
///   model, width, height}`。
/// - 带输入图（img2img / inpaint）：自动改用 `multipart/form-data`，同名文本
///   字段之外，把 [inputImages] 的每一条按 key 作为文件域（`image`/`mask`…，
///   文件名 `<key>.png`，`image/png`）附带。
/// - 响应：原始 PNG 字节（HTTP 200）。
class HttpAiGenerator implements AiGenerator {
  const HttpAiGenerator({
    required this.endpoint,
    this.timeout = const Duration(seconds: 30),
  });

  final String endpoint;
  final Duration timeout;

  @override
  Future<GeneratedResult> generate(
    GenRecipe recipe, {
    required Region region,
    Map<String, Uint8List>? inputImages,
  }) async {
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final HttpClientRequest req = await client.postUrl(Uri.parse(endpoint));
      if (inputImages == null || inputImages.isEmpty) {
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.write(jsonEncode(<String, dynamic>{
          'prompt': recipe.prompt,
          'negative_prompt': recipe.negativePrompt,
          'seed': recipe.seed,
          'steps': recipe.steps,
          'model': recipe.model,
          'width': region.bbox.width.round(),
          'height': region.bbox.height.round(),
        }));
      } else {
        _writeMultipart(req, recipe, region, inputImages);
      }
      final HttpClientResponse res = await req.close();
      if (res.statusCode != 200) {
        throw Exception('AI backend returned HTTP ${res.statusCode}');
      }
      final List<int> data = <int>[];
      await for (final List<int> chunk in res) {
        data.addAll(chunk);
      }
      final File file = File(
        '${Directory.systemTemp.path}'
        '/sinan_ai_${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(data);
      return GeneratedResult(path: file.path);
    } finally {
      client.close(force: true);
    }
  }

  /// 把文本字段 + 输入图字节拼成 multipart/form-data 写入请求体。
  void _writeMultipart(
    HttpClientRequest req,
    GenRecipe recipe,
    Region region,
    Map<String, Uint8List> inputImages,
  ) {
    final String boundary =
        '----sinan${DateTime.now().microsecondsSinceEpoch}';
    req.headers.set(
      HttpHeaders.contentTypeHeader,
      'multipart/form-data; boundary=$boundary',
    );
    final List<int> body = <int>[];
    void appendTextField(String name, String value) {
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(utf8.encode(
        'Content-Disposition: form-data; name="$name"\r\n\r\n',
      ));
      body.addAll(utf8.encode('$value\r\n'));
    }

    appendTextField('prompt', recipe.prompt);
    appendTextField('negative_prompt', recipe.negativePrompt);
    if (recipe.seed != null) {
      appendTextField('seed', recipe.seed.toString());
    }
    if (recipe.steps != null) {
      appendTextField('steps', recipe.steps.toString());
    }
    appendTextField('model', recipe.model);
    appendTextField('width', region.bbox.width.round().toString());
    appendTextField('height', region.bbox.height.round().toString());

    inputImages.forEach((String key, Uint8List bytes) {
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(utf8.encode(
        'Content-Disposition: form-data; name="$key"; filename="$key.png"\r\n',
      ));
      body.addAll(utf8.encode('Content-Type: image/png\r\n\r\n'));
      body.addAll(bytes);
      body.addAll(utf8.encode('\r\n'));
    });
    body.addAll(utf8.encode('--$boundary--\r\n'));
    req.contentLength = body.length;
    req.add(body);
  }
}
