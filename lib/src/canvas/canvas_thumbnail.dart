import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'kernel/canvas_item.dart';
import 'kernel/canvas_migration.dart';

/// 主页画布卡片用的**轻量缩略图快照**。
///
/// 与完整载入（[CanvasDocument] 反序列化）刻意不同：
/// - **只要 item 层**（形状 / 图片 / 卡片 / 思维导图 / 分组框，一页几十个）；
///   笔迹（InkStroke，一页可达几千条、卡片尺度下根本不可辨）整条跳过；
/// - **不推进全局 item id 计数器**：缩略图随网格滚动反复解析，不能有
///   `advanceItemIdSequence` 那种进程级副作用；
/// - **不触发图片解码**：[CanvasItem.fromJson] 对图片是纯数据构造，
///   `load()` 只在真实视图里发生；缩略图里图片走未加载占位外观。
///
/// 生命周期：item 里可能持有运行时资源（图片未来若改为预解码），
/// 缓存方在释放时应调 [dispose]。
class CanvasThumbnail {
  const CanvasThumbnail({required this.items, required this.bounds});

  /// 按 **z 序**（itemOrder）排好的 item；分组框是否在前由 painter 处理。
  final List<CanvasItem> items;

  /// 所有 item 世界包围盒（含旋转 AABB）的并集；空画布不会构造本对象。
  final Rect bounds;

  void dispose() {
    for (final CanvasItem item in items) {
      item.dispose();
    }
  }
}

/// 把一篇画布的存档 JSON 解析成缩略图快照。
///
/// 返回 `null` 的口径（调用方统一落"空画布"占位，不报错、不崩卡）：
/// 空串 / 非法 JSON / 不是 `{camera, document}` 画布格式 / 迁移后没有任何
/// item。单个 item 解析失败只跳过它本人——一张坏元素不该让整墙卡片白屏。
CanvasThumbnail? parseCanvasThumbnail(String content) {
  if (content.trim().isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(content);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final Object? documentRaw = decoded['document'];
  if (documentRaw is! Map) return null;

  // 老存档先迁移：itemOrder / 新字段都是迁移后才保证存在（与
  // CanvasDocument.fromJson 同一个入口，缩略图不能自己猜旧格式）。
  final Map<String, dynamic> doc = CanvasMigrations.migrate(
    documentRaw.cast<String, dynamic>(),
  );
  final Object? itemsRaw = doc['items'];
  if (itemsRaw is! Map) return null;
  final List<Object?> order =
      (doc['itemOrder'] as List?) ?? const <Object?>[];

  Rect? bounds;
  final List<CanvasItem> items = <CanvasItem>[];
  // z 序优先；没有 itemOrder 的脏存档退回 Map 迭代序（有东西看比黑屏强）。
  final Iterable<Object?> keys = order.isNotEmpty
      ? order
      : (itemsRaw as Map<Object?, Object?>).keys;
  for (final Object? key in keys) {
    if (key is! String) continue;
    final Object? raw = (itemsRaw as Map<Object?, Object?>)[key];
    if (raw is! Map) continue;
    final CanvasItem item;
    try {
      item = CanvasItem.fromJson(raw.cast<String, dynamic>());
    } on Object {
      continue;
    }
    items.add(item);
    bounds = bounds == null ? item.bounds : bounds.expandToInclude(item.bounds);
  }
  if (items.isEmpty || bounds == null || bounds.isEmpty) return null;
  return CanvasThumbnail(items: items, bounds: bounds);
}
