# 主页重做：顶部视图切换 + 常驻搜索 + 卡片网格

## Context（为什么做）

当前主区（第三栏）在 `section==0` 时渲染 [HomeHub](file:///d:/Asinan/sinan/lib/src/app/home_hub.dart)——Things 3 式**单列一页纸**（日历→收藏→继续→最近→新建），搜索/收藏则是 `hubNavSelectionProvider` 的独立分区（`kSearchNavIndex=3` / `kFavoritesNavIndex=4`），入口在第一列 [AppRail](file:///d:/Asinan/sinan/lib/src/app/hub_nav.dart) 的图标。

用户要的新范式（2026-09-29 定，本轮只动第三栏，**第二列 HubNav 不动**）：

1. **顶部一排视图切换**：日历 / 笔记 / 画布 / 收藏 / 筛选器，点哪个就显示哪个的内容。日历、收藏、筛选器**不分笔记/画布**（标签跨形态统一池）；笔记、画布各自只看对应形态。
2. **内容以小卡片展示**，卡片带 2–3 行摘要，让人一眼知道大概内容。
3. **搜索从第一列挪到顶部中间的常驻搜索框**，点击直接输入。

已与用户确认的两点：
- 这 5 个视图 + 搜索框**都在"主页"里面**（主页 = 一个带顶栏的容器，内含切换器与内容区）。
- 第一列 AppRail **只留 主页 + 设置**（搜索/收藏图标移除）。

目标产出：一个"顶栏（切换器 + 常驻搜索）+ 内容区（卡片网格 / 日历）"的新一代主页，交互对标 Craft / Bear 的空间切换。

## 设计决策

- **两个正交轴**：
  - `homeViewProvider`（新，enum：`calendar/notes/canvas/favorites/filter`）= 顶部切换器选中的**视图范围**。默认落 `notes`（"看全部笔记"是最有用的落地页；切换器顺序仍按用户给的 日历/笔记/画布/收藏/筛选器）。
  - `searchNotifierProvider`（已有，[search_provider.dart](file:///d:/Asinan/sinan/lib/src/app/search_provider.dart)）= 顶部搜索框的 `query` + `activeTag`，**不新建搜索状态**。
- **内容区解析**：搜索框有词 ⇒ 在**当前视图范围内**过滤（笔记视图过滤笔记、画布过滤画布、收藏过滤收藏、筛选器过滤标签池；日历视图忽略搜索并淡出搜索强调），命中渲染成卡片网格。无词 ⇒ 显示当前视图的默认内容。
- **日历视图**：直接复用现有 [_CalendarView](file:///d:/Asinan/sinan/lib/src/app/home_hub.dart#L646)（月网格 + 选中日行列表），它已在 home_hub.dart 内、无需搬家。日历里的"选中日行"仍用 `_HubRow`（保留该类）。
- **卡片**：新 `_NoteCard`，用现成的卡片三件套 token [AppTheme.cardFill/cardStroke/cardFillHover](file:///d:/Asinan/sinan/lib/src/theme/app_theme.dart#L361-L374)。显示：标题 + `plainText` 摘要 2–3 行（`maxLines:3` + ellipsis）+ 标签小 chip（最多 3 个 + `+n`）+ 相对时间。画布卡片：无缩略图渲染管线（已确认全仓无 canvas thumbnail/preview），故用 `CustomIcons.canvas()` 图标 + 标题 + 时间，摘要仅当 `plainText` 非空时显示。点卡片 = `locateProvider.notifier.locate(noteId:)`（§4 唯一跳转通道）。
- **网格**：`_CardsGrid(List<Note>)` = `GridView.builder` + `SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 240, childAspectRatio: 1.45, crossAxisSpacing/spaceMd, mainAxisSpacing/spaceMd)`，随窗口宽度自动增删列（响应式，无写死列数）。
- **切换器控件**：5 枚不等宽，滑动药丸（`_SpaceSwitch` 那套）过重。用**横向图标+文字 tab 行**，选中项披 [AppTheme.navSelectedTint](file:///d:/Asinan/sinan/lib/src/theme/app_theme.dart#L667)（与 AppRail/选中行同语言），每枚接 [FocusRing](file:///d:/Asinan/sinan/lib/src/theme/focus_ring.dart)（§5.2 键盘可达）。

## 改动清单

### 1. [home_hub.dart](file:///d:/Asinan/sinan/lib/src/app/home_hub.dart)（主战场）
- 新增 `enum HomeView { calendar, notes, canvas, favorites, filter }` + `homeViewProvider`（`NotifierProvider<HomeViewNotifier, HomeView>`，默认 `notes`）。⚠️ riverpod 3.4.3 无 `StateProvider`，用显式 Notifier。
- 重写 `HomeHub.build` → `Column[ _HomeTopBar, Expanded(_HomeBody) ]`：
  - `_HomeTopBar`：左=5 枚视图 tab（`_ViewTab`），中=`_HomeSearchField`（常驻 TextField，`onChanged→searchNotifierProvider.submit`，`autofocus` 由点击触发；Esc 清词/回退沿用 [search_section.dart 的 _onKey](file:///d:/Asinan/sinan/lib/src/app/search_section.dart#L50) 逻辑）。
  - `_HomeBody`：按 `homeViewProvider` + `searchNotifierProvider` 分发：
    - `calendar` → `_CalendarView`（复用，喂全库 notes）。
    - `notes` → `_CardsGrid(有词?搜索命中∩非画布:非画布笔记)`。
    - `canvas` → `_CardsGrid(画布)`。
    - `favorites` → `_CardsGrid(promotedAt!=null)`（把 [favorites_section.dart](file:///d:/Asinan/sinan/lib/src/app/favorites_section.dart) 的过滤逻辑搬进来）。
    - `filter` → 顶部 `_TagChips`（搬 [search_section.dart#L217](file:///d:/Asinan/sinan/lib/src/app/search_section.dart#L217)）+ `_CardsGrid(activeTag 命中的全部形态)`。
  - 空态：某视图无内容 → 居中一行灰字（复用 `labelSmall` + `onSurfaceVariant` 口径）。
- 新增 `_NoteCard` / `_CardsGrid` / `_ViewTab` / `_HomeSearchField`。
- **删除**不再被引用的单列构件：`_Section`、`_FoldHeader`、`_HubRow` 里仅服务"继续/最近/新建"分组的分支、`_EmptyHub`（改为按视图空态）。**保留** `_CalendarView`/`_CalCell`/`_CalNavButton`/`_CalGhostButton`/`_HubRow`（日历选中日仍用）/`_TimeLabel`/`_relativeTime`/`_titleOf`/`_kindTagOf`。
- 移除 `HomeHub.maxWidth`/`recentCount` 相关（若 `home_hub_test` 仍引用则同步测试）。

### 2. [hub_nav.dart](file:///d:/Asinan/sinan/lib/src/app/hub_nav.dart) — AppRail
- [AppRail.build](file:///d:/Asinan/sinan/lib/src/app/hub_nav.dart#L127)：删「搜索」「收藏」两枚 `_RailAction`，只留 主页（顶）+ 设置（底）。主页钮 `active: onHome`（不再看 section==0，因为 section 语义收敛）。
- `hubNavSelectionProvider`/`hubNavItems`/`kSearchNavIndex`/`kFavoritesNavIndex`：**保留常量**（第二列 HubNav 与既有测试仍引用），但主页路由不再用 search/fav 分支。

### 3. [home_screen.dart](file:///d:/Asinan/sinan/lib/src/app/home_screen.dart) — 主区分发
- [L207-229 的 Consumer 分发](file:///d:/Asinan/sinan/lib/src/app/home_screen.dart#L207)：`section==0` 与其余一律 → `const HomeHub()`（搜索/收藏已并入主页内部）。移除 `SearchSection`/`FavoritesSection`/`_SectionPlaceholder` 分支与对应 import。
- 顶条 `WindowStrip` 不变（仍 `NavCollapseButton` + `AiRailToggleButton`）。

### 4. 删除的死代码
- [search_section.dart](file:///d:/Asinan/sinan/lib/src/app/search_section.dart)：搜索 UX 移入主页顶栏 ⇒ 整文件删除（`_TagChips`/`_onKey` 逻辑先搬进 home_hub 再删）。**`search_provider.dart` 保留**（主页搜索仍用它）。
- [favorites_section.dart](file:///d:/Asinan/sinan/lib/src/app/favorites_section.dart)：过滤逻辑搬进收藏 tab ⇒ 删除。

### 5. 测试
- **改** [app_rail_test.dart](file:///d:/Asinan/sinan/test/app/app_rail_test.dart)：4 枚→2 枚（主页/设置）；删搜索/收藏分区写入用例；保留"设置钉底""设置开面板""主页 goHome"。
- **重写** [home_hub_test.dart](file:///d:/Asinan/sinan/test/app/home_hub_test.dart)：从"单列一页纸"改为钉新契约——① 默认落笔记视图且渲染卡片网格；② 点 tab 切 `homeViewProvider` 且内容随之变；③ 卡片点击走 `locateProvider`；④ 搜索框输入 → 结果卡片随当前视图范围过滤；⑤ 日历 tab 显示 `_CalendarView`；⑥ 收藏 tab 只出 `promotedAt` 笔记、可就地取消收藏；⑦ 每张卡片 Material 用 `cardFill`（非透明，防黑块反向：卡片**应**有底色）。
- **迁移** [search_test.dart](file:///d:/Asinan/sinan/test/app/search_test.dart)：把宿主从 `SearchSection` 改为新主页（或至少保留对 `searchNotifierProvider` 的纯 provider 级用例：标题+内容合并、标签过滤），删除依赖已删 widget 的用例。
- 跑 `flutter analyze lib test` + `dart format` + 全量 `flutter test`（基线 945）。

## 验证

1. `flutter analyze lib test` → `No issues found!`（末尾 TRAE Sandbox `.dartServer temp` 噪音忽略）。
2. `dart format` 改动文件。
3. `flutter test test/app/home_hub_test.dart test/app/app_rail_test.dart test/app/search_test.dart` 全绿，再跑全量。
4. 手动 `flutter run -d windows`：
   - 第一列只剩 主页/设置；
   - 主页顶部 5 tab 可切，默认笔记卡片网格；
   - 顶中搜索框点击即输入，输入时当前视图卡片被过滤；
   - 日历 tab 月历正常、选中日出行；收藏 tab 只出收藏；筛选器 tab 出标签 chips + 卡片；
   - 点卡片进编辑器、左上「上一页」回主页且**记住上次的 tab**。
5. 明暗两套主题都过一遍（卡片 `cardFill`/`cardStroke` 明暗对称）。

## 风险 / 取舍

- **改动面大**：HomeHub 从单列重写为"顶栏+网格"，`home_hub_test`/`search_test` 需重写/迁移。若希望更稳，可**分两步**：先只做顶栏 + 笔记/画布卡片网格（日历/收藏/筛选器先占位），验证观感后再补后三个视图。计划默认一次做完，用户可要求拆分。
- **画布卡片无缩略图**：当前无 canvas 渲染管线，卡片用图标占位；后续若要真缩略图另立需求。
- **搜索语义变化**：从"独立搜索页"变成"顶栏常驻 + 按视图过滤"。`searchNotifierProvider` 的 FTS/语义检索完全复用，仅渲染层与"作用域"不同。
