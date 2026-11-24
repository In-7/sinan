import 'dart:async';

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../notes/services/note_media_service.dart';
import '../theme/app_float_surface.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'canvas_color_slot_panel.dart';
import 'canvas_edge_shape_panel.dart';
import 'canvas_header_bar.dart';
import 'canvas_insert_panel.dart';
import 'canvas_tool_strip.dart';
import 'canvas_view_bar.dart';
import 'canvas_shape_panel.dart';
import 'kernel/canvas_bundle.dart';
import 'kernel/canvas_controller.dart';
import 'kernel/canvas_item.dart';
import 'kernel/canvas_export.dart';
import 'kernel/canvas_media.dart';
import 'kernel/canvas_view.dart';

/// 画布面板（**可嵌入**）：顶部动作带 + [CanvasView] + 右下视图组。
///
/// 2026-09-16 从原 `canvas_page.dart` 抽出（那是整页路由版）。抽出后本组件
/// **不含 Scaffold / 路由**，可直接作为右侧内容区的一个视图挂载——文档笔记挂
/// 块编辑器、画布笔记挂本组件（见 `home_screen.dart` 的 `detailPane`）。
///
/// 职责与分层：内核（[CanvasController]/[CanvasView]）不依赖 Material，
/// 颜色与主题接线（[AppTheme] / [Tokens]）以及键盘、PNG 导出都收在这一层。
class CanvasSurface extends StatefulWidget {
  const CanvasSurface({
    super.key,
    required this.controller,
    required this.media,
    this.onImport,
    this.onSendCardToDocument,
    this.onAiRun,
    this.noteId,
    this.onOpenNote,
  });

  final CanvasController controller;

  /// 当前画布笔记 id（2026-11-21）：有值时顶部渲染 搜索/反链/标签 三只耳
  /// （面板都按 noteId 查）。独立演示 / 测试壳不传 ⇒ 只留撤销重做。
  final String? noteId;

  /// 反链条目点击 → 打开来源笔记。
  final void Function(String noteId)? onOpenNote;

  /// 跑一次 AI 指令（一句话 → 结构化动作 → 改画布）。由宿主提供：它持有
  /// [NoteStore]（候选块与块文本）与 LLM 客户端。为 null 时 AI 按钮不出现
  /// （见 `CanvasNoteView`：默认关闭，要用户去设置里显式开启）。
  final Future<void> Function(String instruction)? onAiRun;

  /// 导入 `.canvas.json`（**会替换**当前画布）：由宿主提供，因为它要问确认框
  /// 并换掉宿主持有的控制器（见 `CanvasNoteView._import`）。
  final Future<void> Function()? onImport;

  /// 把画布上选中的卡片**发回它的文档**（块可迁移 #5）。由宿主提供，因为它
  /// 持有 [NoteStore]、能把卡片的 `blockId` 真正落进文档块树；画布侧只负责把
  /// 卡片从内存摘掉（见 [CanvasController.detachSelectedCard]）。不提供则按钮不出现。
  final void Function(String blockId)? onSendCardToDocument;

  /// 媒体引用解析器：导出**自包含 `.canvas.json`** 时要把磁盘上的图片读出来
  /// 内联，得先经它把相对引用换算成绝对路径。
  final MediaResolver media;

  @override
  State<CanvasSurface> createState() => _CanvasSurfaceState();
}

class _CanvasSurfaceState extends State<CanvasSurface> {
  /// 顶部动作带的 State（Ctrl+F 要直接调它的 openFind）。
  final GlobalKey<CanvasHeaderBarState> _headerKey =
      GlobalKey<CanvasHeaderBarState>();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Brightness brightness = Theme.of(context).brightness;
    return Focus(
      // 键盘：空格临时抓手 / Delete 删所选 / Ctrl+Z·Ctrl+Shift+Z 撤销重做。
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Stack(
        children: <Widget>[
          // 画布**铺满整块**（2026-09-19 改 Column→Stack）：工具条从"占布局的
          // 一行"变成"叠在画布上"——画布拿回那 ~60px 高度；工具条两侧的空白
          // 也从"浪费的空行"变成画布本身（Figma / tldraw 的经典形态）。
          Positioned.fill(
            child: CanvasView(
              controller: widget.controller,
              // 画布是浮面卡内的**文档面**：取浮面档（暗 #161616 / 亮纯白），
              // 与笔记编辑区透明透出的卡底同色——不是窗口底（2026-10-09
              // 浮面外壳后 contentCanvas 是卡外 chrome / 移动端纸面）。
              backgroundColor: AppTheme.panelFill(brightness),
              // 墨色**必须与底色同源**：底色暗而墨色黑 = 看不见自己画了什么
              // （2026-09-17 用户反馈，见 AppTheme.canvasInk）。
              inkColor: AppTheme.canvasInk(brightness),
              gridColor: AppTheme.divider(scheme),
              accentColor: scheme.primary,
              // AI 层过期标记：用与主色不同的色角色，避免和选中框混淆。
              staleColor: scheme.tertiary,
            ),
          ),
          // 顶部**一条浮岛带**（2026-11-21 用户定案）：撤销/重做 │ 8 个绘制
          // 工具 │ 搜索/反链/标签。底部中间因此完全腾空。
          // 右缘避让 AI 折叠钮（2026-11-24）：折叠钮热区 28 + 呼吸 12。
          Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(
                right: Tokens.collapseButtonSlotWidth,
              ),
              child: CanvasHeaderBar(
                key: _headerKey,
                controller: widget.controller,
                noteId: widget.noteId,
                onOpenNote: widget.onOpenNote,
                center: CanvasToolStrip(
                  controller: widget.controller,
                  onInsertImage: () => _insertImage(context, widget.controller),
                  onAiRun: widget.onAiRun,
                ),
              ),
            ),
          ),
          // 右下：视图组（缩放 4 件 + 「更多」收文件级动作）。缩放改的是视角、
          // 与"画什么"不同层，按 Figma / Miro / tldraw 的惯例放角落；左下留给
          // 删除通知条（[showUndoToast]）。
          Align(
            alignment: Alignment.bottomRight,
            child: Container(
              margin: const EdgeInsets.only(
                right: Tokens.spaceMd,
                bottom: Tokens.spaceSm,
              ),
              child: CanvasViewBar(
                controller: widget.controller,
                onExport: () => _export(context, widget.controller),
                onExportBundle: () => _exportBundle(context, widget.controller),
                onImport: widget.onImport,
              ),
            ),
          ),
          // 选中物体的**上下文动作条**（tldraw / Figma 形态）：选区非空时浮在包围盒
          // 正上方，把"选中后怎么改"就近贴在物体旁；无选区则自身渲染成空、不占层。
          _CanvasContextBar(
            controller: widget.controller,
            onSendCardToDocument: widget.onSendCardToDocument,
          ),
        ],
      ),
    );
  }

  Future<void> _export(
    BuildContext context,
    CanvasController controller,
  ) async {
    // 在 async gap 之前取出 messenger 状态，避免跨 await 使用 BuildContext。
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final File file = await exportCanvasToPng(
        controller,
        directory: 'sinan_media',
        pixelRatio: MediaQuery.of(context).devicePixelRatio,
      );
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('已导出：${file.path}')));
      }
    } on Object catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  /// 导出**自包含** `.canvas.json`：文档 + 图片字节（base64 内联），单个文件即
  /// 可带走——换机器 / 发给别人也能完整打开（见 `canvas_bundle.dart`）。
  Future<void> _exportBundle(
    BuildContext context,
    CanvasController controller,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final File file = await exportCanvasBundle(
        controller,
        media: widget.media,
        directory: 'sinan_media',
      );
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('已导出画布文件：${file.path}')));
      }
    } on Object catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  /// 插入图片：拾取（可多选）→ 复制进应用数据目录 → 逐张建 item。
  ///
  /// 走 [NoteMediaService]（与笔记里的插图同一个落点 `<appSupport>/media/`）：
  /// 文件被复制进数据目录，画布因此**自包含**——源文件删了/挪了都不影响，
  /// 存 JSON 时再经 `MediaResolver` 写成相对引用（换机器也能打开）。
  Future<void> _insertImage(
    BuildContext context,
    CanvasController controller,
  ) async {
    // 在 async gap 之前取出 messenger，避免跨 await 用 BuildContext。
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final List<String> paths = await NoteMediaService.pickAndStoreImages();
      if (paths.isEmpty) return; // 用户取消
      // 多选时逐张错开，避免全部叠在视口中心（看起来像只插了一张）。
      for (int i = 0; i < paths.length; i++) {
        await insertImageFromPath(
          controller,
          paths[i],
          screenOffset: Offset(24.0 * i, 24.0 * i),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('插入图片失败：$e')));
      }
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.space) {
      widget.controller.setSpacePanning(event is KeyDownEvent);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final bool ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        widget.controller.redo();
      } else {
        widget.controller.undo();
      }
      return KeyEventResult.handled;
    }
    // Ctrl+F：与笔记一致，开本画布的搜索（找卡片文字）。走顶部动作带同一条
    // 路径，不另起一套浮层（2026-11-21）。
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyF) {
      _headerKey.currentState?.openFind();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      widget.controller.deleteSelection();
      return KeyEventResult.handled;
    }
    // Esc：退出形状/连线工具（回选择）。缺了它，形状工具下拖拽永远是"画新的"，
    // 既点不中、也拖不动已有图形——用户会以为卡住了；连线工具下则"退不出来"
    // （setTool 会顺带清掉进行中的预览与选中）。
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        (widget.controller.tool == CanvasTool.shape ||
            widget.controller.tool == CanvasTool.connect)) {
      widget.controller.setTool(CanvasTool.select);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

/// 块可迁移（#5）：把画布上选中的单张卡片「发回文档」。
///
/// 只有恰好选中一张卡片、且宿主提供了 [onSendCardToDocument] 时才显示；否则渲染成空。
/// 按下时：先让控制器把卡片从内存摘除（[CanvasController.detachSelectedCard]，
/// 顺带触发画布防抖保存），再把它的 `blockId` 交给宿主真正落进文档块树。
class _SendCardToDocumentButton extends StatelessWidget {
  const _SendCardToDocumentButton({
    required this.controller,
    required this.onSendCardToDocument,
  });

  final CanvasController controller;
  final void Function(String blockId)? onSendCardToDocument;

  @override
  Widget build(BuildContext context) {
    if (controller.selectedCard == null || onSendCardToDocument == null) {
      return const SizedBox.shrink();
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return TextButton(
      onPressed: () {
        final String? blockId = controller.detachSelectedCard();
        if (blockId != null) onSendCardToDocument!(blockId);
      },
      style: TextButton.styleFrom(
        foregroundColor: scheme.primary,
        padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceSm),
        // 与工具按钮同档（shrinkWrap，见 CanvasToolStrip 的说明）。
        minimumSize: const Size(0, Tokens.toolbarButtonSize),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: const Text('发回文档'),
    );
  }
}

/// 「收藏」按钮（2026-11-20 用户定）：只在选中**单张**卡片时出现——切换收藏
/// （`CardItem.promotedAt` + 浮顶）。已收藏实心星、未收藏空心星。
class _FavoriteCardButton extends StatelessWidget {
  const _FavoriteCardButton({required this.controller});

  final CanvasController controller;

  @override
  Widget build(BuildContext context) {
    final CardItem? card = controller.selectedCard;
    if (card == null) return const SizedBox.shrink();
    final bool promoted = card.promotedAt != null;
    return IconButton(
      onPressed: controller.toggleFavoriteSelectedCard,
      tooltip: promoted ? '取消收藏' : '收藏',
      icon: promoted
          ? const tabler.StarFilled(
              height: Tokens.iconMd,
              width: Tokens.iconMd,
              strokeWidth: 1.5,
            )
          : const tabler.Star(
              height: Tokens.iconMd,
              width: Tokens.iconMd,
              strokeWidth: 1.5,
            ),
    );
  }
}

/// 选中物体的**上下文动作条**（tldraw / Figma 形态）。
///
/// 当选区非空（[CanvasController.selectionBounds] 非 null）时，浮在选区世界包围盒
/// 的**正上方**——图形 / 语义色 / 连线端点 / 发回文档四个属性与删除，从此就近贴在
/// 物体旁；无选区则渲染成空、不占层。顶部工具组因此只剩"画什么"的工具
/// （见 [CanvasToolStrip]），正是这套设计要解决的"工具条有点复杂"。
///
/// 订阅控制器：选区或相机（平移 / 缩放）变化时重定位，条跟着选中物走。位置由
/// [_ContextBarLayout] 计算——**水平居中于选区顶部**、**上方留 8px**，视口顶边不够
/// 则翻到选区下方，最后整体夹在视口内（不跑出画布）。
///
/// 命中测试：本组件铺满 Stack，但 [CustomSingleChildLayout] 只把命中交给那条小岛，
/// 空白处仍落到画布——拖拽选中物时不会被这条压住。
class _CanvasContextBar extends StatelessWidget {
  const _CanvasContextBar({
    required this.controller,
    required this.onSendCardToDocument,
  });

  final CanvasController controller;
  final void Function(String blockId)? onSendCardToDocument;

  Future<void> _confirmDelete(BuildContext context) async {
    final int count = controller.selectedItems.length +
        controller.selection.length +
        (controller.selectedEdge != null ? 1 : 0);
    if (count == 0) return;

    // 批量删除（>3个）时弹确认框
    if (count > 3) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('确认删除'),
          content: Text('删除 $count 个项目？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    controller.deleteSelection();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final Rect? worldBox = controller.selectionBounds;
        if (worldBox == null) return const SizedBox.shrink();
        // 选区世界包围盒 → 屏幕坐标（与 Stack 同原点）；视口用来夹取。
        final Offset anchor = controller.camera.worldToScreen(
          worldBox.topCenter,
        );
        final Size viewport = controller.viewport;
        return CustomSingleChildLayout(
          delegate: _ContextBarLayout(anchor: anchor, viewport: viewport),
          // 与底部工具条同档热区（见 [_CanvasToolbar] 的 [IconButtonTheme] 说明）。
          child: IconButtonTheme(
            data: IconButtonThemeData(
              style: IconButton.styleFrom(
                iconSize: Tokens.iconMd,
                fixedSize: const Size(
                  Tokens.toolbarButtonSize,
                  Tokens.toolbarButtonSize,
                ),
                minimumSize: const Size(
                  Tokens.toolbarButtonSize,
                  Tokens.toolbarButtonSize,
                ),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            child: AppFloatSurface(
              padding: const EdgeInsets.symmetric(
                horizontal: Tokens.spaceXs,
                vertical: Tokens.spaceXs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // 图形属性：只在选中形状时出现（内部自判，未选中时渲染成空）。
                  CanvasShapeButton(controller: controller),
                  // 语义色：只在选中卡片 / 思维导图时出现（内部自判）。
                  CanvasColorSlotButton(controller: controller),
                  // 端点形状：只在选中一条连线时出现（内部自判）。
                  CanvasEdgeShapeButton(controller: controller),
                  // 块可迁移（#5）：只在选中**单张**卡片时出现——把这张卡片发回它的文档。
                  _SendCardToDocumentButton(
                    controller: controller,
                    onSendCardToDocument: onSendCardToDocument,
                  ),
                  // 收藏（2026-11-20 用户定）：只在选中**单张**卡片时出现——切换
                  // 收藏（promotedAt + 浮顶）。已收藏实心星、未收藏空心星。
                  _FavoriteCardButton(controller: controller),
                  // 分隔线（显式高度，理由同 [_CanvasToolbar]）。
                  const SizedBox(height: 24, child: VerticalDivider(width: 24)),
                  IconButton(
                    icon: const tabler.Trash(
                      height: Tokens.iconMd,
                      width: Tokens.iconMd,
                      strokeWidth: 1.5,
                    ),
                    tooltip: '删除所选（Delete）',
                    onPressed: () => _confirmDelete(context),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// [_CanvasContextBar] 的定位：把那条小岛摆在 [anchor]（选区顶部中点，屏幕坐标）
/// 正上方 8px，水平居中；顶边放不下则翻到下方，整体夹在视口内。
class _ContextBarLayout extends SingleChildLayoutDelegate {
  _ContextBarLayout({required this.anchor, required this.viewport});

  final Offset anchor;
  final Size viewport;

  @override
  bool shouldRelayout(covariant _ContextBarLayout old) =>
      old.anchor != anchor || old.viewport != viewport;

  @override
  Size getSize(BoxConstraints constraints) => constraints.biggest;

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const double gap = 8;
    double x = anchor.dx - childSize.width / 2;
    double y = anchor.dy - childSize.height - gap;
    // 上方没空间（贴着视口顶或跑到屏外）：翻到选区下方。
    if (y < 0) y = anchor.dy + gap;
    // 夹在视口内，不跑出画布（[size] 即铺满 Stack 的画布尺寸）。
    x = x.clamp(0, size.width - childSize.width);
    y = y.clamp(0, size.height - childSize.height);
    return Offset(x, y);
  }
}

// 撤销 / 重做已并入顶部动作带 [CanvasHeaderBar]（2026-11-21）：与笔记标题行
// 同一位置、同一规格，不再单独做一个浮岛。
