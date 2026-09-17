import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:provider/provider.dart';

class EditorSvg extends StatelessWidget {
  const EditorSvg({
    super.key,
    this.name,
    this.width,
    this.height,
    this.color,
    this.number,
    this.padding,
  });

  final String? name;
  final double? width;
  final double? height;
  final Color? color;
  final int? number;
  final EdgeInsets? padding;

  /// [sinan 补丁 4] 图标换皮钩子（见 PATCHES.md）。
  ///
  /// 官方图标全部经 [EditorSvg] 渲染（工具栏 / 斜杠菜单 / 图片工具条 /
  /// 色板 …），但对调用方**没有**"换图标"的扩展点。应用侧注册本钩子后，
  /// 返回非 null 的名字改用注册进来的图标（如 Lucide 图标字体），
  /// 未返回的照旧走包内 SVG —— 上游新增图标不会因此坏掉。
  static IconData? Function(String name)? iconOverride;

  final _defaultWidth = 20.0;
  final _defaultHeight = 20.0;

  @override
  Widget build(BuildContext context) {
    final scaleFactor =
        context.read<EditorState?>()?.editorStyle.textScaleFactor ?? 1.0;
    final height = (this.height ?? _defaultHeight) * scaleFactor;
    final width = (this.width ?? _defaultWidth) * scaleFactor;
    return Padding(
      padding: padding ?? const EdgeInsets.all(0),
      child: _buildSvg(
        height,
        width,
      ),
    );
  }

  Widget _buildSvg(
    double height,
    double width,
  ) {
    if (name != null) {
      // [sinan 补丁 4] 应用侧注册了同名字形时优先用它（尺寸沿用官方算出的
      // 值，因此 editorStyle.textScaleFactor 的无障碍缩放仍然生效）。
      final IconData? override = iconOverride?.call(name!);
      if (override != null) {
        return Icon(override, size: height, color: color);
      }
      return SvgPicture.asset(
        'assets/images/$name.svg',
        colorFilter:
            color != null ? ColorFilter.mode(color!, BlendMode.srcIn) : null,
        fit: BoxFit.fill,
        height: height,
        width: width,
        package: 'appflowy_editor',
      );
    } else if (number != null) {
      final numberText =
          '<svg width="200" height="200" xmlns="http://www.w3.org/2000/svg"><text x="30" y="150" fill="black" font-size="160">$number.</text></svg>';
      return SvgPicture.string(
        numberText,
        width: width,
        height: height,
      );
    }
    return Container();
  }
}
