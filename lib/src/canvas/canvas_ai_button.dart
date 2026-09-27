import 'dart:async';

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:material_ui/material_ui.dart';

import '../theme/app_popover.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';

/// 工具条上的「AI」按钮：一句话指令 �?模型 �?改画布�?
///
/// ## 形态照 [CanvasInsertButton]（同一�?[AppPopover] 范式�?
/// �?插入"一致：锚点是个 IconButton，展开一个窄浮层。这样工具条不会因为多一�""?
/// 常驻输入框而变高，也符�?工具条只放触发器、参数进浮层"的既有分工�""?
///
/// ## 为什么浮层里只有一个输入框
/// 其余信息（画布现状、动作契约、坐标规则）全部�?[runCanvasAi] 拼进提示词，
/// 用户只需要说人话。暴露坐�?动作给用户填，等于把模型该干的活推给人�?
class CanvasAiButton extends StatefulWidget {
  const CanvasAiButton({super.key, required this.onRun, this.enabled = true});

  /// 执行一次指令。由宿主提供：它持有 [NoteStore]（候选块 + 块文本）�?LLM 客户端�?
  ///
  /// 返回�?Future 完成即视�?这一轮结�?（成功与否由宿主自己弹提示）�?
  final Future<void> Function(String instruction) onRun;

  /// 未配置模型时�?false �?按钮仍可见但不可点（�?整个按钮消失"更好�""?
  /// 用户能看出这里有功能，只是还没配好）�?
  final bool enabled;

  /// 浮层宽度：够放一行中�?+ 「运行」按钮�?
  static const double panelWidth = 320;

  @override
  State<CanvasAiButton> createState() => _CanvasAiButtonState();
}

class _CanvasAiButtonState extends State<CanvasAiButton> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(VoidCallback close) async {
    final String instruction = _controller.text.trim();
    if (instruction.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.onRun(instruction);
    } finally {
      // 宿主可能已经换了页面/移除了本组件；`mounted` 必须判�?
      if (mounted) {
        setState(() => _busy = false);
        _controller.clear();
        close();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPopover(
      panelWidth: CanvasAiButton.panelWidth,
      anchorBuilder: (BuildContext context, VoidCallback toggle, bool isOpen) =>
          FocusRingIconButton(
            tooltip: widget.enabled
                ? 'AI：用一句话让模型调整画布'
                : 'AI 未配置（到「设置 → AI」填写模型）',
            isSelected: isOpen,
            onPressed: widget.enabled ? toggle : null,
            icon: const tabler.Sparkles(
              height: Tokens.iconMd,
              width: Tokens.iconMd,
              strokeWidth: 1.5,
            ),
          ),
      builder: (BuildContext context, VoidCallback close) => Padding(
        padding: const EdgeInsets.all(Tokens.spaceSm),
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .stretch,
          children: <Widget>[
            TextField(
              controller: _controller,
              autofocus: true,
              enabled: !_busy,
              maxLines: 2,
              minLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => unawaited(_submit(close)),
              decoration: const InputDecoration(
                hintText: '例如：把这两块摆到右边并连起来',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Tokens.spaceSm),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _busy ? '正在推理…' : '改动可一次撤销（Ctrl+Z）',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: Tokens.spaceSm),
                FilledButton(
                  onPressed: _busy ? null : () => unawaited(_submit(close)),
                  child: const Text('运行'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
