import 'dart:async';
import 'dart:ui' as ui;

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/llm_client.dart';
import '../theme/app_float_surface.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../window/window_service.dart';
import 'providers.dart';
import 'settings_panel.dart' show appNavigatorKey;

// 右侧常驻 **AI 问答轨**的宽度（逻辑 px）已收编进 [Tokens.askRailWidth]。
// 320–360 是右聊天栏的行业档（Notion AI / Heptabase Ask）：放得下一条
// 答案 + 引用角标，又不过度挤占编辑区（1280 窗宽下主区仍有 ~600）。

// 右轨布局的**断点**（2026-10-08 收编进 [Tokens.askRailBreakpoint]）：
// 窗口宽度低于它时 AI 不以常驻栏出现，降级为 [showAskPanel] 的居中浮层。

/// **问笔记 · 浮层态**（窄窗 / 移动端）：遮罩 + 居中卡片 + Esc 关闭。
///
/// 宽窗桌面端默认不走这里——问答是常驻右栏（[AskRail]），答案能与正文
/// 同屏对照、引用角标点了不关面板。窗口窄到放不下右轨时（见
/// [Tokens.askRailBreakpoint]），`HomeScreen` 再把同一份问答体降级回本浮层。
///
/// ## 引用角标是这层的灵魂
/// 答案里每个 `[n]` 都能跳回原文块——所以问答体是一个**导航动作**，
/// 浮层态跳转后必须关闭自己（否则遮罩压在刚跳过去的笔记上）。
Future<void> showAskPanel() {
  final OverlayState overlay = appNavigatorKey.currentState!.overlay!;
  final Completer<void> closed = Completer<void>();
  OverlayEntry? entry;
  late final bool Function(KeyEvent event) handleEscKey;

  void close() {
    if (!closed.isCompleted) closed.complete();
    if (entry != null && entry!.mounted) entry!.remove();
    entry = null;
    HardwareKeyboard.instance.removeHandler(handleEscKey);
  }

  handleEscKey = (KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      close();
    }
    return false;
  };
  HardwareKeyboard.instance.addHandler(handleEscKey);

  entry = OverlayEntry(
    builder: (BuildContext overlayContext) => _AskOverlay(onClose: close),
  );
  overlay.insert(entry!);
  return closed.future;
}

class _AskOverlay extends StatelessWidget {
  const _AskOverlay({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Stack(
      children: <Widget>[
        // 点遮罩即关：浮层是短暂停留，不该有"必须找到关闭钮"的路。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: ColoredBox(color: scheme.scrim.withValues(alpha: 0.32)),
          ),
        ),
        Positioned.fill(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 560,
                maxHeight: MediaQuery.sizeOf(context).height * 0.8,
              ),
              child: AppFloatSurface(
                key: const Key('askRailFloatSurface'),
                width: 560,
                child: FocusScope(child: _AskModalCard(onClose: onClose)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 浮层态的卡片：自有头部（Sparkles + 标题 + 关闭钮）+ 内边距，
/// 下面挂与右栏完全相同的 [AskPanelBody]。
class _AskModalCard extends StatelessWidget {
  const _AskModalCard({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Tokens.spaceLg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _AskHeader(onClose: onClose),
          const SizedBox(height: Tokens.spaceSm),
          AskPanelBody(autofocus: true, onCitationOpened: onClose),
        ],
      ),
    );
  }
}

/// 浮层态（窄窗 / 移动端）头部：Sparkles +「问笔记」+ 关闭钮。
/// 右栏 [AskRail] 不再自带关闭钮（2026-10-11 起其开合归工作区右角折叠钮）。
class _AskHeader extends StatelessWidget {
  const _AskHeader({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        const tabler.Sparkles(
          height: Tokens.iconMd,
          width: Tokens.iconMd,
          strokeWidth: 1.5,
        ),
        Text('问笔记', style: theme.textTheme.titleSmall),
        const Spacer(),
        IconButton(
          icon: const tabler.X(
            height: Tokens.iconMd,
            width: Tokens.iconMd,
            strokeWidth: 1.5,
          ),
          tooltip: '关闭（Esc）',
          onPressed: onClose,
        ),
      ],
    );
  }
}

/// **问笔记 · 常驻右栏**（宽窗桌面的主形态）。
///
/// 与左导航同色平铺（[AppTheme.windowBackground]），只靠左侧 1px 分隔线
/// 与主区分界——它是与编辑区**并排工作**的一列，不是浮在窗口上的卡片：
/// - 头部固定（Sparkles + 标题 + 关闭），下面是与浮层**同一个** [AskPanelBody]；
/// - 打开（`aiPanelOpenProvider` 变 true）即把焦点送进提问框，
///   命令 / 图标 / 快捷键三条入口都能直接打字；
/// - 焦点在栏内按 **Esc** 收起整栏（先 unfocus，避免键盘落进宽 0 的隐藏控件）；
/// - 点引用角标只跳转、**不关栏**——答案要留在屏上和原文对照。
///
/// 槽位动画与卸载策略由 `HomeScreen` 的 `_AiRailSlot` 负责
///（开合之间问答体不销毁 ⇒ 问题与答案保留）。
class AskRail extends ConsumerStatefulWidget {
  const AskRail({super.key});

  @override
  ConsumerState<AskRail> createState() => _AskRailState();
}

class _AskRailState extends ConsumerState<AskRail> {
  /// 挂在问答体上：打开时用它把焦点递进输入框（不必让 body 自己 watch 开关）。
  final GlobalKey<AskPanelBodyState> _bodyKey = GlobalKey<AskPanelBodyState>();

  void _close() {
    // 先摘焦点再收起：否则焦点留在宽度动画到 0 的输入框里，键盘事件没有可见落点。
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(aiPanelOpenProvider.notifier).close();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    // 每一次 false → true 都聚焦输入框（首帧布局完成后再要，节点才已挂上）。
    ref.listen<bool>(aiPanelOpenProvider, (bool? _, bool open) {
      if (open) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _bodyKey.currentState?.focusInput();
        });
      }
    });

    return SizedBox(
      width: Tokens.askRailWidth,
      // 底色 / 圆角 / 裁切由外壳的**浮面卡**统一给（home_screen.dart 的
      // _AiRailSlot，2026-10-09 opencode 风）：本体透明、不再画左边线——
      // 主卡与 AI 卡之间的 8px 缝隙（露窗口底）就是分界，不用分割线。
      child: Focus(
        // Esc 只在焦点位于本栏子树时触发（事件沿焦点祖先链冒泡到这里），
        // 不会与画布 / 编辑器的 Esc 语义相撞。
        onKeyEvent: (FocusNode _, KeyEvent event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _close();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Tokens.spaceMd,
                Tokens.spaceXs,
                Tokens.spaceXs,
                Tokens.spaceXs,
              ),
              child: Row(
                children: <Widget>[
                  tabler.Sparkles(
                    height: Tokens.iconMdSm,
                    width: Tokens.iconMdSm,
                    strokeWidth: 1.5,
                    colorFilter: ui.ColorFilter.mode(
                      scheme.onSurfaceVariant,
                      ui.BlendMode.srcIn,
                    ),
                  ),
                  const SizedBox(width: Tokens.spaceSm),
                  Text('问笔记', style: theme.textTheme.titleSmall),
                ],
              ),
            ),
            Container(height: 1, color: AppTheme.divider(scheme)),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Tokens.spaceLg,
                  Tokens.spaceMd,
                  Tokens.spaceLg,
                  Tokens.spaceLg,
                ),
                child: AskPanelBody(key: _bodyKey, fillExpanded: true),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 问答体本身：答案（含引用角标）+ 错误 + 钉底的提问区。
///
/// 无头部、无遮罩、无 Esc——**宿主无关**，浮层（[_AskModalCard]）与右栏
/// （[AskRail]）复用同一实现，保证两种形态永不漂移。
///
/// - [autofocus]：浮层打开即聚焦；右栏靠 [focusInput] 在开关翻转时聚焦。
/// - [fillExpanded]：右栏要占满剩余高度（答案区 `Expanded`）；浮层随内容
///   收缩（`Flexible` + 弹窗自身的高度上限）。
/// - [onCitationOpened]：点引用角标跳原文后的收尾。浮层传关闭；右栏传
///   null（不关栏，答案留着对照）。
class AskPanelBody extends ConsumerStatefulWidget {
  const AskPanelBody({
    super.key,
    this.autofocus = false,
    this.fillExpanded = false,
    this.onCitationOpened,
  });

  final bool autofocus;
  final bool fillExpanded;
  final VoidCallback? onCitationOpened;

  @override
  AskPanelBodyState createState() => AskPanelBodyState();
}

class AskPanelBodyState extends ConsumerState<AskPanelBody> {
  final TextEditingController _question = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onComposerKey);
  bool _busy = false;
  bool _canSend = false;
  Answer? _answer;
  String? _error;

  @override
  void initState() {
    super.initState();
    _question.addListener(_onQuestionChanged);
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _question.removeListener(_onQuestionChanged);
    _question.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 右栏打开时由 [AskRail] 调用：把键盘焦点递交给提问框。
  void focusInput() {
    if (mounted) _focus.requestFocus();
  }

  void _onQuestionChanged() {
    final bool canSend = _question.text.trim().isNotEmpty;
    if (canSend != _canSend) {
      setState(() => _canSend = canSend);
    }
  }

  /// **Enter 发送 / Shift+Enter 换行**（桌面）：挂在输入框自己的
  /// [FocusNode] 上——焦点节点先于编辑器收到键，返回 `handled` 后
  /// 换行符不会被插进文本。手机端没有物理 Enter，走圆形发送钮即可。
  /// （长按产生的是独立的 [KeyRepeatEvent]，这里只认 [KeyDownEvent]，
  /// 忙等也由 [_ask] 自身兜住，不会因连发重入。）
  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      unawaited(_ask());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _ask() async {
    final String q = _question.text.trim();
    if (q.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      // 一问发出即清空、焦点留在框里（focusNode 不动），方便连续追问。
      _question.clear();
    });
    try {
      final Answer answer = await ref.read(answerServiceProvider).ask(q);
      if (!mounted) return;
      setState(() {
        _answer = answer;
        _busy = false;
      });
    } on LlmUnavailableException catch (e) {
      // 服务没配 / 打不通：给可操作的报错（文案来自 LLM 客户端），不静默。
      if (mounted) {
        setState(() {
          _error = e.message;
          _busy = false;
        });
      }
    } on LlmResponseException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _busy = false;
        });
      }
    }
  }

  /// 点引用角标：经唯一跳转通道 `locateProvider` 定位到原文块，
  /// 再交宿主收尾（浮层关闭自己；右栏保持打开）。
  void _jumpTo(Citation citation) {
    ref
        .read(locateProvider.notifier)
        .locate(
          noteId: citation.noteId,
          blockId: citation.blockId,
          focus: true,
        );
    widget.onCitationOpened?.call();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Answer? answer = _answer;

    final Widget answerArea = SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SelectableText(answer?.text ?? '', style: theme.textTheme.bodyMedium),
          if (answer?.vectorFallbackReason != null) ...<Widget>[
            const SizedBox(height: Tokens.spaceSm),
            // 直接展示检索层给的降级原因（与主页搜索同一口径，见
            // search_provider.dart）：那句话本身就是可操作的说明。
            Text(
              answer!.vectorFallbackReason!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (answer?.unknownCitations.isNotEmpty ?? false) ...<Widget>[
            const SizedBox(height: Tokens.spaceSm),
            Text(
              '模型引用了不存在的编码'
              '${answer!.unknownCitations.map((int n) => '[$n]').join()}'
              '（已忽略）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (answer?.citations.isNotEmpty ?? false) ...<Widget>[
            const SizedBox(height: Tokens.spaceMd),
            Text('来源', style: theme.textTheme.labelMedium),
            const SizedBox(height: Tokens.spaceXs),
            Wrap(
              spacing: Tokens.spaceSm,
              runSpacing: Tokens.spaceXs,
              children: <Widget>[
                for (final Citation c in answer!.citations)
                  ActionChip(
                    label: Text(
                      '[${c.index}] ${_preview(c.snippet)}',
                      style: theme.textTheme.bodySmall,
                    ),
                    tooltip: '跳到原文',
                    onPressed: () => _jumpTo(c),
                  ),
              ],
            ),
          ],
        ],
      ),
    );

    return Column(
      mainAxisSize: widget.fillExpanded ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 答案在上、提问区钉底（2026-09-29 用户定，聊天面板惯例）：右栏里
        // 答案占输入框以上的全部高度——空态就是一整块留白，有答案从顶往下读；
        // 浮层随内容长高，仍是"先问后答"的阅读顺序。
        if (widget.fillExpanded)
          Expanded(child: answerArea)
        else if (answer != null) ...<Widget>[
          Flexible(child: answerArea),
          const SizedBox(height: Tokens.spaceMd),
        ],
        // 报错（服务没配 / 打不通）压在 composer 之上、答案之下，不挤进输入区。
        if (_error != null) ...<Widget>[
          if (answer == null) const SizedBox(height: Tokens.spaceMd),
          Padding(
            padding: const EdgeInsets.only(bottom: Tokens.spaceMd),
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
        // 钉底的一体化 composer（输入区与发送钮同容器，见 [_AskComposer]）。
        _AskComposer(
          controller: _question,
          focusNode: _focus,
          canSend: _canSend,
          busy: _busy,
          onSend: _ask,
        ),
      ],
    );
  }

  static String _preview(String snippet) {
    final String flat = snippet.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 16 ? flat : '${flat.substring(0, 16)}…';
  }
}

/// 一体化**提问 Composer**（ChatGPT / Claude 范式，2026-09-29 用户定）。
///
/// 取代旧的"描边输入框 + 独立『提问』按钮"：
/// - 输入区与发送钮合并进同一板形容器（[AppTheme.boardFill] + 1px
///   [AppTheme.divider] + 圆角 [Tokens.radiusLg]），层次靠板色不靠粗描边；
/// - 聚焦态**只提亮描边**（onSurfaceVariant 50%，150ms），不染主色、不发光；
/// - 多行自适应（1–6 行），超出内部滚动；
/// - 右下角 32 圆形发送钮（tabler.ArrowUp）：空内容禁用（primary 30%），
///   `busy` 时原位换成转圈，不再改文字 / 不再外挂进度圈；
/// - 桌面键位提示「Enter 发送 · Shift+Enter 换行」只在桌面显示。
class _AskComposer extends StatefulWidget {
  const _AskComposer({
    required this.controller,
    required this.focusNode,
    required this.canSend,
    required this.busy,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool canSend;
  final bool busy;
  final VoidCallback onSend;

  @override
  State<_AskComposer> createState() => _AskComposerState();
}

class _AskComposerState extends State<_AskComposer> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool focused = widget.focusNode.hasFocus;

    return AnimatedContainer(
      duration: Tokens.durationFast,
      decoration: BoxDecoration(
        color: AppTheme.boardFill(theme.brightness),
        borderRadius: BorderRadius.circular(Tokens.radiusLg),
        border: Border.all(
          color: focused
              ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
              : AppTheme.divider(scheme),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        Tokens.spaceMd,
        Tokens.spaceXs,
        Tokens.spaceXs,
        Tokens.spaceXs,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            minLines: 1,
            maxLines: 6,
            style: theme.textTheme.bodyMedium,
            cursorColor: scheme.primary,
            decoration: const InputDecoration(
              hintText: '问一句，答案带原文引用',
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: Tokens.spaceSm),
            ),
          ),
          Row(
            children: <Widget>[
              // 物理键位只在桌面有意义；移动端这行留给发送钮即可。
              // Flexible 兜底：340 栏宽在大字号/长翻译下也只能省略号，不能溢出。
              if (WindowService.isSupported)
                Flexible(
                  child: Text(
                    'Enter 发送 · Shift+Enter 换行',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const Spacer(),
              _SendButton(
                active: widget.canSend && !widget.busy,
                busy: widget.busy,
                onSend: widget.onSend,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// composer 右下角的 32 圆形发送钮。
///
/// [active] 为 false（空内容或检索中）时：底色降到 primary 30%、不响应点击，
/// 语义上就是 disabled；[busy] 时箭头原位换成 14px 转圈。
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.active,
    required this.busy,
    required this.onSend,
  });

  final bool active;
  final bool busy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '发送（Enter）',
      child: Material(
        color: active ? scheme.primary : scheme.primary.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(Tokens.radiusFull),
        child: InkWell(
          borderRadius: BorderRadius.circular(Tokens.radiusFull),
          onTap: active ? onSend : null,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: busy
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onPrimary,
                      ),
                    )
                  : tabler.ArrowUp(
                      height: 16,
                      width: 16,
                      strokeWidth: 2,
                      colorFilter: ui.ColorFilter.mode(
                        scheme.onPrimary,
                        ui.BlendMode.srcIn,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
