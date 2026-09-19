/// 设计地基：尺寸、间距、圆角、时长的唯一来源。
///
/// UI 代码里不要出现裸数字，一律从这里取。
/// Tokens 只描述几何，不描述颜色——换主题不影响它。
class Tokens {
  const Tokens._();

  // 间距
  static const double spaceXxs = 2;
  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 12;
  static const double spaceLg = 16;
  static const double spaceXl = 24;

  // 圆角
  static const double radiusSm = 6;
  static const double radiusMd = 10;
  static const double radiusLg = 14;

  // 控件尺寸
  // 标题栏高度 == 窗口按钮高度，二者始终相等（按钮永远铺满，无留白）。
  //
  // window_manager 的 WindowCaptionButton 内部是
  // Container(constraints: minWidth 46 / minHeight 32) + Center：
  // minHeight 只是「下限」而非固定高度，Center 在 Row（默认
  // crossAxisAlignment.center）的松约束下会 expand 到父容器最大高度，
  // 所以按钮跟着标题栏一起伸缩，悬浮背景始终与标题栏等高。
  //
  // 因此本值即按钮高度与点击热区：
  //   - 32：与 Win11 原生标题栏一致，最紧凑（当前选择）
  //   - 36：更宽松，热区更大
  // 不宜低于 32：低于时按钮被 minHeight 顶到 32，会溢出容器。
  static const double titleBarHeight = 32;

  // 图标
  // 工具栏功能图标：18 在 32×32 热区里视觉更饱满
  // （16 偏瘦）。编辑器工具栏（fixed_toolbar）与应用各处图标用。
  static const double iconSm = 18;
  static const double iconMd = 20;

  // 画布工具条按钮（Material IconButton 的热区）：32×32 正方、18px 图标
  // （[iconSm]）四周各余 7px。此前裸用 M3 默认（40×40 布局 + 48 padded 热区），
  // 按钮顶出工具条卡片边缘（2026-09-19 用户实测反馈）。与标题栏按钮同档 32。
  static const double toolbarButtonSize = 32;

  // 字号
  static const double fontSizeSm = 12;
  static const double fontSizeMd = 14;

  // 笔记列表条目（自绘 _NoteTile，单行标题）
  static const double noteTileHeight = 32;
  // 格式工具栏按钮（自绘 NoteFormatToolbar）
  // 工具栏按钮：24×30，18px 图标四周各有 3px/6px 呼吸，
  // 悬浮高亮不贴字形，热区也稳。
  static const double formatButtonWidth = 24;
  static const double formatButtonHeight = 30;
  // 选中项左侧的强调色指示条
  static const double indicatorWidth = 3;

  // 笔记标题行右侧的「文档工具耳」（搜索 / 目录）：热区 30。
  // 图标 18（[iconSm]，与工具栏同档）在 30 里上下各余 6px —— 比原来的
  // 26/16 更有"按钮"体量，也刚好够到最小可点目标。
  //
  // ⚠️ 改这个值要**连标题行里双耳的上内边距一起重算**：
  //   图标字形顶 = 上内边距 +（本值 − 图标）/2，目标是与标题字形顶齐平
  //   （见 `note_editor_view_appflowy.dart` 标题行处的校准公式）。
  static const double headerActionSize = 30;

  // 动效
  static const Duration durationFast = Duration(milliseconds: 120);
  static const Duration durationNormal = Duration(milliseconds: 200);
}
