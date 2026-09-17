import 'dart:io';

import 'package:flutter/gestures.dart'
    show EagerGestureRecognizer, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/tokens.dart';
import 'note_context_menu.dart';
import 'note_image_preview.dart';
import 'note_media_service.dart';

/// 图片嵌入渲染（路线 B 自建渲染，数据格式对齐官方扩展）：
///
/// Delta 里存 `{image: 路径, width?: 逻辑像素}`（width 可选，缺省
/// 撑满内容列——与官方扩展的 size 字段同思路），渲染/交互全部归
/// 本项目：
///
/// - **单击选中**：显示主题色边框 + 右下角缩放手柄（Word/飞书惯例）
/// - **拖手柄**：等比调宽，松手写回 Delta（进撤销栈），持久化
/// - **双击**：全屏预览（lightbox）
/// - **右键/长按**：菜单（预览 / 删除 / 复制）
/// - 点击图片外自动取消选中（TapRegion）
class NoteImageEmbedBuilder extends EmbedBuilder {
  @override
  String get key => BlockEmbed.imageType;

  @override
  WidgetSpan buildWidgetSpan(Widget widget) {
    // 图片与文本混排时的行内渲染（网页复制粘贴常见：HTML 里 <img>
    // 与文字同段落 → quill 只在「整行仅此嵌入」时才块级渲染）。
    // WidgetSpan 无约束会按原图尺寸绘制、溢出覆盖周边内容——统一
    // 压进行内缩略尺寸。widget 本身是 build() 的产物（含选中/
    // 双击预览/右键全部交互），无需重复包装。
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: SizedBox(width: 120, height: 48, child: widget),
    );
  }

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    return _BlockImage(embedContext: embedContext);
  }
}

/// 块级图片：选中/拖拽/预览/菜单的完整交互。
class _BlockImage extends StatefulWidget {
  const _BlockImage({required this.embedContext});

  final EmbedContext embedContext;

  @override
  State<_BlockImage> createState() => _BlockImageState();
}

class _BlockImageState extends State<_BlockImage> {
  static const double _minWidth = 120;
  static const double _handleSize = 14;

  bool _selected = false;

  /// 右键按下的指针 id（Listener 原始事件识别用）。
  int? _secondaryPointer;

  /// 右键/长按时的鼠标全局坐标（菜单锚点）。
  Offset? _menuPosition;

  /// 拖拽中的实时宽度（未拖拽时为 null，用 Delta 里的持久值）。
  double? _dragWidth;

  /// 本轮拖拽的起始宽度（onStart 时由手柄回填）。
  double _dragStart = 0;

  EmbedContext get _embed => widget.embedContext;

  /// 解析嵌入源：外部粘贴的图片经 quill 的 HTML 解析后 src 常是
  /// `file:///D:/...` 协议形式——`Image.file` 只认纯路径，统一转换。
  String get _source {
    final String raw = _embed.node.value.data as String? ?? '';
    if (raw.startsWith('file://')) {
      try {
        return Uri.parse(raw).toFilePath();
      } catch (_) {
        return raw;
      }
    }
    return raw;
  }

  /// Delta 里的持久宽度。官方存储语义（ResolveImageFormatRule）：
  /// 宽度存在 embed 的 `style` **属性**里（内联 CSS 形式
  /// `width: 300px;`）——与官方扩展/网页版 quill 互通。
  /// 无 = 撑满内容列。
  double? get _storedWidth {
    final Object? style = _embed.node.style.attributes['style']?.value;
    if (style is String) {
      final RegExpMatch? match = RegExp(r'width:\s*(\d+(?:\.\d+)?)px')
          .firstMatch(style);
      if (match != null) {
        return double.parse(match.group(1)!);
      }
    }
    return null;
  }

  @override
  void dispose() {
    _imageStream?.removeListener(_imageListener!);
    _imageStream = null;
    super.dispose();
  }

  /// 拖拽结束时把宽度写回 Delta：formatText + style 属性（命中
  /// 官方 ResolveImageFormatRule）——进入撤销栈、随保存持久化；
  /// 重建后 _dragWidth 复位由数据接管。
  void _commitWidth(double width) {
    _embed.controller.formatText(
      _embed.node.documentOffset,
      1,
      Attribute.clone(Attribute.style, 'width: ${width.round()}px;'),
    );
  }

  /// 图片原始宽度（加载完成后回填）：小图默认按原尺寸显示（只缩
  /// 不放，飞书/Notion 同款），拖拽也从原尺寸起步而非列宽。
  double? _intrinsicWidth;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;

  /// 注册图片尺寸监听（build 内 resolve，key 变化才重挂）。
  void _observeImageSize(
    BuildContext context,
    ImageProvider provider,
    bool isNetwork,
  ) {
    final ImageStream newStream = provider.resolve(
      createLocalImageConfiguration(context),
    );
    if (identical(newStream, _imageStream)) return;
    _imageStream?.removeListener(_imageListener!);
    _imageStream = newStream;
    _imageListener = ImageStreamListener((ImageInfo info, _) {
      final double w = info.image.width.toDouble();
      if (mounted && _intrinsicWidth != w) {
        setState(() => _intrinsicWidth = w);
      }
    });
    _imageStream!.addListener(_imageListener!);
  }

  @override
  Widget build(BuildContext context) {
    final String source = _source;
    final bool isNetwork = source.startsWith('http');

    // 限制**解码尺寸**：手机随手拖进来的照片动辄 4000×3000（全尺寸
    // 解码 ≈ 48MB 内存 + 首帧解码卡顿 + GPU 一直采样全尺寸纹理）。
    // 上限取**屏幕逻辑宽 × DPR**——不依赖 LayoutBuilder 的精确列宽
    // （resolve 触发的同步 listener 回调里 setState 只允许发生在
    // widget build 阶段，LayoutBuilder.builder 是 layout 阶段，会崩
    // "setState called during build"）。屏幕宽可能大于标准列宽 720，
    // 但仍比原图小一个数量级；ResizeImage 默认不放大，小图原尺寸解码。
    // 监听与显示用**同一个** resize 后的 provider：ImageStream 同一条，
    // 不会出现「监听走全尺寸、显示走降采样」的双份开销。
    final double decodeLimit = MediaQuery.sizeOf(context).width;
    final ImageProvider provider = ResizeImage(
      isNetwork ? NetworkImage(source) : FileImage(File(source)),
      width: (decodeLimit * MediaQuery.devicePixelRatioOf(context)).round(),
    );
    _observeImageSize(context, provider, isNetwork);
    final Widget image = Image(
      image: provider,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        // 输出真实解码错误：失败原因（目标尺寸异常/格式不支持等）
        // 只有 errorBuilder 能看到。
        debugPrint('图片解码失败 [$source]: $error');
        return _error(context, detail: error.toString());
      },
    );

    // 图片块**左对齐**（用户偏好）：Align 给松约束——无 width 时
    // RenderImage 按**原始尺寸**落位（loose 约束 constrain(原尺寸)，
    // 只缩不放），小图不再被拉伸；拖拽调宽后按指定宽左对齐。
    return Align(
      alignment: Alignment.centerLeft,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double columnWidth = constraints.maxWidth;
          final double? width = _dragWidth ?? _storedWidth;
          final Widget sized = width == null
              ? image
              : SizedBox(
                  width: width.clamp(_minWidth, columnWidth),
                  child: image,
                );

          return TapRegion(
            onTapOutside: (_) {
              if (_selected) {
                setState(() => _selected = false);
              }
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                // 右键走**原始指针事件**（Listener 不参与手势竞技场）：
                // 图片的 secondary tap 手势会在竞技场里输给编辑器的
                // 手势（图片菜单不弹、正文菜单反而叠加）——原始事件
                // 沿路径 leaf → root 先于编辑器到达，弹图片菜单并置
                // 抑制标志，编辑器的右键回调检测标志后跳过。
                Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (PointerDownEvent event) {
                    _secondaryPointer = event.buttons == kSecondaryMouseButton
                        ? event.pointer
                        : null;
                    _menuPosition = event.position;
                  },
                  onPointerUp: (PointerUpEvent event) {
                    if (event.pointer != _secondaryPointer) return;
                    _secondaryPointer = null;
                    _showMenu(context, source, _menuPosition);
                  },
                  onPointerCancel: (PointerCancelEvent event) {
                    if (event.pointer == _secondaryPointer) {
                      _secondaryPointer = null;
                    }
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // 单击切换选中（Word/飞书惯例）；双击预览；
                    // 长按菜单（触屏）。
                    onTap: () => setState(() => _selected = !_selected),
                    onDoubleTap: () => showNoteImagePreview(context, source),
                    onLongPressStart: (LongPressStartDetails details) {
                      _menuPosition = details.globalPosition;
                      _showMenu(context, source, _menuPosition);
                    },
                    // 选中边框：foregroundDecoration 画在内容之上、
                    // 不参与布局。
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      foregroundDecoration: BoxDecoration(
                        border: _selected
                            ? Border.all(
                                width: 2,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : null,
                      ),
                      child: sized,
                    ),
                  ),
                ),
                // 右下角缩放手柄：**必须与图片的 GestureDetector 平级**
                // （不能放进其子树）——否则手柄按下时图片的 tap/
                // doubletap recognizer 同入竞技场，Eager 立即胜出后
                // DoubleTap dispose 的 late-release 会在锁树期 sweep
                // 出一次迟到的 tap 裁决，触发 quill 在 finalizeTree
                // 里 updateSelection → 斱言崩溃。
                if (_selected)
                  Positioned(
                    right: -16,
                    bottom: -16,
                    child: _ResizeHandle(
                      size: _handleSize,
                      onStart: () => _dragStart =
                          _storedWidth ??
                          width ??
                          _intrinsicWidth ??
                          columnWidth,
                      onUpdate: (dx) => setState(() {
                        _dragWidth = (_dragStart + dx).clamp(
                          _minWidth,
                          columnWidth,
                        );
                      }),
                      onEnd: () {
                        final double? w = _dragWidth;
                        _dragWidth = null;
                        if (w != null) {
                          _commitWidth(w);
                        }
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 右键/长按菜单（贴鼠标指针右下，共享组件）：预览 / 删除 / 复制。
  Future<void> _showMenu(
    BuildContext context,
    String source,
    Offset? globalPosition,
  ) async {
    final Offset pos = globalPosition ?? Offset.zero;
    final bool isLocal = !source.startsWith('http');
    // 本次右键已由嵌入菜单处理：正文层的右键回调收到同一 up 事件
    // 时会检测此标志并跳过（防止双菜单叠加）。
    noteContextMenuEmbedHandled = true;

    await showNoteContextMenu(
      context,
      position: pos,
      entries: <NoteContextMenuEntry>[
        NoteContextMenuEntry(
          icon: LucideIcons.maximize200,
          label: '预览图片',
          onPressed: () => showNoteImagePreview(context, source),
        ),
        if (isLocal)
          NoteContextMenuEntry(
            icon: LucideIcons.copy200,
            label: '复制图片',
            onPressed: () =>
                NoteMediaService.copyImageFileToWindowsClipboard(source),
          ),
        NoteContextMenuEntry(
          icon: LucideIcons.trash2200,
          label: '删除图片',
          destructive: true,
          onPressed: () {
            // 嵌入占 1 个文档位：从其文档偏移处整体移除。
            // 显式把光标折叠到删除点——selection 传 null 时选区不动，
            // 删除后 caret 悬空（还指在被删图片的旧偏移上）。
            _embed.controller.replaceText(
              _embed.node.documentOffset,
              1,
              '',
              TextSelection.collapsed(offset: _embed.node.documentOffset),
            );
          },
        ),
      ],
    );
  }

  Widget _error(BuildContext context, {String? detail}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      height: 120,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Tokens.radiusSm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          Icon(LucideIcons.imageOff200, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: Tokens.spaceSm),
          // Expanded 约束详情文本：错误串可能很长（异常消息动辄
          // 上千字符），无约束会撑爆 Row 溢出数千像素。
          Expanded(
            child: Text(
              detail == null ? '图片无法加载' : '图片无法加载（$detail）',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 缩放手柄：原始指针跟踪（Listener 直接消费 Pointer 事件流，
/// 不参与手势竞技场——与编辑器的 tap/拖选/双击零竞争，且无
/// PanGestureRecognizer 的触发死区，指哪动哪）。
/// 视觉 14px 圆点，命中区外扩到 32px（小目标的可点击性惯例）。
///
/// **必须是 StatefulWidget**：拖拽起点要在跨帧重建间存活——
/// 拖动实时 setState 会触发父级重建，若起点是 build 局部变量
/// 会被重置，第一次 move 后就「锁死」（上一版卡死的根因）。
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({
    required this.size,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  final double size;
  final VoidCallback onStart;
  final void Function(double deltaX) onUpdate;
  final VoidCallback onEnd;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  double? _startX;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeDownRight,
      // EagerGestureRecognizer：指针按下**立即**宣称竞技场胜利
      // （零 slop）——编辑器的 tap/拖选手势当场被 reject，不会在
      // 拖手柄时高亮正文。之前用空 pan 手势占位失败：Pan 的 slop
      //（36px）比编辑器拖选（18px）大，竞技必输。实际的宽度跟踪
      // 由内层 Listener 原始指针完成（不参与竞技场，无死区）。
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures:
            <
              Type,
              GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>
            >{
              EagerGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                    EagerGestureRecognizer.new,
                    (_) {},
                  ),
            },
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (PointerDownEvent event) {
            _startX = event.position.dx;
            widget.onStart();
          },
          onPointerMove: (PointerMoveEvent event) {
            if (_startX != null) {
              widget.onUpdate(event.position.dx - _startX!);
            }
          },
          onPointerUp: (PointerUpEvent event) {
            if (_startX != null) {
              widget.onEnd();
              _startX = null;
            }
          },
          onPointerCancel: (PointerCancelEvent event) {
            _startX = null;
          },
          child: Padding(
            // 命中区外扩：14px 视觉圆点外包 32px 可按区。
            padding: const EdgeInsets.all(9),
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
