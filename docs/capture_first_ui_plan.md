# 桌面端「捕获优先」UI 重构执行方案

- 起草：2026-10-05。状态：**未开工**，待拍板项见 §2。
- 定位：`docs/ui_rewrite_plan.md`（上一代 UI 重写方案）的后续。该文档的 §3 命令层、
  §4 locateProvider、§5.6 外壳同色平铺等设计**继续有效**，本方案不替代它们；
  本方案只新增/修正两块：**主页重排为捕获优先**、**外壳补齐桌面骨架**。
- 设计语言与配色推导过程见本方案末尾 §15（对话结论存档）。

---

## 0. 目标

一句话：**打开应用第一眼就知道点哪里**——主页唯一主操作是"捕获"，其余一切更小、更灰；
整窗是 PC 桌面观感（密度 / hover 三态 / 右键 / 快捷键 / 状态栏 / 发丝线），不是放大了的手机页。

## 1. 设计原则（第一性原理）

记录灵感的笔记应用，用户只有三个任务，界面按任务排，不按"视图类型"排：

| 任务 | 含义 | 界面推论 |
|---|---|---|
| ① 捕获 | 灵感半衰期以分钟计，每多一步就漏一批 | 主页唯一主操作 = **捕获条**，视觉权重压倒性最大；打字即捕获 |
| ② 找回 | 时间自传记忆扫读 + 关键词检索 | **心流流**（今天/昨天/本周分组）是启动视图；卡片网格/日历降为备视图 |
| ③ 发展 | 想法长成文章、画布、关联 | 画布与 AI 常驻但安静；行元数据显示"关联数" |

"第一眼知道点哪里"的机制不是引导教程，是**视觉权重的压倒性对比**：
全场最大的可点物只有一个（捕获条），其他一切尺寸更小、颜色更灰。

## 2. 决策记录

已定（前序对话确认）：

1. 保留 material_ui 内核（Overlay/Focus/TextField IME 内核/Scrollable/ThemeData 管道），
   只自绘表层组件——**不换 UI 包**。
2. 主页重心从"卡片墙 + 侧栏"换成"**捕获条 + 心流流**"；卡片网格降级为「全部」视图。
3. 页内搜索框退役，职责并入捕获条；Ctrl+K 全局浮层保留（同一引擎、同一注册表）。
4. 配色走"中性阶梯 + 单一强调 + 发丝线"，前景纯灰阶与 APCA 体检结论不动。
5. 四区外壳骨架：图标轨 / 主区 / AI 轨 / 状态栏；侧栏（编辑态大纲）暂缓。
6. 组件自绘放最后阶段，先行路径全部复用现有资产。

待拍板（方案按推荐默认值书写，动工前确认）：

| # | 决策 | 推荐默认 |
|---|---|---|
| A | 强调色 #00B5B5 偏荧光，是否去饱和为 #0D9488（亮）/ #14B8A6（暗） | **换**（只动种子一处，APCA 32 项回归兜底） |
| B | 图标轨（48px）目的地 | **主页 / 日历 / 画布 / AI / 设置** 五个 |
| C | 启动默认视图是否改为「心流」 | **是**（「全部」网格保留可切） |

## 3. 现状核对表（2026-10-05 写方案时逐条核实）

外壳与窗口：

| 事实 | 证据 |
|---|---|
| 窗口底由 main.dart builder 统一铺 `AppTheme.windowBackground` 纯色 | lib/main.dart、lib/src/app/home_screen.dart:213 |
| WindowStrip：参数 leading/title/center/trailing；高 36；DragToMoveArea + 双击最大化 + 窗控钮 | lib/src/window/app_title_bar.dart:25-49、88-145；lib/src/theme/tokens.dart:42 |
| 最小窗口 720×560 | lib/src/window/window_service.dart:20（app_title_bar.dart:245 另有一处 minimumSize） |
| 桌面布局 = 顶条 + (HomeHub ‖ 编辑器) + _AiRailSlot；AI 轨宽窗常驻断点 1000 | lib/src/app/home_screen.dart:112-241；lib/src/app/ask_panel.dart:30 |
| 左侧整列为空：HubNav 2026-09-30 整撤、AppRail 2026-09-29 撤；navCollapsedProvider 机制保留无消费方 | lib/src/app/providers.dart:129-143 |
| **无状态栏**（全项目无匹配） | grep「状态栏」零命中 |

主页与视图：

| 事实 | 证据 |
|---|---|
| HomeView 五值 all/notes/canvas/calendar/favorites；icon() 扩展在 home_hub.dart | lib/src/app/providers.dart:296-307 |
| 统一导航历史（selectHome/goBack/goForward/goHome）；启动默认视图 = HomeView.all | lib/src/app/providers.dart:380-480（默认值 :385-389） |
| 顶栏左簇常驻 tab：全部 / 日历 / 收藏（notes/canvas 在三点菜单） | lib/src/app/home_hub.dart:385-433 |
| 顶栏右侧 = 定宽 TextField 搜索框（searchNotifierProvider.submit + 清空钮）+ FilterMenuButton 筛选/排序 | lib/src/app/home_hub.dart:459-536 |
| 内容分发：有 query → _SearchResultsView；日历 → _CalendarView；其余 → homeItemsProvider((view,tag)) 卡片网格 | lib/src/app/home_hub.dart:571-611 |
| 搜索框持有 _searchFocus = FocusNode(onKeyEvent)；home_hub 另有 4 处 FocusNode（卡片/日历 FocusRing 用，不消费字符键） | lib/src/app/home_hub.dart:303、789、877、1274、2118 |
| hub_nav.dart 残留旧形态素材：hubNavItems（主页/笔记/画布/搜索/收藏）+ kSearchNavIndex/kFavoritesNavIndex | lib/src/app/hub_nav.dart:30-60 |

命令与搜索（捕获条的直接依赖）：

| 事实 | 证据 |
|---|---|
| 命令注册表完整且"一处定义四处消费"；现有命令：note.new Ctrl+N、canvas.new Ctrl+Shift+N、note.promote、search.open Ctrl+K、palette.open Ctrl+Shift+P、app.settings Ctrl+,、ai.ask Ctrl+J | lib/src/command/commands.dart:66-80、84-194 |
| 快捷键为旁观者分发（HardwareKeyboard.addHandler → CommandRegistry.resolve），不与编辑器抢事件 | lib/src/command/bindings.dart:8-31 |
| Ctrl+K 浮层与页内搜索共用同一引擎 searchAllNotes；浮层默认不写 searchNotifierProvider | lib/src/app/search_palette.dart:19-30 |
| 浮层"查看全部结果"交接 = selectHome(HomeView.all) + searchNotifierProvider.submit(q) ——捕获条照抄这条口径 | lib/src/app/search_palette.dart:260-275 |
| runCreateNote：新建后立刻选中进入（"新建=立刻写"语义已存在），但不带初始文本 | lib/src/command/commands.dart:196-200 |

基建与交互语言：

| 事实 | 证据 |
|---|---|
| 滚动条走 theme 层 ScrollbarThemeData（app_theme.dart:1276），无自绘滚动条组件 | lib/src/theme/app_theme.dart:1276 |
| 右键菜单仅两处旧重命名入口（hub_nav/note_list_view）+ 编辑器 vendored 右键；主页卡片/列表无右键 | lib/src/app/hub_nav.dart:941、lib/src/notes/note_list_view.dart:316 |
| **无 golden 测试基建**（test/ 无 matchesGoldenFile） | grep 零命中 |
| Tokens 齐：space 2-48、radius 6/8/12、fontSize 11/13、noteTileHeight 28、hairlineWidth 0.5、focusRingWidth 2、duration 150/250 | lib/src/theme/tokens.dart 全文 |
| SurfaceLadder 明暗两实例（纸面/浮层/board 档，_derive 派生） | lib/src/theme/surface_ladder.dart:42、61、74 |
| 数据快照：notesProvider 全量 List<Note>（含 summary 列，1 万篇 allNotes ~100ms 实测）；保存走增量换行 | lib/src/app/providers.dart:580-731；integration_test/db_bench_test.dart |
| 架构约束：只有 main.dart 与 app/providers.dart 可 import data/ | test/architecture/architecture_test.dart |

核对结论——四个缺口正好是本方案要补的：无持久导航（左列空）、无状态栏、主页无右键/批量、
主页重心错放在卡片墙。命令层与搜索管线已经完备，捕获条是"装配"而不是"新建轮子"。

## 4. 里程碑总览

| 阶段 | 交付物 | 依赖 | 备注 |
|---|---|---|---|
| 0 | 令牌与配色地基（侧轨/hover 档、hover 时长档；强调色拍板后换种子） | 拍板 A | 可与阶段 1 并行 |
| 1 | **主页捕获优先**：OmniBar + 心流流 + 分段改造 + 页内搜索框退役 | 拍板 C | 核心，价值最大 |
| 2 | 外壳：AppRail 48px + StatusBar 26px | 拍板 B | 与阶段 1 无相互依赖 |
| 3 | 交互语言：右键菜单、快捷键页、多选批量、滚动条核对、动效档 | 阶段 1（流行/卡片挂菜单） | |
| 4 | 侧栏（编辑态大纲 + 反链） | 前置 spike：vendored 编辑器大纲出口 | 暂缓，先盘点再立项 |
| 5 | 组件表层自绘（12-15 个）+ golden 基建 | 阶段 1-3 稳定后 | |
| 6 | 编辑器皮肤（工具条/斜杠菜单/查找面板对齐令牌） | 阶段 0 | 点睛 |

每阶段独立成 commit 收口，可单独 revert；1 与 2 顺序可换，建议先 1。

## 5. 阶段 0：令牌与配色地基

任务：

1. surface_ladder 补两档显式语义：
   - **侧轨 rail**（比纸面沉一档：亮 L*≈base−3，暗 ≈7 以下）——AppRail/StatusBar/AI 轨共用；
   - **hover 微镀**（纸面 +4% 墨 / 暗 +12% 光）——列表行、卡片、按钮 hover 统一入口
     `AppTheme.hoverOverlay(brightness)`。
   - 现有 light/dark 实例（surface_ladder.dart:61/74）不动既有档值，只**追加**，避免全局色变。
2. 发丝线不新增：`hairlineWidth=0.5` + `AppTheme.menuBorder` 已有（tokens.dart:124），
   补一个列表分组 divider 语义别名，同源同值。
3. tokens.dart 补 `durationHover = 100ms`（hover/按压过渡 ≤120ms 档；150/250 保留原用途）。
4. （拍板 A 后）换强调色种子：ColorScheme.fromSeed 种子一处改为 #0D9488；
   暗色 primary 由 seed 机制派生后核对是否落在 #14B8A6 观感带。回归：apca_audit_test 32 项 +
   editorLink 钳制（app_theme.dart）行为不变。

验收：`flutter analyze`、`dart analyze`、`flutter test` 全绿（基线 1027+，本阶段应零测试变更）。

## 6. 阶段 1：主页捕获优先（核心）

### 6.1 OmniBar（新文件 `lib/src/app/omni_bar.dart`）

一框三用 + 实时意图提示。常驻 HomeHub 顶部，高 44，聚焦时全页内容压暗至 ~60%
（遮罩 color-mix 纸面 60%，不拦截点击，点击遮罩即失焦），结果浮层带投影浮出。

状态机（决定下拉与 Enter 行为）：

| 输入 | 下拉内容 | Enter | 意图胶囊（框右） |
|---|---|---|---|
| 空 | 无下拉；placeholder「记点什么… ／ / 命令 ／ # 标签」 | 不动作（防手滑建空笔记） | 「记点什么…」灰 |
| 纯文本 q | 第 1 行「新建笔记「q」」；下方 searchAllNotes 命中 ≤8 条（200ms 防抖，snippet 关键词高亮复用现有 matchColor 口径） | 新建 spark 笔记：createNote → saveTitle(q) → locate(focus: true) | 「↵ 新建笔记」 |
| `/` 前缀 | 命令列表：commandRegistryProvider 按 title/hint 过滤 + activeCommandScopesProvider 作用域过滤 | 执行选中命令 | 「↵ 执行命令」 |
| `#` 前缀 | 标签列表：notesProvider 快照内存聚合 | 等价于选标签筛选（走 homeItemsProvider((view, tag)) 现有路径） | 「↵ 按标签筛选」 |
| Shift+Enter（或 ↓ 选中某命中后 Enter） | — | selectHome(HomeView.all) + searchNotifierProvider.submit(q)（与 search_palette.dart:260-275 逐字同口径） | 「↵ 查看全部结果」 |

复用与扩展：

- 新建路径**必须**走 `runCreateNote`（commands.dart:196）的同一管线，扩展其签名支持初始文本；
  `note.new` 命令不传文本，OmniBar 传——单一写路径，杜绝两套创建逻辑漂移。
- 搜索命中直接调 `contentRetrieverProvider`（providers.dart:260-273，app 层唯一检索端口）。
- 键盘：↑↓ 移选择、Enter 提交、Esc 失焦并把焦点还给主页（打字即捕获重新接管）。
- 事件消费遵守 bindings.dart 的旁观者约定：OmniBar 自身持焦时事件天然归它，不碰全局分发。

### 6.2 打字即捕获（焦点管理）

- HomeHub 根部挂 `Focus(autofocus: true, onKeyEvent: …)`：事件为 PrintableCharacter
  且当前无其他 TextField 持焦时，把字符灌入 OmniBar controller 并 requestFocus，返回 handled。
- 生效域三重闸：仅 `selectedId == null`（主页分支）＋ 无模态浮层（浮层打开时浮层自身持焦，
  天然隔离）＋ OmniBar 未持焦。编辑器/画布分支不渲染 OmniBar，无冲突面。
- home_hub 现有 5 处 FocusNode 均不消费字符键，无冲突；`_searchFocus`（:303）随搜索框退役一并删除。

### 6.3 心流流（新文件 `lib/src/app/stream_view.dart`）

- `HomeView` 追加 `timeline('心流')`（providers.dart:296-307）；同步三处：
  home_hub 的 icon() 扩展与三点菜单、NavHistoryNotifier 默认视图改 timeline（providers.dart:385-389）。
- 顶栏 tabs 改为：**心流 | 全部 | 日历 | 收藏**（notes/canvas 留三点菜单不动）；FilterMenuButton 保留右移。
- 分组：今天 / 昨天 / 本周 / 本月 / 更早，键 = revisedAt（与 allNotes 的 revised_at DESC 同源，顺序天然一致）；
  收藏**不**提升置顶（保持时间线纯度，收藏走 favorites 视图）；「更早」>200 条折叠为计数行懒展开。
- 行 `_StreamTile`：高 44 两行 = 标题（13px/medium，无标题借正文首行，空白显示「（空白）」——沿用卡片口径）
  ＋ 元数据行（11px 灰：标签 · 相对时间）；画布笔记带 CustomIcons.canvas 角标（卡片已有口径，不画缩略图，保密度）。
- 交互：hover = hoverOverlay 微底 + 行尾浮出「收藏 / 更多」；点击 `locateProvider.locate(noteId)`
  （**不带 focus**，与现列表口径一致）；↑↓ 移 FocusRing（theme/focus_ring.dart 已有），Enter 打开。
- 数据：notesProvider 快照内存分组（无新 SQL；分组是 O(n) 内存操作，快照已实测 ~100ms/万篇量级）。
- 空库空态：居中大捕获条 + 示例提示（「试试：输入一句话回车」）。

### 6.4 页内搜索框退役

- 删除 home_hub.dart:459-536 的 TextField 段与 `_searchFocus`；FilterMenuButton/排序钮保留。
- `searchNotifierProvider`、`_SearchResultsView`、搜索态切 tab 不清词等语义**全部保留**——
  只是唯一写入口从页内框换成 OmniBar（Ctrl+K 交接行也写它，两入口殊途同归）。

### 6.5 阶段 1 验收

- 四条创建路径手测：OmniBar 回车 / Ctrl+N / Ctrl+Shift+N（画布）/ 空库空态回车。
- 两条搜索路径：OmniBar 下拉命中点击；Shift+Enter 交接铺全部结果（含关键词高亮与计数状态条）。
- 命令与标签：`/` 列表执行 note.promote；`#` 筛选落地网格。
- 焦点回归：编辑器内打字不受影响；浮层打开时打字不误触发；Esc 层级正确。
- 测试：navHistory 默认视图相关用例同步改 timeline；home_hub 顶栏 tab 用例改新 tabs；
  新增 OmniBar 状态机单测（纯逻辑部分抽成可测函数）与心流分组单测。
- 收口：双 analyze + 全量 flutter test。

## 7. 阶段 2：外壳（AppRail + StatusBar）

### 7.1 AppRail 48px（新文件 `lib/src/app/app_rail.dart`）

- 布局改 `Row[ AppRail(全高贴窗缘), Expanded(Column[ WindowStrip, 主区 ]) , _AiRailSlot ]`；
  WindowStrip 只盖 rail 右侧（拖拽区随之右移，窗控钮仍在右上，Windows 惯例）。
- 目的地（拍板 B）：主页（goHome）/ 日历（selectHome(calendar)）/ 画布（selectHome(canvas)）/
  AI（runCommandById('ai.ask')，开关态点亮）/ 设置（runCommandById('app.settings')，钉底部）。
- 选中态：主页态高亮当前 HomeView 对应项；编辑态不高亮任何项（"在笔记里"不属于任何目的地）。
- 顶条左簇微调：NavHistoryButton 前进/后退保留；HomeNavButton 与 rail 主页重复，实机确认后移除；
  NavCollapseButton 暂时隐藏（阶段 4 侧栏落地时复用 navCollapsedProvider 挂侧栏）。
- 720 最小窗宽下 48px rail 无压力（主区仍余 672）。

### 7.2 StatusBar 26px（新文件 `lib/src/app/status_bar.dart`）

- 左：「N 篇笔记」（notesProvider 快照 length）；预留 AI 索引状态位（IndexProgress 有流再接）。
- 右：「Ctrl+K 快速跳转 · Ctrl+Shift+P 命令」静态提示（快捷键的发现入口，命令层 §3.5 口径）。
- 只挂桌面分支（home_screen 桌面 body 最底）；移动分支不动。底色用阶段 0 的 rail 档 + 顶部发丝线。

验收：三档窗宽手测（720 / 1340 / ≥1600）× AI 轨开合 × 明暗主题；双 analyze + 全量测试。

## 8. 阶段 3：交互语言

1. **右键菜单**：心流流行与卡片 onSecondaryTapUp → showMenu：打开 / 收藏 / 编辑标签 /
   复制标题 / 删除（删除复用 undo_toast 撤销）。锚点遵守既有三条铁律（全屏 MediaQuery 尺寸 +
   RelativeRect 四边缘 + 32×32 外壳锚点，注释在 home_hub 既有实现里）。
2. **快捷键页**：设置面板新增「快捷键」页，读 commandRegistryProvider 渲染（palette.open
   已具备展示能力，此处是静态总表）。现有键位已够用，不新增键。
3. **多选批量**：网格与心流流 Ctrl/Shift 多选 → 底部浮动批条（收藏 / 标签 / 删除）。
   数据层 togglePromoted/saveTags/deleteNote 均现成，批量删除逐篇调用（个人库规模可接受）。
4. **滚动条**：核对 app_theme.dart:1276 的 ScrollbarThemeData 向幽灵口径靠拢
   （细、悬停才现身、主题色一致），不新造组件。
5. **动效**：新组件一律 durationHover/150/250 三档 + 只动 transform/opacity；
   AnimatedSwitcher 的 emphasized 曲线口径沿用 home_screen.dart:75-80。

## 9. 阶段 4：侧栏（暂缓，先 spike）

- 形态：rail 右侧 280px（240-360 拖拽记忆，Splitter 自绘）；主页态 = 分区/收藏/标签上下文列表；
  编辑态自动切「本篇大纲 + 反链」。
- 前置 spike：vendored appflowy 编辑器的大纲数据出口（标题节点遍历）与反链数据来源盘点，
  出结论后再立项动工。navCollapsedProvider（providers.dart:134-143）届时作为折叠开关接回。

## 10. 阶段 5：组件表层自绘 + golden

- 组件清单（自绘表层、内核不动）：Button(ghost/subtle/filled/danger)、StreamTile/ListItem 收编、
  Menu/MenuItem、Tooltip、Slider、Segment(Tab)、Splitter、Toast（undo_toast 收编）、Dialog、
  PaletteRow 收编、分组头、空态、Badge。
- golden 基建：test/goldens/ + matchesGoldenFile；**本机 Windows 基线**（跨平台 golden 不稳，
  CI 只跑逻辑测试不跑 golden）；每组件 ≥ 明/暗 × 默认/hover 四张。
- 触发条件：阶段 1-3 稳定后启动；期间靠现有 1027+ 用例兜底。

## 11. 阶段 6：编辑器皮肤

vendored 工具条 / 斜杠菜单 / 查找面板的颜色与密度对齐全局令牌（PATCHES.md 补丁机制已有），
内核零改动。放在最后，属点睛。

## 12. 全局验收基线

- 每阶段收口：`flutter analyze`、`dart analyze`、`flutter test` 全绿。
- 手测脚本随各阶段列出（§6.5 / §7）；明暗两主题、三档窗宽为固定动作。
- 性能红线：主页首帧不引入新同步重活（分组/聚合均为内存 O(n)）；OmniBar 防抖 200ms。

## 13. 风险与回退

| 风险 | 缓解 |
|---|---|
| 默认视图改心流牵动 navHistory 测试与"回主页保持视图"语义 | 只改默认值一处，语义不变；测试同步属预期成本 |
| 打字即捕获误触发（编辑器/浮层） | 三重闸（§6.2）；OmniBar 不在编辑器分支渲染；浮层持焦天然隔离 |
| OmniBar 创建路径与 note.new 漂移 | 同一 runCreateNote 管线，OmniBar 只是多了初始文本参数 |
| home_hub.dart 已 93KB | 新组件独立文件（omni_bar/stream_view/app_rail/status_bar），HomeHub 只做装配与删段 |
| 搜索框退役回归 | searchNotifierProvider/_SearchResultsView 契约不动，只换写入口；搜索态切 tab 语义保留 |
| 回退 | 每阶段独立 commit；阶段 1 与 2 互不依赖，可单独 revert |

## 14. 不做清单

- 不换 material_ui 内核、不引入新 UI 三方包。
- 不动 vendored appflowy 编辑器内核（皮肤除外，见阶段 6）。
- 不做 Mica/亚克力窗口材质（2026-09-22 已取消，不回头）。
- 不恢复主题色可设置项（2026-10-04 已删）。
- 移动端布局分支（NoteListView 路径）不动。
- raw primary 多处前景用法不在本方案范围（遗留观察点，另行确认）。

## 15. 设计语言存档（对话结论）

- 三任务模型：捕获（唯一主操作）/ 找回（时间流 + 检索）/ 发展（画布·关联·AI 安静常驻）。
- 「第一眼知道点哪里」= 视觉权重压倒性对比：全场最大可点物只有捕获条，其余更小更灰。
- 高级感五动作：打字即捕获、意图实时提示胶囊、聚焦收拢（全页压暗 + 结果浮层）、
  乐观创建（回车即进编辑器无 spinner）、键盘一等公民（↑↓/Enter/hover 仅补充）。
- 配色公式：四级中性表面阶梯（纸面/浮层/侧轨/hover）+ 1px 级发丝线（0.5 逻辑像素）代替投影
  + 单一强调色只用于交互态/焦点环/12% 选中着色；前景纯灰阶沿用 APCA 体检值（亮 91.4 / 暗 −85.0）。
- 参考系：Linear / Raycast / Things 的密度与克制，Notion 的库视图降级为备视图。
