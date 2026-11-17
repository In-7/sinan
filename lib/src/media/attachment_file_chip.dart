import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'open_file_externally.dart';

/// 附件**文件片**（视频 Tier 0，2026-11-17）：图标 + 标签，**双击**交给系统
/// 默认程序打开（视频 ⇒ 系统播放器）。
///
/// 为什么不做内置播放器：视频在灵感收件箱是低频输入（flomo 同定位产品也只
/// 有文字 + 图），低频需求配低成本——系统播放器的编解码覆盖反而更好。将来要
/// 应用内播放（笔记 / 画布复用本组件），只换这里的双击行为，调用方不动。
class AttachmentFileChip extends StatelessWidget {
  const AttachmentFileChip({
    super.key,
    required this.path,
    required this.label,
    this.size = 96,
  });

  /// app 私有目录里那份独立副本的绝对路径。
  final String path;

  /// 片上显示的标签（如 `MP4`）——落库文件名是 uuid，真名没存，别拿它当标题。
  final String label;

  /// 边长（与图片缩略图同高并排：96）。
  final double size;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Brightness b = theme.brightness;
    return Semantics(
      button: true,
      label: '$label 视频，双击用系统播放器打开',
      child: Tooltip(
        message: '双击用系统播放器打开',
        child: GestureDetector(
          onDoubleTap: () => unawaited(openFileExternally(path)),
          child: Container(
            width: size,
            height: size,
            padding: const EdgeInsets.all(Tokens.spaceXs),
            decoration: BoxDecoration(
              color: Bauhaus.surface(b),
              borderRadius: BorderRadius.circular(Tokens.radiusSm),
              border: Bauhaus.hairline(b),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                tabler.Video(
                  height: Tokens.iconMd,
                  width: Tokens.iconMd,
                  color: Bauhaus.inkMuted(b),
                ),
                const SizedBox(height: Tokens.spaceXxs),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Bauhaus.inkMuted(b),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
