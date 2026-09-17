import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart';
import 'package:material_ui/material_ui.dart';

import 'attachment_card.dart';
import 'attachment_meta.dart';

/// 附件嵌入（type = "attachment"）：data = JSON
/// `{"path": "...", "name": "...", "size": 12345}`。
///
/// **卡片与打开动作已抽到 [AttachmentCard] / [openAttachment]**
/// （与 appflowy 的 `AttachmentBlockComponent` 共用）；本类只负责 quill
/// 侧的渲染接线。
class NoteAttachmentEmbedBuilder extends EmbedBuilder {
  const NoteAttachmentEmbedBuilder();

  static const String embedType = 'attachment';

  @override
  String get key => embedType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    AttachmentMeta? meta;
    try {
      final Object? data = embedContext.node.value.data;
      if (data is String && data.isNotEmpty) {
        meta = AttachmentMeta.fromJson(
          Map<String, dynamic>.from(jsonDecode(data) as Map),
        );
      }
    } catch (_) {
      meta = null;
    }
    if (meta == null) {
      return Text(
        '附件数据损坏',
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.error,
        ),
      );
    }
    return AttachmentCard(
      meta: meta,
      onOpen: () => openAttachment(meta!.path),
    );
  }
}
