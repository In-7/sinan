import 'package:appflowy_editor/appflowy_editor.dart';
import 'dart:ui' as ui;
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../domain/embed_line.dart';
import '../../domain/note.dart';
import '../../theme/tokens.dart';
import 'non_text_block.dart';

/// 引用块（type = `ref`）：指向**另一篇笔�?/ 另一个块**的结构化引用�?
///
/// 属性：`ref_type` = [refNote] / [refBlock]，`ref_id` = 目标 id�?
///
/// ## 为什么是"�?而不是正文里�?`[[…]]`
/// 引用存的�?**id** 而不是标题文本：于是"谁引用了�?（反链）只是一�?SQL
/// （见 `NoteStore.backlinks`），不需要解析正文，也不会因为改名而断�?—�?
/// 目标是删掉时这里显式显示"引用已失�?，而不是悄悄变成一段死文字�?
class RefBlockKeys {
  const RefBlockKeys._();

  static const String type = 'ref';
  static const String refType = 'ref_type';
  static const String refId = 'ref_id';
  static const String refView = 'ref_view';

  /// [refType] 的取值：引用整篇笔记 / 引用某一块�?
  static const String refNote = 'note';
  static const String refBlock = 'block';

  /// [refView] 的取值：
  /// - [viewLink]（默认）：一行卡片，只显示目标标题（= 传统双链�?链接"）；
  /// - [viewEmbed]�?*就地展开**目标内容（Obsidian �?`![[…]]` / Notion �?
  ///   "显示�?embed"）。只�?—�?编辑得去目标那边�?
  static const String viewLink = 'link';
  static const String viewEmbed = 'embed';
}

/// 构造引用块节点�?
Node refBlockNode({
  required String refType,
  required String refId,
  String refView = RefBlockKeys.viewLink,
}) => Node(
  type: RefBlockKeys.type,
  attributes: <String, dynamic>{
    RefBlockKeys.refType: refType,
    RefBlockKeys.refId: refId,
    // link 是默认值也照样写进属性：读侧不必�?缺这个键"再准备一条分支�?
    RefBlockKeys.refView: refView,
  },
);

/// 解出来的引用目标；`null` 表示目标已不存在（UI 显示"引用已失�?）�?
class RefTarget {
  const RefTarget({required this.title, required this.kind});

  final String title;
  final NoteKind kind;
}

/// 引用块与宿主（笔记库 / 导航）之间的**接缝**�?
///
/// 内核不碰 provider：解析目标、跳转都由宿主注�?—�?�?`MediaResolver` /
/// `EditorTypography` 同一条路子。于是块组件不依�?Riverpod、可单测�?
/// 也不会在渲染层执着�?数据从哪�?�?
class RefBlockBridge {
  const RefBlockBridge({
    required this.resolve,
    required this.open,
    this.preview,
    this.revision,
  });

  /// �?(`refType`, `refId`) 解析目标；目标不存在返回 null�?
  final RefTarget? Function(String refType, String refId) resolve;

  /// 打开目标（跳到那篇笔记）�?
  final void Function(String refType, String refId) open;

  /// 嵌入模式（`ref_view='embed'`）要展示的内容；�?null �?嵌入降级为链接卡片�?
  ///
  /// 只读：嵌入只�?在这里看到内�?，编辑得去目标那边（避免两套编辑入口�?
  /// 同一份数据写）�?
  final List<EmbedLine> Function(String refType, String refId)? preview;

  /// 目标信息可能变了的信号（改名 / 删除�?+1）。不传则不自动刷新标题�?
  final Listenable? revision;
}

class RefBlockComponentBuilder extends BlockComponentBuilder {
  RefBlockComponentBuilder({this.bridge, super.configuration});

  /// 宿主注入的接缝；�?null 时块只显示原�?id（测�?/ 无宿主场景）�?
  final RefBlockBridge? bridge;

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final Node node = blockComponentContext.node;
    return RefBlockComponentWidget(
      key: node.key,
      node: node,
      bridge: bridge,
      configuration: configuration,
      showActions: showActions(node),
      actionBuilder: (context, state) =>
          actionBuilder(blockComponentContext, state),
      actionTrailingBuilder: (context, state) =>
          actionTrailingBuilder(blockComponentContext, state),
    );
  }

  /// 非文本块：不接受子块（与官方 divider 的判定一致）�?
  @override
  BlockComponentValidate get validate => (node) => node.children.isEmpty;
}

class RefBlockComponentWidget extends BlockComponentStatefulWidget {
  const RefBlockComponentWidget({
    super.key,
    required super.node,
    this.bridge,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  final RefBlockBridge? bridge;

  @override
  State<RefBlockComponentWidget> createState() =>
      _RefBlockComponentWidgetState();
}

class _RefBlockComponentWidgetState
    extends State<RefBlockComponentWidget>
    with
        SelectableMixin<RefBlockComponentWidget>,
        BlockComponentConfigurable<RefBlockComponentWidget>,
        NonTextBlockGeometry<RefBlockComponentWidget> {
  @override
  final GlobalKey contentKey = GlobalKey(debugLabel: 'ref_block');

  // 本状态自�?editorState（骨架的混入组合里没有声明它，故不是 override）�?
  late final EditorState editorState = Provider.of<EditorState>(
    context,
    listen: false,
  );

  @override
  Widget build(BuildContext context) => buildNonTextBlock(context);

  @override
  Widget buildContent(BuildContext context) {
    // 属性在 ListenableBuilder 内读：事务改�?ref_id �?node �?notify�?
    // 这样读到的是新值（在外面读会拿到陈旧闭包值）�?
    // 目标标题可能�?*别处**改（改名 / 删除），所以接上宿主的 [RefBlockBridge.revision]�?
    final Listenable? revision = widget.bridge?.revision;
    final Listenable listenable = revision == null
        ? node
        : Listenable.merge(<Listenable>[node, revision]);
    return ListenableBuilder(
      listenable: listenable,
      builder: (BuildContext context, Widget? child) => _card(context),
    );
  }

  /// 三个属性都�?`ListenableBuilder` 内读（事务改�?node �?notify）�?
  String get _refType =>
      (node.attributes[RefBlockKeys.refType] as String?) ?? RefBlockKeys.refNote;

  String get _refId => (node.attributes[RefBlockKeys.refId] as String?) ?? '';

  String get _view =>
      (node.attributes[RefBlockKeys.refView] as String?) ?? RefBlockKeys.viewLink;

  Widget _card(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final RefTarget? target = widget.bridge?.resolve(_refType, _refId);
    final bool missing = target == null;
    // 嵌入模式：就地展开目标内容（只读）�?*断链时仍走链接卡�?*—�?引用�?
    // 失效"这个位置在那边�?
    if (!missing && _view == RefBlockKeys.viewEmbed) return _embedCard(context);
    final Color base = missing ? scheme.error : scheme.primary;
    return MouseRegion(
      cursor: missing ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: missing
            ? null
            : () => widget.bridge?.open(_refType, _refId),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: Tokens.spaceXs / 2),
          padding: const EdgeInsets.symmetric(
            horizontal: Tokens.spaceSm,
            vertical: Tokens.spaceXs,
          ),
          decoration: BoxDecoration(
            // 底色�?*主题色的极淡�?*（不是固定灰）：深浅两套主题下都成立�?
            // 也与正文的卡片式块（callout）同一口气。用 alpha 而非 Opacity
            // —�?后者是 SaveLayer，Impeller 下的性能红线�?
            color: base.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
            border: Border.all(color: base.withValues(alpha: 0.28)),
          ),
          child: Row(
            children: <Widget>[
              tabler.LinkOff(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(base, ui.BlendMode.srcIn)),
              const SizedBox(width: Tokens.spaceSm),
              Expanded(
                child: Text(
                  missing ? '引用已失�? : target.title,
                  maxLines: 1,
                  overflow: .ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: missing ? scheme.error : scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: Tokens.spaceSm),
              Text(
                _labelOf(_refType, missing: missing),
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 嵌入卡片�?*就地展开**目标内容（只读），顶上一行可点回原处�?
  Widget _embedCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final RefTarget? target = widget.bridge?.resolve(_refType, _refId);
    final List<EmbedLine> lines =
        widget.bridge?.preview?.call(_refType, _refId) ?? const <EmbedLine>[];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: Tokens.spaceXs / 2),
      // 左边一道竖�?= "这是别处的内�?（与引用�?quote 同一口气）�?
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: scheme.primary.withValues(alpha: 0.45),
            width: 3,
          ),
        ),
        color: scheme.primary.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(Tokens.radiusSm),
      ),
      padding: const EdgeInsets.fromLTRB(
        Tokens.spaceSm,
        Tokens.spaceXs,
        Tokens.spaceSm,
        Tokens.spaceXs,
      ),
      child: Column(
        crossAxisAlignment: .stretch,
        mainAxisSize: .min,
        children: <Widget>[
          // 顶行：来源标题。嵌入是只读的，这是**回到原处去编�?*的唯一入口�?
          GestureDetector(
            onTap: () => widget.bridge?.open(_refType, _refId),
            child: Row(
              children: <Widget>[
                tabler.LayoutDashboard(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(scheme.primary, ui.BlendMode.srcIn)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    target?.title ?? '',
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Tokens.spaceXs / 2),
          ...lines.isEmpty
              ? <Widget>[
                  Text(
                    '（没有可嵌入的内容）',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ]
              : <Widget>[
                  for (final EmbedLine line in lines) _embedLine(context, line),
                ],
        ],
      ),
    );
  }

  /// 嵌入内容的一行：**按块类型给一个只读的样子**（不套用编辑器组件—�?
  /// 目标属于另一篇笔记，没有本编辑器�?`EditorState`）�?
  Widget _embedLine(BuildContext context, EmbedLine line) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle base =
        theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 15);

    if (line.blockType == 'todo_list') {
      final bool done = line.checked ?? false;
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          crossAxisAlignment: .start,
          children: <Widget>[
            tabler.Checkbox(height: Tokens.iconXs, width: Tokens.iconXs, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(done ? scheme.primary : scheme.onSurfaceVariant, ui.BlendMode.srcIn)),
            const SizedBox(width: 6),
            Expanded(child: Text(line.text, style: base)),
          ],
        ),
      );
    }

    final TextStyle style = switch (line.blockType) {
      'heading' => base.copyWith(fontWeight: .w600),
      'quote' => base.copyWith(
        fontStyle: FontStyle.italic,
        color: scheme.onSurfaceVariant,
      ),
      'code' => base.copyWith(
        fontFamily: 'monospace',
        color: scheme.onSurface,
      ),
      _ => base,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(line.text, style: style, maxLines: 3, overflow: .ellipsis),
    );
  }

  static String _labelOf(String refType, {required bool missing}) {
    if (missing) return '断链';
    return refType == RefBlockKeys.refBlock ? '�? : '笔记';
  }
}
