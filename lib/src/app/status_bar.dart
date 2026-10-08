import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'providers.dart' show notesProvider;

/// **状态栏**（阶段 2，2026-10-06）：桌面骨架的最后一块——26px，贴窗底。
///
/// 只放"状态"不放"动作"：
/// - 左：库规模（`notesProvider` 快照 length）；AI 索引进度（IndexProgress
///   有流）到位后接在第二位；
/// - 右：键位提示——快捷键的**发现入口**（`docs/ui_rewrite_plan.md` §3.5：
///   不提示就没人知道 Ctrl+K 存在）。
///
/// 底色 = [AppTheme.railFill]（阶段 0 的"侧轨"档：凹进窗体的列），与窗体之间
/// 只隔一道发丝线——它是"窗体的一部分"，不是又一块浮起的板子。
class StatusBar extends ConsumerWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final int count = ref.watch(notesProvider).value?.length ?? 0;
    final TextStyle style =
        (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
      color: scheme.onSurfaceVariant,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.railFill(theme.brightness),
        border: Border(top: AppTheme.menuBorder(scheme)),
      ),
      child: SizedBox(
        height: 26,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceMd),
          child: Row(
            children: <Widget>[
              Text('$count 篇笔记', style: style),
              const Spacer(),
              Text('Ctrl+K 快速跳转 · Ctrl+Shift+P 命令', style: style),
            ],
          ),
        ),
      ),
    );
  }
}
