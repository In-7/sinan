import 'package:flutter_quill/flutter_quill.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// 目录（TOC）面板：收集正文中的标题行（H1~H3），点击跳转。
///
/// - 数据源：遍历 `document.root.children`，取 `header` 属性的行——
///   标题体系（H1~H3）本来就是文档数据的一部分，TOC 只是**读侧**，
///   不写任何 Delta；
/// - 实时性：挂 controller 监听，文档/选区变化时重算（标题数量级
///   小，重算成本可忽略）；
/// - 跳转：交由 [onJump] 回调（编辑器视图实现「标题滚到视口顶部」
///   的飞书式定位——依赖滚动锁与 RenderEditor，不宜下放本组件）。
///
/// 视觉：**高亮跟随滚动**——当前章节 = 视口顶部之上最近的标题
/// （网页端目录的「我读到哪了」指示）。滚一次只做一次命中查询
/// （[topVisibleOffset]），标题位置不逐帧重算，成本恒定。
class NoteTocPanel extends StatefulWidget {
  const NoteTocPanel({
    super.key,
    required this.controller,
    required this.onJump,
    required this.scrollController,
    required this.topVisibleOffset,
    this.scrollLocked,
  });

  final QuillController controller;

  /// 跳转回调：参数为标题行的文档偏移。
  final ValueChanged<int> onJump;

  /// 编辑区滚动控制器：滚动时重算高亮。
  final ScrollController scrollController;

  /// 视口顶部对应的文档偏移（null = 暂无法计算，如尚未布局）。
  final int? Function() topVisibleOffset;

  /// 是否处于「编程滚动」中（目录跳转动画期间为 true）：此时的滚动
  /// 事件不是用户滚动，不能清除点击固定项。
  final bool Function()? scrollLocked;

  @override
  State<NoteTocPanel> createState() => _NoteTocPanelState();
}

class _NoteTocPanelState extends State<NoteTocPanel> {
  /// 是否需要重算标题列表：文档变化 → 重算。
  bool _dirty = true;
  List<_TocEntry> _entries = const <_TocEntry>[];
  int _activeIndex = -1;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    widget.scrollController.addListener(_onScroll);
    // 首帧后算一次高亮（渲染对象此时已布局完成）。
    _scheduleActiveUpdate();
  }

  @override
  void didUpdateWidget(NoteTocPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      _dirty = true;
    }
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onChanged() {
    _dirty = true;
    setState(_scheduleActiveUpdate);
  }

  /// 滚动：只重算高亮（标题列表不变），成本一次命中查询 + O(N) 比较。
  ///
  /// 编程滚动（目录跳转动画）期间**忽略**——那不是用户滚动，不能解除
  /// 点击固定；用户自己滚则解除固定，交还给滚动规则。
  void _onScroll() {
    if (widget.scrollLocked?.call() ?? false) return;
    _pinnedOffset = null;
    _scheduleActiveUpdate();
  }

  /// 最近一次点击的条目（存**文档偏移**而非索引）：文档末尾几条标题
  /// 受 maxScrollExtent 限制无法滚到顶部，滚动规则选不中它们——
  /// 点击后固定住，直到用户手动滚动才交还规则。偏移失效（该标题被
  /// 删除/改写）时自动回落规则，不会指错。
  int? _pinnedOffset;

  /// 高亮计算**必须推迟到布局完成之后**：它要对编辑器渲染对象做命中
  /// 查询（getPositionForOffset），而文档变化（如撤销）会把渲染对象
  /// 标记为 dirty——在 build 阶段查询会踩
  /// `!debugNeedsLayout` 断言（paragraph.dart）。
  /// 同帧合并（_activeScheduled），每帧最多算一次。
  bool _activeScheduled = false;

  void _scheduleActiveUpdate() {
    if (_activeScheduled || !mounted) return;
    _activeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activeScheduled = false;
      if (!mounted) return;
      final int next = _activeIndexOfView();
      if (next != _activeIndex) {
        setState(() => _activeIndex = next);
      }
    });
  }

  void _recompute() {
    final List<_TocEntry> entries = <_TocEntry>[];
    for (final Node node in widget.controller.document.root.children) {
      // header 属性 value：**int 1/2/3**（本版 quill 的 Delta 形如
      // "attributes":{"header": 1}，非 'h1' 字符串；或分支兼容官方
      // 潜在的字符串变体）。其余档位不入目录，与 Notion/飞书的
      // 目录只收 1~3 级一致。
      final int level = switch (node.style.attributes[Attribute.h1.key]?.value) {
        1 || 'h1' => 1,
        2 || 'h2' => 2,
        3 || 'h3' => 3,
        _ => 0,
      };
      if (level == 0) continue;
      final String text = node.toPlainText().trim();
      if (text.isEmpty) continue;
      entries.add(_TocEntry(level, text, node.documentOffset));
    }
    _entries = entries;
    _dirty = false;
  }

  /// 当前章节，三条规则按优先级：
  ///
  /// 1. **点击固定**（[_pinnedOffset]）：末尾几条标题受 maxScrollExtent
  ///    限制滚不到顶部，滚动规则选不中——点了就固定住，直到用户手动
  ///    滚动才解除（见 [_onScroll]）；
  /// 2. **到底兜底**：已滚到底时，取视口内第一条可见标题（同样是末尾
  ///    标题无法停靠顶部的补偿）；
  /// 3. **常规规则**：视口顶部之上最近的标题（网页端目录语义——滚轮
  ///    阅读时高亮随滚动移动，而非只在光标移动时才更新）。
  ///
  /// 取不到视口偏移时回落为 -1（不高亮，不做错误指示）。
  int _activeIndexOfView() {
    // ① 点击固定（偏移失效则自动回落后续规则，不会指错）。
    final int? pinned = _pinnedOffset;
    if (pinned != null) {
      for (int i = 0; i < _entries.length; i++) {
        if (_entries[i].offset == pinned) return i;
      }
    }

    final int? top = widget.topVisibleOffset();
    if (top == null) return -1;

    // ② 到底兜底。
    final ScrollPosition? position = widget.scrollController.hasClients
        ? widget.scrollController.position
        : null;
    final bool atBottom = position != null &&
        position.pixels >= position.maxScrollExtent - 1;
    if (atBottom) {
      for (int i = 0; i < _entries.length; i++) {
        if (_entries[i].offset >= top) return i;
      }
      if (_entries.isNotEmpty) return _entries.length - 1;
      return -1;
    }

    // ③ 常规规则。
    int active = -1;
    for (int i = 0; i < _entries.length; i++) {
      if (_entries[i].offset <= top) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }

  void _jump(_TocEntry entry) {
    // 固定本次点击的条目并立即反映（不等滚动规则重算）。
    _pinnedOffset = entry.offset;
    setState(() {});
    widget.onJump(entry.offset);
  }

  @override
  Widget build(BuildContext context) {
    if (_dirty) _recompute();
    // 高亮不在 build 里算（见 _scheduleActiveUpdate 的说明）：
    // 文档变化/滚动各触发一次 post-frame 重算。
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return SizedBox(
      width: 248,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tokens.spaceLg,
              Tokens.spaceLg,
              Tokens.spaceLg,
              Tokens.spaceXs,
            ),
            child: Text(
              '目录',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                letterSpacing: 1,
              ),
            ),
          ),
          Expanded(
            child: _entries.isEmpty
                ? Center(
                    child: Text(
                      '用「标题 1~3」组织正文，\n结构会出现在这里',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                        height: 1.8,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(
                      left: Tokens.spaceMd,
                      right: Tokens.spaceMd,
                      bottom: Tokens.spaceLg,
                    ),
                    itemCount: _entries.length,
                    itemBuilder: (BuildContext context, int index) {
                      final _TocEntry entry = _entries[index];
                      final bool active = index == _activeIndex;
                      return InkWell(
                        borderRadius: BorderRadius.circular(Tokens.radiusSm),
                        onTap: () => _jump(entry),
                        child: Container(
                          padding: EdgeInsetsDirectional.only(
                            start: (entry.level - 1) * 14,
                            top: 5,
                            bottom: 5,
                            end: Tokens.spaceXs,
                          ),
                          decoration: BoxDecoration(
                            // 14%：8% 在浅色下几乎看不出选中态。
                            color: active
                                ? scheme.primary.withValues(alpha: 0.14)
                                : null,
                            borderRadius: BorderRadius.circular(
                              Tokens.radiusSm,
                            ),
                          ),
                          child: Text(
                            entry.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              // 三级字号梯度（14/13/12）：之前 H2/H3
                              // 同为 12，层级全靠缩进，H2 显得偏小。
                              fontSize: entry.level == 1
                                  ? 14
                                  : entry.level == 2
                                      ? 13
                                      : 12,
                              // 字重梯度（600/500/400）配合字号强化层级；
                              // 选中态一律加重（H3 原本 400，光靠底色
                              // 区分度不足）。
                              fontWeight: active
                                  ? FontWeight.w600
                                  : switch (entry.level) {
                                      1 => FontWeight.w600,
                                      2 => FontWeight.w500,
                                      _ => FontWeight.w400,
                                    },
                              color: active
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 目录条目：级别（1~3）、标题文本、文档偏移（跳转落点）。
class _TocEntry {
  const _TocEntry(this.level, this.text, this.offset);

  final int level;
  final String text;
  final int offset;
}
