import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';

import '../../notes/services/attachment_card.dart';
import '../../notes/services/attachment_meta.dart';
import 'non_text_block.dart';

/// 附件块（type = `attachment`）：属性 `meta` = 附件元数据 JSON
/// `{"path": "...", "name": "...", "size": 12345}`。
///
/// 与 Delta 嵌入的对应关系（见 `NoteDocumentAdapter`）：
/// `{"insert":{"attachment":"<json>"}}` ↔ `Node('attachment', {meta: '<json>'})`。
/// 卡片与"打开附件"走 `attachment_card.dart`（与 quill 侧共用同一实现）。
class AttachmentBlockKeys {
  const AttachmentBlockKeys._();

  static const String type = 'attachment';
  static const String meta = 'meta';
}

/// 构造附件块节点（[metaJson] 为 [AttachmentMeta.toJson] 的编码结果）。
Node attachmentBlockNode({required String metaJson}) => Node(
  type: AttachmentBlockKeys.type,
  attributes: <String, dynamic>{AttachmentBlockKeys.meta: metaJson},
);

class AttachmentBlockComponentBuilder extends BlockComponentBuilder {
  AttachmentBlockComponentBuilder({super.configuration});

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final Node node = blockComponentContext.node;
    return AttachmentBlockComponentWidget(
      key: node.key,
      node: node,
      configuration: configuration,
      showActions: showActions(node),
      actionBuilder: (context, state) =>
          actionBuilder(blockComponentContext, state),
      actionTrailingBuilder: (context, state) =>
          actionTrailingBuilder(blockComponentContext, state),
    );
  }

  /// 非文本块：不接受子块（与官方 divider 的判定一致）。
  @override
  BlockComponentValidate get validate => (node) => node.children.isEmpty;
}

class AttachmentBlockComponentWidget extends BlockComponentStatefulWidget {
  const AttachmentBlockComponentWidget({
    super.key,
    required super.node,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  @override
  State<AttachmentBlockComponentWidget> createState() =>
      _AttachmentBlockComponentWidgetState();
}

class _AttachmentBlockComponentWidgetState
    extends State<AttachmentBlockComponentWidget>
    with
        SelectableMixin<AttachmentBlockComponentWidget>,
        BlockComponentConfigurable<AttachmentBlockComponentWidget>,
        NonTextBlockGeometry<AttachmentBlockComponentWidget> {
  @override
  final GlobalKey contentKey = GlobalKey(debugLabel: 'attachment_block');

  @override
  Widget build(BuildContext context) => buildNonTextBlock(context);

  @override
  Widget buildContent(BuildContext context) {
    return ListenableBuilder(
      listenable: node,
      builder: (BuildContext context, Widget? child) {
        final AttachmentMeta? meta = _parseMeta(
          node.attributes[AttachmentBlockKeys.meta],
        );
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
          onOpen: () => openAttachment(meta.path),
        );
      },
    );
  }

  /// 属性里存的是 JSON 串；解析失败返回 null（渲染错误提示，不崩）。
  static AttachmentMeta? _parseMeta(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      return AttachmentMeta.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } on Object catch (_) {
      return null;
    }
  }
}
