import 'dart:async';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'dart:io';

import 'package:flutter/services.dart';import 'package:material_ui/material_ui.dart';

import '../notes/services/note_media_service.dart';
import '../theme/app_float_surface.dart';
import '../theme/app_theme.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';
import 'canvas_ai_button.dart';
import 'canvas_brush_panel.dart';
import 'canvas_color_slot_panel.dart';
import 'canvas_edge_shape_panel.dart';
import 'canvas_insert_panel.dart';
import 'canvas_shape_panel.dart';
import 'kernel/canvas_bundle.dart';
import 'kernel/canvas_controller.dart';
import 'kernel/canvas_export.dart';
import 'kernel/canvas_media.dart';
import 'kernel/canvas_view.dart';

/// 画布面板�?*可嵌�?*）：工具�?+ [CanvasView]�?
///
/// 2026-09-16 从原 `canvas_page.dart` 抽出（那是整页路由版）。抽出后本组�?
/// **不含 Scaffold / 路由**，可直接作为右侧内容区的一个视图挂载——文档笔记挂
/// 块编辑器、画布笔记挂本组件（�?`home_screen.dart` �?`detailPane`）�?
///
/// 职责与分层：内核（[CanvasController]/[CanvasView]）不依赖 Material�?
/// 颜色与主题接线（[AppTheme] / [Tokens]）以及键盘、PNG 导出都收在这一层�?
class CanvasSurface extends StatefulWidget {
  const CanvasSurface({
    super.key,
    required this.controller,
    required this.media,
    this.onImport,
    this.onSendCardToDocument,
    this.onAiRun,
  });

  final CanvasController controller;

  /// 跑一�?AI 指令（一句话 �?结构化动�?�?改画布）。由宿主提供：它持有
  /// [NoteStore]（候选块与块文本）与 LLM 客户端。为 null �?AI 按钮不出�?
  /// （见 `CanvasNoteView`：默认关闭，要用户去设置里显式开启）�?
  final Future<void> Function(String instruction)? onAiRun;

  /// 导入 `.canvas.json`�?*会替�?*当前画布）：由宿主提供，因为它要问确认框
  /// 并换掉宿主持有的控制器（�?`CanvasNoteView._import`）�?
  final Future<void> Function()? onImport;

  /// 把画布上选中的卡�?*发回它的文档**（块可迁�?#5）。由宿主提供，因为它
  /// 持有 [NoteStore]、能把卡片的 `blockId` 真正落进文档块树；画布侧只负责把
  /// 卡片从内存摘掉（�?[CanvasController.detachSelectedCard]）。不提供则按钮不出现�?
  final void Function(String blockId)? onSendCardToDocument;

  /// 媒体引用解析器：导出**自包�?`.canvas.json`** 时要把磁盘上的图片读出来
  /// 内联，得先经它把相对引用换算成绝对路径�?
  final MediaResolver media;

  @override
  State<CanvasSurface> createState() => _CanvasSurfaceState();
}

class _CanvasSurfaceState extends State<CanvasSurface> {
  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Brightness brightness = Theme.of(context).brightness;
    return Focus(
      // 键盘：空格临时抓�?/ Delete 删所�?/ Ctrl+Z·Ctrl+Shift+Z 撤销重做�?
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Stack(
        children: <Widget>[
          // 画布**铺满整块**�?026-09-19 �?Column→Stack）：工具条从"占布局�?
          // 一�?变成"叠在画布�?——画布拿回那 ~60px 高度；工具条两侧的空�?
          // 也从"浪费的空�?变成画布本身（Figma / tldraw 的经典形态）�?
          Positioned.fill(
            child: CanvasView(
              controller: widget.controller,
              // 与笔记编辑区同一块画布底色（�?暗都跟随主题）�?
              backgroundColor: AppTheme.contentCanvas(brightness),
              // 墨色**必须与底色同�?*：底色暗而墨色黑 = 看不见自己画了什�?
              // �?026-09-17 用户反馈，见 AppTheme.canvasInk）�?
              inkColor: AppTheme.canvasInk(brightness),
              gridColor: AppTheme.divider(scheme),
              accentColor: scheme.primary,
              // AI 层过期标记：用与主色不同的色角色，避免和选中框混淆�?
              staleColor: scheme.tertiary,
            ),
          ),
          // 工具条：真悬浮，底部居中（tldraw 形态）。比顶部居中更贴手——画�?
          // 主力操作在视野中央，工具条在下方正中离鼠标动线最近；同样不占布局
          // （画布铺满整块），遮挡的只是底部一条、平移即可躲开�?
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.only(
                bottom: Tokens.spaceSm,
                left: Tokens.spaceMd,
                right: Tokens.spaceMd,
              ),
              // 高度不再钉死（原 minHeight 44）：卡片随内容收缩——按钮统一
              // 32（见 [Tokens.toolbarButtonSize]�? 上下 4 呼吸 = 40�?
              child: _CanvasToolbar(
                controller: widget.controller,
                onExport: () => _export(context, widget.controller),
                onExportBundle: () => _exportBundle(context, widget.controller),
                onInsertImage: () => _insertImage(context, widget.controller),
                onImport: widget.onImport,
                onSendCardToDocument: widget.onSendCardToDocument,
                onAiRun: widget.onAiRun,
              ),
            ),
          ),
          // 撤销 / 重做：画�?*左上�?*常驻浮岛，姿态与笔记标题行左端一致—�?
          // 文档级、无选区也要能用（Word / VS Code / 笔记同款），不挤进底部工具条�?
          // �?[ListenableBuilder] 订阅控制器：历史栈变空时按钮自动灰显�?
          Align(
            alignment: Alignment.topLeft,
            child: Container(
              margin: const EdgeInsets.only(
                top: Tokens.spaceSm,
                left: Tokens.spaceMd,
              ),
              child: _CanvasHistoryBar(controller: widget.controller),
            ),
          ),
          // 选中物体�?*上下文动作条**（tldraw / Figma 形态）：选区非空时浮在包围盒
          // 正上方，�?选中后怎么�?就近贴在物体旁；无选区则自身渲染成空、不占层�?
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
    // �?async gap 之前取出 messenger 状态，避免�?await 使用 BuildContext�?
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
        messenger.showSnackBar(SnackBar(content: Text('导出失败�?e')));
      }
    }
  }

  /// 导出**自包�?* `.canvas.json`：文�?+ 图片字节（base64 内联），单个文件�?
  /// 可带走——换机器 / 发给别人也能完整打开（见 `canvas_bundle.dart`）�?
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
        messenger.showSnackBar(SnackBar(content: Text('导出失败�?e')));
      }
    }
  }

  /// 插入图片：拾取（可多选）�?复制进应用数据目�?�?逐张�?item�?
  ///
  /// �?[NoteMediaService]（与笔记里的插图同一个落�?`<appSupport>/media/`）：
  /// 文件被复制进数据目录，画布因�?*自包�?*——源文件删了/挪了都不影响�?
  /// �?JSON 时再�?`MediaResolver` 写成相对引用（换机器也能打开）�?
  Future<void> _insertImage(
    BuildContext context,
    CanvasController controller,
  ) async {
    // �?async gap 之前取出 messenger，避免跨 await �?BuildContext�?
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final List<String> paths = await NoteMediaService.pickAndStoreImages();
      if (paths.isEmpty) return; // 用户取消
      // 多选时逐张错开，避免全部叠在视口中心（看起来像只插了一张）�?
      for (int i = 0; i < paths.length; i++) {
        await insertImageFromPath(
          controller,
          paths[i],
          screenOffset: Offset(24.0 * i, 24.0 * i),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('插入图片失败�?e')));
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
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      widget.controller.deleteSelection();
      return KeyEventResult.handled;
    }
    // Esc：退出形�?连线工具（回选择）。缺了它，形状工具下拖拽永远�?画新�?�?
    // 既点不中、也拖不动已有图形——用户会以为卡住了；连线工具下则"退不出�?
    // （setTool 会顺带清掉进行中的预览与选中）�?
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        (widget.controller.tool == CanvasTool.shape ||
            widget.controller.tool == CanvasTool.connect)) {
      widget.controller.setTool(CanvasTool.select);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

/// 工具条：工具切换 + 撤销/重做 + 缩放 + 删除所选�?
///
/// �?[ListenableBuilder] 订阅控制器（工具/撤销态变化即刷新），
/// 尺寸与图标档位走 [Tokens]（与编辑器工具栏同口径）�?
class _CanvasToolbar extends StatelessWidget {
  const _CanvasToolbar({
    required this.controller,
    this.onExport,
    this.onExportBundle,
    this.onInsertImage,
    this.onImport,
    this.onSendCardToDocument,
    this.onAiRun,
  });

  /// 跑一�?AI 指令（见 [CanvasSurface.onAiRun]）；�?null 时按钮不渲染�?
  final Future<void> Function(String instruction)? onAiRun;

  final CanvasController controller;

  /// 导出当前画布�?PNG 的回调（由面板提供，需 BuildContext）�?
  final VoidCallback? onExport;

  /// 导出**自包�?* `.canvas.json`（含图片字节）的回调�?
  final VoidCallback? onExportBundle;

  /// 插入图片（拾�?+ 落盘）的回调：需 BuildContext 做错误提示，故由面板提供�?
  final Future<void> Function()? onInsertImage;

  /// 导入 `.canvas.json`（替换当前画布）的回调，理由�?[onInsertImage]�?
  final Future<void> Function()? onImport;

  /// 把选中卡片发回文档（块可迁�?#5）；�?null 时按钮不渲染�?
  final void Function(String blockId)? onSendCardToDocument;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? child) {
        Widget toolButton(CanvasTool tool, Widget icon, String tooltip) {
          final bool selected = controller.tool == tool;
          // `FocusRingIconButton`：统一焦点环（§5.2）。工具条本来键盘可达
          // （`IconButton` 自带焦点），缺的�?我在�?的表达——此前只�?M3
          // 那层淡色状态层，键盘用户在 11 个同形按钮里看不出自己在哪个上�?
          return FocusRingIconButton(
            icon: icon,
            tooltip: tooltip,
            style: ButtonStyle(
              // 选中态直接用主题主色（real 种子色），不借派生色角色—�?
              // 主题色本就“少而强调”，�?secondaryContainer 搬暗反而看不出强调�?
              // onPrimary �?M3 算法专门�?primary 的前景，包票 �?.5:1 对比�?
              backgroundColor: WidgetStatePropertyAll<Color>(
                selected ? scheme.primary : Colors.transparent,
              ),
              foregroundColor: WidgetStatePropertyAll<Color>(
                selected ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            ),
            onPressed: () => controller.setTool(tool),
          );
        }

        // 统一按钮热区�?026-09-19）：此前各处裸用 M3 默认 IconButton
        // �?0×40 布局 + 48 padded 热区），按钮顶出卡片边缘。在根部�?
        // [IconButtonTheme] 一处管住本工具条（含四个面板入口按钮）�?*所�?*
        // IconButton——单个按钮自己的 `style:` 只覆盖颜色，尺寸仍落到这里�?
        return IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(
              iconSize: Tokens.iconMd,
              // 正方热区 + shrinkWrap：布局尺寸=热区尺寸�?8 �?padded 目标
              // 会把布局也撑�?48�?看不见的�?顶出卡片）�?
              fixedSize: const Size(
                Tokens.toolbarButtonSize,
                Tokens.toolbarButtonSize,
              ),
              minimumSize: const Size(
                Tokens.toolbarButtonSize,
                Tokens.toolbarButtonSize,
              ),
              padding: EdgeInsets.zero,
              tapTargetSize: .shrinkWrap,
            ),
          ),
          child: AppFloatSurface(
            // 浮层三件套（底色 + 描边 + 投影）：与项目其余浮层同一套语言
            // �?026-09-19 改：原先�?底色与画布同色、连成一�?的通栏）�?
            //
            // ⚠️ 刻意**不用** `BackdropFilter` 做毛玻璃：画布是三层 CustomPaint
            // 高频重绘（写�?/ 拖动 / 缩放），blur 会跟着每帧重算 —�?SaveLayer
            // �?Impeller 下的性能红线。要"透出下面一�?，靠底色 alpha 就够�?
            // 胶囊圆角 = 半个条高（按�?32 + 上下 4×2 = 40 �?圆角 20）：
            // 与按钮的圆形选中底（M3 IconButton 默认 CircleBorder）同曲率�?
            // 整条看是一枚拉长的胶囊、按钮是嵌在里面的圆，观感统一
            // �?026-09-19 用户反馈：radiusLg=14 与圆形按钮不搭）�?
            borderRadius: BorderRadius.circular(
              (Tokens.toolbarButtonSize + Tokens.spaceXs * 2) / 2,
            ),
            // 水平 12 / 垂直 4：按钮不再贴卡片边缘（此前垂直为 0�?
            // 选中高亮块与圆角描边直接相交）�?
            padding: const EdgeInsets.symmetric(
              horizontal: Tokens.spaceSm,
              vertical: Tokens.spaceXs,
            ),
            // ⚠️ �?Wrap 而不是固定高度的 Row：按钮排不下�?*换行继续显示**�?
            // 实测反馈：先前的"横向滚动"版拖窄后"按钮看不到了"——滚动条�?44px 高的
            // 条里既不显眼、又压内容。Wrap 一个都不会藏；单行放得下时�?Row 观感一致�?
            child: Wrap(
              crossAxisAlignment: .center,
              children: <Widget>[
                // 工具排布对齐 tldraw：选择 �?抓手 �?画笔 �?橡皮 �?连线�?
                // 属性（笔刷�? 插入随后。画笔与橡皮的内核能力（InkStroke /
                // 压感 / 橡皮�?/ 分片持久化）一直保留，2026-09-19 �?工具�?
                // 功能对齐 tldraw"重新挂回�?
                toolButton(
                  CanvasTool.select,
                  const tabler.Mouse(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                  '选择 / 框�?,
                ),
                toolButton(CanvasTool.pan, const tabler.HandStop(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5), '抓手（空格）'),
                toolButton(CanvasTool.pen, const tabler.Edit(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5), '画笔'),
                toolButton(CanvasTool.eraser, const tabler.Eraser(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5), '橡皮'),
                toolButton(
                  CanvasTool.connect,
                  const tabler.Hierarchy(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                  '连线（从一个卡片拖到另一个）',
                ),
                // 笔刷设置（颜�?/ 笔迹粗细 / 橡皮大小）：画笔 / 橡皮工具
                // 生效期间保持"选中"，同 [CanvasInsertButton] 对形状工具的处理�?
                CanvasBrushButton(controller: controller),
                CanvasInsertButton(
                  controller: controller,
                  onInsertImage: onInsertImage ?? () async {},
                ),
                // AI 入口紧挨"插入"：两者都�?往画布上加东西"，姿态一致�?
                // `onAiRun == null`（未在设置里启用）时整块不渲染——比留一�?
                // 点了报错的按钮好�?
                if (onAiRun != null) CanvasAiButton(onRun: onAiRun!),
                // 选中�?怎么�?不放主条：图�?/ 语义�?/ 连线端点 / 发回文档这四�?
                // 属性与删除，已搬到选区正上方的上下文动作条（见 [_CanvasContextBar]�?
                // 对齐 tldraw / Figma）——主工具条只�?画什�?的工具，立刻瘦下来�?
                // 撤销 / 重做已搬到画�?*左上�?*（见 [_CanvasHistoryBar]），姿态与
                // 笔记标题行左端一致——它们是文档级、无选区也要能用，不该挤在底�?
                // 工具条里；底部条只留"当前画布"的工具�?
                // Wrap 里给分隔�?*显式高度**：VerticalDivider 默认不限高，
                // 在不定高�?Wrap 里会直接报无限高度�?
                const SizedBox(height: 24, child: VerticalDivider(width: 24)),
                FocusRingIconButton(
                  icon: const tabler.ZoomOut(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                  tooltip: '缩小',
                  onPressed: () => controller.zoomBy(1 / 1.25),
                ),
                // 放大倍数**实时显示**，与放大/缩小同组：滚�?/ 抓手 / 适应内容
                // 引发的缩放也会跟着变（工具栏外�?ListenableBuilder 订阅了控制器）�?
                // 固定最小宽度：位数变化时按钮不会左右抖、Wrap 也不会跳行�?
                // shrinkWrap + �?32：TextButton 默认 padded 热区�?8）会�?
                // 布局也撑高，同样顶出卡片——与 IconButton 统一档位�?
                _ZoomBadge(
                  controller: controller,
                  foreground: scheme.onSurfaceVariant,
                  textStyle: Theme.of(context).textTheme.labelMedium,
                ),
                FocusRingIconButton(
                  icon: const tabler.ZoomIn(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                  tooltip: '放大',
                  onPressed: () => controller.zoomBy(1.25),
                ),
                FocusRingIconButton(
                  icon: const tabler.ArrowsMaximize(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                  tooltip: '适应内容',
                  onPressed: controller.fitToContent,
                ),
                FocusRingIconButton(
                  icon: const tabler.Photo(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                  tooltip: '导出 PNG',
                  onPressed: onExport,
                ),
                FocusRingIconButton(
                  icon: const tabler.Package(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                  tooltip: '导出画布文件�?canvas.json，含图片�?,
                  onPressed: onExportBundle,
                ),
                FocusRingIconButton(
                  icon: const tabler.Download(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                  tooltip: '导入画布文件�?canvas.json，替换当前画布）',
                  onPressed: onImport,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 缩放倍数徽标：`TextButton` + 统一焦点环（§5.2 第二步）�?
///
/// 为什么单独一件、不复用 [FocusRingIconButton]：形状不同。`IconButton` 是圆
/// （那件的默认圆角�?`RRect` 夹成圆），�?`TextButton` 的形状来自全局
/// `textButtonTheme` �?`shapeSm` �?环的圆角得显式跟它对齐，否则环与按钮"错位"
/// 一个圆角�?*这是第一�?`TextButton` 消费�?*——等第二个出现再抽共用，
/// 现在抽等于按一个调用点猜接口�?
///
/// 其余取舍沿用原位：固定最小宽度（位数变化时按钮不左右抖、`Wrap` 不跳行）�?
/// `shrinkWrap` + �?32（`TextButton` 默认 padded 热区 48 会把布局也撑高，顶出卡片）�?
class _ZoomBadge extends StatefulWidget {
  const _ZoomBadge({
    required this.controller,
    required this.foreground,
    required this.textStyle,
  });

  final CanvasController controller;
  final Color foreground;
  final TextStyle? textStyle;

  @override
  State<_ZoomBadge> createState() => _ZoomBadgeState();
}

class _ZoomBadgeState extends State<_ZoomBadge> {
  /// 同一个节点交�?*两边**（`FocusRing` + `TextButton`），理由�?[FocusRing]�?
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusRing(
      focusNode: _focus,
      borderRadius: BorderRadius.circular(Tokens.radiusSm),
      child: Tooltip(
        message: '当前缩放（点击回�?100%�?,
        child: TextButton(
          focusNode: _focus,
          onPressed: widget.controller.resetZoom,
          style: TextButton.styleFrom(
            minimumSize: const Size(56, Tokens.toolbarButtonSize),
            tapTargetSize: .shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceXs),
            foregroundColor: widget.foreground,
            textStyle: widget.textStyle,
          ),
          child: Text('${(widget.controller.camera.scale * 100).round()}%'),
        ),
      ),
    );
  }
}

/// 块可迁移�?5）：把画布上选中的单张卡片「发回文档」�?
///
/// 只有恰好选中一张卡片、且宿主提供�?[onSendCardToDocument] 时才显示；否则渲染成空�?
/// 按下时：先让控制器把卡片从内存摘除（[CanvasController.detachSelectedCard]�?
/// 顺带触发画布防抖保存），再把它的 `blockId` 交给宿主真正落进文档块树�?
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
        // 与工具条其他按钮同档（shrinkWrap，见 _CanvasToolbar 的说明）�?
        minimumSize: const Size(0, Tokens.toolbarButtonSize),
        tapTargetSize: .shrinkWrap,
      ),
      child: const Text('发回文档'),
    );
  }
}

/// 选中物体�?*上下文动作条**（tldraw / Figma 形态）�?
///
/// 当选区非空（[CanvasController.selectionBounds] �?null）时，浮在选区世界包围�?
/// �?*正上�?*——图�?/ 语义�?/ 连线端点 / 发回文档四个属性与删除，从此就近贴�?
/// 物体旁；无选区则渲染成空、不占层。主工具条因此只�?画什�?的工具（�?
/// [_CanvasToolbar] 里那条说明），正是这套设计要解决�?工具条有点复�?�?
///
/// 订阅控制器：选区或相机（平移 / 缩放）变化时重定位，条跟着选中物走。位置由
/// [_ContextBarLayout] 计算—�?*水平居中于选区顶部**�?*上方�?8px**，视口顶边不�?
/// 则翻到选区下方，最后整体夹在视口内（不跑出画布）�?
///
/// 命中测试：本组件铺满 Stack，但 [CustomSingleChildLayout] 只把命中交给那条小岛�?
/// 空白处仍落到画布——拖拽选中物时不会被这条压住�?
class _CanvasContextBar extends StatelessWidget {
  const _CanvasContextBar({
    required this.controller,
    required this.onSendCardToDocument,
  });

  final CanvasController controller;
  final void Function(String blockId)? onSendCardToDocument;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final Rect? worldBox = controller.selectionBounds;
        if (worldBox == null) return const SizedBox.shrink();
        // 选区世界包围�?�?屏幕坐标（与 Stack 同原点）；视口用来夹取�?
        final Offset anchor = controller.camera.worldToScreen(
          worldBox.topCenter,
        );
        final Size viewport = controller.viewport;
        return CustomSingleChildLayout(
          delegate: _ContextBarLayout(anchor: anchor, viewport: viewport),
          // 与底部工具条同档热区（见 [_CanvasToolbar] �?[IconButtonTheme] 说明）�?
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
                tapTargetSize: .shrinkWrap,
              ),
            ),
            child: AppFloatSurface(
              padding: const EdgeInsets.symmetric(
                horizontal: Tokens.spaceXs,
                vertical: Tokens.spaceXs,
              ),
              child: Row(
                mainAxisSize: .min,
                children: <Widget>[
                  // 图形属性：只在选中形状时出现（内部自判，未选中时渲染成空）�?
                  CanvasShapeButton(controller: controller),
                  // 语义色：只在选中卡片 / 思维导图时出现（内部自判）�?
                  CanvasColorSlotButton(controller: controller),
                  // 端点形状：只在选中一条连线时出现（内部自判）�?
                  CanvasEdgeShapeButton(controller: controller),
                  // 块可迁移�?5）：只在选中**单张**卡片时出现——把这张卡片发回它的文档�?
                  _SendCardToDocumentButton(
                    controller: controller,
                    onSendCardToDocument: onSendCardToDocument,
                  ),
                  // 分隔线（显式高度，理由同 [_CanvasToolbar]）�?
                  const SizedBox(height: 24, child: VerticalDivider(width: 24)),
                  IconButton(
                    icon: const tabler.Trash(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                    tooltip: '删除所选（Delete�?,
                    onPressed: controller.deleteSelection,
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

/// [_CanvasContextBar] 的定位：把那条小岛摆�?[anchor]（选区顶部中点，屏幕坐标）
/// 正上�?8px，水平居中；顶边放不下则翻到下方，整体夹在视口内�?
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
    // 上方没空间（贴着视口顶或跑到屏外）：翻到选区下方�?
    if (y < 0) y = anchor.dy + gap;
    // 夹在视口内，不跑出画布（[size] 即铺�?Stack 的画布尺寸）�?
    x = x.clamp(0, size.width - childSize.width);
    y = y.clamp(0, size.height - childSize.height);
    return Offset(x, y);
  }
}

/// 画布左上角的撤销 / 重做浮岛，与笔记标题行左端的常驻历史按钮同一定位逻辑�?
///
/// 它们�?*文档级、无选区也要能用**的操作（Word / VS Code / 笔记同款），故从
/// 底部工具条抽出、常驻画布左上角，不挤进"当前画布"的工具区�?
///
/// 与底部工具条同款 [AppFloatSurface] 浮岛（底�?+ 描边 + 投影），保持画布内浮�?
/// 语言统一；[ListenableBuilder] 订阅控制器，历史栈空时按钮自动灰显�?
class _CanvasHistoryBar extends StatelessWidget {
  const _CanvasHistoryBar({required this.controller});

  final CanvasController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) => IconButtonTheme(
        // 与底部工具条同档热区（见 [_CanvasToolbar] �?[IconButtonTheme] 说明）�?
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
            tapTargetSize: .shrinkWrap,
          ),
        ),
        child: AppFloatSurface(
          // 圆角不指定：继承浮层默认�?radiusLg（与全场浮层统一）�?
          padding: const EdgeInsets.symmetric(
            horizontal: Tokens.spaceXs,
            vertical: Tokens.spaceXs,
          ),
          child: Row(
            mainAxisSize: .min,
            children: <Widget>[
              IconButton(
                icon: const tabler.ArrowBackUp(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                tooltip: '撤销（Ctrl+Z�?,
                onPressed: controller.document.canUndo ? controller.undo : null,
              ),
              IconButton(
                icon: const tabler.ArrowForwardUp(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
                tooltip: '重做（Ctrl+Shift+Z�?,
                onPressed: controller.document.canRedo ? controller.redo : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
