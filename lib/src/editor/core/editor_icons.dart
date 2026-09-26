/// 编辑器图标：**全部 Tabler**（经 tabler_icons_next 渲染，线稿风格）。
///
/// ## 为什么需要这张表
/// 官方工具栏 / 斜杠菜单 / 图片工具条 / 色板的图标都是**包内 SVG**，名字写死在
/// 各自的 item 里（`SVGIconItemWidget(iconName: 'toolbar/bold')` → `EditorSvg`
/// → `assets/images/toolbar/bold.svg`），对调用方没有"换图标"的扩展点。
///
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

import '../../theme/tokens.dart';

/// 官方图标名 → Tabler 控件构造器（height/width/color 由编辑器统一传入）。
typedef EditorIconBuilder = Widget Function({
  double height,
  double width,
  Color? color,
});

/// tabler 符号类构造器的**结构类型**：只声明我们会用到的具名参数。
///
/// 取值方式为具名构造器 tear-off（如 `tabler.Typography`）——它自身还有
/// `key`/`fit`/`theme` 等参数，函数子类型允许目标只要求一个子集。
typedef _TablerCtor = Widget Function({
  double? height,
  double? width,
  double? strokeWidth,
  ui.ColorFilter? colorFilter,
});

/// 把 tabler 构造器包装成 [EditorIconBuilder]，统一注入描边与着色。
///
/// 之所以不在表里逐条写闭包：53 条各写一遍 `({double height = 24, ...})`
/// 纯属噪音，且容易漏参；这里一次性定型，表里只留 `_b(tabler.Xxx.new)`。
/// 描边统一取 [Tokens.iconStroke]（与 `AppIconTheme` 下发的是同一个值）。
EditorIconBuilder _b(_TablerCtor ctor) =>
    ({double height = 24, double width = 24, Color? color}) => ctor(
      height: height,
      width: width,
      // ⚠️ 描边要**按框反算**：[Tokens.iconStroke] 的数值长在 24 画板坐标系里，
      // 而编辑器这里的框是 18（工具条）或 18 × textScaleFactor。反算 ⇒ 一律实得
      // 1.5px —— 因为工具条里我们的图标与**官方包内 SVG 并排**（后者是 24 画板
      // 2px 描边、缩到 18 就是 1.5px），不跟齐就会一边粗一边细。
      strokeWidth: Tokens.iconStroke * 24 / height,
      colorFilter: color == null
          ? null
          : ui.ColorFilter.mode(color, ui.BlendMode.srcIn),
    );

/// 表用 `final` 而非 `const`：值是闭包，不是编译期常量。
final Map<String, EditorIconBuilder> kEditorIcons = <String, EditorIconBuilder>{
  // ── 顶部工具栏（官方 toolbar/*）────────────────────────────────
  'toolbar/text': _b(tabler.Typography.new),
  'toolbar/h1': _b(tabler.H1.new),
  'toolbar/h2': _b(tabler.H2.new),
  'toolbar/h3': _b(tabler.H3.new),
  'toolbar/bold': _b(tabler.Bold.new),
  'toolbar/italic': _b(tabler.Italic.new),
  'toolbar/underline': _b(tabler.Underline.new),
  'toolbar/strikethrough': _b(tabler.Strikethrough.new),
  'toolbar/code': _b(tabler.Code.new),
  'toolbar/bulleted_list': _b(tabler.List.new),
  'toolbar/numbered_list': _b(tabler.ListNumbers.new),
  'toolbar/quote': _b(tabler.Quote.new),
  'toolbar/left': _b(tabler.AlignLeft.new),
  'toolbar/center': _b(tabler.AlignCenter.new),
  'toolbar/right': _b(tabler.AlignRight.new),
  'toolbar/divider': _b(tabler.Minus.new),
  'toolbar/link': _b(tabler.Link.new),
  'toolbar/text_color': _b(tabler.TextColor.new),
  'toolbar/highlight_color': _b(tabler.Highlight.new),
  'toolbar/text_direction_auto': _b(tabler.ArrowLeftRight.new),
  'toolbar/text_direction_ltr': _b(tabler.TextDirectionLtr.new),
  'toolbar/text_direction_rtl': _b(tabler.TextDirectionRtl.new),

  // ── 斜杠菜单（官方 selection_menu/*）──────────────────────────
  'selection_menu/text': _b(tabler.Typography.new),
  'selection_menu/h1': _b(tabler.H1.new),
  'selection_menu/h2': _b(tabler.H2.new),
  'selection_menu/h3': _b(tabler.H3.new),
  'selection_menu/bulleted_list': _b(tabler.List.new),
  'selection_menu/number': _b(tabler.ListNumbers.new),
  'selection_menu/checkbox': _b(tabler.Checkbox.new),
  'selection_menu/quote': _b(tabler.Quote.new),
  'selection_menu/image': _b(tabler.Photo.new),

  // ── 图片工具条（官方 image_toolbar/*）──────────────────────────
  'image_toolbar/align_left': _b(tabler.AlignLeft.new),
  'image_toolbar/align_center': _b(tabler.AlignCenter.new),
  'image_toolbar/align_right': _b(tabler.AlignRight.new),
  'image_toolbar/copy': _b(tabler.Copy.new),
  'image_toolbar/delete': _b(tabler.Trash.new),
  'image_toolbar/divider': _b(tabler.Minus.new),
  'image_toolbar/share': _b(tabler.Share.new),

  // ── 无前缀的零散名（色板勾选 / 链接菜单 / 查找替换 / 表格操作）──
  'checkmark': _b(tabler.Check.new),
  // 待办勾选：✓ 改为"方框内带勾"（checkbox），符合"点框内出现对号"的直觉，
  // 且与斜杠菜单的 selection_menu/checkbox 图标统一；uncheck 仍是空心方框。
  'check': _b(tabler.Checkbox.new),
  'uncheck': _b(tabler.Square.new),
  'clear': _b(tabler.X.new),
  'copy': _b(tabler.Copy.new),
  'delete': _b(tabler.Trash.new),
  'link': _b(tabler.Link.new),
  'point': _b(tabler.Mouse.new),
  'quote': _b(tabler.Quote.new),
  'regex': _b(tabler.$Function.new),
  'case_sensitive': _b(tabler.LetterCase.new),
  'image': _b(tabler.Photo.new),
  'reset_text_color': _b(tabler.Rotate.new),
  'clear_highlight_color': _b(tabler.Eraser.new),
  'upload_image': _b(tabler.FileUpload.new),
};

/// 安装到官方渲染层（幂等；启动时调一次即可，见 `main.dart`）。
///
/// 钩子是 `EditorSvg` 的静态字段，注册后**所有**经官方渲染的图标都会先问它：
/// 命中用 Tabler 控件，未命中原样走包内 SVG。
void installEditorIcons() {
  EditorSvg.iconOverride =
      (String name, {double height = 24, double width = 24, Color? color}) {
        final EditorIconBuilder? b = kEditorIcons[name];
        return b?.call(height: height, width: width, color: color);
      };
}
