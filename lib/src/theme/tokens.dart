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

  /// Things 式页首呼吸（§5.6 2026-09-24）：页大标题上方的留白档。
  /// 与 [spaceXl] 的区别：它是"一页纸"的段落呼吸，不是控件间距。
  static const double spaceXxl = 48;

  // ── 布局网格：瑞士隐形 8pt 网格（2026-10-13）──────────────────
  // 界面**不画网格线**：秩序来自每个区域 / 元素对齐到这套常数 + 留白表达。
  // 与 [Bauhaus]（固定色板 / 4px 硬边 / 边框粗细分层）**互补**——Bauhaus 定"材质"，
  // 这层定"度量"；层次靠 对齐 + 留白 + Bauhaus 边框，**不靠投影 / 色差**
  // （Bauhaus 全站零投影）。此前布局尺寸是一批互不对齐的散点（侧栏 280 /
  // AI 轨 340 / 卡片距 20…），这一层把它们收编到同一个 8pt 基数上。
  /// 网格基数（8pt）：区块尺寸 / 区块间距一律取它的整数倍；控件内微调
  /// （4px 硬边、半格呼吸）可用它的 1/2（= [spaceXs] 4）与 1/4（[spaceXxs] 2）。
  static const double gridBaseline = 8;

  /// 区块间距（gutter）：区域之间 / 网格列距。24（大留白档 = [spaceXl]）。
  static const double gridGutter = 24;

  /// 内容区左右安全边距（margin）：正文 / 网格列离容器缘的距离。24。
  static const double gridMargin = 24;

  /// 宽屏内容边距（留白更舒展一档）。48。
  static const double gridMarginWide = 48;

  /// 内容区结构列数。列宽**运行时**按容器宽与 [gridGutter] 分摊，token 只定列数。
  static const int gridColumns = 12;

  /// 阅读 / 单栏内容的一个基准上限 = 90×8。⚠️ 主页 / 编辑器的实际内容宽**不写死
  /// 这里**，而是跟随 `AppSettings.contentWidth`（EditorWidthMode 三档
  /// narrow 728 / standard 800 / wide 1008）——2026-10-13 起主页卡片区也用同一
  /// settings 限宽、水平居中。此 token 仅作不随设置变的固定上限基准。
  static const double contentMaxWidth = 720;

  // 圆角
  // 比例分级（2026-10-16 用户定）：圆角随元素尺寸 / 层级走，不再全局一个数。
  // - 控件档（按钮 / 单行输入 / chip / 列表行 / 焦点环）：**10px**
  // - 卡片档（笔记卡 / 内面板 / 日历卡）：**12px**
  // - 浮层+创作条档（菜单 / 对话框 / popover / sheet / 心流 Composer / 新建胶囊浮层）：**16px**
  // 10 在 32px 小控件上比例最稳；16 落在 iOS sheet / M3 dialog 甜区上沿，浮起更柔。
  static const double radiusSm = 10;
  static const double radiusMd = 12;
  static const double radiusLg = 16;

  /// 按钮圆角：控件档（**10px**），与 [radiusSm] 同值。
  static const double radiusButton = 10;

  /// 全圆（胶囊按钮 / 圆点 / 圆形发送钮）。
  static const double radiusFull = 999;

  // 控件尺寸
  // 主区顶条高度 == 窗控按钮高度，二者始终相等（按钮永远铺满，无留白）。
  //
  // window_manager 的 WindowCaptionButton 内部是
  // Container(constraints: minWidth 46 / minHeight 32) + Center：
  // minHeight 只是「下限」而非固定高度，Center 在 Row（默认
  // crossAxisAlignment.center）的松约束下会 expand 到父容器最大高度，
  // 所以按钮跟着标题栏一起伸缩，悬浮背景始终与标题栏等高。
  //
  // 因此 [titleBarHeightMain] 即条高（窗控按钮在 Row 里垂直居中跟着伸缩）：
  // 2026-10-13 用户定 **32**——恰好等于 [window_manager] `WindowCaptionButton`
  // 的 `minHeight: 32` 下限，且 [chromeActionButton] 的方块也是
  // [Tokens.chromeButtonSize]=32：窗控 + 导航都满格、零溢出，无需压高/裁切。
  static const double titleBarHeightMain = 32;

  /// **顶部带中心线**（2026-10-14 骨架定）：全应用顶部控件共享一条 y=20 的
  /// 水平中心线，各元素按自身高反推 `top = headerBandCenter − h/2`：
  /// 筛选钮(32)→top 4、编辑器耳朵(30)→top 5、新建胶囊(32)→top 4。
  /// 新增顶部钮一律按这条线算，禁止各自拍 top。
  ///
  /// ⚠️ 侧栏是唯一例外（2026-10-15）：顶带上方插了品牌行（[brandStripHeight]
  /// + 一档 [regionGap]）⇒ 侧栏的搜索 / 新建带整体下移 56，不再与内容卡筛选行
  /// 共享这条线（Linear 的侧栏页头同样不共享）；内容卡 / 编辑器仍按本线算。
  static const double headerBandCenter = 20;

  /// **侧栏页头行高**（2026-10-15 定）：侧栏顶部「logo + 应用名 + 右侧动作钮」行。
  ///
  /// 取 **40**：锚是右栏编辑器「撤销 / 重做 + 双耳」那条头一带
  /// （`note_editor_view_appflowy.dart` 的 `_kHeaderBandHeight`
  /// = `上留白 5 + 按钮热区 [headerActionSize]=30 + 间距 4` = **39**），
  /// 取它的**最近 4pt 倍数** 40 —— 差 1px 察觉不到，换来整列全 4 倍数：
  /// `顶 4 → 页头 40 → 12 → 顶带 32 → 12 → 导航`。
  /// 两列顶端的动作区因此近乎同高（40 vs 39），仍是 C 方案里唯一保留的跨列关系。
  ///
  /// ⚠️ 改这个数**只动等号右侧**：上面那组 4 倍数（4/40/12/32/12）是整列节奏的来源，
  /// 别为凑别的数把它推离 4pt（派生关系写在文档里就够了，不必牺牲网格）。
  ///
  /// 行内：logo [iconMd]=24 + 名称 13px w600，左缘与搜索框对齐（= 侧栏左内距
  /// [spaceMd]）⇒ 与导航文字同一条左基线；logo 上下余 (40−24)/2 = 8，正好一档
  /// [spaceSm]。
  static const double brandStripHeight = 40;

  /// **区块间距**（2026-10-14 骨架定）：侧栏内"新建胶囊↔导航"、侧栏↔内容卡
  /// （= 侧栏右内距 [spaceSm] + 环缝 [appPanelInset] = 12）等**区块之间**的
  /// 唯一间距。区块内元素仍走 space 阶梯（4/8/16），别拿它当万能间距。
  static const double regionGap = 12;

  // ── 桌面外壳 chrome 度量（2026-10-08 令牌收口：从各外壳文件的 k 级私有
  // 常量收编到此，与 [titleBarHeightMain] 同一档）────────────────
  /// **内嵌浮面**离窗缘的环缝（2026-10-09 opencode 风外壳）：内容是一张
  /// 四角圆角的浮面卡，**右侧与底部**与窗口底之间靠这圈缝隙分层，不用分割线；
  /// **顶与左为 0**（2026-10-15 用户定）：面板顶缘贴标题条、左缘贴侧栏。
  /// 分界主要交给 [AppTheme.surfaceRing] 那圈 1px 亮线（Linear 口径），
  /// 环缝只保留右 / 下两处。
  static const double appPanelInset = 4;

  /// 顶条动作按钮（历史 / 设置 / AI）的固定方块：32。与居中目的地图标药丸
  /// （心流 / 全部 / 日历 / 收藏，走全局 [toolbarButtonSize] = 32）同大——
  /// 2026-10-11 用户定：悬浮背景齐平。条高 44 时垂直居中，上下各 6 呼吸；
  /// 图标 [iconMd]=24。
  static const double chromeButtonSize = 32;

  /// AI 问答轨常驻右缘的最小窗宽，低于它降级为居中浮层。
  /// （账：外壳 ≈615 ⇒ 1000 以下主区不足 385，编辑器失去意义。）
  static const double askRailBreakpoint = 1000;

  /// AI 问答轨宽（320–360 是右聊天栏的行业档：Notion AI / Heptabase Ask）。
  /// （8pt 收编时曾收敛到 336，2026-10-14 用户要求撤回到 340。）
  static const double askRailWidth = 340;

  /// 卡片网格行列距（2026-10-01 用户定的 20 档：间距表 16/24 之间的定值，
  /// 不在 t 恤码表上，收编为命名几何量）。（8pt 收编时曾收敛到 24，
  /// 2026-10-14 用户要求撤回到 20。）
  static const double cardGridSpacing = 20;

  // ── 外壳区块宽（2026-10-13 收编：原各文件私有 const，收敛到 8pt 整数倍，
  //    消除"互不对齐的散点"）────────────────────────────────────
  /// 左侧扁平导航栏宽 = **32×8**（2026-10-15 用户定：280 → 216 → **256**；
  /// 参照 Linear 侧栏 ≈200 但不缩占位文字）。硬约束是顶行：搜索框 + 8 缝 +
  /// 新建胶囊（≥80）⇒ 256 时搜索框 152，够放完整占位「搜索笔记与画布」。
  static const double sidebarWidth = 256;
  /// 最左**图标导航轨**宽（2026-10-16 Option 2 第一阶段）：60，常驻脊梁、暂仍可折叠
  /// （Phase D 起改为常驻 + 只折 208 列表列）。旧 [sidebarWidth](256) 的未来 = 本轨 + 列表列。
  static const double railWidth = 60;
  /// 图标轨内**交互钮**边长（2026-10-16 用户定：36）：搜索 / 新建 / 四视图共用；
  /// 图标仍 [Tokens.iconMd](24)。轨 60 − 左右各 8 呼吸 = 44 内容区，36 钮两侧各余 4。
  static const double railButtonSize = 36;
  /// 主菜单面板宽 = 原 `app_menu._panelWidth`（180；8pt 收编时曾收敛到 176，
  /// 2026-10-14 用户要求撤回到 180）。
  static const double menuPanelWidth = 180;
  /// 设置面板宽 = 90×8（原 `settings_panel._panelWidth = 720`，= [contentMaxWidth]）。
  static const double settingsPanelWidth = 720;
  /// 搜索面板宽 = 75×8（原 `search_palette._paletteWidth = 600`）。
  static const double paletteWidth = 600;
  // ── 图标 ────────────────────────────────────────────────────────
  // ⚠️ 先记住一条：Tabler 的尺寸是**画板框**，不是视觉大小。它的图形画在
  // **24×24 画板**里、四周留白（实测 `Search`：内容范围 x 3~21 ⇒ 占画板 ~75%），
  // 描边数值也在同一个 24 坐标系里。于是：
  //   · `height: 24` ⇒ 视觉内容 ≈ 18px、描边 1.5×24/24
  //   · `height: 18` ⇒ 视觉内容 ≈ 13.5px、描边 1.5×18/24 = 1.125
  // 声明只差 6，**视觉小 25%、笔画细 25%** —— 2026-09-23 实测"看着小一圈"就是它。
  // 改尺寸或描边之前，先把这两个换算算一遍。
  //
  // 各档（收编前全项目 139 处横跨 10/12/14/16/18/24/40 七档，24 占 55%）：
  //
  // **应用侧常规交互图标（主力）**：视觉 ≈ **18px**（框 24 × 画板占比 ~75%）
  // —— 这正是"照抄 24"那版的观感。2026-09-23 用户实机比过 18 / 20 / 24 三档后
  // 定的就是它。描边配套见 [iconStroke]（24 框下恰好给出 1.5px）。
  static const double iconMd = 24;
  // **应用侧顶条辅助按钮**：框 20，介于 18/24 之间——顶条空间紧凑但又不想用
  // 18 那档时（如折叠面板按钮）。描边按比例 1.5 × 20/24 ≈ 1.25。
  static const double iconMdSm = 20;
  // **编辑器官方容器内专用**（工具栏 `SVGIconItemWidget` 的 `iconSize`、斜杠菜单
  // `SelectionMenuIconWidget` 的 `SizedBox(18)`）—— 这是**别人的契约**，
  // 不是我们的选择：跟着应用侧一起调会立刻与官方条目混排、甚至撑破 30px 槽位。
  static const double iconSm = 18;
  // 次级小图标：勾选 / 关闭 / 星标 / 外链 —— 菜单行与卡片里的"小记号"。
  static const double iconXs = 14;
  // 行内装饰记号（下拉箭头）：必须**跟着主图标挤进 30px 的槽位**（`18 + 10 = 28`，
  // 留 2px 余量；取 14 会撑到 32 直接溢出 —— 收编时实测踩到，13 个用例一次变红）。
  // 这一档不是"想细一点"，是算出来的。
  static const double iconXxs = 10;
  // 空状态大图标：图片加载失败那类占位插画级别。
  static const double iconXl = 40;

  // Tabler 的**描边**：数值长在 24 画板坐标系里 ⇒ 实际渲染 = 本值 × (框 ÷ 24)。
  // 取 **1.5**：主力档 [iconMd] 恰好是 24 框 ⇒ 实得正好 1.5px。
  //
  // ⚠️ **不要**把"让各档实得都等于 1.5px"当目标：小图标按比例细下去才对
  // （14px 的勾选要是也画 1.5px，笔画占 10.7%，会糊成一团）。所以这里是
  // **按比例**的：24 框 → 1.50、18 框 → 1.13、14 框 → 0.88、10 框 → 0.63。
  //
  // 唯一的例外是**编辑器通路**：`editor_icons.dart` 的 `_b()` 按框反算，让它一律
  // 呈 1.5px —— 因为编辑器工具栏里我们的 tabler 图标与**官方包内 SVG 并排**
  // （后者是 24 画板 2px 描边，缩到 18 就是 1.5px），不跟齐就会一边粗一边细。
  //
  // ⚠️ 改这一个数 = 全项目图标粗细一起变（应用侧 138 处显式传参 + 编辑器映射表）。
  static const double iconStroke = 1.5;

  // 画布工具条按钮（Material IconButton 的热区）：32×32 正方、图标 [iconMd]（24）
  // 四周各余 4px。此前裸用 M3 默认（40×40 布局 + 48 padded 热区），
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
  // 侧栏行高（nav_rail 目的地行、hub_nav 内联行、设置左导航等单行侧栏项）。
  // 与 [noteTileHeight] 同档——2026-10-08 用户拍板"行高 28"，正落在上面
  // Apple 口径 24–28 的上沿：比 M3 触控档 32/36 紧凑，一屏多放两三行。
  static const double sidebarRowHeight = 28;
  // 格式工具栏按钮（自绘 NoteFormatToolbar）
  // 工具栏按钮：24×30，18px 图标四周各有 3px/6px 呼吸，
  // 悬浮高亮不贴字形，热区也稳。
  static const double formatButtonWidth = 24;
  static const double formatButtonHeight = 30;

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

  // 笔记标题行**两端**的常驻按钮（左 = 撤销/重做，右 = 三个耳）：热区 30。
  // 图标 [iconMd]（24）在 30 里上下各余 3px —— 比原来的 26/16 更有"按钮"体量，
  // 也刚好够到最小可点目标。
  //
  // ⚠️ 改这个值要**连标题行的上内边距一起重算**（那个内边距是从落点反推出来的，
  //   不是随手填的间距）：图标字形顶 = 上内边距 +（本值 − 图标）/2，
  //   现取 `7 +（30 − 24）/2 = 10` —— 见 `note_editor_view_appflowy.dart` 的
  //   `_kHeaderActionTopPadding`（改热区或改 [iconMd] 都要按这个式子重推）。
  static const double headerActionSize = 30;

  // 动效
  // Apple 口径（§9.2）：比 M3 略长、收尾更缓——"精致"有一半在节奏。
  static const Duration durationFast = Duration(milliseconds: 150);
  static const Duration durationNormal = Duration(milliseconds: 250);

  /// **hover / 按压**的过渡（阶段 0 新增，≤120ms 档）。
  ///
  /// 与上面两档**分工不同**：[durationFast] / [durationNormal] 是"内容变化"
  /// （展开、切换、浮层进出）的节奏，要**看得见过程**；hover 是**跟随指针的
  /// 反馈**，慢了会黏手——指针已经移开、底色还在追。桌面端 hover 是高频动作，
  /// 故单列一档而不复用 150。
  static const Duration durationHover = Duration(milliseconds: 100);
}
