import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// 编辑器内查找/跳转：官方 QuillToolbarSearchDialog 的 M3 自绘版。
///
/// 交互语义与官方一致（源码 search_dialog.dart）：
/// - 输入防抖 300ms 后全文查找（`document.search`，支持大小写/全字）；
/// - 命中列表循环跳转（上/下按钮，首尾相接）；
/// - 跳转 = `updateSelection` 选中命中段，编辑器自动滚动到位；
/// - 命中落在嵌入块（图片等）上时只选中整个嵌入块（长度 1）；
/// - 计数 `n/m` 显示当前命中序号。
///
/// 桌面端改为编辑区右上角的浮动面板（VS Code/Word 惯例），
/// 非模态——查找时不打断正文阅读。Ctrl+F 由编辑器视图接键触发。
class NoteSearchBar extends StatefulWidget {
  const NoteSearchBar({
    super.key,
    required this.controller,
    required this.onClose,
  });

  final QuillController controller;

  /// 关闭回调：视图负责恢复正文焦点。
  final VoidCallback onClose;

  @override
  State<NoteSearchBar> createState() => _NoteSearchBarState();
}

class _NoteSearchBarState extends State<NoteSearchBar> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  /// 全部命中偏移量与当前序号。
  List<int> _offsets = const <int>[];
  int _index = 0;

  bool _caseSensitive = false;
  bool _wholeWord = false;

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // 首帧后再聚焦：initState 直接抢焦点时 EditableText 尚未挂树，
    // IME 连接携带的组字光标矩形是零值/过期变换——Windows 输入法
    // 候选窗会飘到窗口角落甚至窗口外（「看不到输入法」的根因）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  String get _query => _input.text;

  /// 输入防抖 300ms（官方一致）：停顿才查找，避免逐键全文扫描。
  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _find);
  }

  /// 全文查找：保留当前位置，跳到 >= 当前位置的首个命中（官方语义）。
  void _find() {
    if (_query.isEmpty) {
      setState(() {
        _offsets = const <int>[];
        _index = 0;
      });
      _collapseToBase();
      return;
    }
    final int currPos = _offsets.isNotEmpty ? _offsets[_index] : 0;
    List<int> offsets;
    try {
      offsets = widget.controller.document.search(
        _query,
        caseSensitive: _caseSensitive,
        wholeWord: _wholeWord,
      );
    } on StateError {
      // 正则语法错误等：按无命中处理，不崩搜索条。
      offsets = const <int>[];
    }
    setState(() {
      _offsets = offsets;
      _index = 0;
      for (int n = 0; n < _offsets.length; n++) {
        if (_offsets[n] >= currPos) {
          _index = n;
          break;
        }
      }
    });
    if (_offsets.isNotEmpty) {
      _moveTo(_offsets[_index]);
    } else {
      _collapseToBase();
    }
  }

  /// 选中命中段（编辑器随之滚动到位）。
  void _moveTo(int offset) {
    int length = _query.length;
    // 命中嵌入块：只选中整个嵌入块（长度 1），官方同款陷阱处理。
    final Node? leaf = widget.controller.queryNode(offset);
    if (leaf is Embed) {
      length = 1;
    }
    widget.controller.updateSelection(
      TextSelection(baseOffset: offset, extentOffset: offset + length),
      ChangeSource.local,
    );
  }

  void _moveToNext() {
    if (_offsets.isEmpty) return;
    setState(() {
      _index = _index < _offsets.length - 1 ? _index + 1 : 0;
    });
    _moveTo(_offsets[_index]);
  }

  void _moveToPrevious() {
    if (_offsets.isEmpty) return;
    setState(() {
      _index = _index > 0 ? _index - 1 : _offsets.length - 1;
    });
    _moveTo(_offsets[_index]);
  }

  /// 无命中/清空时把选区收回光标（官方 clearSelection 同款）。
  void _collapseToBase() {
    final TextSelection selection = widget.controller.selection;
    if (selection.isValid && !selection.isCollapsed) {
      widget.controller.updateSelection(
        TextSelection(
          baseOffset: selection.baseOffset,
          extentOffset: selection.baseOffset,
        ),
        ChangeSource.local,
      );
    }
  }

  void _close() {
    _collapseToBase();
    widget.onClose();
  }

  String get _counter {
    if (_query.isEmpty) return '';
    return _offsets.isEmpty ? '0/0' : '${_index + 1}/${_offsets.length}';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color iconColor = scheme.onSurfaceVariant;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        // Escape 关闭：焦点在输入框时也生效（Shortcuts 向上冒泡）。
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      // 浮层不在任何 Material 之下（编辑画布是自绘 Container），
      // 而 TextField/IconButton 硬校验 Material 祖先——包透明 Material
      // 满足校验且不额外绘制（面板底色由下方 Container 提供）。
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          width: 440,
          padding: const EdgeInsets.symmetric(
            horizontal: Tokens.spaceSm,
            vertical: Tokens.spaceXs,
          ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(Tokens.radiusMd),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.18),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 2,
          children: <Widget>[
            // 输入框最左（紧挨触发它的工具栏搜索按钮，视觉延续）；
            // 开关居中；导航+关闭居右（浏览器/VS Code 惯例）。
            // 查找输入框：suffix 显示 n/m 命中计数（官方一致）。
            Expanded(
              child: Container(
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(Tokens.radiusSm),
                ),
                child: TextField(
                  controller: _input,
                  focusNode: _inputFocus,
                  onChanged: _onChanged,
                  onSubmitted: (_) => _moveToNext(),
                  style: TextStyle(fontSize: 14, color: scheme.onSurface),
                  cursorWidth: 1.5,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '查找',
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: AppTheme.hintColor(scheme.onSurface),
                    ),
                    counterText: '',
                    suffixText: _counter,
                    suffixStyle: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: Tokens.spaceSm,
                      vertical: 9,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Tokens.radiusSm),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
            // 大小写 / 全字匹配开关（官方设置区收进两个切换钮）。
            IconButton(
              icon: Icon(LucideIcons.caseSensitive, size: 16),
              tooltip: '区分大小写',
              isSelected: _caseSensitive,
              visualDensity: VisualDensity.compact,
              onPressed: () {
                setState(() => _caseSensitive = !_caseSensitive);
                _find();
              },
            ),
            IconButton(
              icon: Icon(LucideIcons.wholeWord, size: 16),
              tooltip: '全字匹配',
              isSelected: _wholeWord,
              visualDensity: VisualDensity.compact,
              onPressed: () {
                setState(() => _wholeWord = !_wholeWord);
                _find();
              },
            ),
            const _BarDivider(color: null),
            IconButton(
              icon: Icon(LucideIcons.chevronUp, size: 16, color: iconColor),
              tooltip: '上一个',
              visualDensity: VisualDensity.compact,
              onPressed: _offsets.isNotEmpty ? _moveToPrevious : null,
            ),
            IconButton(
              icon: Icon(LucideIcons.chevronDown, size: 16, color: iconColor),
              tooltip: '下一个',
              visualDensity: VisualDensity.compact,
              onPressed: _offsets.isNotEmpty ? _moveToNext : null,
            ),
            IconButton(
              icon: Icon(LucideIcons.x, size: 16, color: iconColor),
              tooltip: '关闭（Esc）',
              visualDensity: VisualDensity.compact,
              onPressed: _close,
            ),
          ],
          ),
        ),
      ),
    );
  }
}

/// 搜索条内的细分隔线。
class _BarDivider extends StatelessWidget {
  const _BarDivider({required this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: Tokens.spaceXxs),
      color: (color ?? scheme.outlineVariant).withValues(alpha: 0.6),
    );
  }
}
