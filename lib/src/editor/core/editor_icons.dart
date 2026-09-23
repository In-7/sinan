/// 编辑器图标：**全部 Tabler**（经 tabler_icons_next 渲染，线稿风格）。
///
/// ## 为什么需要这张表
/// 官方工具栏 / 斜杠菜单 / 图片工具条 / 色板的图标都是**包内 SVG**，名字写死在
/// 各自的 item 里（`SVGIconItemWidget(iconName: 'toolbar/bold')` → `EditorSvg`
/// → `assets/images/toolbar/bold.svg`），对调用方没有"换图标"的扩展点。
/// vendored 侧为此加了一个钩子（`EditorSvg.iconOverride`，见
/// `third_party/appflowy_editor/PATCHES.md` 补丁 4），这里把官方名字逐个映射
/// 到 Tabler 控件 —— 于是编辑器内不再混两种字形语言。
///
/// **未登记的名字返回 null ⇒ 自动回落官方 SVG**。注意这是**防御性**兜底、
/// 不是现状：官方**现有**的图标资源已**全部登记**（editor_icons_test.dart
/// 直接读 `third_party/appflowy_editor/assets/images` 逐项核对，缺一个就红）。
/// 回落只在"上游升级新增了图标、我们还没登记"时生效。
///
/// ## 描边（1.5）
/// Tabler 是 24×24 网格、2px 线稿；我们用 1.5 描边获得更轻盈的观感，与全应用
/// 一致。尺寸沿用官方算出的 height/width（含 textScaleFactor 无障碍缩放）。
library;

import 'dart:ui' as ui;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

/// 官方图标名 → Tabler 控件构造器（height/width/color 由编辑器统一传入）。
typedef EditorIconBuilder = Widget Function({
  double height,
  double width,
  Color? color,
});

const double _editorStroke = 1.5;

/// 用统一描边 + 着色封装任意 Tabler 控件构造器。
Widget _icon(
  Widget Function({
    double? height,
    double? width,
    Color? color,
    double? strokeWidth,
    ui.ColorFilter? colorFilter,
  }) ctor, {
  required double height,
  required double width,
  Color? color,
}) {
  return ctor(
    height: height,
    width: width,
    strokeWidth: _editorStroke,
    colorFilter:
        color == null ? null : ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
  );
}

/// 构造器封装：把 Tabler 控件类（构造器 tearoff）包成 [EditorIconBuilder]。
Widget Function({double height, double width, Color? color}) _eb(
  Widget Function({
    double? height,
    double? width,
    Color? color,
    double? strokeWidth,
    ui.ColorFilter? colorFilter,
  }) ctor,
) =>
    ({double height = 24, double width = 24, Color? color}) =>
        _icon(ctor, height: height, width: width, color: color);

final Map<String, EditorIconBuilder> kEditorIcons = <String, EditorIconBuilder>{
  // ── 顶部工具栏（官方 toolbar/*）────────────────────────────────
  'toolbar/text': _eb(tabler.Typography),
  'toolbar/h1': _eb(tabler.H1),
  'toolbar/h2': _eb(tabler.H2),
  'toolbar/h3': _eb(tabler.H3),
  'toolbar/bold': _eb(tabler.Bold),
  'toolbar/italic': _eb(tabler.Italic),
  'toolbar/underline': _eb(tabler.Underline),
  'toolbar/strikethrough': _eb(tabler.Strikethrough),
  'toolbar/code': _eb(tabler.Code),
  'toolbar/bulleted_list': _eb(tabler.List),
  'toolbar/numbered_list': _eb(tabler.ListNumbers),
  'toolbar/quote': _eb(tabler.Quote),
  'toolbar/left': _eb(tabler.AlignLeft),
  'toolbar/center': _eb(tabler.AlignCenter),
  'toolbar/right': _eb(tabler.AlignRight),
  'toolbar/divider': _eb(tabler.Minus),
  'toolbar/link': _eb(tabler.Link),
  'toolbar/text_color': _eb(tabler.TextColor),
  'toolbar/highlight_color': _eb(tabler.Highlight),
  'toolbar/text_direction_auto': _eb(tabler.ArrowLeftRight),
  'toolbar/text_direction_ltr': _eb(tabler.TextDirectionLtr),
  'toolbar/text_direction_rtl': _eb(tabler.TextDirectionRtl),

  // ── 斜杠菜单（官方 selection_menu/*）──────────────────────────
  'selection_menu/text': _eb(tabler.Typography),
  'selection_menu/h1': _eb(tabler.H1),
  'selection_menu/h2': _eb(tabler.H2),
  'selection_menu/h3': _eb(tabler.H3),
  'selection_menu/bulleted_list': _eb(tabler.List),
  'selection_menu/number': _eb(tabler.ListNumbers),
  'selection_menu/checkbox': _eb(tabler.Checkbox),
  'selection_menu/quote': _eb(tabler.Quote),
  'selection_menu/image': _eb(tabler.Photo),

  // ── 图片工具条（官方 image_toolbar/*）──────────────────────────
  'image_toolbar/align_left': _eb(tabler.AlignLeft),
  'image_toolbar/align_center': _eb(tabler.AlignCenter),
  'image_toolbar/align_right': _eb(tabler.AlignRight),
  'image_toolbar/copy': _eb(tabler.Copy),
  'image_toolbar/delete': _eb(tabler.Trash),
  'image_toolbar/divider': _eb(tabler.Minus),
  'image_toolbar/share': _eb(tabler.Share),

  // ── 无前缀的零散名（色板勾选 / 链接菜单 / 查找替换 / 表格操作）──
  'checkmark': _eb(tabler.Check), // 色板里的"已选"
  // 待办勾选：✓ 改为"方框内带勾"（checkbox），符合"点框内出现对号"的直觉，
  // 且与斜杠菜单的 selection_menu/checkbox 图标统一；uncheck 仍是空心方框。
  'check': _eb(tabler.Checkbox),
  'uncheck': _eb(tabler.Square),
  'clear': _eb(tabler.X),
  'copy': _eb(tabler.Copy),
  'delete': _eb(tabler.Trash),
  'link': _eb(tabler.Link),
  'point': _eb(tabler.Mouse),
  'quote': _eb(tabler.Quote),
  'regex': _eb(tabler.Function),
  'case_sensitive': _eb(tabler.LetterCase),
  'image': _eb(tabler.Photo),
  'reset_text_color': _eb(tabler.Rotate),
  'clear_highlight_color': _eb(tabler.Eraser),
  'upload_image': _eb(tabler.FileUpload),
};

/// 安装到官方渲染层（幂等；启动时调一次即可，见 `main.dart`）。
///
/// 钩子是 `EditorSvg` 的静态字段，注册后**所有**经官方渲染的图标都会先问它：
/// 命中用 Tabler 控件，未命中原样走包内 SVG。
void installEditorIcons() {
  EditorSvg.iconOverride = (String name, {double height = 24, double width = 24, Color? color}) {
    final EditorIconBuilder? b = kEditorIcons[name];
    return b?.call(height: height, width: width, color: color);
  };
}
