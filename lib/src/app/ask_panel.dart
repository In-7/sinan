import 'dart:async';

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/llm_client.dart';
import '../theme/app_float_surface.dart';
import '../theme/tokens.dart';
import 'providers.dart';
import 'settings_panel.dart' show appNavigatorKey;

/// /
///
/// /
/// 与设置页同一个范式（遮罩 + 悬浮卡片 + Esc 关闭）——问一句、看一眼、要么点角标
/// /
///
/// ## 引用角标是这层的灵魂
/// /
/// /
/// /
///
/// ## 初版不做流式
/// /
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
        //  
        Positioned.fill(
          child: GestureDetector(
            behavior: .opaque,
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
              //  
              //  
              //  
              //  
              //  
              child: AppFloatSurface(
                width: 560,
                child: FocusScope(child: _AskCard(onClose: onClose)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AskCard extends ConsumerStatefulWidget {
  const _AskCard({required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<_AskCard> createState() => _AskCardState();
}

class _AskCardState extends ConsumerState<_AskCard> {
  final TextEditingController _question = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _busy = false;
  Answer? _answer;
  String? _error;

  @override
  void initState() {
    super.initState();
    //  
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _question.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final String q = _question.text.trim();
    if (q.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Answer answer = await ref.read(answerServiceProvider).ask(q);
      if (!mounted) return;
      setState(() {
        _answer = answer;
        _busy = false;
      });
    } on LlmUnavailableException catch (e) {
      //  
      //  
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

  ///  
  ///
  ///  
  ///  
  ///
  ///  
  void _jumpTo(Citation citation) {
    ref
        .read(locateProvider.notifier)
        .locate(
          noteId: citation.noteId,
          blockId: citation.blockId,
          focus: true,
        );
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Answer? answer = _answer;
    return Padding(
      padding: const EdgeInsets.all(Tokens.spaceLg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
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
                onPressed: widget.onClose,
              ),
            ],
          ),
          const SizedBox(height: Tokens.spaceSm),
          TextField(
            controller: _question,
            focusNode: _focus,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _ask(),
            decoration: const InputDecoration(
              hintText: '问一句，答案带原文引用',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Tokens.spaceSm),
          Row(
            children: <Widget>[
              FilledButton(
                onPressed: _busy ? null : _ask,
                child: Text(_busy ? '检索中…' : '提问'),
              ),
              const SizedBox(width: Tokens.spaceMd),
              if (_busy)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: Tokens.spaceMd),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (answer != null) ...<Widget>[
            const SizedBox(height: Tokens.spaceMd),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SelectableText(
                      answer.text,
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (answer.vectorFallbackReason != null) ...<Widget>[
                      const SizedBox(height: Tokens.spaceSm),
                      Text(
                        '模型引用了不存在的编码',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (answer.unknownCitations.isNotEmpty) ...<Widget>[
                      const SizedBox(height: Tokens.spaceSm),
                      Text(
                        '模型引用了不存在的编码'
                        '${answer.unknownCitations.map((int n) => '[$n]').join()}'
                        '（已忽略）',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (answer.citations.isNotEmpty) ...<Widget>[
                      const SizedBox(height: Tokens.spaceMd),
                      Text('来源', style: theme.textTheme.labelMedium),
                      const SizedBox(height: Tokens.spaceXs),
                      Wrap(
                        spacing: Tokens.spaceSm,
                        runSpacing: Tokens.spaceXs,
                        children: <Widget>[
                          for (final Citation c in answer.citations)
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
              ),
            ),
          ],
        ],
      ),
    );
  }

  ///  
  static String _preview(String snippet) {
    final String flat = snippet.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 16 ? flat : '${flat.substring(0, 16)}…';
  }
}
