import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../command/commands.dart' show runCaptureNote;
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// **独立常驻捕获框**（2026-10-08 修订：撤销 OmniBar「一框三用」）。
///
/// 只做捕获、不与搜索混：高 ~64、整宽、直接可输入，回车 → [runCaptureNote]
/// 新建 spark（带初始文本）。搜索走左栏「搜索」项 + `Ctrl+K` 浮层；命令走
/// `Ctrl+Shift+P`。
class OmniBar extends ConsumerStatefulWidget {
  const OmniBar({super.key, this.autofocus = true});

  /// 是否挂载即抢焦点（主页顶部的那条默认 `true`）。
  final bool autofocus;

  @override
  ConsumerState<OmniBar> createState() => _OmniBarState();
}

class _OmniBarState extends ConsumerState<OmniBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _fieldFocus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String q = _controller.text.trim();
    if (q.isEmpty) return; // 空回车不建空笔记
    _controller.clear();
    await runCaptureNote(ref, q);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return SizedBox(
      height: 64,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.floatSurface(theme.brightness),
          borderRadius: BorderRadius.circular(Tokens.radiusMd),
          border: Border.fromBorderSide(AppTheme.menuBorder(scheme)),
        ),
        child: Row(
          children: <Widget>[
            const SizedBox(width: Tokens.spaceLg),
            tabler.Plus(
              height: Tokens.iconMd,
              width: Tokens.iconMd,
              strokeWidth: Tokens.iconStroke,
              colorFilter: ui.ColorFilter.mode(
                scheme.onSurfaceVariant,
                ui.BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: Tokens.spaceMd),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _fieldFocus,
                autofocus: widget.autofocus,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface,
                ),
                onSubmitted: (_) => unawaited(_submit()),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '记点什么…',
                  hintStyle: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(width: Tokens.spaceLg),
          ],
        ),
      ),
    );
  }
}
