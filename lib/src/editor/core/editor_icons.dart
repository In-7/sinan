/// 编辑器图标：**全部 Lucide**（含"官方 SVG 图标"的换皮映射）。
///
/// ## 为什么需要这张表
/// 官方工具栏 / 斜杠菜单 / 图片工具条 / 色板的图标都是**包内 SVG**，
/// 名字写死在各自的 item 里（`SVGIconItemWidget(iconName: 'toolbar/bold')`
/// → `EditorSvg` → `assets/images/toolbar/bold.svg`），对调用方没有"换图标"
/// 的扩展点。vendored 侧为此加了一个钩子（`EditorSvg.iconOverride`，见
/// `third_party/appflowy_editor/PATCHES.md` 补丁 4），这里把官方名字逐个映射
/// 到 Lucide 字形 —— 于是编辑器内不再混两种字形语言。
///
/// **未登记的名字返回 null ⇒ 自动回落官方 SVG**。注意这是**防御性**兜底、
/// 不是现状：官方**现有**的图标资源已**全部登记**（`editor_icons_test.dart`
/// 直接读 `third_party/appflowy_editor/assets/images` 逐项核对，缺一个就红）。
/// 回落只在"上游升级新增了图标、我们还没登记"时生效——那一刻图标会暂时退回
/// 官方 SVG（观感上就是混排），但不会崩。
///
/// ## 描边粗细
/// Lucide 的粗细是**字体族级别**的（`<名>100` ~ `<名>600`，数字越大越粗，
/// 名字是编译期常量、不能拼字符串）：
///
/// | 档位 | 24 网格描边 | 18px 下等效 | 观感 |
/// |---|---|---|---|
/// | `100` | 0.5px | ≈0.375px | 基本看不见（不可用） |
/// | `200` | 1.0px | ≈0.75px | 太轻（1x 屏上偏"虚"） |
/// | **`300`** | **1.55px** | **≈1.16px** | **当前选择：最接近传统图标观感** |
/// | `400`/无后缀 | 2.0px | ≈1.5px | Lucide 默认（改版前的观感） |
/// | `500` | 2.5px | ≈1.9px | 明显偏粗 |
/// | `600` | 3.0px | ≈2.25px | 近"实心描边" |
///
/// 数值来源：包内各变体**内嵌 SVG 的 `stroke-width`**（`Lucide100` .5 /
/// `200` 1.0 / `300` 1.55 / `400` 2.0 / `500` 2.5 / `600` 3.0），不是估算。
/// 18px 列 = 24 网格值 × 18/24——图标按字号整体缩放，描边跟着缩放。
///
/// ⚠️ 粗细**没有运行时开关**：它是字体族级别的东西（每个档位一个 ttf），且
/// 图标名是编译期常量（不能 `'x$weight'` 拼字符串），`Icon` 也没有
/// `strokeWidth` 参数（每个族只装一个面，改 `fontWeight` 也无效）。
/// **换档 = 改两处**：下面这张映射表，以及应用里直接写 `LucideIcons.…300` 的
/// 地方（工具栏 / 斜杠菜单 / 附件卡等）。做法：对 `LucideIcons\.(\w+?)300\b`
/// 做锚定替换（`heading1` / `trash2` 这类**名字里本来带数字**的不会误伤，
/// 因为档位后缀永远紧跟在完整名字之后）。
library;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 官方图标名 → Lucide 字形（名字里的 `300` 是描边档位，见文件头说明）。
///
/// 键就是官方传给 `EditorSvg` 的 `name`（含 `toolbar/` `selection_menu/`
/// `image_toolbar/` 前缀；色板/链接菜单那批是**无前缀**的零散名）。
const Map<String, IconData> kLucideEditorIcons = <String, IconData>{
  // ── 顶部工具栏（官方 toolbar/*）────────────────────────────────
  'toolbar/text': LucideIcons.type300, // 正文
  'toolbar/h1': LucideIcons.heading1300,
  'toolbar/h2': LucideIcons.heading2300,
  'toolbar/h3': LucideIcons.heading3300,
  'toolbar/bold': LucideIcons.bold300,
  'toolbar/italic': LucideIcons.italic300,
  'toolbar/underline': LucideIcons.underline300,
  'toolbar/strikethrough': LucideIcons.strikethrough300,
  // 行内代码（代码块条目是我们自研的，用的是 squareCode）。
  'toolbar/code': LucideIcons.code300,
  'toolbar/bulleted_list': LucideIcons.list300,
  'toolbar/numbered_list': LucideIcons.listOrdered300,
  'toolbar/quote': LucideIcons.quote300,
  'toolbar/left': LucideIcons.alignLeft300,
  'toolbar/center': LucideIcons.alignCenter300,
  'toolbar/right': LucideIcons.alignRight300,
  'toolbar/divider': LucideIcons.minus300,
  'toolbar/link': LucideIcons.link300,
  'toolbar/text_color': LucideIcons.baseline300,
  'toolbar/highlight_color': LucideIcons.highlighter300,
  'toolbar/text_direction_auto': LucideIcons.arrowLeftRight300,
  'toolbar/text_direction_ltr': LucideIcons.arrowLeftToLine300,
  'toolbar/text_direction_rtl': LucideIcons.arrowRightToLine300,

  // ── 斜杠菜单（官方 selection_menu/*）──────────────────────────
  'selection_menu/text': LucideIcons.type300,
  'selection_menu/h1': LucideIcons.heading1300,
  'selection_menu/h2': LucideIcons.heading2300,
  'selection_menu/h3': LucideIcons.heading3300,
  'selection_menu/bulleted_list': LucideIcons.list300,
  'selection_menu/number': LucideIcons.listOrdered300,
  'selection_menu/checkbox': LucideIcons.squareCheck300,
  'selection_menu/quote': LucideIcons.quote300,
  'selection_menu/image': LucideIcons.image300,

  // ── 图片工具条（官方 image_toolbar/*）──────────────────────────
  'image_toolbar/align_left': LucideIcons.alignLeft300,
  'image_toolbar/align_center': LucideIcons.alignCenter300,
  'image_toolbar/align_right': LucideIcons.alignRight300,
  'image_toolbar/copy': LucideIcons.copy300,
  'image_toolbar/delete': LucideIcons.trash2300,
  'image_toolbar/divider': LucideIcons.minus300,
  'image_toolbar/share': LucideIcons.share300,

  // ── 无前缀的零散名（色板勾选 / 链接菜单 / 查找替换 / 表格操作）──
  'checkmark': LucideIcons.check300, // 色板里的"已选"
  // 待办勾选：✓ 改为"方框内带勾"（squareCheck），符合"点框内出现对号"的直觉，
  // 且与斜杠菜单的 selection_menu/checkbox 图标统一；uncheck 仍是空心方框。
  'check': LucideIcons.squareCheck300,
  'uncheck': LucideIcons.square300,
  'clear': LucideIcons.x300,
  'copy': LucideIcons.copy300,
  'delete': LucideIcons.trash2300,
  'link': LucideIcons.link300,
  'point': LucideIcons.mousePointer300,
  'quote': LucideIcons.quote300,
  'regex': LucideIcons.regex300,
  'case_sensitive': LucideIcons.caseSensitive300,
  'image': LucideIcons.image300,
  'reset_text_color': LucideIcons.removeFormatting300,
  'clear_highlight_color': LucideIcons.eraser300,
  'upload_image': LucideIcons.imageUp300,
};

/// 安装到官方渲染层（幂等；启动时调一次即可，见 `main.dart`）。
///
/// 钩子是 `EditorSvg` 的静态字段，注册后**所有**经官方渲染的图标都会先问它：
/// 命中用 Lucide，未命中原样走包内 SVG。
void installLucideEditorIcons() {
  EditorSvg.iconOverride = (String name) => kLucideEditorIcons[name];
}
