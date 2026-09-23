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
/// 不是现状：官方**现有**的图标资源已**全部登记**（`editor_icons_test.dart`
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

Widget _mk({
  required Widget Function({double? height, double? width, Color? color, double? strokeWidth})
      ctor,
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

const Map<String, EditorIconBuilder> kEditorIcons = <String, EditorIconBuilder>{
  // ── 顶部工具栏（官方 toolbar/*）────────────────────────────────
  'toolbar/text': (h, w, c) => _mk(ctor: tabler.Typography, height: h, width: w, color: c),
  'toolbar/h1': (h, w, c) => _mk(ctor: tabler.H1, height: h, width: w, color: c),
  'toolbar/h2': (h, w, c) => _mk(ctor: tabler.H2, height: h, width: w, color: c),
  'toolbar/h3': (h, w, c) => _mk(ctor: tabler.H3, height: h, width: w, color: c),
  'toolbar/bold': (h, w, c) => _mk(ctor: tabler.Bold, height: h, width: w, color: c),
  'toolbar/italic': (h, w, c) => _mk(ctor: tabler.Italic, height: h, width: w, color: c),
  'toolbar/underline': (h, w, c) =>
      _mk(ctor: tabler.Underline, height: h, width: w, color: c),
  'toolbar/strikethrough': (h, w, c) =>
      _mk(ctor: tabler.Strikethrough, height: h, width: w, color: c),
  'toolbar/code': (h, w, c) => _mk(ctor: tabler.Code, height: h, width: w, color: c),
  'toolbar/bulleted_list': (h, w, c) =>
      _mk(ctor: tabler.List, height: h, width: w, color: c),
  'toolbar/numbered_list': (h, w, c) =>
      _mk(ctor: tabler.ListNumbers, height: h, width: w, color: c),
  'toolbar/quote': (h, w, c) => _mk(ctor: tabler.Quote, height: h, width: w, color: c),
  'toolbar/left': (h, w, c) =>
      _mk(ctor: tabler.AlignLeft, height: h, width: w, color: c),
  'toolbar/center': (h, w, c) =>
      _mk(ctor: tabler.AlignCenter, height: h, width: w, color: c),
  'toolbar/right': (h, w, c) =>
      _mk(ctor: tabler.AlignRight, height: h, width: w, color: c),
  'toolbar/divider': (h, w, c) => _mk(ctor: tabler.Minus, height: h, width: w, color: c),
  'toolbar/link': (h, w, c) => _mk(ctor: tabler.Link, height: h, width: w, color: c),
  'toolbar/text_color': (h, w, c) =>
      _mk(ctor: tabler.TextColor, height: h, width: w, color: c),
  'toolbar/highlight_color': (h, w, c) =>
      _mk(ctor: tabler.Highlight, height: h, width: w, color: c),
  'toolbar/text_direction_auto': (h, w, c) =>
      _mk(ctor: tabler.ArrowLeftRight, height: h, width: w, color: c),
  'toolbar/text_direction_ltr': (h, w, c) =>
      _mk(ctor: tabler.TextDirectionLtr, height: h, width: w, color: c),
  'toolbar/text_direction_rtl': (h, w, c) =>
      _mk(ctor: tabler.TextDirectionRtl, height: h, width: w, color: c),

  // ── 斜杠菜单（官方 selection_menu/*）──────────────────────────
  'selection_menu/text': (h, w, c) =>
      _mk(ctor: tabler.Typography, height: h, width: w, color: c),
  'selection_menu/h1': (h, w, c) => _mk(ctor: tabler.H1, height: h, width: w, color: c),
  'selection_menu/h2': (h, w, c) => _mk(ctor: tabler.H2, height: h, width: w, color: c),
  'selection_menu/h3': (h, w, c) => _mk(ctor: tabler.H3, height: h, width: w, color: c),
  'selection_menu/bulleted_list': (h, w, c) =>
      _mk(ctor: tabler.List, height: h, width: w, color: c),
  'selection_menu/number': (h, w, c) =>
      _mk(ctor: tabler.ListNumbers, height: h, width: w, color: c),
  'selection_menu/checkbox': (h, w, c) =>
      _mk(ctor: tabler.Checkbox, height: h, width: w, color: c),
  'selection_menu/quote': (h, w, c) =>
      _mk(ctor: tabler.Quote, height: h, width: w, color: c),
  'selection_menu/image': (h, w, c) =>
      _mk(ctor: tabler.Photo, height: h, width: w, color: c),

  // ── 图片工具条（官方 image_toolbar/*）──────────────────────────
  'image_toolbar/align_left': (h, w, c) =>
      _mk(ctor: tabler.AlignLeft, height: h, width: w, color: c),
  'image_toolbar/align_center': (h, w, c) =>
      _mk(ctor: tabler.AlignCenter, height: h, width: w, color: c),
  'image_toolbar/align_right': (h, w, c) =>
      _mk(ctor: tabler.AlignRight, height: h, width: w, color: c),
  'image_toolbar/copy': (h, w, c) => _mk(ctor: tabler.Copy, height: h, width: w, color: c),
  'image_toolbar/delete': (h, w, c) =>
      _mk(ctor: tabler.Trash, height: h, width: w, color: c),
  'image_toolbar/divider': (h, w, c) =>
      _mk(ctor: tabler.Minus, height: h, width: w, color: c),
  'image_toolbar/share': (h, w, c) =>
      _mk(ctor: tabler.Share, height: h, width: w, color: c),

  // ── 无前缀的零散名（色板勾选 / 链接菜单 / 查找替换 / 表格操作）──
  'checkmark': (h, w, c) => _mk(ctor: tabler.Check, height: h, width: w, color: c),
  // 待办勾选：✓ 改为"方框内带勾"（checkbox），符合"点框内出现对号"的直觉，
  // 且与斜杠菜单的 selection_menu/checkbox 图标统一；uncheck 仍是空心方框。
  'check': (h, w, c) => _mk(ctor: tabler.Checkbox, height: h, width: w, color: c),
  'uncheck': (h, w, c) => _mk(ctor: tabler.Square, height: h, width: w, color: c),
  'clear': (h, w, c) => _mk(ctor: tabler.X, height: h, width: w, color: c),
  'copy': (h, w, c) => _mk(ctor: tabler.Copy, height: h, width: w, color: c),
  'delete': (h, w, c) => _mk(ctor: tabler.Trash, height: h, width: w, color: c),
  'link': (h, w, c) => _mk(ctor: tabler.Link, height: h, width: w, color: c),
  'point': (h, w, c) => _mk(ctor: tabler.Mouse, height: h, width: w, color: c),
  'quote': (h, w, c) => _mk(ctor: tabler.Quote, height: h, width: w, color: c),
  'regex': (h, w, c) => _mk(ctor: tabler.$Function, height: h, width: w, color: c),
  'case_sensitive': (h, w, c) =>
      _mk(ctor: tabler.LetterCase, height: h, width: w, color: c),
  'image': (h, w, c) => _mk(ctor: tabler.Photo, height: h, width: w, color: c),
  'reset_text_color': (h, w, c) =>
      _mk(ctor: tabler.Rotate, height: h, width: w, color: c),
  'clear_highlight_color': (h, w, c) =>
      _mk(ctor: tabler.Eraser, height: h, width: w, color: c),
  'upload_image': (h, w, c) =>
      _mk(ctor: tabler.FileUpload, height: h, width: w, color: c),
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
