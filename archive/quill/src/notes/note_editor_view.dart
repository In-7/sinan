import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderObjectWithChildMixin;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, LogicalKeyboardKey, PlatformException;
import 'package:quill_native_bridge/quill_native_bridge.dart' as bridge;
import 'package:url_launcher/url_launcher.dart';
import 'package:material_ui/material_ui.dart';

import '../data/note_content.dart';
import '../models/note.dart';
import '../models/settings.dart';
import '../providers.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'note_attachment_embed_builder.dart';
import 'note_context_menu.dart';
import 'note_code_syntax.dart';
import 'note_format_toolbar.dart';
import 'note_formula_embed_builder.dart';
import 'note_hr_embed_builder.dart';
import 'note_image_embed_builder.dart';
import 'note_toc_panel.dart';
import 'note_media_service.dart';
import 'note_search_bar.dart';

/// 右栏编辑器：标题（TextField）+ Quill 富文本正文。
///
/// 正文存储为 Quill Delta JSON；打开旧纯文本笔记时自动转换（无损）。
/// 标题/正文均防抖自动保存；切换或关闭前 flush（dispose）。
/// 工具栏先精简到核心动作，M3 化定制在阶段 2。
class NoteEditorView extends ConsumerStatefulWidget {
  const NoteEditorView({super.key, required this.noteId});

  final String noteId;

  @override
  ConsumerState<NoteEditorView> createState() => _NoteEditorViewState();
}

/// 有序列表标记的光学微调：行高余量改 `leadingDistribution.even`
/// （上下均分）后，标记盒与正文首行盒都几何居中，无需补偿——
/// 旧值 2 是按旧的 proportional 分布（正文字形盒偏低 ~2.8px）
/// 标定的，even 下会让数字偏低 2px。
/// 若视觉上数字仍略高（字体墨迹差的残余），在此 +0.5~1 微调。
/// 圆点字形小且光学居中，无需微调。
const double _olMarkerNudge = 0;

/// 无序列表圆点的放大字号（默认 16，大一号）：圆点字形小，
/// 成熟应用的圆点视觉分量更足。
const double _ulBulletFontSize = 19;

/// 行有效排版（正文样式）：标题+列表混合行时正文走标题样式
/// （quill L390-404：header 优先 merge），标记必须同步缩放——
/// 成熟应用（Word 编号继承段落字号 / HTML li::marker 继承
/// font-size）的标记都随内容字号变化，quill 默认不跟随。
///
/// 标题档按**基准字号的比例**派生（16 → 24/20/17），这样调正文字号
/// 时标题同步缩放，档位关系不变。
(double, double) _lineTypography(
  LeadingConfig config, {
  required double base,
  required double lineHeight,
}) {
  final Object? header = config.attrs[Attribute.header.key]?.value;
  if (header == 1) return (base * 1.5, 1.4);
  if (header == 2) return (base * 1.25, 1.4);
  if (header == 3) return (base * 1.0625, 1.4);
  return (base, lineHeight);
}

/// 列表标记自定义构建（quill 官方容器结构 + 中文排版化居中）：
///
/// 复刻 quill 默认容器公式（宽 = 字号×2、间距 = 字号/2），但容器
/// 高度锁定为**正文首行盒**（字号×行高），标记文字 height: 1.0
/// （盒 = 字号）在容器内垂直居中——字形光学中心 ≈ 首行盒中心，
/// 随字号/行高变化自动保持居中（标题缩放无需逐档补偿）。
///
/// 返回 null 的类型（复选/代码块）沿用包默认。
Widget? _listLeadingBuilder(
  Node node,
  LeadingConfig config, {
  required double base,
  required double lineHeight,
}) {
  final TextStyle? base_ = config.style;
  if (config.attribute == Attribute.ol) {
    final String? index = config.getIndexNumberByIndent;
    if (index == null) return null;
    final (double fontSize, double lh) = _lineTypography(
      config,
      base: base,
      lineHeight: lineHeight,
    );
    return Transform.translate(
      offset: Offset(0, _olMarkerNudge),
      child: Container(
        height: fontSize * lh,
        width: fontSize * 2,
        alignment: AlignmentDirectional.centerEnd,
        padding: EdgeInsetsDirectional.only(end: fontSize / 2),
        child: Text(
          '$index.',
          style: base_?.copyWith(fontSize: fontSize, height: 1.0),
        ),
      ),
    );
  }
  if (config.attribute == Attribute.ul && base_ != null) {
    final (double fontSize, double lh) = _lineTypography(
      config,
      base: base,
      lineHeight: lineHeight,
    );
    final double bulletSize = fontSize * _ulBulletFontSize / 16;
    return Container(
      height: fontSize * lh,
      width: fontSize * 2,
      alignment: AlignmentDirectional.centerEnd,
      padding: EdgeInsetsDirectional.only(end: fontSize / 2),
      child: Text('•', style: base_.copyWith(fontSize: bulletSize, height: 1.0)),
    );
  }
  return null;
}

/// 中文黄金排版：覆盖 flutter_quill 的西文默认值。
///
/// quill 默认按拉丁文设计——正文行高 1.15（靠字母 ascender/descender
/// 呼吸，等宽方块字会上下粘连）、标题行高 1.08 且带负字距（西文
/// 标题惯例，汉字负字距会笔画相碰）。中文基准：
/// 正文 16/1.7、段间距 8；标题 = 两家共识档位**收一档**（base×1.75/1.4/1.2）·
/// 行高 1.4·零字距·上间距 20px·**Semibold**（苹方无 Bold 真字重）；
/// 列表与正文同基。只列差异项，其余字段经 merge 沿用包默认。
/// [base] = 正文字号、[lineHeight] = 正文行高：均来自设置
/// （AppSettings），改设置时编辑器整体重建 → 背后实时预览生效。
/// 标题档按 base 的比例派生，档位关系不随字号变化。
DefaultStyles _chineseStyles(
  BuildContext context, {
  required double base,
  required double lineHeight,
}) {
  final ThemeData theme = Theme.of(context);
  final ColorScheme scheme = theme.colorScheme;
  // 中英文必须同字体：Segoe UI（拉丁）与雅黑（中文）的升部/降部
  // 比例不同，Flutter 按各自比例在行盒内定位基线——中英混排时
  // 基线上下漂移（英文行往回缩、中文行往下顶，行盒高度其实恒定）。
  // quill 不暴露 strutStyle（无法强制行 strut），统一主字体是
  // 唯一正解：雅黑自带拉丁字形，中英同源后基线恒定。
  final List<String>? fallback = theme.textTheme.bodyLarge?.fontFamilyFallback;

  TextStyle block(double fontSize, double height) => TextStyle(
    fontSize: fontSize,
    height: height,
    letterSpacing: 0,
    color: scheme.onSurface,
    fontFamily: AppTheme.editorFont,
    fontFamilyFallback: fallback,
    // 字重 Regular：Apple 与鸿蒙两家的正文规范都写明用 Regular
    // （曾用 w500 补偿桌面灰度抗锯齿下的偏淡观感，属经验值，已按规范回退）。
    // 标题各行 copyWith(w600) 覆盖，不受影响。
    fontWeight: FontWeight.w400,
    // 行盒居中：CJK 字体（雅黑）升部大、降部小，默认按字体比例
    // 分配行高余量会把字形压到行盒底部（选中高亮时尤其明显）。
    // even = 余量上下均分，字形视觉居中——与浏览器 CSS 行为一致。
    leadingDistribution: TextLeadingDistribution.even,
  );

  /// 行内代码运行样式（Consolas 链 + 主色），随标题档字号缩放。
  TextStyle mono(double fontSize) => TextStyle(
    fontFamily: AppTheme.monoFont,
    fontFamilyFallback: AppTheme.monoFallback,
    fontSize: fontSize,
    color: scheme.primary.withValues(alpha: 0.9),
  );

  return DefaultStyles(
    h1: DefaultTextBlockStyle(
      block(base * 1.75, 1.4).copyWith(fontWeight: FontWeight.w600),
      const HorizontalSpacing(0, 0),
      // 上间距统一 20px（= 1.25 × 16px 正文）：对标 GitHub markdown 的
      // `margin-top: 24px`（块间距不折叠，故取 20 让渲染间距≈24）。
      const VerticalSpacing(20, 0),
      VerticalSpacing.zero,
      null,
    ),
    h2: DefaultTextBlockStyle(
      block(base * 1.4, 1.4).copyWith(fontWeight: FontWeight.w600),
      const HorizontalSpacing(0, 0),
      const VerticalSpacing(20, 0),
      VerticalSpacing.zero,
      null,
    ),
    h3: DefaultTextBlockStyle(
      block(base * 1.2, 1.4).copyWith(fontWeight: FontWeight.w600),
      const HorizontalSpacing(0, 0),
      const VerticalSpacing(20, 0),
      VerticalSpacing.zero,
      null,
    ),
    paragraph: DefaultTextBlockStyle(
      block(base, lineHeight),
      const HorizontalSpacing(0, 0),
      const VerticalSpacing(8, 0),
      VerticalSpacing.zero,
      null,
    ),
    lineHeightNormal: DefaultTextBlockStyle(
      block(base, lineHeight),
      const HorizontalSpacing(0, 0),
      VerticalSpacing.zero,
      VerticalSpacing.zero,
      null,
    ),
    lists: DefaultListBlockStyle(
      block(base, lineHeight),
      const HorizontalSpacing(0, 0),
      // 块级 top(6) 必须等于行间距 bottom(6)：勾选待办时 quill 会在
      // checked/unchecked 块样式间拆分/合并块（不同块样式），边界间隙
      // = 块级 top、块内间隙 = 行间距——两者不等就是勾选 ±2px 位移
      // 的根源（探针实测：8-6=2）。改 6/6 后边界与块内完全等距。
      const VerticalSpacing(6, 0),
      const VerticalSpacing(0, 6),
      null,
      null,
    ),
    // 列表/代码块的标记（"1."、圆点）样式：必须与正文同行高——
    // quill 的标记盒顶对齐于正文行盒，包默认 leading 是 1.15，
    // 在 1.7 的正文行盒里基线错位（符号悬在行顶）。
    leading: DefaultTextBlockStyle(
      block(base, lineHeight),
      const HorizontalSpacing(0, 0),
      VerticalSpacing.zero,
      VerticalSpacing.zero,
      null,
    ),
    // ── 以下同为「全局统一」审计补齐项：包默认全是西文基准 ──
    // 对齐段落（居中/居右时 quill 换用 align 样式）：不覆盖的话
    // 行高从 1.7 掉回 1.15，对齐瞬间行距突变。
    align: DefaultTextBlockStyle(
      block(base, lineHeight),
      const HorizontalSpacing(0, 0),
      VerticalSpacing.zero,
      VerticalSpacing.zero,
      null,
    ),
    // 缩进段落：同正文基线。
    indent: DefaultTextBlockStyle(
      block(base, lineHeight),
      const HorizontalSpacing(0, 0),
      const VerticalSpacing(8, 0),
      VerticalSpacing.zero,
      null,
    ),
    // 引用块：默认无字体链 + 1.15 行高；边线取主题色（默认灰是
    // 硬编码浅色值，深色模式下不可见）。
    quote: DefaultTextBlockStyle(
      block(base, lineHeight).copyWith(color: scheme.onSurface.withValues(alpha: 0.7)),
      const HorizontalSpacing(0, 0),
      const VerticalSpacing(8, 0),
      const VerticalSpacing(4, 4),
      BoxDecoration(
        border: Border(
          left: BorderSide(
            width: 3,
            color: scheme.primary.withValues(alpha: 0.4),
          ),
        ),
      ),
    ),
    // 代码块：默认 13/1.15 过紧 + 灰底浅色硬编码；等宽字体显式
    // 指定（Consolas → Cascadia 回退），行高 1.6（代码舒适区间）。
    code: DefaultTextBlockStyle(
      TextStyle(
        fontFamily: AppTheme.monoFont,
        fontFamilyFallback: AppTheme.monoFallback,
        fontSize: 13,
        height: 1.6,
        letterSpacing: 0,
        color: scheme.onSurface,
        leadingDistribution: TextLeadingDistribution.even,
      ),
      const HorizontalSpacing(0, 0),
      const VerticalSpacing(8, 0),
      VerticalSpacing.zero,
      BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Tokens.radiusSm),
      ),
    ),
    // 行内代码：包默认三宗罪——Roboto Mono（Windows 无此字体，
    // 实际回退成非等宽）、灰底浅色硬编码（深色模式刺眼）、标题档
    // 32/22/18 按包默认大标题标定（比我们的 24/20/17 标题还大）。
    // 主题化：等宽链、主题底色、随标题档（base 的比例）缩放。
    inlineCode: InlineCodeStyle(
      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      radius: const Radius.circular(4),
      style: mono(base * 0.84),
      header1: mono(base * 1.125),
      header2: mono(base * 1.0),
      header3: mono(base * 0.9),
    ),
    // 行内链接：**固定薄荷绿**（不随种子色漂移）——链接的「可跳转」
    // 语义全局唯一，主题化实测会在部分种子下与正文灰阶糊在一起
    // （深色模式 primary 饱和度被压低）。深色亮薄荷 / 浅色深薄荷，
    // 各自保证与正文对比度。字重不设 → 随正文基线（w500）。
    // 外观：同色细描边方框（TextStyle.background 走 Paint——
    // style: stroke 即描边矩形，与实底同一条渲染通路，零额外成本），
    // 给链接「小卡片」的轮廓感。
    link: TextStyle(
      color: theme.brightness == Brightness.dark
          ? const Color(0xFF4DE3B8)
          : const Color(0xFF0B8A6C),
      background: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = theme.brightness == Brightness.dark
            ? const Color(0xFF4DE3B8).withValues(alpha: 0.55)
            : const Color(0xFF0B8A6C).withValues(alpha: 0.45),
    ),
    // 空文档占位符：默认 20/1.5 与正文 16/1.7 不一致，输入瞬间
    // 字号跳变。对齐正文基线 + 与标题占位同浓度的灰。
    placeHolder: DefaultTextBlockStyle(
      block(base, lineHeight).copyWith(color: AppTheme.hintColor(scheme.onSurface)),
      const HorizontalSpacing(0, 0),
      VerticalSpacing.zero,
      VerticalSpacing.zero,
      null,
    ),
  );
}

class _NoteEditorViewState extends ConsumerState<NoteEditorView> {
  // 控制器在 initState 构造：粘贴拦截（clipboardConfig）需要
  // 引用实例方法，无法在字段初始化器中完成。
  late final QuillController _quill;
  final TextEditingController _titleController = TextEditingController();
  final FocusNode _contentFocus = FocusNode();
  // 外部滚动条共享控制器：滚动区域全宽（滚动条贴窗口右缘），
  // 文字内容才单独限宽。自定义类型提供拖选滚动锁（见 _EditorScrollController）。
  final _EditorScrollController _scroll = _EditorScrollController();
  Timer? _contentDebounce;
  Timer? _titleDebounce;

  /// 官方内容变更通道（document.changes）订阅：只有内容变化才触发
  /// 保存，光标移动不再产生无效保存定时器。文档对象随水合重建，
  /// 订阅必须在装载文档之后建立（见 _hydrateFromNotes）。
  StreamSubscription<DocChange>? _changesSub;

  /// 正文文档是否已从列表数据装载。
  /// 未装载前控制器里是空文档——此时若允许保存，会用空内容
  /// 覆盖原笔记（数据丢失），所以订阅与保存都以它为前提。
  bool _documentLoaded = false;

  /// Riverpod 3 禁止在 dispose 中使用 ref，initState 缓存 notifier。
  late final NotesNotifier _notifier;

  /// 编辑器内搜索条（Ctrl+F / 工具栏放大镜）显隐。
  bool _searchVisible = false;

  /// 目录（TOC）面板显隐：工具栏 list-tree 按钮切换；窗口过窄时
  /// 由 build 自动隐藏（宽度放不下三栏）。
  bool _tocVisible = false;

  // ── 链接悬浮提示（诊断模式：细粒度日志定位命中断点）──
  final GlobalKey _editorKey = GlobalKey();
  OverlayEntry? _linkTip;
  String? _linkTipUrl;
  Timer? _linkTipTimer;

  void _onEditorHover(Offset global) {
    final String? url = _linkAtGlobal(global);
    if (url == null) {
      _hideLinkTip();
      return;
    }
    if (_linkTipUrl == url && _linkTip != null) return;
    _hideLinkTip();
    _linkTipUrl = url;
    _linkTip = OverlayEntry(
      builder: (_) => _LinkTip(url: url, position: global),
    );
    Overlay.of(context, rootOverlay: true).insert(_linkTip!);
    _linkTipTimer = Timer(const Duration(seconds: 4), _hideLinkTip);
  }

  void _hideLinkTip() {
    _linkTipTimer?.cancel();
    _linkTipTimer = null;
    _linkTip?.remove();
    _linkTip = null;
    _linkTipUrl = null;
  }

  String? _linkAtGlobal(Offset global) {
    final RenderEditor? editor = _resolveRenderEditor();
    if (editor == null) return null;
    final int offset = editor.getPositionForOffset(global).offset;
    if (offset < 0 || offset >= _quill.document.length) return null;
    final Object? value =
        _quill.queryNode(offset)?.style.attributes[Attribute.link.key]?.value;
    return value is String ? value : null;
  }

  /// 视口顶部对应的文档偏移：供目录面板算「当前章节」高亮
  /// （网页端目录语义——高亮跟随滚动）。
  ///
  /// 取样点必须在**停靠标题的行内**：目录跳转把标题停在距顶
  /// [Tokens.spaceLg]（16px）处，取样点取 16+4 —— 若取在 8px 会落进
  /// 标题上方的空隙，命中上一条标题（表现为「只有 H1 有选中背景」）。
  int? _topVisibleDocOffset() {
    final BuildContext? editorContext = _editorKey.currentContext;
    if (editorContext == null) return null;
    final RenderObject? box = editorContext.findRenderObject();
    final RenderEditor? editor = _resolveRenderEditor();
    if (box is! RenderBox || editor == null) return null;
    // 防御：命中查询要求渲染树已布局。文档变化（撤销/粘贴）会把
    // 渲染对象标记 dirty，此时查询会踩 `!debugNeedsLayout` 断言——
    // 高亮是尽力而为的提示，本帧拿不到就返回 null（不高亮），下一帧
    // 的 post-frame 回调会重算，绝不让界面因它崩溃。
    if (editor.debugNeedsLayout) return null;
    final Offset point = box.localToGlobal(
      const Offset(4, Tokens.spaceLg + 4),
    );
    final int offset;
    try {
      offset = editor.getPositionForOffset(point).offset;
    } catch (_) {
      // 子节点（RenderParagraph）尚未布局等边缘时序：同上，降级处理。
      return null;
    }
    if (offset < 0 || offset >= _quill.document.length) return null;
    return offset;
  }

  /// 已解析的编辑器渲染对象：命中查询（链接悬浮、目录高亮）每帧可能
  /// 调用多次，下钻一次即可，之后复用——用 attached 判定仍挂载。
  RenderEditor? _cachedRenderEditor;

  /// 定位 quill 的 RenderEditor：沿单-child 渲染链下钻（QuillEditor
  /// context 的首个渲染对象是工具栏锚点的 RenderLeaderLayer）。
  RenderEditor? _resolveRenderEditor() {
    final RenderEditor? cached = _cachedRenderEditor;
    if (cached != null && cached.attached) return cached;

    final BuildContext? editorContext = _editorKey.currentContext;
    if (editorContext == null || !mounted) return null;
    RenderObject? ro = editorContext.findRenderObject();
    for (int depth = 0; ro != null && depth < 24; depth++) {
      if (ro is RenderEditor) {
        _cachedRenderEditor = ro;
        return ro;
      }
      // 单-child 渲染对象都挂 RenderObjectWithChildMixin（RenderProxyBox
      // 只是它的常见子类）——_RenderSingleChildViewport 不是 ProxyBox，
      // 首版在此断链（提示永不弹的根因）。
      if (ro is RenderObjectWithChildMixin<RenderObject>) {
        ro = ro.child;
        continue;
      }
      break;
    }
    return null;
  }

  /// 链接属性 → 常驻点击识别器（customRecognizerBuilder 优先于 quill
  /// 的 Ctrl+点击门控被采用）：直点即跳浏览器；recognizer 常驻也让
  /// textSpanBuilder 的 mouseCursor（click 手型）常驻。
  /// quill 会对节点的每个属性调用本函数，非 link 属性返回 null。
  GestureRecognizer? _linkRecognizer(Attribute attribute, Leaf leaf) {
    if (attribute.key != Attribute.link.key) return null;
    final Object? value = attribute.value;
    if (value is! String || value.isEmpty) return null;
    return TapGestureRecognizer()..onTap = () => _launchUrl(value);
  }

  /// 打开链接：无 scheme 补 https（裸域名如 example.com）；仅放行
  /// http/https（防 javascript: 等方案注入）；外部应用打开（浏览器）。
  Future<void> _launchUrl(String url) async {
    final Uri? uri = Uri.tryParse(
      url.contains('://') ? url : 'https://$url',
    );
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// 标题行右侧的元信息（字数）：在保存防抖后更新（与落盘同拍），
  /// 而非每次按键都全文扫描——大文档逐键正则统计会拖输入手感。
  final ValueNotifier<int> _wordCount = ValueNotifier<int>(0);

  /// 字数统计（中文/日文字符逐字计数，西文与数字按词计数——
  /// 与 Word/飞书的混合计数语义一致）。
  static final RegExp _cjkChar = RegExp(
    r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3040-\u30ff]',
  );
  static final RegExp _latinWord = RegExp(r'[A-Za-z0-9]+');

  int _countWords(String plainText) =>
      _cjkChar.allMatches(plainText).length +
      _latinWord.allMatches(plainText).length;

  /// 修改时间的展示格式：今天只显时刻，跨日带日期。
  String _formatRevised(DateTime t) {
    final DateTime now = DateTime.now();
    final String hhmm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final bool isToday =
        t.year == now.year && t.month == now.month && t.day == now.day;
    return isToday
        ? hhmm
        : '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} $hhmm';
  }

  /// 恢复选区快照：右键菜单动作（剪切/复制/粘贴/删除）执行前恢复到
  /// 右键瞬间的选区。quill 11.x 右键在有完整选区时保持选区不动、
  /// 折叠光标时把光标移到右键位置——快照恢复是防御性的，保证操作
  /// 对象永远是右键瞬间的选区。
  void _restoreSelection(TextSelection selection) {
    _quill.updateSelection(selection, ChangeSource.local);
  }

  void _openSearch() {
    setState(() => _searchVisible = true);
  }

  void _closeSearch() {
    setState(() => _searchVisible = false);
    // 关闭搜索后焦点回正文，直接继续输入。
    _contentFocus.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(notesProvider.notifier);
    _quill = QuillController(
      document: Document(),
      selection: const TextSelection.collapsed(offset: 0),
      // ignore: experimental_member_use
      config: QuillControllerConfig(
        // ignore: experimental_member_use
        clipboardConfig: QuillClipboardConfig(
          // ignore: experimental_member_use
          onClipboardPaste: _onClipboardPaste,
          // 截图/复制图片直存：剪贴板图片字节 → 数据目录 →
          // quill 官方流程自动按 BlockEmbed.image 插入。
          onImagePaste: NoteMediaService.saveBytes,
          // 富文本（网页 HTML / 内部 Delta）粘贴规范化：
          // 剔 Chrome 的 SourceURL 垃圾行 + 图片块级化（混排图片
          // 拆成独立行，撑满内容列；行内缩略只是渲染兜底）。
          // ignore: experimental_member_use
          onRichTextPaste: (Delta delta, bool isInternal) async =>
              _normalizePastedDelta(delta),
        ),
      ),
    );
    // 正常流程下选中态来自列表（必然已加载）；万一未加载，
    // build 里 notesProvider 到值时会再尝试（见 _hydrateFromNotes）。
    _hydrateFromNotes();
  }

  /// 富文本粘贴规范化（onRichTextPaste 钩子，交互对标飞书——
  /// 图片粘贴后本地化存储，离线可看、重启持久）：
  ///
  /// ① 剔除 Chrome 写进剪贴板片段的 `SourceURL:...` 来源注释——
  ///    它不在 CF_HTML 的 StartFragment 标记外，quill 的 HTML 清理
  ///    不认，会被当正文插入（实测 Chrome 扩展页复制必现）。
  /// ② 图片本地化：官方转换器把 <img src> 原样塞进 embed（外链），
  ///    离线丢图、防盗链站加载失败——http(s)/data 图先下载/解码
  ///    落进数据目录，embed 改指本地文件；失败兜底保留原 URL。
  /// ③ 图片块级化：HTML 里 <img> 与文字同段落时，quill 只在
  ///    「整行仅此嵌入」时才块级渲染（text_line 的 childCount==1
  ///    条件），混排图片只能走行内小图——前后补换行拆成独立行。
  Future<Delta?> _normalizePastedDelta(Delta delta) async {
    // 阶段一：收集需要本地化的图片源（去重）。
    final Set<String> pending = <String>{};
    for (final Operation op in delta.operations) {
      final String? src = _pastedImageSource(op);
      if (src != null && (src.startsWith('http') || src.startsWith('data:'))) {
        pending.add(src);
      }
    }

    // 阶段二：并行下载/解码 → 存数据目录。单张失败保留原 URL。
    final Map<String, String> localized = <String, String>{};
    await Future.wait(<Future<void>>[
      for (final String src in pending)
        () async {
          final String? local = await _localizeImage(src);
          if (local != null) {
            localized[src] = local;
          }
        }(),
    ]);

    // 阶段三：重建 Delta（剔除垃圾行 / 替换本地路径 / 块级化）。
    // 图片后的行尾闭合采用「延迟策略」（对齐飞书/Notion：不制造
    // 多余空行）——图片独占一行需要行尾换行，但 HTML 转出的 Delta
    // 里图片后通常自带段落 \n，若再无条件补一个就叠出空行：先挂
    // 起闭合，下一个 op 自带 \n 开头就直接充当行尾，否则才补。
    final Delta out = Delta();
    bool pendingClose = false;
    for (final Operation op in delta.operations) {
      final Object? data = op.data;

      // ① SourceURL 垃圾行剔除（只处理纯文本 op，按行过滤）。
      if (op.isInsert && data is String && data.contains('SourceURL:')) {
        final String cleaned = data
            .split('\n')
            .where((String line) => !line.trimLeft().startsWith('SourceURL:'))
            .join('\n');
        if (cleaned.isNotEmpty) {
          out.insert(cleaned, op.attributes);
        }
        continue;
      }

      // 图片行尾闭合（挂在上一张图片后的欠账）。
      if (pendingClose) {
        final bool startsWithNewline =
            op.isInsert &&
            op.data is String &&
            (op.data as String).startsWith('\n');
        if (!startsWithNewline) {
          out.insert('\n');
        }
        pendingClose = false;
      }

      // ②③ 图片：替换本地化路径 + 块级化。
      final String? src = _pastedImageSource(op);
      if (src != null) {
        final String url = localized[src] ?? src;
        // 前闭合：图片必须行首（不在行首才补）。
        if (!_endsWithNewline(out)) {
          out.insert('\n');
        }
        // 保留原 embed 的其他字段（width 等自定义尺寸）。
        final Map<String, Object?> embedData = <String, Object?>{
          if (data is Map)
            for (final MapEntry<Object?, Object?> entry in data.entries)
              entry.key as String: entry.value,
          BlockEmbed.imageType: url,
        };
        out.insert(embedData, op.attributes);
        pendingClose = true;
        continue;
      }

      out.push(op);
    }
    // 图片是最后一个 op：文档必须以单个 \n 结尾。
    if (pendingClose) {
      out.insert('\n');
    }
    return out;
  }

  /// 取粘贴 op 里的图片源字符串（非图片 op 返回 null）。
  String? _pastedImageSource(Operation op) {
    if (!op.isInsert) return null;
    final Object? data = op.data;
    if (data is Map && data.containsKey(BlockEmbed.imageType)) {
      return data[BlockEmbed.imageType] as String?;
    }
    return null;
  }

  /// 图片本地化：data URI 直接解码；http(s) 下载（带 UA——防盗链
  /// 站点普遍校验浏览器 UA，超时 8s/连接 5s）。失败返回 null
  /// （调用方保留原 URL，走 Image.network 兜底）。
  Future<String?> _localizeImage(String src) async {
    try {
      final Uint8List? bytes;
      if (src.startsWith('data:')) {
        bytes = UriData.parse(src).contentAsBytes();
      } else {
        bytes = await _downloadImage(src);
      }
      if (bytes == null || bytes.isEmpty) return null;
      return await NoteMediaService.saveBytes(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _downloadImage(String url) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      );
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode != HttpStatus.ok) return null;
      final BytesBuilder builder = BytesBuilder();
      await for (final List<int> chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 当前已累积 Delta 是否以换行结尾（图片块级化的重复补行守卫）。
  bool _endsWithNewline(Delta delta) {
    if (delta.operations.isEmpty) return true;
    final Operation last = delta.operations.last;
    return last.isInsert &&
        last.data is String &&
        (last.data as String).endsWith('\n');
  }

  /// Windows 桥 bug：剪贴板无 HTML 格式（如从记事本复制纯文本、
  /// 截图）时 getClipboardHtml 对空指针 toDartString 崩溃
  /// （quill_native_bridge_windows 0.1.0，上游未修）。**官方的
  /// pasteHTML 内部也调同一个桥且不捕获**——一旦我们放行（返回
  /// false），官方读 HTML 时必崩。所以「无 HTML」时必须完全接管。
  ///
  /// 返回 true = 应用已处理本次粘贴。
  ///
  /// 优先级：
  /// 1. 有 HTML → false 放行官方富文本粘贴（同一剪贴板状态下
  ///    官方再读不会崩——只有无 HTML 格式才触发空指针）；
  /// 2. 剪贴板有位图（截图/「复制图片」，Windows 桥不实现图片
  ///    剪贴板 API，用 PowerShell 读）→ 直存数据目录 + 自插 → true；
  /// 3. 其余（纯文本/应用内复制）→ 自行按内部 Delta/纯文本处理 →
  ///    true（不放行——官方 HTML/markdown 路径会踩桥崩溃）。
  Future<bool> _onClipboardPaste() async {
    try {
      final String? html = await bridge.QuillNativeBridge().getClipboardHtml();
      if (html != null && html.isNotEmpty) {
        return false;
      }
    } catch (_) {
      // 桥崩溃 = 剪贴板无 HTML 格式：官方富文本路径已不可用，
      // 下面全部路径必须返回 true 接管。
    }

    final clipboardImage = await NoteMediaService.readWindowsClipboardImage();
    if (clipboardImage != null) {
      final String path = await NoteMediaService.saveBytes(clipboardImage);
      // 有选区（含全选）→ **替换选区**为图片（Word 语义），否则原
      // 选区内容残留且图片被插到选区末尾（全选时落在文档末尾，视口
      // 不动就"看不到图"）。embed 占 1 个文档位，光标落在图片后。
      final TextSelection sel = _quill.selection;
      final int start = sel.isValid ? sel.start : 0;
      final int deleteLen = sel.isValid && !sel.isCollapsed
          ? sel.end - sel.start
          : 0;
      _quill.replaceText(
        start,
        deleteLen,
        BlockEmbed.image(path),
        TextSelection.collapsed(offset: start + 1),
      );
      return true;
    }

    await _pastePlainTextOnly();
    return true;
  }

  /// 纯文本兜底：光标处插入剪贴板文本（无 HTML 无位图时替代
  /// 官方粘贴路径——那条路会踩桥的空指针崩溃）。
  ///
  /// 读文本走 super_clipboard 原生层（自管 FFI 降级）；engine 的
  /// Clipboard.getData 降为最后兜底（其平台通道与我们 FFI 的
  /// 跨线程 OpenClipboard 竞争是 error 5 的来源之一）。
  Future<void> _pastePlainTextOnly() async {
    String? text = await NoteMediaService.readClipboardText();
    if (text == null || text.isEmpty) {
      ClipboardData? data;
      try {
        data = await Clipboard.getData(Clipboard.kTextPlain);
      } on PlatformException {
        return;
      }
      text = data?.text;
    }
    if (text == null || text.isEmpty) return;
    // 净化 U+FFFC（对象替换字符）：Windows 剪贴板复制富文本对象时
    // 纯文本层常带它。quill 会把它当 embed 替换符处理，toPlainText
    // 与真实节点类型错位（文本节点被误判为 embed），复制全选内容时
    // 触发 "String is not a subtype of Embeddable" 崩溃。
    text = text.replaceAll('\uFFFC', '');
    if (text.isEmpty) return;
    final TextSelection selection = _quill.selection;
    _quill.replaceText(
      selection.start,
      selection.end - selection.start,
      text,
      TextSelection.collapsed(offset: selection.start + text.length),
    );
  }

  /// 正文右键菜单（右键释放时触发，位置即指针处）：剪切/复制/粘贴 |
  /// 全选 | 删除。无选区（右键在选区外或纯光标）时剪切/复制/删除
  /// 自动隐藏——quill 11.x 的右键语义：选区已折叠才把光标移到右键
  /// 位置，有完整选区时保持选区不动（editor.dart
  /// onSecondarySingleTapUp），所以右键在选区内菜单即全套可见。
  ///
  /// 图片等嵌入元素的右键已被嵌入菜单处理（抑制标志置位，且该 up
  /// 事件沿路径派发到本回调晚于嵌入菜单）——检测到即跳过。
  void _showTextContextMenu(Offset position) {
    // 无论正文还是嵌入元素（图片）的右键都先聚焦：图片右键时嵌入
    // 菜单已处理、本回调会在下方抑制检查提前返回——聚焦必须放在
    // 检查之前，否则删除图片后 Ctrl+Z 撤销、继续输入都因焦点不在
    // 编辑器而失效。
    _contentFocus.requestFocus();
    if (noteContextMenuEmbedHandled) return;
    final TextSelection selection = _quill.selection;
    final bool hasSelection = selection.isValid && !selection.isCollapsed;
    unawaited(
      showNoteContextMenu(
        context,
        position: position,
        entries: <NoteContextMenuEntry>[
          // 剪贴板组：剪切/复制/粘贴（有选区才显示剪切/复制）。
          // 动作前恢复选区快照（防御：quill 对折叠光标会把光标移到
          // 右键位置，快照保证操作对象永远是右键瞬间的选区）。
          //
          // 动作全部走 controller 公开 API——不依赖 QuillRawEditorState
          // （它只能在官方 toolbar 流程的 contextMenuBuilder 里拿到，
          // 首次右键时必为 null，任何 `state?.xxx()` 都会静默失效）。
          // 键盘快捷键的终点同样是这些 controller 方法，行为一致。
          if (hasSelection)
            NoteContextMenuEntry(
              icon: LucideIcons.scissors,
              label: '剪切',
              onPressed: () => _runMenuAction(() {
                _restoreSelection(selection);
                // ignore: experimental_member_use
                _quill.clipboardSelection(false);
              }),
            ),
          if (hasSelection)
            NoteContextMenuEntry(
              icon: LucideIcons.copy,
              label: '复制',
              onPressed: () => _runMenuAction(() {
                _restoreSelection(selection);
                // ignore: experimental_member_use
                if (_quill.clipboardSelection(true)) {
                  // 与官方 copySelection(toolbar) 同语义：复制后选区
                  // 折叠到末端（光标停在继续输入的自然位置）。
                  _quill.updateSelection(
                    TextSelection.collapsed(offset: selection.end),
                    ChangeSource.local,
                  );
                }
              }),
            ),
          NoteContextMenuEntry(
            icon: LucideIcons.clipboardPaste,
            label: '粘贴',
            onPressed: () => _runMenuAction(() {
              // 有选区 → 恢复快照后粘贴 = **替换选区**（Word 惯例）；
              // 无选区 → 光标处插入。clipboardPaste 是官方全链路
              // （内部富文本 Delta → HTML → 图片钩子 → 纯文本兜底），
              // 也是 Ctrl+V 的终点，行为一致。
              if (hasSelection) _restoreSelection(selection);
              // ignore: experimental_member_use
              unawaited(_quill.clipboardPaste());
            }),
          ),
          // 选择组：全选（Word 惯例放粘贴后）。
          NoteContextMenuEntry(
            icon: LucideIcons.listChecks,
            label: '全选',
            separatorBefore: true,
            onPressed: () => _runMenuAction(() {
              // 与 Ctrl+A 终点一致（QuillEditorSelectAllAction 最终
              // 也走 controller.updateSelection 全选）。**滚动锁**过滤
              // 选区更新触发的 _showCaretOnScreen（animateTo 光标矩形
              // → 跳动），600ms 后解锁。
              _scroll.dragScrollLock = true;
              Timer(const Duration(milliseconds: 600), () {
                _scroll.dragScrollLock = false;
              });
              _quill.updateSelection(
                TextSelection(
                  baseOffset: 0,
                  extentOffset: _quill.document.length,
                ),
                ChangeSource.local,
              );
            }),
          ),
          // 删除：破坏性操作固定最后 + 警告色。直接删选区（不进
          // 剪贴板，与剪切区分），进撤销栈。
          if (hasSelection)
            NoteContextMenuEntry(
              icon: LucideIcons.trash2,
              label: '删除',
              destructive: true,
              onPressed: () => _runMenuAction(() {
                _restoreSelection(selection);
                _quill.replaceText(
                  selection.start,
                  selection.end - selection.start,
                  '',
                  TextSelection.collapsed(offset: selection.start),
                );
              }),
            ),
        ],
      ).then((itemTapped) {
        // 仅「直接关闭」（点外部/Esc）才折叠选区：菜单打开期间保持
        // 高亮，让用户知道是哪部分文字。点了条目则不折叠——动作已
        // 自行处理选区终态（全选须保持高亮；剪切/删除/粘贴后光标已
        // 落位；复制已折叠），且 close 先于 onPressed 完成 Future，
        // 此时若读选区会把刚设置的新状态（如全选）折叠掉。
        if (itemTapped) return;
        final TextSelection remaining = _quill.selection;
        if (remaining.isValid && !remaining.isCollapsed) {
          _quill.updateSelection(
            TextSelection.collapsed(offset: remaining.extentOffset),
            ChangeSource.local,
          );
        }
      }),
    );
  }

  /// 右键菜单动作统一入口：controller 公开 API + 焦点保障。
  ///
  /// - 全部动作走 QuillController 公开方法（clipboardSelection /
  ///   clipboardPaste / updateSelection / replaceText）——键盘快捷键
  ///   的终点也是这些方法，行为天然一致，且不依赖编辑器内部 state
  ///   （首次右键时 contextMenuBuilder 还没被官方 toolbar 流程调用过）；
  /// - 焦点由菜单浮层的 TextFieldTapRegion 保护（点菜单项不触发
  ///   编辑器 unfocus），此处 requestFocus 兜底「编辑器未聚焦就
  ///   弹菜单」的场景，确保动作后光标可见、Ctrl+Z 立即可用。
  void _runMenuAction(VoidCallback action) {
    if (!_contentFocus.hasFocus) {
      _contentFocus.requestFocus();
    }
    action();
  }

  /// 从列表数据装载笔记正文与标题；只装载一次。
  void _hydrateFromNotes() {
    if (_documentLoaded) return;
    final List<Note>? notes = ref.read(notesProvider).value;
    if (notes == null) return;
    Note? note;
    for (final Note n in notes) {
      if (n.id == widget.noteId) {
        note = n;
        break;
      }
    }
    final NoteContent decoded = NoteContent.decode(note?.content ?? '');
    _quill.document = Document.fromJson(decoded.delta);
    _titleController.text = note?.title ?? '';
    _documentLoaded = true;
    // 装载完成即算初始字数（元信息行显示）。
    _wordCount.value = _countWords(_quill.document.toPlainText());
    // 装载（可能更换了 Document 实例）之后再订阅内容变更流。
    _changesSub?.cancel();
    _changesSub = _quill.document.changes.listen((DocChange change) {
      // 远端同步（本项目暂无）不触发本地保存。
      if (change.source == ChangeSource.local) {
        _onQuillChanged();
        // Word「标题的后续段落 = 正文」：标题行尾回车后新行回正文。
        _resetHeaderOnEnter(change);
      }
    });
  }

  /// 列表标记构建入口：待办需要访问滚动锁（实例成员），
  /// 其余类型委托纯函数 [_listLeadingBuilder]。
  Widget? _leadingBuilder(Node node, LeadingConfig config) {
    // 待办列表：与有序标记同一几何（宽 字号×2 / 高 首行盒 / 右对齐），
    // 复选框垂直居中于**首行盒**——quill 默认把它居中于整个多行块
    // （官方 checkboxLeading 的容器是整块高），标杆应用均为首行对齐。
    // 复选框本体沿用官方 QuillCheckboxPoint（含点击切换与 UI 钩子）。
    if (config.attribute == Attribute.unchecked ||
        config.attribute == Attribute.checked) {
      final AppSettings s = ref.read(settingsProvider);
      final (double fontSize, double lineHeight) = _lineTypography(
        config,
        base: s.fontSize,
        lineHeight: s.lineHeight,
      );
      return Container(
        height: fontSize * lineHeight,
        width: fontSize * 2,
        alignment: AlignmentDirectional.centerEnd,
        // 方框到文字的间距：与原 QuillCheckboxPoint 一致（size/2）。
        padding: EdgeInsetsDirectional.only(end: fontSize / 2),
        child: _TodoCheckbox(
          // 视觉/文档解耦的勾选组件：ValueNotifier 立即反馈，不等
          // quill 块级 unwrap/wrap + 整文档 rebuild；formatText 推到
          // postFrame 用最新的 node.documentOffset 异步执行。
          checked: config.value,
          fontSize: fontSize,
          onToggle: (next) => _toggleTodo(node, next),
        ),
      );
    }
    return _listLeadingBuilder(
      node,
      config,
      base: ref.read(settingsProvider).fontSize,
      lineHeight: ref.read(settingsProvider).lineHeight,
    );
  }

  /// 目录跳转（对标飞书）：标题行滚到**视口顶部**（留 spaceLg 留白），
  /// 而非 quill caret reveal 的「最小可见」（常落视口底部）。
  ///
  /// 顺序（关键）：先上**滚动锁**拦掉聚焦/updateSelection 触发的
  /// caret reveal，再**绕锁**动画滚动到目标——两者靠锁分清敌我：
  /// 锁过滤 quill 的编程滚动，`forceAnimateTo` 是我们自己的通道。
  /// 滚完后光标落位到标题行（仍在锁内，reveal 被过滤），600ms 解锁
  /// （宽限期覆盖动画后排队触发的 reveal）。
  Future<void> _jumpToHeading(int docOffset) async {
    final RenderEditor? editor = _resolveRenderEditor();
    _scroll.dragScrollLock = true;
    _contentFocus.requestFocus();
    if (editor != null) {
      // 光标矩形在 RenderEditor 本地坐标 = 内容坐标（编辑器铺满文档高）。
      final Rect rect = editor.getLocalRectForCaret(
        TextPosition(offset: docOffset),
      );
      final double target = (rect.top - Tokens.spaceLg).clamp(
        0.0,
        _scroll.position.maxScrollExtent,
      );
      await _scroll.forceAnimateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
    if (!mounted) return;
    _quill.updateSelection(
      TextSelection.collapsed(offset: docOffset),
      ChangeSource.local,
    );
    Timer(const Duration(milliseconds: 600), () {
      if (mounted) _scroll.dragScrollLock = false;
    });
  }

  /// 待办勾选切换（自定义实现，替代官方 _handleCheckboxTap）：
  ///
  /// quill 的块级 formatText 会把 selection 重置到文档 0，官方靠
  /// postFrame 恢复——中间态真实渲染一帧，自绘工具栏按 selection=0
  /// 算 getSelectionStyle()，加粗/待办等激活按钮闪一下。这里 format
  /// 后**同一执行栈内**立即恢复选区：两次 notifyListeners 只产生一帧
  /// （恢复后的正确状态），无闪烁。滚动锁 600ms 过滤 format/
  /// updateSelection 触发的 caret reveal animateTo（视口小幅位移）。
  void _toggleTodo(Node node, bool value) {
    final TextSelection selection = _quill.selection;
    _scroll.dragScrollLock = true;
    _quill
      ..ignoreFocusOnTextChange = true
      ..skipRequestKeyboard = true
      ..formatText(
        node.documentOffset,
        0,
        value ? Attribute.checked : Attribute.unchecked,
      )
      ..updateSelection(
        selection.isValid
            ? selection
            : const TextSelection.collapsed(offset: 0),
        ChangeSource.local,
      );
    _quill.ignoreFocusOnTextChange = false;
    Timer(const Duration(milliseconds: 600), () {
      _scroll.dragScrollLock = false;
    });
  }

  /// 对齐 Word 的标题回车行为：在标题行**行尾**按 Enter，新行自动
  /// 回正文——否则 quill 默认延续 header，下一行还是 24/1.4 的大字，
  /// 与正文行距/位置不统一（用户「回车下一行」观感问题的根因）。
  ///
  /// 边界（与 Word 一致）：
  /// - 行中拆分标题 → 两半都保留标题（只处理「插入单个 \n 且新行
  ///   为空行」的行尾回车）；
  /// - 列表/引用回车延续自身样式，不受影响（只清 header）。
  void _resetHeaderOnEnter(DocChange change) {
    final List<Operation> ops = change.change.operations;
    if (ops.isEmpty) return;
    // 只认「插入单个换行符」的纯回车（排除粘贴多行/IME 长串）。
    final Object? data = ops.last.data;
    if (!ops.last.isInsert || data != '\n') return;

    // 新行起点：前面 op 的累计长度 + 1（跳过换行符本身）。
    // Operation.length 可空（retain 携带 num），插入 op 恒为正整数。
    int offset = 0;
    for (final Operation op in ops.sublist(0, ops.length - 1)) {
      offset += (op.length ?? 0).round();
    }
    final int newLineStart = offset + 1;

    // 新行必须为空行（行尾回车的特征）；行中拆分的新行有内容，
    // 保留标题（Word 同款）。
    if (_quill.document.getPlainText(newLineStart, 1) != '\n') return;

    final Style style = _quill.document.collectStyle(newLineStart, 0);
    final Object? header = style.attributes[Attribute.header.key]?.value;
    if (header is int && header > 0) {
      // 行内格式化（len 0 对块级属性作用于整行，同工具栏折叠选区）。
      // 这次格式化本身是 local change，会再次进本监听，但 last op
      // 是 retain（非纯 \n 插入）→ 不会递归。
      _quill.formatText(newLineStart, 0, Attribute.clone(Attribute.h1, null));
    }
  }

  @override
  void dispose() {
    final Timer? pendingContent = _contentDebounce;
    final Timer? pendingTitle = _titleDebounce;
    _contentDebounce = null;
    _titleDebounce = null;
    if (_documentLoaded) {
      if (pendingContent != null) {
        pendingContent.cancel();
        _flushContent();
      }
      if (pendingTitle != null) {
        pendingTitle.cancel();
        _notifier.saveTitle(widget.noteId, _titleController.text);
      }
    }
    unawaited(_changesSub?.cancel());
    _linkTipTimer?.cancel();
    if (_linkTip != null && _linkTip!.mounted) {
      _linkTip!.remove();
    }
    _wordCount.dispose();
    _contentFocus.dispose();
    _scroll.dispose();
    _quill.dispose();
    _titleController.dispose();
    super.dispose();
  }

  void _flushContent() {
    final String content = jsonEncode(_quill.document.toDelta().toJson());
    final String plainText = _quill.document.toPlainText();
    _notifier.saveContent(widget.noteId, content, plainText: plainText);
    // 元信息字数与落盘同拍更新（保存防抖 500ms 一次，不逐键全扫）。
    _wordCount.value = _countWords(plainText);
  }

  void _onQuillChanged() {
    _contentDebounce?.cancel();
    _contentDebounce = Timer(const Duration(milliseconds: 500), _flushContent);
  }

  void _onTitleChanged(String value) {
    _titleDebounce?.cancel();
    _titleDebounce = Timer(const Duration(milliseconds: 500), () {
      _notifier.saveTitle(widget.noteId, value);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 只订阅「本笔记是否存在」这一个布尔（Riverpod select）——
    // 自动保存每次更新整张笔记列表时，编辑器不再全量重建。
    // 列表数据本身只在 hydration 时经 ref.read 读取一次。
    final bool exists = ref.watch(
      notesProvider.select(
        (async) => async.value?.any((Note n) => n.id == widget.noteId) ?? false,
      ),
    );
    // notes 晚于 initState 到达时兜底装载（装载后本行立即变空操作）。
    _hydrateFromNotes();
    if (!exists) {
      return const Center(child: Text('笔记已删除'));
    }
    final ThemeData theme = Theme.of(context);
    // 设置（外观/编辑器偏好）：watch 后改设置即整体重建 —— 设置面板
    // 浮在主界面之上时，背后内容因此实时反映宽度/字号/行高的变化。
    final AppSettings settings = ref.watch(settingsProvider);
    // 当前笔记的最后修改时间（标题行元信息）：select 只订阅这一个
    // 字段，保存落盘后刷新，列表其他变化不牵动编辑器重建。
    final DateTime? revisedAt = ref.watch(
      notesProvider.select((AsyncValue<List<Note>> async) {
        for (final Note n in async.value ?? const <Note>[]) {
          if (n.id == widget.noteId) {
            return n.revisedAt;
          }
        }
        return null;
      }),
    );

    // 视图级 Stack：搜索条浮层要贴工具栏搜索按钮（在 Column 顶部），
    // 挂在编辑区 Stack 会落到标题/正文上。坐标 (44, 72) 恰为按钮左下角。
    //
    // TOC 实际可见性：窗口 < 1120 放不下「侧栏 320 + 正文 + TOC 248」
    // 三栏，自动隐藏（开关状态保留，拉宽后恢复显示）。
    final bool tocVisible =
        _tocVisible && MediaQuery.sizeOf(context).width >= 1120;
    return Stack(
      children: <Widget>[
        Column(
          children: <Widget>[
            // 顺序对齐成熟文档应用（飞书/语雀）：工具栏 → 标题 → 正文。
            // 自绘工具栏（AppFlowy 式）：格式动作依赖选区，
            // 无选区时禁用；撤销/重做随使用条件启用。
            // Word/飞书式：全时可用，动作前自动聚焦正文，
            // 待输入样式（toggledStyle）不因「没先进过编辑器」而失效。
            NoteFormatToolbar(
              controller: _quill,
              contentFocus: _contentFocus,
              onSearch: _openSearch,
              tocActive: _tocVisible,
              onToggleToc: () => setState(() => _tocVisible = !_tocVisible),
            ),
            // 标题与正文同列：与正文同一内容列（宽度随设置实时变化），
            // 左对齐（对齐 Notion/飞书——标题不贴窗口左缘）。
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: settings.titleWidth),
                child: SizedBox(
                  height: 52,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Tokens.spaceLg,
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _titleController,
                            onChanged: _onTitleChanged,
                            // 输完标题按 Enter，光标直接进正文开头：
                            // requestFocus 只给焦点不移光标，必须显式设选区。
                            onSubmitted: (_) {
                              _quill.skipRequestKeyboard = false;
                              _quill.updateSelection(
                                const TextSelection.collapsed(offset: 0),
                                ChangeSource.local,
                              );
                              _contentFocus.requestFocus();
                            },
                            // 标题字号 = base × 1.75（粗体），随设置的正文字号
                            // 联动。**必须大于正文 h1 档（base × 1.5）**，否则
                            // 笔记标题比正文一级标题还小——层级倒挂。
                            // 与 appflowy 版视图同口径（`EditorTypography.titleScale`）。
                            // 字体同正文统一雅黑——中英混排基线才不漂移。
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontSize: settings.fontSize * 2.0,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0,
                              fontFamily: AppTheme.editorFont,
                            ),
                            maxLines: 1,
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              hintText: '无标题',
                              // hint 不继承标题的字号/字重，且用 35% 透明的
                              // 「待输入」灰（onSurfaceVariant 在墨绿种子下
                              // 偏深，看不出占位感）。与列表空标题回退文案
                              // 同一概念同一词。
                              hintStyle: TextStyle(
                                fontSize: settings.fontSize * 2.0,
                                fontWeight: FontWeight.w400,
                                color: AppTheme.hintColor(
                                  theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ),
                        ),
                        // 元信息（修改时间 · 字数）：右侧小字，与标题同行。
                        // 字数走 ValueListenableBuilder（保存防抖后更新，
                        // 不逐键全文扫描）；修改时间由 revisedAt select
                        // 驱动，落盘即变。
                        ValueListenableBuilder<int>(
                          valueListenable: _wordCount,
                          builder: (BuildContext context, int count, _) {
                            final String revised =
                                revisedAt == null ? '' : _formatRevised(revisedAt);
                            final String meta = <String>[
                              if (revised.isNotEmpty) '修改于 $revised',
                              if (count > 0) '$count 字',
                            ].join(' · ');
                            if (meta.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return Text(
                              meta,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.6),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              // 编辑区 + 右侧 TOC 栏：AnimatedSize 宽度 0↔248 平滑展开
              // （窄窗口自动隐藏——宽度放不下三栏时 tocVisible 恒 false，
              // 开关状态保留，拉宽后恢复）。
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
              // Ctrl+F 打开编辑器内搜索（搜索条自身 Esc 关闭）。
              // CallbackShortcuts 挂在编辑区：焦点在任何子节点（正文/标题）
              // 时都可达，且不拦截正文自己的按键。
              child: CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                      _openSearch,
                },
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      // 拖选贴边自动滚动：补齐 quill 缺失的边缘连续滚动
                      // （quill 只在指针移动事件里 bringIntoView 一步，鼠标停住即停）。
                      child: _DragAutoScroll(
                        scrollController: _scroll,
                        onSecondaryTapUp: _showTextContextMenu,
                        onPrimaryPointerDown: () =>
                            _contentFocus.requestFocus(),
                        onHover: _onEditorHover,
                        child: Scrollbar(
                          controller: _scroll,
                          thumbVisibility: true,
                          // 厚度/颜色走全局 scrollbarTheme（6px，悬浮 9）。
                          radius: const Radius.circular(4),
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context)
                                .copyWith(scrollbars: false),
                            // 不再外层限宽 720：滚动器铺满全宽——两侧空白
                            // 处滚轮也能滚（标杆应用行为）；文字列宽改由
                            // quill 原生 maxContentWidth 限宽并居中。
                            // Ctrl+\ 清除格式（Word/飞书惯例键位）：quill
                            // 内部快捷键表没绑这个组合，按键会冒泡到本层
                            // CallbackShortcuts——与「更多」菜单共用
                            // clearSelectionFormatting 单一实现。
                            child: CallbackShortcuts(
                              bindings: <ShortcutActivator, VoidCallback>{
                                const SingleActivator(
                                  LogicalKeyboardKey.backslash,
                                  control: true,
                                ): () => clearSelectionFormatting(_quill),
                                const SingleActivator(
                                  LogicalKeyboardKey.backslash,
                                  meta: true,
                                ): () => clearSelectionFormatting(_quill),
                              },
                              child: QuillEditor.basic(
                              key: _editorKey,
                              controller: _quill,
                              scrollController: _scroll,
                              // 显式持有焦点节点：标题 Enter 跳正文（onSubmitted）才有落点，
                              // 后续工具栏保持编辑器焦点也要靠它。
                              focusNode: _contentFocus,
                              config: QuillEditorConfig(
                                // 撑满整列高度：文字下方的空白也属于编辑器——
                                // 右键空白处有菜单、点击定位到文末（成熟编辑器行为）。
                                // 没有它编辑器高度收缩为内容高度，空白区不在范围内。
                                expands: true,
                                // 720px 内容列（40 字/行甜点区）：
                                // quill 原生限宽 + 水平居中——滚动器
                                // 全宽铺满，滚轮在空白处同样生效。
                                // null（全宽）= 不限宽，内容铺满可用宽。
                                maxContentWidth: settings.contentWidth,
                                padding: const EdgeInsets.fromLTRB(
                                  Tokens.spaceLg,
                                  Tokens.spaceXs,
                                  Tokens.spaceLg,
                                  Tokens.spaceLg,
                                ),
                                // 空文档占位（quill 内置，内容为空时显示）。
                                placeholder: '记录此刻的想法…',
                                // 有序列表标记的光学对齐：数字用 Segoe UI、正文中文
                                // 用雅黑回退，两套字体的基线/字面有 1~2px 视觉差，
                                // 导致数字相对中文行偏上。微调量见 _olMarkerNudge。
                                // 返回 null 的分支（无序/复选/代码块）沿用 quill 默认。
                                // ignore: experimental_member_use
                                customLeadingBlockBuilder: _leadingBuilder,
                                // 中文黄金排版（customStyles 与包默认 merge，只覆盖差异项）。
                                customStyles: _chineseStyles(
                                  context,
                                  base: settings.fontSize,
                                  lineHeight: settings.lineHeight,
                                ),
                                // 勾选完成的待办：整行文字淡化（**渲染层**，
                                // 不写进 Delta）——对标 Notion/飞书/语雀的
                                // 完成态表现，不加删除线：删除线是行内属性，
                                // 自动写入会覆盖用户自己的格式（取消勾选
                                // 丢失），且导出/搜索/复制都会带上假删除线。
                                // 这里只改颜色，取消勾选即刻恢复。
                                customStyleBuilder: (Attribute attribute) {
                                  if (attribute.key == Attribute.list.key &&
                                      attribute.value ==
                                          Attribute.checked.value) {
                                    return TextStyle(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.5),
                                    );
                                  }
                                  return const TextStyle();
                                },
                                // 嵌入渲染（自建 builder，数据格式对齐官方）：
                                // 图片 + 分隔线 + 公式（「插入」菜单写入）。
                                embedBuilders: [
                                  NoteImageEmbedBuilder(),
                                  NoteHrEmbedBuilder(),
                                  noteFormulaEmbedBuilder,
                                  NoteAttachmentEmbedBuilder(),
                                ],
                                // 代码块语法高亮（纯渲染层，不改文档数据）：
                                // 代码块行按 highlight 解析着色，普通行原样。
                                textSpanBuilder: (
                                  BuildContext context,
                                  Node node,
                                  int nodeOffset,
                                  String text,
                                  TextStyle? style,
                                  GestureRecognizer? recognizer,
                                ) => buildCodeAwareSpan(
                                  context,
                                  node,
                                  text,
                                  style,
                                  recognizer,
                                ),
                                // 链接直点打开 + 手型光标：quill 桌面
                                // 编辑模式默认 Ctrl+点击才给 recognizer
                                // （canLaunchLinks 门控）——普通悬停无
                                // recognizer、无手型、点击只挪光标。用
                                // customRecognizerBuilder 给 link 属性
                                // 常驻 TapGestureRecognizer（优先于门控
                                // 被采用）：直点即跳浏览器；textSpanBuilder
                                // 据 recognizer != null 画 click 手型。
                                customRecognizerBuilder: _linkRecognizer,
                                // 右键上下文菜单：**不走 contextMenuBuilder**
                                // （它只在官方 toolbar 显示流程中被调用，
                                // 且曾随编辑器重建多次触发叠出双菜单）——
                                // 右键释放事件直接弹共享菜单，见
                                // _showTextContextMenu。本 builder 仅返回
                                // 空以抑制 quill 默认浮条（null = 官方
                                // 默认浮条会弹出）。
                                contextMenuBuilder:
                                    (context, rawEditorState) {
                                  return TextFieldTapRegion(
                                    child: const SizedBox.shrink(),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
                  ),
                  // TOC 目录栏：左侧细分隔线勾轮廓（与内容面板边线同款）。
                  AnimatedSize(
                    duration: Tokens.durationNormal,
                    curve: Curves.easeOutCubic,
                    child: tocVisible
                        ? DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  color: theme.colorScheme.outlineVariant
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            ),
                            child: NoteTocPanel(
                              controller: _quill,
                              onJump: _jumpToHeading,
                              scrollController: _scroll,
                              topVisibleOffset: _topVisibleDocOffset,
                              // 跳转动画期间锁为 true：区分「目录跳转的
                              // 编程滚动」与「用户滚动」。
                              scrollLocked: () => _scroll.dragScrollLock,
                            ),
                          )
                        : const SizedBox(width: 0),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (_searchVisible)
          // 搜索条贴工具栏搜索按钮正下方：视图级 Stack 的 (44, 72)
          // 恰为按钮左下角（工具栏高 40 + 4 间隙；边距 8 + undo 24 +
          // 8 + redo 24 + 8）。不用 CompositedTransformFollower——
          // Windows 上 IME 组合光标经 FollowerLayer 变换后反复触发
          // 候选窗重定位，实测点击即卡死；布局为确定值，静态定位等效。
          Positioned(
            top: 44,
            left: 72,
            child: NoteSearchBar(controller: _quill, onClose: _closeSearch),
          ),
      ],
    );
  }
}

/// 拖选贴边自动滚动：补齐 quill 缺失的边缘连续滚动。
///
/// quill 的拖选滚动只由指针移动事件驱动（`_handleSelectionChanged`
/// → `bringIntoView`，每移动一次滚一步）——鼠标停在视口上下边缘
/// 时不再产生移动事件，滚动即停（表现为「拖不出视口、一下一下跳」）。
///
/// 本组件监听原始指针事件：拖选期间指针进入上下边缘区时，周期性
/// 滚动视口并合成指针移动事件（按滚动后的内容位置重新落点），
/// 驱动选区随滚动连续扩展——等效框架 `SelectableRegion` 的
/// `AutoScroller` 行为。
/// 链接悬浮提示气泡：跟随光标旁显示目标 URL（inverse 配色）。
/// 4s 自动消失 / 移出链接即消 / 同链接不重复弹。
class _LinkTip extends StatelessWidget {
  const _LinkTip({required this.url, required this.position});

  final String url;
  final Offset position;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Size screen = MediaQuery.sizeOf(context);

    const double tipWidth = 420;
    double left = position.dx + 12;
    if (left + tipWidth > screen.width - 8) {
      left = screen.width - tipWidth - 8;
    }
    double top = position.dy + 24;
    if (top > screen.height - 48) {
      top = position.dy - 44;
    }

    return Positioned(
      left: left,
      top: top,
      child: Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: tipWidth),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.inverseSurface.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(Tokens.radiusSm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                LucideIcons.link,
                size: 13,
                color: scheme.onInverseSurface.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onInverseSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DragAutoScroll extends StatefulWidget {
  const _DragAutoScroll({
    required this.scrollController,
    required this.child,
    this.onSecondaryTapUp,
    this.onPrimaryPointerDown,
    this.onHover,
  });

  final _EditorScrollController scrollController;
  final Widget child;

  /// 右键释放回调：在此弹上下文菜单（比 contextMenuBuilder 可靠——
  /// builder 会随编辑器重建被多次触发）。
  final ValueChanged<Offset>? onSecondaryTapUp;

  /// 左键按下（拖选/点击定位开始）回调：编辑器视图在此 requestFocus
  /// ——quill 桌面拖选不聚焦编辑器，未聚焦时按键（Delete 等）到不了
  /// 编辑器快捷键层。
  final VoidCallback? onPrimaryPointerDown;

  /// 指针悬停（无按键移动）回调：编辑器视图做链接悬浮提示。
  final ValueChanged<Offset>? onHover;

  @override
  State<_DragAutoScroll> createState() => _DragAutoScrollState();
}

class _DragAutoScrollState extends State<_DragAutoScroll> {
  /// 边缘触发区高度（距上/下边多少像素内开始滚动）。
  static const double _edgeZone = 48;

  /// 贴死边缘时的最大滚动速度（px/帧）。
  static const double _maxSpeed = 14;

  static const Duration _tick = Duration(milliseconds: 16);

  /// 松开鼠标后保持滚动锁的宽限期：拖选中排队的
  /// _showCaretOnScreen（500ms 延迟）可能在松手后才触发，
  /// 它会 animateTo 拖动起点的旧光标矩形——正是「拖完跳回顶部」。
  static const Duration _gracePeriod = Duration(milliseconds: 600);

  int? _pointer;
  int? _secondaryPointer;
  Offset? _position;
  Timer? _timer;
  Timer? _grace;

  /// 最近一次真实指针移动的时刻：真实事件活跃（<32ms）时 quill 的
  /// bringIntoView 已在逐事件滚动，本组件让位避免同帧双滚动（快拖闪烁）。
  DateTime _lastRealMove = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _grace?.cancel();
    _stopAll();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent event) {
    // 右键按下：记录指针 id（up 时回调弹菜单），不进拖选流程。
    // 顺带清零嵌入菜单抑制标志——down 在嵌入菜单处理之前收到
    // （hit test 路径 leaf → root），保证每轮右键从干净状态开始。
    if (event.buttons == kSecondaryMouseButton) {
      _secondaryPointer = event.pointer;
      noteContextMenuEmbedHandled = false;
      return;
    }
    _pointer = event.pointer;
    _position = event.position;
    // 拖选即聚焦：quill 桌面的拖选不 requestFocus（与点击不同，
    // delegate.onDragSelectionStart 只更新选区）——刚进编辑页没点过
    // 正文时直接拖选，焦点仍在编辑器之外，按 Delete/Backspace 到不了
    // 编辑器的 Shortcuts，表现为「第一次拖选按删除键没反应」。聚焦
    // 触发的 caret reveal 会被下面的拖选锁拦截，无跳动。
    widget.onPrimaryPointerDown?.call();
    // 拖选期间上锁：quill 的一切编程滚动（bringIntoView 的 jumpTo、
    // _showCaretOnScreen 的 animateTo）被 ScrollPosition 过滤，
    // 滚动全权归本组件的平滑 AutoScroller。
    widget.scrollController.dragScrollLock = true;
    _updateTimer();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    _position = event.position;
    _lastRealMove = DateTime.now();
    _updateTimer();
  }

  void _onPointerEnd(PointerEvent event) {
    // 右键释放：回调弹菜单（位置即指针处）。
    if (event.pointer == _secondaryPointer) {
      _secondaryPointer = null;
      widget.onSecondaryTapUp?.call(event.position);
      return;
    }
    if (event.pointer != _pointer) return;
    // 停边缘自动滚动（松手即停）；锁保留到宽限期结束——
    // 拖选中排队的 _showCaretOnScreen 在松手后触发会跳回拖动起点。
    _timer?.cancel();
    _timer = null;
    _grace?.cancel();
    _grace = Timer(_gracePeriod, () {
      _grace = null;
      widget.scrollController.dragScrollLock = false;
    });
  }

  void _stopAll() {
    _timer?.cancel();
    _timer = null;
    _pointer = null;
    _position = null;
  }

  void _updateTimer() {
    if (_inEdgeZone()) {
      _timer ??= Timer.periodic(_tick, (_) => _scrollTick());
    } else {
      // 离开边缘区：停自动滚动，正常拖选继续。
      _timer?.cancel();
      _timer = null;
    }
  }

  bool _inEdgeZone() {
    final Offset? position = _position;
    if (position == null) return false;
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || box.size.isEmpty) return false;
    final Offset local = box.globalToLocal(position);
    // 越界（拖出窗口/内容区外）视作贴死边缘：钳制进 [0, height]。
    final double y = local.dy.clamp(0.0, box.size.height);
    return y < _edgeZone || box.size.height - y < _edgeZone;
  }

  /// 距边缘越近滚动越快。
  double _speedFor(double distance) {
    final double t = (distance / _edgeZone).clamp(0.0, 1.0);
    return _maxSpeed - (_maxSpeed - 2) * t;
  }

  void _scrollTick() {
    final Offset? position = _position;
    final int? pointer = _pointer;
    if (position == null || pointer == null) return _stopAll();
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null) return _stopAll();
    final ScrollPosition position_ = widget.scrollController.position;
    if (position_ is! _EditorScrollPosition) return _stopAll();
    final Offset local = box.globalToLocal(position);
    // 越界按贴死边缘处理（速度取最大），保证拖出内容区外也连续滚动。
    final double y = local.dy.clamp(0.0, box.size.height);
    double delta;
    if (y < _edgeZone) {
      delta = -_speedFor(y);
    } else if (box.size.height - y < _edgeZone) {
      delta = _speedFor(box.size.height - y);
    } else {
      _timer?.cancel();
      _timer = null;
      return;
    }
    // 真实指针事件活跃期让位：quill 的 bringIntoView 已随事件滚动，
    // 再 jumpTo + 合成事件就是同帧双滚动（快拖文字闪烁的根因）。
    // 只在鼠标停住/微动（边缘区）时由本组件接管连续滚动。
    final bool realMovesFlowing =
        DateTime.now().difference(_lastRealMove) <
        const Duration(milliseconds: 32);
    if (realMovesFlowing) {
      return;
    }
    final double target = (position_.pixels + delta).clamp(
      position_.minScrollExtent,
      position_.maxScrollExtent,
    );
    if ((target - position_.pixels).abs() < 0.5) {
      // 已滚到文档尽头：停下（但保留指针状态，拖回边缘区可再启动）。
      _timer?.cancel();
      _timer = null;
      return;
    }
    // forceJumpTo：绕过拖选锁（锁只拦 quill 的编程滚动）。
    position_.forceJumpTo(target);
    // 合成一次指针移动事件：拖动识别器按滚动后的内容位置扩展选区
    // （位置加微小偏移，保证识别器收到非零增量）。
    final Offset next = position + const Offset(0.01, 0.01);
    GestureBinding.instance.handlePointerEvent(
      PointerMoveEvent(
        pointer: pointer,
        position: next,
        kind: PointerDeviceKind.mouse,
        buttons: 1,
      ),
    );
    _position = next;
  }

  @override
  Widget build(BuildContext context) {
    // MouseRegion：悬停事件的保证派发通道（MouseTrackerAnnotation）。
    return MouseRegion(
      onHover: (PointerHoverEvent event) =>
          widget.onHover?.call(event.position),
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerEnd,
        onPointerCancel: _onPointerEnd,
        child: widget.child,
      ),
    );
  }
}

/// 编辑器滚动控制器：提供「拖选滚动锁」。
///
/// 拖选期间（dragScrollLock = true）quill 的一切编程滚动被过滤：
///   - `bringIntoView` 的逐事件 jumpTo（拖选跳动的来源）
///   - `_showCaretOnScreen` 的 animateTo（拖完跳回拖动起点的来源）
/// 滚动全权交给 _DragAutoScroll 的平滑 AutoScroller；滚轮等
/// 用户主动滚动走 pointerScroll 路径，不受锁影响。
class _EditorScrollController extends ScrollController {
  bool dragScrollLock = false;

  /// 目录跳转等**自有滚动**的绕锁通道：锁的职责是拦 quill 的编程
  /// 滚动（caret reveal / bringIntoView），不是拦我们自己。
  Future<void> forceAnimateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    final _EditorScrollPosition position = this.position
        as _EditorScrollPosition;
    return position.forceAnimateTo(to, duration: duration, curve: curve);
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _EditorScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    owner: this,
  );
}

class _EditorScrollPosition extends ScrollPositionWithSingleContext {
  _EditorScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.owner,
  });

  final _EditorScrollController owner;

  bool get _locked => owner.dragScrollLock;

  /// 供 _DragAutoScroll 绕过锁直接驱动视口。
  void forceJumpTo(double value) => super.jumpTo(value);

  /// 目录跳转的绕锁动画滚动（同 forceJumpTo 的动画版）。
  Future<void> forceAnimateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) => super.animateTo(to, duration: duration, curve: curve);

  _ChaseScrollActivity? get _chase => activity is _ChaseScrollActivity
      ? activity! as _ChaseScrollActivity
      : null;

  @override
  void pointerScroll(double delta) {
    // 平滑滚轮（浏览器同构）：Flutter 桌面默认滚轮是逐格 jumpTo
    // （瞬跳、无动画，flutter#14749，「不丝滑 + 闪烁感」的来源）。
    //
    // 追赶循环以**框架正规的 ScrollActivity** 实现（与官方
    // BallisticScrollActivity 同构）：每格滚轮把目标前移，活动内的
    // 帧回调向目标做指数逼近——快滚间隙大追得快，慢滚小步缓跟，
    // 停手指数减速滑出，单一连续运动、无逐格重启的脉冲。
    // （Windows 触控板走 PanZoom 路径，本就平滑，不经过此处。）
    if (_locked) return;
    final _ChaseScrollActivity? chase = _chase;
    final double base = chase?._target ?? pixels;
    final double target = (base + delta).clamp(
      minScrollExtent,
      maxScrollExtent,
    );
    if (chase != null) {
      chase.accumulateTo(target);
    } else if ((target - pixels).abs() >= 0.5) {
      beginActivity(
        _ChaseScrollActivity(this, vsync: context.vsync, initialTarget: target),
      );
    }
  }

  @override
  void jumpTo(double value) {
    if (_locked) return;
    super.jumpTo(value);
  }

  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    if (_locked) return Future<void>.value();
    return super.animateTo(to, duration: duration, curve: curve);
  }
}

/// 待办勾选框（**视觉/文档解耦**——解决 quill 块级 unwrap 副作用
/// 导致的偶发"勾不上"与"一次点两个"）。
///
/// 痛点：quill 的块级 `formatText` 改 list 属性的 value 时，Line
/// 节点会从所属 Block unwrap + wrap 新 Block，controller notify
/// 同步标记 dirty，但 rebuild 实际排到下一帧。复选框只有 16×16px
/// 命中区且紧贴文字，连点时下一次 hit test 可能命中"已变更但尚未
/// rebuild"的旧 RenderObject 树——onTap 触发但闭包的 node/offset
/// 已过期，toggle 写到错位置；或落空被 quill 接管为 selection 更新。
///
/// 方案：
/// - **ValueNotifier 即时视觉反馈**：点击瞬间方框变色，**不等** quill
///   rebuild——用户感知"我点到了"；
/// - **formatText 推到 postFrame 异步执行**：Node 引用保留，documentOffset
///   getter 动态算最新值，避开与下一帧 rebuild 的时序竞争；
/// - **扩命中区**：`HitTestBehavior.opaque` 让 padding 区也接收事件，
///   距离文字 fontSize/4 容差，提升点按精度。
class _TodoCheckbox extends StatefulWidget {
  const _TodoCheckbox({
    required this.checked,
    required this.fontSize,
    required this.onToggle,
  });

  /// 来自 quill 的当前文档状态（行级 list 属性值）。
  final bool checked;
  final double fontSize;

  /// 期望变成的勾选状态（onTap 回调时传入）。
  final ValueChanged<bool> onToggle;

  @override
  State<_TodoCheckbox> createState() => _TodoCheckboxState();
}

class _TodoCheckboxState extends State<_TodoCheckbox> {
  /// 视觉层即时状态：点击瞬间翻转，**不等** quill 文档 rebuild。
  /// 外部状态（widget.checked）在文档更新后通过 didUpdateWidget 同步。
  late bool _local = widget.checked;

  /// 防止 postFrame 的 onToggle 与下一次快速点击撞车。
  bool _pending = false;

  /// 最近 down 的本地位置（不存 pointer id：每个 down 都覆盖，
  /// 任何状态下重新计算距离，避免状态残留导致误触发）。
  Offset? _downOffset;

  @override
  void didUpdateWidget(covariant _TodoCheckbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 文档状态已更新（quill rebuild 后传入新 checked）：
    // 当前没有未完成的 toggle 时同步视觉，否则视觉保持由 _pending
    // 决定（避免把"用户刚点的期望"被外部状态回滚成旧值）。
    if (!_pending && oldWidget.checked != widget.checked) {
      _local = widget.checked;
    }
  }

  void _onTap() {
    // 同批次去重：同一次点击命中重叠的多个 Listener 时，只有第一个
    // 响应（第二个在 60ms 内到达，直接忽略）。
    final DateTime now = DateTime.now();
    final DateTime? last = _lastTodoToggleAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 60)) {
      return;
    }
    _lastTodoToggleAt = now;
    if (_pending) return;
    final bool next = !_local;
    // 视觉即时反馈：不等 quill 文档 rebuild 就翻转方框——用户立刻
    // 看到"我点到了"，消除"勾不上"的主观感受。
    setState(() => _local = next);
    // **同步**写文档：曾试过推到 postFrame，结果在 postFrame 里改
    // 文档结构（块级属性会 unwrap/wrap 行节点）后，本帧 postFrame
    // 队列中排在后面的 quill caret 回调（_updateCaretRectIfNeeded）
    // 会拿**新 selection** 去查**尚未 rebuild 的旧渲染树**，触发
    // text_line.dart 的 "The provided text position is not in the
    // current node" 断言。同步执行时 selection 与文档始终一致。
    _pending = true;
    widget.onToggle(next);
    _pending = false;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Listener(
      // opaque：让 padding 区域也接收 pointer 事件，扩点击命中区
      // （避免紧贴文字导致误落空被 quill 接管为 selection 更新）。
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        // 不存 pointer id：每个 down 都覆盖 _down，任何状态下重新
        // 计算距离，避免状态残留导致误触发。
        _downOffset = event.localPosition;
      },
      onPointerUp: (event) {
        final Offset? down = _downOffset;
        _downOffset = null;
        if (down == null) return;
        // 阈值放宽到 18px（含 padding 命中区内的轻微移动）。
        if ((event.localPosition - down).distance < 18) {
          _onTap();
        }
      },
      onPointerCancel: (_) {
        _downOffset = null;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        // padding 只扩**水平**方向：垂直方向扩会让相邻行复选框的
        // 命中区重叠（框高 16 + 上下 padding ≈ 命中区高，接近行间距），
        // hit test 会把重叠的两个兄弟 Listener 都加入路径 → 一次点击
        // 触发两个 onTap = "两个框一起选"。水平方向邻居是文字，无重叠。
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.fontSize / 4),
          child: SizedBox(
            width: widget.fontSize,
            height: widget.fontSize,
            child: Material(
              color: _local ? scheme.primary : scheme.surface,
              shape: RoundedRectangleBorder(
                side: BorderSide(
                  color: _local
                      ? scheme.primary
                      : scheme.onSurface.withValues(alpha: 0.5),
                ),
                borderRadius: BorderRadius.circular(2),
              ),
              child: _local
                  ? Icon(
                      LucideIcons.check,
                      size: widget.fontSize,
                      color: scheme.onPrimary,
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// 同一次点击的响应去重：相邻复选框的命中区可能重叠（padding 扩命中
/// 区 + 行间距有限），hit test 会把重叠的**多个兄弟 Listener** 都加入
/// 路径，一次点击触发多个 toggle = "两个框一起选"。记录上次 toggle 的
/// 时刻，极短时间内的重复响应直接忽略（人工连点两个不同框的间隔远
/// 大于此阈值，不会误伤）。
DateTime? _lastTodoToggleAt;

/// 原始指针点击（down/up 配对 + 位移阈值）：**不进手势竞技场**。
///
/// 用途：嵌在编辑器内的可点击元素（复选框等）。若用 InkWell/手势，
/// tap 会与编辑器的双击选词识别器同场竞争——单击被 hold 到双击
/// 超时（~300ms），且双击判定有 100px 位置容差，快速连续点击相邻
/// 元素时第二击被误判为双击、tap 直接取消（点击偶发无效的根源）。
/// 原始指针事件沿路径派发即时可得，与图片右键走 Listener 同一思路。
class _InstantTap extends StatefulWidget {
  const _InstantTap({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_InstantTap> createState() => _InstantTapState();
}

class _InstantTapState extends State<_InstantTap> {
  int? _pointer;
  Offset? _down;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (PointerDownEvent event) {
        _pointer = event.pointer;
        _down = event.position;
      },
      onPointerUp: (PointerUpEvent event) {
        if (event.pointer != _pointer) return;
        _pointer = null;
        final Offset? down = _down;
        _down = null;
        // 按下后基本未移动才算点击：排除「拖选文字时起按/收按落在
        // 复选框上」的误触（拖选位移远超阈值）。
        if (down != null && (event.position - down).distance < 12) {
          widget.onTap();
        }
      },
      onPointerCancel: (PointerCancelEvent event) {
        if (event.pointer == _pointer) {
          _pointer = null;
          _down = null;
        }
      },
      child: widget.child,
    );
  }
}

/// 滚轮追赶活动：帧驱动指数逼近（浏览器平滑滚动同构算法）。
///
/// 每帧 `pixels += (target - pixels) × k`，`k = 1 - e^(-dt/τ)`、
/// 帧率无关；新滚轮格经 [accumulateTo] 推远目标即可继续追赶，
/// 无需重启活动。到达目标（<0.5px）后自动 `goIdle` 收尾。
class _ChaseScrollActivity extends ScrollActivity {
  _ChaseScrollActivity(
    this._position, {
    required TickerProvider vsync,
    required double initialTarget,
  }) : super(_position) {
    _target = initialTarget.clamp(
      _position.minScrollExtent,
      _position.maxScrollExtent,
    );
    _ticker = vsync.createTicker(_tick);
    _ticker!.start();
  }

  final _EditorScrollPosition _position;

  Ticker? _ticker;
  Duration? _lastElapsed;
  late double _target;

  /// 时间常数（秒）：越小越跟手。65ms ≈ 浏览器平滑滚动的量级。
  static const double _chaseTau = 0.065;

  /// 推进累积目标（绝对位置，内部钳制在可滚动范围内）。
  void accumulateTo(double target) {
    _target = target.clamp(
      _position.minScrollExtent,
      _position.maxScrollExtent,
    );
  }

  void _tick(Duration elapsed) {
    final Duration dt = elapsed - (_lastElapsed ?? elapsed);
    _lastElapsed = elapsed;
    final double k = 1 - math.exp(-dt.inMicroseconds / 1e6 / _chaseTau);
    final double next = _position.pixels + (_target - _position.pixels) * k;
    if ((_target - next).abs() < 0.5) {
      // 距离小于半像素：贴合目标并收尾（自然减速到停）。
      _ticker!.stop();
      _position.setPixels(_target);
      _position.goIdle();
    } else {
      _position.setPixels(next);
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }

  @override
  bool get shouldIgnorePointer => false;

  @override
  bool get isScrolling => true;

  @override
  double get velocity => 0.0;

  @override
  void applyNewDimensions() {
    // 内容尺寸变化（如续写追加内容）：目标钳制进新范围。
    _target = _target.clamp(
      _position.minScrollExtent,
      _position.maxScrollExtent,
    );
  }
}
