import 'dart:io';
import 'dart:ui' as ui;
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'attachment_meta.dart';

// 附件卡片与"打开附件"：quill 的 EmbedBuilder 与 appflowy 的块组件共用
// （同 AttachmentMeta、formula_render.dart 的抽取动机——迁移期两份实现
// 必然漂移）。

/// 用系统默认程序打开附件（Windows explorer；其他平台后续补）。
Future<void> openAttachment(String path) async {
  if (!Platform.isWindows) return;
  try {
    await Process.run('explorer.exe', <String>[path]);
  } on Object catch (_) {
    // 打开失败静默（无默认程序的类型等）。
  }
}

/// 附件卡片：图标 + 文件名 + 大小，整体可点打开。
class AttachmentCard extends StatelessWidget {
  const AttachmentCard({
    super.key,
    required this.meta,
    required this.onOpen,
  });

  final AttachmentMeta meta;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Brightness brightness = Theme.of(context).brightness;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(Tokens.radiusSm),
          onTap: onOpen,
          child: Container(
            width: 320,
            padding: const EdgeInsets.symmetric(
              horizontal: Tokens.spaceMd,
              vertical: Tokens.spaceSm,
            ),
            decoration: BoxDecoration(
              color: AppTheme.editorCodeBlockBg(brightness),
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
              border: Border.all(
                color: scheme.outlineVariant.withValues(
                  alpha: brightness == Brightness.dark ? 0.5 : 0.8,
                ),
              ),
            ),
            child: Row(
              children: <Widget>[
                tabler.FileText(height: Tokens.iconSm, width: Tokens.iconSm, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(scheme.onSurfaceVariant, ui.BlendMode.srcIn)),
                const SizedBox(width: Tokens.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        meta.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurface,
                        ),
                      ),
                      Text(
                        meta.sizeLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                tabler.ExternalLink(height: 14, width: 14, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(scheme.onSurfaceVariant, ui.BlendMode.srcIn)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
