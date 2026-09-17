# appflowy_editor 迁移 spike 验证结论

- 日期：2026-09-10
- 环境：Flutter **3.47.2** stable / Dart 3.13.2 · Windows
- 被测：`third_party/appflowy_editor`（官方 **6.2.0**，见其 `PATCHES.md`）
- 载体：`lib/src/notes/editor_spike_page.dart`
  （**已于 2026-09-10 删除**：验证收口后 `main.dart` 的启动页改回 `HomeScreen`）
- 自动化验证：`test/editor_spike_verification_test.dart`
  （复跑：`flutter test test/editor_spike_verification_test.dart`）

## 结论速览

| # | 项目 | 结论 | 依据 |
|---|---|---|---|
| ① | 中文输入法 | ✅ **通过**（人工验证 2026-09-10） | 测试框架无法驱动（见下），已由人工实测确认"使用没问题" |
| ② | 基础编辑 | ✅ **通过**（代码块除外） | 官方 11 类块注册表 + 六类块实测渲染 |
| ③ | 块虚拟化 | ✅ **通过** | 400 块文档实际只构建 **75** 个块 |
| ④ | 明暗主题跟随 | ✅ **通过（配色）**；Mica 融合观感**未验证** | 正文字色 == 主题 `onSurface`；`EditorStyle.desktop` 默认硬编码浅色已显式覆盖 |
| ⑤ | material_ui 主题桥 | ✅ **通过** | 带桥/不带桥对照：带桥读到 `Brightness.dark` + 我们的 `#202020`；不带桥读到 `Brightness.light` |

**总判定**：**已收口**——① 人工验证通过，②③④⑤ 自动化部分全部通过。
唯一遗留是 ④ 的 Mica 观感（没法在 spike 页看，见该节），但它**不阻塞迁移**。

> 附：Mica 在 spike 页**看不到是正常的**——该页用
> `Scaffold(backgroundColor: scheme.surface)` 铺满整窗不透明底色，
> 把 DWM 材质盖住了。要看 Mica 必须在真实应用（`HomeScreen`）里。

---

## ① 中文输入法 —— 通过（人工验证）

### 为什么无法自动化（实测，非推测）

1. appflowy 的输入服务 `delta_input_service.dart` **只消费 IME 增量**：
   实际生效的是 `updateEditingValueWithDeltas`，而 `updateEditingValue`
   （Flutter 传统 IME 通道）是**空实现**（`:125`）。
2. Flutter 测试框架的 `TestTextInput` **没有** delta 通道——
   `flutter_test/lib/src/test_text_input.dart` 内不存在
   `updateEditingValueWithDeltas`，无法构造组合串（composing range）。
3. 实测旁证：建立光标选区后发送裸按键（`sendKeyEvent(keyA)`），
   文档纯文本仍为空——appflowy 的按键层只处理**命令类**事件
   （退格/回车/方向键等），可打印字符走 IME 通路。

→ 测试脚本已写好并置 `skip`（`editor_spike_verification_test.dart` 末组），
将来测试框架支持 delta 后可一键启用。

### 人工验证结果（2026-09-10）

**在真实窗口里用输入法实测：中文输入正常，无问题**（人工确认）。
下列清单转为**后续回归项**保留——正式迁移落地（编辑器视图换成 appflowy 实现）
时再跑一遍：

- [ ] 微软拼音：连续输入拼音，**组合串下划线**是否正确显示、是否错位
- [ ] 候选框位置：是否贴近光标（不在窗口左上角、不遮住文字）
- [ ] 上屏：选词后文档内容与光标位置是否正确
- [ ] 退格删组合：组合状态下退格只删组合串、不删已上屏文字
- [ ] 搜狗输入法：同上四项
- [ ] 中英混排：组合串中途切英文，边界是否有残留/重复字符
- [ ] 长文档中输入：输入时视图是否跳动（与 ③ 的滚动定位相关）

---

## ② 基础编辑 —— 通过（代码块除外）

**官方块组件注册表（实测打印）**：

```
[page, paragraph, todo_list, bulleted_list, numbered_list, quote,
 heading, image, divider, table, table/cell]
```

- 六类块实测渲染通过：段落 / 标题 / 无序列表 / 有序列表 / 待办（勾选与未勾选）/ 引用 / 分隔线。
- **官方自带、无需我们写**：段落、标题、无序、有序、待办、引用、分隔线、图片、表格、页面。
- **官方 6.2.0 没有代码块**：`codeBlock` 与 `code` 均不在注册表内
  （只有 Markdown 插件的 `CodeBlockNodeParser`——能解析，无渲染组件）。
  → **代码块必须自定义块组件**，这与 `note_document_adapter.dart`
  里记录的"已知有损项"一致，迁移时一并解决（内含现有 `highlight` 语法高亮）。
- 表格是**白送的新能力**（quill 时代没有）。

---

## ③ 块虚拟化 —— 通过

- 代码层：`editor_component/entry/page_block_component.dart:96` 用
  `ScrollablePositionedList.builder`（`itemBuilder` 按需构建）。
- 实测：**400 块**文档渲染后，树上只有 **75** 个块
  （测试视口 800×600 + 预建缓存区；远小于 400）。
- 意义：这是相对 quill（全量 RenderObject）的**大文档性能优势**，
  是本次迁移的核心收益之一。

---

## ④ 明暗主题跟随 —— 通过（配色）；视觉融合待人工

- **既定工序（务必保留）**：`EditorStyle.desktop()` 的默认色硬编码为浅色
  （正文字色 `Colors.black`），深色窗口下会"深字压深底"——
  必须显式按项目主题构造 `EditorStyle`（`padding` / `cursorColor` /
  `selectionColor` / `TextStyleConfiguration` 全套）。
- **同类坑还有一处：斜杠菜单**（2026-09-10）。官方 `customSlashCommand(items)`
  的 `style` 默认是 `SelectionMenuStyle.light`——**硬编码**白底 `#FFFFFF` +
  文字 `#333333` + 强调色青蓝 `#00BCF0`（`selection_menu_widget.dart` 的
  `light`/`dark` 常量），**既不读种子色也不看明暗** ⇒ 深色主题下弹出白色菜单。
  修法同样走官方扩展点（**零补丁**）：`customSlashCommand(..., style:)` 传
  `sinanSlashMenuStyle(...)`，由应用 `ColorScheme` 的角色构造
  （`slash_menu_items.dart`；回归见 `slash_menu_items_test.dart` 的
  "斜杠菜单配色跟随主题"——含"官方指纹色一个不留"断言）。
  ⚠️ 该参数**必传、不给默认值**：留默认值等于把"忘了传"变成静默的浅色菜单。
- **⚠️ 2026-09-10 修正一条记错的旧结论**：本项原先写着"深色下正文渲染色 ==
  `onSurface`，精确相等"。**那是错的**——真正的机制是：官方
  `AppFlowyRichText` 最终交给 **`RichText`** 渲染，而 `RichText`
  **不继承 `DefaultTextStyle`**，span 上没有 color 时会落到引擎默认
  （`dart:ui` 的 `TextStyle`：color 缺省 = **白色**）。
  于是：深色底白字**看起来正常**（才误判成"跟随主题"），而
  **亮色画布 `#FAF9F6` 上白底白字、正文几乎隐形**（用户反馈即此项）。
  实测证据：亮色渲染 span 的 `color` 是 `null`
  （`test/editor_typography_test.dart` 的"正文/标题的文字色来自主题"）。
- **正确接法**：`TextStyleConfiguration.text` 必须显式带上前景色
  （`scheme.onSurface`，见 `EditorTypography.toTextStyleConfiguration` 的 `text`
  参数）。一处生效、全编辑器统一——段落 / 标题 / 列表 / 引用 / **代码块 /
  公式**都读这同一个基样式；标题不许自己写死颜色（靠 `combine` 继承，才顶不掉
  行内"文字颜色"属性）。
- **未验证（需在真实应用里看）**：窗口 Mica 材质与编辑区底色的融合观感
  （浅色/深色各看一次），以及窗口底色切换时是否跳色。
  ⚠️ 注意：**spike 页看不到 Mica 是正常的**——它整窗铺了不透明
  `Scaffold(backgroundColor: scheme.surface)`，把 DWM 材质盖住了。
  该项必须在 `HomeScreen`（真实应用）里评估，与迁移本身无关。

---

## ⑤ material_ui 主题桥 —— 通过

appflowy 内部 `import 'package:flutter/material.dart'`，而我们应用用
`material_ui`（Material 层是**两套同名不同类型**）。桥 `MaterialUiCompatibilityBridge`
是这条路的唯一支点，实测结论：

| 条件 | appflowy 内部 `Theme.of` 读到的 |
|---|---|
| **带桥** | `Brightness.dark`，`scaffoldBackground` = `#202020`（我们的窗口底色），`primary` = 我们的主色 |
| **不带桥**（对照） | `Brightness.light`（官方默认浅色主题） |

对照实验证明了：**桥确实是 appflowy 拿到我们主题的唯一来源**，
且它工作正常——原判定为"本页最大风险点"的项**风险解除**。

附带确认：`AppFlowyEditorLocalizations.delegate` 与
`GlobalMaterialLocalizations.delegates` 必须同时挂上（缺失会抛
`AppFlowyEditorLocalizations not found`）；测试脚手架已按 `main.dart` 同构复刻。

---

## 附带发现：一个真 bug（已修 + 回归测试）

**appflowy 的文档根节点必须是 `page`**：

- `Document.blank()` 即 `Node(type: 'page')`；
  页面由 `PageBlockComponentBuilder` 渲染，它只认 `PageBlockKeys.type`。
- 而我们的适配器在**存量 Delta 读入路径**里把根写成了
  `Node(type: 'document')` → 若照此迁移，**编辑器会整页空白**。
- 已修（`note_document_adapter.dart`）：
  1. `documentFromQuillOps` 改为 `Document(root: pageNode(children: nodes))`；
  2. `_documentFromBlockJson` 对非 `page` 的根**归一化为 page**（容错历史/脏数据）；
  3. 文档示例与落库格式的根类型说明同步更正。
- 回归测试：`test/note_document_adapter_test.dart` 新增
  「根节点必须是 page」用例（覆盖 Delta 路径 / 脏数据归一化 / 往返稳定）。

> 这条是 spike 测试真实抓出来的——迁移前不跑，就会在合并后以"打开笔记空白"
> 这种最难排查的形式爆出来。

---

## 自动化资产（建议保留）

`test/editor_spike_verification_test.dart` 用真实的编辑器（真主题、真桥、
真块组件）做断言，其中：

- 「官方块组件清单」——升级 appflowy 后可立刻看出新增/变更（例如哪天补上代码块）；
- 「块虚拟化」——防止将来的包装层破坏惰性渲染；
- 「主题桥 + 正文配色」——防止 `EditorStyle`/主题桥被改坏。

`editor_spike_page.dart` **已删除**，`main.dart` 的 `home:` 已改回
`const HomeScreen()`；本验证文件不依赖它（自带 `_EditorHarness`
复刻同一套 `EditorStyle` 配置）。

## 迁移原则（2026-09-10 定）

> **只用官方原生方案；官方确实不足的，才补——补优先用"官方扩展点"，
> 且必须记录理由与依据。appflowy 与 quill 是两种东西（块编辑器 vs 单文档
> 富文本），同名 API 语义可能完全不同，不可照搬 quill 的写法。**

判据（按优先级）：

1. **官方有扩展点** → 只用扩展点。例：中文排版走
   `TextStyleConfiguration` + `HeadingBlockComponentBuilder.textStyleBuilder`，
   零补丁（`editor_typography.dart`）。
2. **官方默认关、需应用侧接的能力** → 用官方零件接起来，不算补丁。例：块手柄
   `showActions` / `actionBuilder` 默认是 `false` / `SizedBox.shrink()`，
   但官方零件 `BlockComponentActionList` / `BlockComponentActionButton` 齐全。
3. **官方确实没有的能力** → 才自研。例：代码块（官方 6.2.0 注册表里没有）、
   公式、附件（`custom_block_components.dart`）。
4. **排版 / 间距类不满** → **先问"这是不是我们自己的错"**。例：块间距变成 4 倍
   是 `EditorStyle.padding` 的**按块语义**被当成编辑器外框用了（见下"坑"），
   不是官方不足。
5. **不为了顺手而改数据**。内容归一化、折叠空行这类一律不做。

### 已否决方案（避免重走）

| 方案 | 结论 | 依据（实测） |
|---|---|---|
| 渲染层"压扁"空段落（`placeholderTextStyle` / `textStyle`） | ✗ 不可行 | 官方把空段落渲染成**占位符 + 无样式空 span 两层**，块高取大者；那个空 span 自带 **14px** 默认行高，而 `updateTextStyle` 对无样式 span 是空操作（`style?.combine` 空值短路）→ 24px 最多压到 22px，等于没做 |
| 装载时折叠连续空行（`collapseRedundantBlankLines`） | ✗ 已撤销 | 官方行为本就和 quill 一致（一个空行 = 一行高度），无"不足"可补；且会改数据（首次编辑即按折叠后落库） |

### 四个已入坑的语义差（务必记住）

| 项 | quill | appflowy | 实测后果 |
|---|---|---|---|
| 编辑器 `padding` | **外框**内边距，只算一次 | **按块**生效（`page_block_component.dart` 的 `items.map` 里，每个块各吃一遍） | 照搬 quill 的"左右 16 / 上 4 / 底 96" → **每块多 100px**，表现为"行距是正常的 4 倍" |
| 块手柄 | quill 无此概念 | 默认**不渲染**（基类 `showActions = (_) => false`），需应用侧接 | 悬浮也不出现（不是 hover 问题、与文档数据无关） |
| **文字颜色继承** | quill 的 `TextSpan` 走 `Text`/默认样式，能吃 Ambient 前景色 | 官方最后是 **`RichText`**，**不继承 `DefaultTextStyle`** ⇒ 基样式不设 color 就落到引擎默认（`dart:ui`：缺省 **白**） | 深色下白字"看着正常"（掩盖了 bug），**亮色画布上白底白字、正文隐形**；修法：`TextStyleConfiguration.text` 显式给 `onSurface`（见 §④） |
| **工具栏按钮无状态层** | 按钮有 hover 底 | 官方 `SVGIconItemWidget` 把 `hoverColor/highlightColor/splashColor` **全设透明**（`icon_item_widget.dart:40-42`）——为浮动栏贴正文时减少视觉噪音，**有意设计** | 常驻固定栏里图标"只有变色没有按钮感"（用户反馈）。我们**有意偏离**：在条目槽位统一画 M3 状态层（`_StateLayer`，hover/press = `onSurfaceVariant @ 12%`）——**必须在槽位**，官方条目的 builder 各自构造 widget、改单个按钮构造器盖不到它们；与全应用 `IconButton` 同语言 |

---

## 排版基准（中文最佳尺寸 × Impeller 整像素，2026-09-10 定）

编辑器的字号 / 字重 / 间距**不是官方默认**（官方按拉丁标定，标题写死 32/28/24），
而是取两家**中文优先**规范（Apple HIG / 鸿蒙 PC）的**共识值**，再按两条准则收口。
全部收敛在 `lib/src/notes/editor_migration/editor_typography.dart`——改一处即全站
生效，**不需要动数据**（标题块里存的是 level 数字，不含字号）：

1. **中文显示与输入的最佳尺寸**：正文 ≥14px（汉字识别下限；两家规范的 Body 分别
   是 17pt / 14vp）、行高 ≥1.5（汉字满 em，1.2~1.3 会上下粘连）、字距 0、
   正文 w400 / 标题 w600；
2. **Impeller 整像素**：所有"算出来的"尺寸（字号 / 行盒 / 行距 / 块间距）都吸附到
   整数像素（见本文档「整像素」一节）。

> **不以 markdown 为基准**：markdown 规范本身不定义任何字号与间距（那是 CSS 的
> 事），它的数值只作对照参考、不作采用依据。

### 字号层级（比例 = 相对正文字号）

| 档 | Apple HIG（÷Body 17） | 鸿蒙 PC（÷Body 14） | 采用 | 依据 |
|---|---|---|---|---|
| h1 | Large Title 34 → 2.0 | Title_L 28 → 2.0 | **1.75** | 共识 2.0 收一档（≈×0.875） |
| h2 | Title1 28 → 1.65 | Title_M 22 → 1.57 | **1.4** | 共识 1.6 收一档 |
| h3 | Title2 22 → 1.29 | Title_S 18 → 1.29 | **1.2** | 共识 1.29 收一档 |
| h4 | Title3 20 → 1.18 | Subtitle_L 16 → 1.14 | **1.0** | 取两家共识的**第四档**（Headline / Subtitle_M 都与 Body 同号）：1.16 收一档后是 17.6，吸附后 18 与 h3（19）只差 1px——**层级不可辨** |
| h5/h6 | Headline = Body | Subtitle_M = Body | **1.0** | 两家都"同号不同字重"；鸿蒙 Subtitle_S 12vp **小于正文**，这里钳平（比正文小的"标题"在中文里没有语义） |
| 笔记标题 | —（应用层概念，两家规范都没有） | — | **1.4** | **与 h2 同号**（2026-09-14 定案，原为 1.75 = h1）。**标题比 h1 小是有意的**——它是"一篇的名字"，不是文档里的一级标题；2.0（32px）压在正文标题之上过重，先收到 1.75、再收到 1.4 |

> **采用值在两家共识基础上整体收一档（≈ ×0.875）**：实测按共识原值观感偏大
> ——正文 16 时 h1 = 32 已是 Word 级大标题，笔记场景偏重。
> 想回到共识原值：`headingScales` 换成 2 / 1.6 / 1.29 / 1.16 / 1 / 1 即可。

**吸附后的实际像素**（字号一律整数）：

| 正文字号 | 笔记标题 | h1 | h2 | h3 | h4~h6 | 正文行盒 |
|---|---|---|---|---|---|---|
| 14（小） | 20 | 25 | 20 | 17 | 14 | 24 |
| **16（默认）** | **22** | **28** | **22** | **19** | **16** | **28** |
| 18（大） | 25 | 32 | 25 | 22 | 18 | 32 |

层级：**h1 > 笔记标题 = h2 > h3 > h4~h6 = 正文**（笔记标题与 h2 同号，2026-09-14
定案；h4~h6 靠 w600 与正文区分）。

### 字重

| 元素 | 采用 | 依据 |
|---|---|---|
| 正文 | **w400（Regular）** | Apple 与鸿蒙的正文规范都写明 Regular（本项目曾用 w500 补偿桌面灰度抗锯齿下的偏淡观感，属经验值，已按规范回退） |
| 标题 | **w600（Semibold）** | Apple：苹方**没有 Bold 真字重**，`w700` 会合成加粗（笔画糊边）；Windows 雅黑 UI 无 Semibold 面时 Skia 取最接近字重 → 命中 **Bold**，等价于鸿蒙 PC 的「Title = Bold」 |

### 间距（官方没给，我们补的）

- 官方标题与正文的块内边距**完全一致**（上下各 4）⇒ **不靠间距区分标题**。
  我们只补**上间距** = `1.25em`（16px 正文下 20px；加上上一块的 `bottom: 4` ⇒ 渲染 ≈24px）。
- ⚠️ **依据是中文生态通行的 markdown 排版**（GitHub markdown CSS：h1~h6 统一
  `margin-top: 24px`，语雀/掘金/CSDN 等渲染都贴它）——**不是** Apple/鸿蒙的数值：
  **这两家规范都没有给标题间距**（它们给的是层级 / 字重 / 行高 / 排版规则）。
- 文档**首块不给**上间距（对标 GitHub 的 `*:first-child { margin-top: 0 }`）。
- 块 `padding` **不折叠**（≠ CSS `margin`）⇒ 上下都给会与邻块叠加成双倍，故只给上。
- **笔记标题 → 正文** = `0.75em`（16px 正文下 12px；加上首个块自带的 4px ⇒
  渲染 ≈16px，与 markdown 的标题下间距 `1rem` 同源）。改之前是 0——标题行盒
  余量与 4px 内边距加起来只有 ~10px，标题贴着正文"太近"。

### 整像素（Impeller 锐度）

Flutter 不做字体 hinting、文字是**线性度量 + 亚像素抗锯齿**：字号 / 行盒 / 间距
只要落在半像素上，字形就按"半个像素"取样，笔画边缘发灰（汉字笔画密，比拉丁文
更明显）。

- 我们能控制的是**让所有派生尺寸落在整数像素**（`EditorTypography.snap`）；
  剩下那点亚像素取样由引擎决定，控制不了、也不该靠"改字号"去凑（官方 Impeller
  文档没有承诺"对齐字形原点"，所以这条只能按**机制**来验收）。
- 行盒除整数外还要**与字号同奇偶**：实测行距 =（行盒 + 字号）/ 2（见
  `line_height_metrics_test.dart`）⇒ 只有同奇偶时**每一行**才落在整像素上，
  否则每行依次偏移半个像素、长段落越往下越糊。旧默认 1.7 就是这情况：
  16px 下盒 27.2、行距 21.4、首行顶被顶下 0.4（吸附后盒 26、行距 21）。
- 覆盖：`editor_typography_test.dart` 的「整像素」组钉住 14/16/18 下的字号 /
  行盒 / 行距 / 标题上下间距；`line_height_metrics_test.dart` 用**真渲染几何**
  钉住行距公式与整像素。
- ⚠️ 边界：**"是否发虚"是光栅化观感**——widget 测试用测试字体（不走真实字形
  光栅化、也没有亚像素 AA），测不了，只能人眼在 400% 放大截图里对比。

### 对照鸿蒙 PC：符合与不符合（诚实清单）

| 鸿蒙 PC 规范 | 我们 | 结论 |
|---|---|---|
| Title / Subtitle / Body 字号阶梯 | 阶梯同向、档距相近（正文取 14 时 = 25 / 20 / 17，规范是 28 / 22 / 18——我们整体小一档） | ⚠️ 有意偏小 |
| Title = **Bold** | 声明 w600，Windows 上渲染命中雅黑 Bold | ⚠️ 声明值不同、渲染等效 |
| Subtitle = **Medium** | h4~h6 用 w600 | ⚠️ 略重于规范 |
| Subtitle_S = 12vp | 钳到 1.0（= 正文） | ❌ 有意偏离 |
| Body = 14 **Regular** | 字重 ✅；字号默认 16 且用户可调（含 14） | ✅ / ⚠️ |
| 排版五项要求 | 齐（第五项"支持系统大字体"：`EditorStyle.textScaleFactor` 接 `MediaQuery.textScalerOf`） | ✅ |
| 中文段落规则（避头尾、标点悬挂、标点连用、中西文自动空格、**中文两端对齐**、行长缩进、避免孤立字） | **做不到** | ❌ **引擎层缺口** |

> 关于"两端对齐"：鸿蒙那套建立在**排版引擎**上（带标点挤压 / 避头尾 / 悬挂），而
> Flutter 的 `TextAlign.justify` 只是把空白均分到字间、没有任何标点处理——会正好
> 得到 **Apple 规范明令警告**的"字距忽宽忽窄"。故保持左对齐（官方默认）。

**结论（准确表述）**：**排版参数已对齐（字号 / 字重 / 间距 / 无障碍五项）**
；**中文段落排版规则那一章做不到**——它是引擎级能力，不是配置项。
所以"完全符合鸿蒙 PC 设计标准"不成立，准确说法是「参数对齐 + 段落规则受引擎限制」。

---

## 下一步

1. ~~人工跑完 ① 与 ④ 的视觉项~~ → **① 已通过**；④ 的 Mica 观感需在
   **真实应用**里再看一眼（不阻塞迁移，与编辑器选型无关）。
2. ~~接回 `HomeScreen`、删除 spike 页~~ → **已完成**（2026-09-10）。
3. ~~进入迁移主线：数据层解耦（`note_content.dart` 等 12 个 quill 依赖文件）→
   编辑器视图 + 工具栏 → 自定义块组件（代码块 / 公式 / 附件）。~~ → **已完成**
   （2026-09-10）：数据层**读入侧不再依赖 flutter_quill**；编辑器视图 / 工具栏 /
   目录 / 搜索全部换成 appflowy 侧实现或官方能力；自定义块组件就位。收尾时把
   quill 文件归档、依赖摘除（见下一节）。

> 迁移落地后请重跑本文档的两份人工清单（① 的输入法回归项、④ 的 Mica 观感）。

---

## quill 归档（2026-09-10）

编辑器只剩 appflowy 一个。quill 视图及其专属文件**整体移出 `lib/`、保留在
仓库里**（不删，便于比对与回退），依赖也从 `pubspec.yaml` 摘除。摘除后
`flutter analyze` 干净、全量测试通过（103 passed / 1 skipped）。

### 归档位置与清单

`archive/quill/src/notes/`——**镜像 `lib/src/notes/` 的相对结构**，
所以"搬回去"即可恢复文件间的相对 import：

| 文件 | 作用 |
|---|---|
| `note_editor_view.dart` | quill 版编辑器视图（工具栏 / 目录 / 搜索 / 右键菜单的装配） |
| `note_format_toolbar.dart` | quill 版工具栏 |
| `note_search_bar.dart` | quill 版查找/替换 |
| `note_toc_panel.dart` | quill 版目录面板 |
| `note_attachment_embed_builder.dart`、`note_hr_embed_builder.dart`、`note_formula_embed_builder.dart`、`note_image_embed_builder.dart` | quill 的嵌入块渲染 |
| `note_link_dialog.dart` | quill 的链接编辑对话框 |
| `note_context_menu.dart` | 自绘右键菜单（仅被上面几个 quill 文件使用） |
| `note_code_syntax.dart` | **原件快照**：含只供 quill 的逐段入口 `buildCodeAwareSpan`；留在 `lib/` 的那份已摘掉该入口（appflowy 的 `buildHighlightedCodeSpan` 留用），故整份留档备查 |

`analysis_options.yaml` 已 `exclude: archive/**`：归档文件 import 的
`flutter_quill` 已不在依赖里，不排除会分析报错。

### 随归档摘除的依赖

`flutter_quill: 11.5.1`、`quill_native_bridge: 11.2.0`、`url_launcher`
（只被 quill 视图直用；appflowy 侧由 vendored 包自己声明），以及
`dependency_overrides: flutter_quill → third_party/flutter_quill`。

> 本地补丁版 `third_party/flutter_quill`（给 `text_line.dart` 加
> `forceStrutHeight`，修空行高度差）**目录仍保留在磁盘上**，不再参与构建。
> 将来若回退 quill，**这条 override 要一起恢复**，否则那个空行高度差的
> bug 会回来。

### 恢复步骤（文件保留的用途）

1. `Move-Item archive/quill/src/notes/*.dart lib/src/notes/`
2. `pubspec.yaml` 加回 `flutter_quill`、`quill_native_bridge`、`url_launcher`
   与那条 `dependency_overrides` → `flutter pub get`
3. `editor_switch.dart` 改回两视图分支（`kUseAppFlowyEditor`）
4. 用归档快照覆盖 `note_code_syntax.dart`（quill 的逐段入口在里面）

### 两处**不**随归档消失的事

- **存量 Delta 笔记**：读入时由 `NoteDocumentAdapter` 转成块树，**编辑保存即
  改写为块树、不可逆**（只打开不编辑不会动它）。
- **`third_party/flutter_quill`**：保留备查，见上。
