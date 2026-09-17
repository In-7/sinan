import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'canvas_ai.dart';

/// 确定性 32 位 FNV-1a 车道。
///
/// **为什么不用 `String.hashCode`**：Dart 的字符串哈希**每次进程启动都会随机
/// 化**（防哈希洪泛），拿它当缓存键会导致重启后永不命中——而"重启后仍在"正是
/// 磁盘缓存的全部意义。这里必须用跨进程稳定的确定性哈希。
///
/// 两条不同种子的车道拼成 64 位（[_cacheKey] 用），对本地结果缓存（几十~几千
/// 条）碰撞空间绰绰有余。这不是密码学哈希，不要用于安全用途。
class _Fnv1a32 {
  _Fnv1a32(this._hash);

  int _hash;

  static const int _prime = 0x01000193;
  static const int _mask = 0xFFFFFFFF;

  void add(List<int> bytes) {
    for (final int b in bytes) {
      _hash = ((_hash ^ b) * _prime) & _mask;
    }
  }

  void addString(String s) => add(utf8.encode(s));

  String get hex => _hash.toRadixString(16).padLeft(8, '0');
}

/// 计算一次生成的**缓存键**：与"实际发给后端的载荷"一一对应，任何一项变了就
/// 必须重算。刻意**不含**选区左上角坐标——模型只看到像素，同一张图平移后应当
/// 命中同一结果（这既正确又能提高命中率）；尺寸则要算，因为它是载荷的一部分。
///
/// 构成：model / prompt / negative / seed / steps / 宽高（与 [HttpAiGenerator]
/// 发送的 `width`/`height` 一致）/ `recipe.inputs` 的角色→节点对 /
/// 每张输入图的**像素字节**哈希（输入图变了必须重算）。
String aiCacheKey(
  GenRecipe recipe,
  Region region,
  Map<String, Uint8List>? inputImages,
) {
  final _Fnv1a32 a = _Fnv1a32(0x811c9dc5);
  final _Fnv1a32 b = _Fnv1a32(0x811c9dc5 ^ 0x5bd1e995);

  void put(String label, String value) {
    // 带标签 + 长度前缀，避免字段拼接产生歧义（"ab"+"c" vs "a"+"bc"）。
    final String line = '$label\u0000${value.length}\u0000$value\u0001';
    a.addString(line);
    b.addString(line);
  }

  put('model', recipe.model);
  put('prompt', recipe.prompt);
  put('negative', recipe.negativePrompt);
  put('seed', recipe.seed?.toString() ?? '');
  put('steps', recipe.steps?.toString() ?? '');
  put('w', region.bbox.width.round().toString());
  put('h', region.bbox.height.round().toString());

  final List<String> roles = recipe.inputs.keys.toList()..sort();
  for (final String role in roles) {
    put('ref:$role', recipe.inputs[role] ?? '');
  }

  final Map<String, Uint8List> images =
      inputImages ?? const <String, Uint8List>{};
  final List<String> imageRoles = images.keys.toList()..sort();
  for (final String role in imageRoles) {
    final _Fnv1a32 bytesHash = _Fnv1a32(0x811c9dc5);
    bytesHash.add(images[role]!);
    put('img:$role', '${images[role]!.length}:${bytesHash.hex}');
  }

  return '${a.hex}${b.hex}';
}

/// 一次清理的结果（供日志/设置面板展示）。
class CachePruneReport {
  const CachePruneReport({
    required this.removed,
    required this.freedBytes,
    required this.kept,
  });

  /// 删掉的条目数。
  final int removed;

  /// 释放的字节数。
  final int freedBytes;

  /// 清理后仍在的条目数。
  final int kept;

  @override
  String toString() =>
      'CachePruneReport(removed: $removed, freedBytes: $freedBytes, kept: $kept)';
}

/// 磁盘结果缓存（内容寻址）：键 → `<directory>/<key>.png`。
///
/// 两个收益，都不只是"省一次调用"：
/// 1. **重复配方不再调模型**（ComfyUI 执行缓存的核心口径）；
/// 2. 生成结果一律变成**文件路径** ⇒ [ImageItem.src] 有值 ⇒ 随画布 JSON 落库
///    ⇒ **重启后图像还在**（此前本地桩只给内存图，重启即丢）。
///
/// [resolveDirectory] 延迟解析（宿主层用 `path_provider` 注入），因此本类保持
/// 与 Flutter/Material 无关、构造是同步的。
///
/// ## 容量与清理：为什么必须由宿主给"引用保护"
/// 落盘的结果**同时是文档的图片本体**（[AiImageItem.src] 直接指向它），不是纯
/// 副本。因此删一个仍被引用的文件就等于删用户的正文内容。内核读不到数据库，
/// 无法自己判断谁被引用，于是：
/// - 未提供 [protectedPaths] ⇒ [prune] 与自动清理**什么都不删**（宁可涨，不可丢）；
/// - 提供了 ⇒ 被保护的文件永不淘汰，其余按 LRU 淘汰到限额内。
class AiResultCache {
  AiResultCache({
    required this.resolveDirectory,
    this.maxBytes = 256 << 20,
    this.maxEntries = 512,
    this.protectedPaths,
  });

  final Future<String> Function() resolveDirectory;

  /// 容量上限（字节）。超出即触发 LRU 淘汰。
  final int maxBytes;

  /// 条目数上限。
  final int maxEntries;

  /// 引用保护：返回**不可淘汰**的路径集合。
  ///
  /// 用"一次性返回集合"而不是 `bool Function(String)`：宿主构建这个集合需要扫
  /// 数据库（画布正文里的图片路径），逐文件回调会把那次扫描重复 N 遍。
  final Set<String> Function()? protectedPaths;

  Future<Directory>? _dir;
  final Map<String, String> _index = <String, String>{};
  bool _prunedThisSession = false;

  Future<Directory> _ensureDir() {
    return _dir ??= resolveDirectory().then((String path) {
      final Directory dir = Directory(path);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _reindex(dir);
      return dir;
    });
  }

  /// 从目录重建索引：缓存**跨会话**才有意义——重启后同一配方应直接命中，
  /// 而不是白跑一次模型。键即文件名（去掉 `.png`），故重建无需额外元数据。
  void _reindex(Directory dir) {
    if (_index.isNotEmpty) return;
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.png')) continue;
      _index[_keyOf(entity.path)] = entity.path;
    }
  }

  /// 缓存键 ⇄ 文件名的互换（`<key>.png`）。
  static String _keyOf(String filePath) {
    final String name = Uri.file(filePath).pathSegments.last;
    return name.endsWith('.png') ? name.substring(0, name.length - 4) : name;
  }

  /// 命中则返回落盘路径；未命中或文件已被清理返回 null。
  Future<String?> lookup(String key) async {
    // 必须先 _ensureDir：首次查询要在目录里重建索引（跨会话命中的前提）。
    await _ensureDir();
    final String? path = _index[key];
    if (path == null) return null;
    final File file = File(path);
    if (!file.existsSync()) {
      // 外部清理过缓存目录：丢掉索引项，当作未命中。
      _index.remove(key);
      return null;
    }
    // 命中即"最近使用"：刷新 mtime，LRU 才不会把常用的结果淘汰掉。
    // 失败（权限/文件系统）只让 LRU 退化成"最近写入"，不影响正确性。
    try {
      file.setLastModifiedSync(DateTime.now());
    } on Object catch (_) {
      // 忽略。
    }
    return path;
  }

  /// 按 **LRU**（最近一次使用时间）淘汰，直到同时满足 [maxEntries] 与
  /// [maxBytes]。
  ///
  /// - [protectedPaths] 返回的路径**永不淘汰**（引用保护，见类文档）；
  /// - 未提供 [protectedPaths] 时直接返回空报告：**不删任何东西**。
  /// - 单个文件删不掉（被占用/权限）只跳过，不中断整轮。
  Future<CachePruneReport> prune() async {
    final Directory dir = await _ensureDir();
    final List<File> files = <File>[];
    int total = 0;
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.png')) continue;
      files.add(entity);
      total += entity.lengthSync();
    }

    int removed = 0;
    int freed = 0;
    int kept = files.length;
    final Set<String>? protect = protectedPaths?.call();
    if (protect == null) {
      // 没有引用保护 ⇒ 不删（内核无法判断谁被引用）。
      return CachePruneReport(removed: 0, freedBytes: 0, kept: kept);
    }
    if (kept <= maxEntries && total <= maxBytes) {
      return CachePruneReport(removed: 0, freedBytes: 0, kept: kept);
    }

    // 最久未用的排前面（mtime = 最近一次写入或命中）。
    files.sort(
      (File a, File b) =>
          a.statSync().modified.compareTo(b.statSync().modified),
    );

    for (final File file in files) {
      if (kept <= maxEntries && total <= maxBytes) break;
      if (protect.contains(file.path)) continue;
      final int size = file.lengthSync();
      try {
        file.deleteSync();
      } on Object catch (_) {
        continue;
      }
      _index.remove(_keyOf(file.path));
      removed++;
      kept--;
      freed += size;
      total -= size;
    }
    return CachePruneReport(removed: removed, freedBytes: freed, kept: kept);
  }

  /// 本会话首次落盘后自动清理一次（同一个缓存实例只跑一次）。
  ///
  /// 刻意放在 [store] 之后而不是构造时：构造在 UI 装配路径上，而清理要遍历目录
  /// 并让宿主扫一遍引用，不该拖慢首屏。
  Future<void> _pruneOnce() async {
    if (_prunedThisSession) return;
    _prunedThisSession = true;
    if (protectedPaths == null) return; // 无引用保护 ⇒ 不删
    await prune();
  }

  /// 落盘一份结果并把索引指向它（路径稳定，可安全写进 [ImageItem.src]）。
  Future<String> store(String key, Uint8List pngBytes) async {
    // 清理放在**写入之前**：本轮刚写下的文件很快就会被文档引用，
    // 不该成为自己那一轮清理的候选。
    await _pruneOnce();
    final Directory dir = await _ensureDir();
    final File file = File('${dir.path}${Platform.pathSeparator}$key.png');
    if (!file.existsSync()) {
      await file.writeAsBytes(pngBytes, flush: true);
    }
    _index[key] = file.path;
    return file.path;
  }

  /// 把任意 [GeneratedResult] 归一化成磁盘 PNG 并返回路径。
  ///
  /// - 已是文件（网络后端落盘）⇒ 复制进缓存目录，缓存自包含、不依赖临时文件
  ///   是否被清理；
  /// - 是内存图（本地桩）⇒ 编码 PNG 后落盘，使其**可持久化**。
  Future<String?> storeResult(String key, GeneratedResult result) async {
    final String? existing = result.path;
    if (existing != null) {
      final File src = File(existing);
      if (!src.existsSync()) return null;
      return store(key, await src.readAsBytes());
    }
    final ui.Image? image = result.image;
    if (image == null) return null;
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (bytes == null) return null;
    return store(key, bytes.buffer.asUint8List());
  }

  /// 已缓存的条目数（测试/诊断用）。
  int get length => _index.length;
}

/// 缓存装饰器：包住任意 [AiGenerator]，命中直接回缓存路径，未命中才转发并
/// 顺手落盘。画布侧（[CanvasController]）无需感知。
class CachingAiGenerator implements AiGenerator {
  CachingAiGenerator(this.inner, this.cache);

  final AiGenerator inner;
  final AiResultCache cache;

  @override
  Future<GeneratedResult> generate(
    GenRecipe recipe, {
    required Region region,
    Map<String, Uint8List>? inputImages,
  }) async {
    final String key = aiCacheKey(recipe, region, inputImages);
    final String? hit = await cache.lookup(key);
    if (hit != null) return GeneratedResult(path: hit);

    final GeneratedResult result = await inner.generate(
      recipe,
      region: region,
      inputImages: inputImages,
    );
    final String? stored = await cache.storeResult(key, result);
    // 落盘失败（不可写等）不该让生成失败：原样返回内存结果。
    return stored == null ? result : GeneratedResult(path: stored);
  }
}
