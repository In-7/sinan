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
  // Apple 口径（`docs/ui_rewrite_plan.md` §9.2）：三档跨度收敛为 **6 / 8 / 12**。
  // 控件档（6）本就与 macOS 同档、未动；改的是"大档过圆"——原 14 让菜单与面板
  // 比 macOS 的 popover（10–12）更圆。
  // ⚠️ 浮层族（菜单 / 气泡 / 工具条 / 斜杠菜单 / 面板）**共用 radiusLg**，不按
  // Apple 的菜单档（6–8）单独分——族内语法一致优先（§2.3）。
  static const double radiusSm = 6;
  static const double radiusMd = 8;
  static const double radiusLg = 12;

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
  // Apple 口径（§9.2）：桌面正文 **13**、辅助 **11**——M3 的 14/12 是移动端尺度。
  static const double fontSizeSm = 11;
  static const double fontSizeMd = 13;

  // 笔记列表条目（自绘 _NoteTile，单行标题）
  // Apple 口径（§9.2）：macOS 侧栏行为 24–28；32 是 M3 触控档，一屏少放两三条。
  // ⚠️ 这是本表里**最该用眼睛确认**的一个值（它决定列表的"手感密度"），
  // 觉得挤就调回 30/32——只动这一个数，不牵动别处。
  static const double noteTileHeight = 28;
  // 格式工具栏按钮（自绘 NoteFormatToolbar）
  // 工具栏按钮：24×30，18px 图标四周各有 3px/6px 呼吸，
  // 悬浮高亮不贴字形，热区也稳。
  static const double formatButtonWidth = 24;
  static const double formatButtonHeight = 30;
  // 选中项左侧的强调色指示条
  static const double indicatorWidth = 3;

  // 焦点环粗细（`docs/ui_rewrite_plan.md` §5.2）。
  // ⚠️ 计划原文是"primary 2px + 1px offset（外间隙）"，实现取**画在边界内侧**：
  // 向外画要多占 3px 布局（要么内容位移、要么被父容器裁剪切掉），而 1px 的外间隙
  // 在 32px 图标按钮 / 28px 列表行上视觉收益极小。这是实现期修正，理由在
  // `theme/focus_ring.dart`。
  static const double focusRingWidth = 2;

  // 浮层描边的**发丝宽度**（`AppTheme.menuBorder` 消费）。
  // 1px 在近黑底上存在感偏强——用户 2026-09-22 实机反馈"边框线再细一点"。
  // 做法是**亚像素宽度**（抗锯齿把线自然减淡、且四边均匀），而**不是降颜色对比度**：
  // 细线恰恰需要更高对比度来补偿（空间对比敏感度，见 `apca.dart`），
  // 把 Lc 22 调低会同时撞上"最低可见线"（Lc 15）。
  static const double hairlineWidth = 0.5;

  // 笔记标题行右侧的「文档工具耳」（搜索 / 目录）：热区 30。
  // 图标 18（[iconSm]，与工具栏同档）在 30 里上下各余 6px —— 比原来的
  // 26/16 更有"按钮"体量，也刚好够到最小可点目标。
  //
  // ⚠️ 改这个值要**连标题行里双耳的上内边距一起重算**：
  //   图标字形顶 = 上内边距 +（本值 − 图标）/2，目标是与标题字形顶齐平
  //   （见 `note_editor_view_appflowy.dart` 标题行处的校准公式）。
  static const double headerActionSize = 30;

  // 动效
  // Apple 口径（§9.2）：比 M3 略长、收尾更缓——"精致"有一半在节奏。
  static const Duration durationFast = Duration(milliseconds: 150);
  static const Duration durationNormal = Duration(milliseconds: 250);
}
