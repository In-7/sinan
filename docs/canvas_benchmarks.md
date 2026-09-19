# 无限画布标杆对照笔记（AFFiNE / tldraw / Excalidraw / JSON Canvas）

> **目的**：给 sinan 画布找**可落地**的设计参考。
> **纪律**：只采信**一手来源**（官方文档、开放规范、官方博客），每条结论标注出处；二手解读一律标明。
> **调研日期**：2026-09-18。
> **范围**：`AFFiNE(+BlockSuite)`、`tldraw`、`Excalidraw`、`JSON Canvas 1.0`。
> **不覆盖**：Flutter 侧画布库（已另有结论，见 `canvas_architecture.md` 第一章"为什么不用第三方画布底座"）。

---

## 0. 先给结论（TL;DR）

| 标杆 | 一句话 | 最值得拿的 | 不建议拿的 |
|---|---|---|---|
| **AFFiNE / BlockSuite** | 文档与白板是**同一批 block** 的两种渲染模式 | ① note block 作为 doc↔canvas 的桥；② "块是原子单位，不是文件" | 推翻我们的 `flow/canvas` 双载体去追"同一棵树"（存储/编辑器/迁移全动） |
| **tldraw** | 画布引擎 = **响应式 Store + 记录 + 绑定 + 输入状态机** | ① binding 是**一等记录**（我们已同构）；② **事务**合并为单次撤销（我们已同构）；③ 工具用**状态机**而非枚举 | 引入其代码（React/Web 栈，我们是 Flutter 自研内核） |
| **Excalidraw** | 元素模型 + **双向登记的绑定** + 极简文件格式 | ① `startBinding`/`endBinding` + 被绑元素上的 `boundElements` **双向登记**；② 文件 `version` + 迁移意识 | 内嵌图片用 base64（我们外置文件 + 相对引用更省） |
| **JSON Canvas 1.0** | **最小的开放画布格式**（Obsidian 发起） | ① `fromSide/toSide`（我们已有，**完全一致**）；② **语义色预设**（值故意不定义，交应用按品牌定）；③ `group` 容器节点 | 数组顺序表达 z 序（我们有显式 `itemOrder`，更清楚） |

**最重要的一个判断**：我们现在的数据模型（`CanvasEdge` 存 id 不存坐标、参与撤销、驱动联动）与 tldraw 的 binding **已经同构**；真正值得动的不是"换模型"，而是 AFFiNE 的那条产品洞察——**"块是原子单位，不是文件"**。

---

## 1. AFFiNE（+ BlockSuite）——"一份 block 数据，两种视图"

### 1.1 是什么

开源、本地优先的知识工作台，定位"Notion + Miro"。它有 **Page（文档）** 与 **Edgeless（无边界/白板）** 两种模式，且**一键互转、双向同步**。

### 1.2 一手来源与关键原文

来源：[AFFiNE 官方博客 "Why you should try AFFiNE whiteboard - Edgeless Mode"](https://affine.pro/blog/why-you-should-try-affine-whiteboard-edgeless-mode)（发布 2025-03-07）

官方原文（TECHNOLOGY HIGHLIGHTS 一节）：

> 第二次开发基于 **TLDraw**，使用 **Zustand** 管理状态，并使用**与文档部分相同的 JWST 持久化**来存储数据。文本编辑部分**复用了文档的代码**，并在幕后做了大量工作以确保**同一份代码在两端都能正常工作**。

同页页脚给出许可证：

> ©2026 Toeverything · **MIT (most code)** · **AFFiNE EE (backend)**

即：**大部分代码 MIT**，后端/企业版走单独的 EE 许可。

底层框架是 **BlockSuite**。二手来源（[BlockSuite Note Block 解析](https://blog.gitcode.com/a35ad640593ea56bc0b8f517b24990d2.html)）描述 `affine:note`：

> Note Block（`affine:note`）是一个承载流式文档内容的容器块，它既是页面（Doc）编辑器中全部正文的**唯一容器**，在 edgeless 模式下**作为画布上的一个元素**。

### 1.3 关键设计（我们能吸收的）

1. **块是原子单位，不是文件**。传统工具里"文档"和"白板"是两种文件、各自 schema；AFFiNE 里一段文字、一张图、一个白板都是**同一个 block**。
2. **note block 是桥**：同一个 note block，在 doc 模式下**按文档流排布**，在 edgeless 模式下**作为画布元素摆放**。这就是"两种视图消费同一份数据"的物理实现。
3. **持久化层与文本编辑代码复用**：不是两套实现，是同一套代码跑在两种渲染模式上。

### 1.4 对照 sinan

| | AFFiNE | sinan 现状 |
|---|---|---|
| 载体 | **一种数据，两种视图** | **两种载体**：`notes.kind = flow \| canvas`，各有一套 schema |
| 块 | 唯一原子单位 | flow 用 blocks 树；canvas 用 `canvas_items` + `canvas_edges` + `canvas_meta` |
| 桥 | note block | **卡片 CardItem 已经在做这件事**：内容存 `blocks`（`type='card'`）、几何存 `canvas_items`，靠 `block_id` 关联 |

**我们已经有个"半个桥"**：画布卡片的**内容**就在 `blocks` 表里，和文档块**同一张表**。这正是 AFFiNE 精神的**最小实现**。

### 1.5 能落地的

- **【中，高价值】把"桥"从卡片扩展到"块可迁移/可引用"**：既然卡片内容已是 block，就可以做
  ① 文档块 → 拖到画布变卡片（同一 blockId 换个视图）；
  ② 画布卡片 → 在文档里以引用/嵌入出现。
  这条不需要推翻现有架构，是**渐进融合**，且直接回应"两个载体到底什么关系"。
- **【低】思维导图节点已经走在同一条路上**：Phase 2 计划把节点树投影到 `blocks.parent_id` —— 与"块是原子单位"完全一致，保持这个方向即可。

### 1.6 不建议

**不要**为了"同一棵树"推翻现有双载体。代价是存储层、编辑器、迁移全动，而收益要靠长期验证。AFFiNE 自己也经历了"第二次开发"，且它的编辑器与我们是不同技术栈（它前端 TS/React 生态、我们 Flutter + appflowy_editor）。**渐进融合 > 推倒重来。**

---

## 2. tldraw —— 记录 + 绑定 + 输入状态机

### 2.1 一手来源

来源：[tldraw 官方文档 Editor 页](https://tldraw.dev/docs/editor)（页面标注 Last edited 2023-03-22；v2 系列文档）。

官方对该页能力的原文表述（表格）：

| 领域 | 主题 | 官方描述 |
|---|---|---|
| Data | **Store** | The reactive database holding all records（持有全部 records 的**响应式数据库**） |
| Data | **Shapes** | Create, read, update, and delete shapes |
| Data | **Bindings** | **Relationships between shapes**（形状之间的关系） |
| Interaction | **Tools** | **The state machine that handles user input**（处理用户输入的**状态机**） |
| State | History | 撤销、重做与历史管理 |
| Output | Image export | 导出 SVG / PNG |

关于事务，官方原文要点：每次修改都发生在**一个 transaction** 内，`Editor.run` 可把多次修改合并为**单个事务**，好处是**合并为单个撤销步骤**并降低持久化开销；`run` 支持 `{ history: 'ignore' }`（不记入撤销栈）等选项。

并发/协作、records 的具体类型清单、bindings 的生命周期 API 在**本页只有一句话**，需查 Store / Bindings / Tools 各专章（正文已注明）。

### 2.2 对照 sinan —— 大部分已经同构

| tldraw | sinan | 结论 |
|---|---|---|
| **Bindings = 形状之间的关系，一等记录、可持久化、参与撤销、驱动联动** | `CanvasEdge`：端点存 `blockId`（不存坐标）、独立表 `canvas_edges`、进撤销栈、拖卡片线自动跟随 | **已同构**。我们当初就是照它设计的（见 `canvas_edge.dart` 类文档） |
| **事务 `Editor.run` 合并为单次撤销** | `CanvasDocument` 的 `setItemTransforms`：一次手势一条命令（多 item 的 rect/angle 合成一条） | **已同构** |
| **Tools = 输入状态机** | `CanvasTool` **枚举** + `onPointerDown/Move/Up` 分支 | **不同**：我们用枚举 + 分支，工具内部状态（如连线拖拽中）靠零散字段（`_pendingFrom`、`_edgeGripEdge`…） |
| Store 是所有记录的**响应式**数据库 | `CanvasDocument`（内存对象）+ `ChangeNotifier` | 大体等价（我们的"响应式"由 controller 的通知承担） |
| Shape 有 `parentId`、`index`（同层排序） | `CanvasItem` **扁平**，无 parent | 差异（见第 6 节"分组框"） |

### 2.3 能落地的

- **【中】工具状态机化**：现在连线工具的内部状态是几个散落字段（`_pendingFrom / _pendingFromSide / _edgeGripEdge / _edgeGripIsFrom / _edgeGripCursor`），每加一种交互就多一个字段、多处 `if`。tldraw 用**树形状态节点**（工具内可嵌套子状态：idle → pointing → dragging）。等工具复杂度再上一个台阶（比如节点级连线、框选细化），值得把它改成"每工具一个状态对象"。
- **【低】bindings 分类型**：tldraw 的 binding 是**可扩展类型 + props**。我们的 `CanvasEdge` 已经有 `props` 与 `fromSide/toSide`，将来做"节点级连线"或"思维导图端口连线"时，沿用它扩展即可，不必新表。

### 2.4 不建议

引入 tldraw 代码。它是 React/Web 栈的 SDK，我们是 Flutter 自研内核；且其许可为**自定义许可（非 MIT）**，商用需自行核实条款。

---

## 3. Excalidraw —— 元素模型与双向绑定

### 3.1 一手来源

来源：[Excalidraw 官方开发文档 JSON Schema 页](https://docs.excalidraw.com/docs/codebase/json-schema)。

官方给出的 `.excalidraw` 顶层结构：

| 属性 | 说明 |
|---|---|
| `type` | 固定 `"excalidraw"` |
| `version` | schema 版本（数字） |
| `source` | 应用来源 URL |
| `elements` | 元素对象数组 |
| `appState` | 应用状态（如 `viewBackgroundColor`、`gridSize`） |
| `files` | 图片元素数据：`{ [fileId]: fileData }`，含 `mimeType / dataURL / created / lastRetrieved` |

页面另有对 `created`（元素创建时间，可为 `null` 且**不会**用加载时间顶替）的详细语义说明。

**元素级字段（`containerId` / `boundElements` / `startBinding` / `endBinding` / `angle`）该页未定义** —— 官方文档自己在示例里用注释省略了其余字段。因此这些字段的权威定义在源码类型文件（`ExcalidrawElement`）。二手来源（[DeepWiki: Excalidraw Element Binding System](https://deepwiki.com/excalidraw/excalidraw/3.2-element-binding-system)，二手，仅作交叉参考）描述其绑定系统：

> 箭头（与线）与"可绑定元素"之间的连接；箭头持 `startBinding`/`endBinding`，被绑元素在 `boundElements` 里**反向登记**。

### 3.2 对照 sinan

| Excalidraw | sinan | 结论 |
|---|---|---|
| 箭头持 `startBinding`/`endBinding` | `CanvasEdge.fromId/toId` | 一致 |
| 被绑元素上 `boundElements` **反向登记** | **无反向登记**：靠 `document.itemByBlockId()` **线性扫描**反查 | 差异（见下） |
| 元素 `x/y/width/height/angle` | `CanvasItem.rect` + `angle` | 一致 |
| `containerId`（元素被装进容器/框） | 无（`CanvasItem` 扁平） | 差异（同"分组框"） |
| `files` 内嵌 base64 | **外置文件 + 相对引用**（`MediaResolver`） | **我们更优**：JSON 不膨胀、可增量、可复用 |
| `version` + 迁移意识 | `canvas_meta.schema_version` 有，但**没有迁移函数链** | 差异（见下） |

### 3.3 能落地的

- **【低，规模到了再做】反向索引**：Excalidraw 在元素上登记 `boundElements`，是为了**快**（"这个元素连着哪些箭头"是高频查询）。我们目前线性扫描，边几十条无感；等边数/卡片数上一个量级，可在 `CanvasDocument` 里维护 `blockId → Set<edgeId>` 的索引（随增删更新）。
- **【中】画布 schema 迁移链**：Excalidraw 明确把 `version` 当契约。我们 `canvas_meta` 已有 `schema_version`，但**没有"版本 → 迁移函数"的机制**（数据库那边有 `userVersion` + 自愈，画布 JSON 这边缺）。**这条优先级要提**——它决定以后改画布格式会不会砸存量数据。

### 3.4 不建议

照搬 `files` 内嵌 base64。我们外置文件 + 相对引用的方案更适合桌面端（JSON 小、图片可独立管理、可增量保存）。

---

## 4. JSON Canvas 1.0 —— 最小的开放画布格式

### 4.1 一手来源

来源：[jsoncanvas.org/spec/1.0](https://jsoncanvas.org/spec/1.0/)（Obsidian 团队发起的开放格式，**Version 1.0，2024-03-11**）。

**顶层**（两个数组**均可选**）：

| 字段 | 类型 | 必需 | 说明 |
|---|---|---|---|
| `nodes` | array | 否 | 节点集合 |
| `edges` | array | 否 | 连线集合 |

**z 序**：不用显式字段，**`nodes` 数组顺序即层级**（第一个在最底层，最后一个在最顶层）。

**节点通用字段**：`id`(必需)、`type`(必需，`text`/`file`/`link`/`group`)、`x`/`y`/`width`/`height`(整数，必需)、`color`(可选)。

各类型专属：

- `text`：`text`（**支持 Markdown**）
- `file`：`file`(必需)、`subpath`(可选，**必须以 `#` 开头**，可指向标题或块)
- `link`：`url`(必需)
- `group`：`label`、`background`、`backgroundStyle`（`cover`/`ratio`/`repeat`）

**连线字段**：

| 字段 | 必需 | 说明 |
|---|---|---|
| `id` | ✅ | |
| `fromNode` / `toNode` | ✅ | 端点节点 id |
| `fromSide` / `toSide` | ❌ | `top`/`right`/`bottom`/`left` |
| `fromEnd` / `toEnd` | ❌ | 端点形状 `none`/`arrow`；**默认不对称**：起点默认 `none`、终点默认 `arrow` |
| `color` | ❌ | |
| `label` | ❌ | 连线的文本标签 |

**颜色 `canvasColor`**：字符串，两种形式——16 进制（如 `"#FF0000"`），或**预设编号 `"1"`~`"6"`**（red/orange/yellow/green/cyan/purple）。规范特别声明：

> 预设色的**具体色值被有意地未定义**，目的是让各应用按自身品牌色或配色方案自行调整预设。

### 4.2 对照 sinan —— 重合度最高的一份

| JSON Canvas | sinan | 结论 |
|---|---|---|
| `fromSide` / `toSide`（top/right/bottom/left） | `CanvasEdge.fromSide/toSide`（同名同义，可空 = 自动） | **完全一致** |
| `fromNode`/`toNode` 存 **id** | `fromId`/`toId` 存 **blockId** | 一致（我们把 id 具体化为"卡片内容块的 id"，见 `CanvasEdge` 类文档的 binding 说明） |
| `fromEnd`/`toEnd`（是否箭头） | 箭头**固定画在终点**（`EdgeGeometry.arrowPath`） | 差异：我们少一个"要不要箭头"的开关 |
| 预设色 1~6（值**故意不定义**，交应用按品牌定） | `kThemeInk` **哨兵色**（跟随主题墨色） | **理念一致**，但覆盖面不同（我们只墨色，它有 6 个语义槽） |
| `group` 节点（可视化容器，可带 label/背景） | 无 | 差异（同"分组框"） |
| `text` 节点支持 Markdown | 卡片文本（进 `blocks`，同文档块） | 方向一致 |
| `subpath` 以 `#` 指向**块** | 卡片 `blockId` 指向块 | **同一思路**（都是"指向文档里的块"） |
| z 序 = 数组顺序 | `items` map + **显式 `itemOrder` 数组** | 我们更显式，等价 |
| `nodes`/`edges` 可空 | `edges` 空则**不写这个键**（旧存档兼容） | 一致（甚至更谨慎） |

### 4.3 能落地的

- **【低】`fromEnd`/`toEnd`**：给 `CanvasEdge` 加"端点形状"（要不要箭头/双向箭头）。字段现成（`props` 或新列），UI 复用连线工具。
- **【中】语义色预设**：JSON Canvas 把 6 个语义色的**具体值留给应用**——这和我们"主题种子色 + 哨兵色"的思路天然契合。可以做"卡片/思维导图节点的语义色"（红/橙/黄/绿/青/紫），值由主题给，切主题自动变。**这是低成本高观感的一项**。
- **【中】`group` 容器节点 → 分组框**：把若干块框进一个"组"，整组拖动。三家（JSON Canvas 的 `group`、tldraw 的 frame/`parentId`、AFFiNE 的 frame）**都有** —— 说明这是画布的刚需，不是可选项。

### 4.4 不建议

用"数组顺序"表达 z 序。我们的显式 `itemOrder` 更好维护（插入/撤销回原位有据可依）。这一点我们比规范更严谨。

---

## 5. 横向对照表（vs sinan 现状）

| 能力 | sinan | AFFiNE | tldraw | Excalidraw | JSON Canvas |
|---|---|---|---|---|---|
| 连线存**id 而非坐标** | ✅ | ✅ | ✅ | ✅ | ✅ |
| 连线可空端口（自动选边） | ✅ | — | — | — | ✅（侧可空） |
| 连线**箭头开关** | ❌（固定终点箭头） | — | — | ✅ | ✅（fromEnd/toEnd） |
| 连线**标签** | ❌ | — | — | — | ✅（label） |
| 元素**双向绑定登记** | ❌（线性反查） | — | ✅（binding 记录） | ✅（boundElements） | — |
| **分组/容器**（frame/group） | ❌ | ✅ | ✅（parentId） | ✅（containerId） | ✅（group） |
| **语义色预设** | 仅墨色哨兵 | — | — | — | ✅（1~6） |
| 图片**外置引用** | ✅ | ✅ | ✅ | ❌（内嵌 base64） | ✅（file 路径） |
| **schema 版本 + 迁移** | 半（有版本号，无迁移链） | ✅ | ✅ | ✅ | ✅（Version 1.0） |
| 事务合并为单次撤销 | ✅ | — | ✅ | — | — |
| 工具**状态机** | ❌（枚举 + 分支） | — | ✅ | — | — |

---

## 6. 落地清单（按性价比排序）

| # | 项 | 借鉴自 | 成本 | 价值 | 备注 |
|---|---|---|---|---|---|
| 1 | **画布 schema 迁移链**（版本 → 迁移函数） | Excalidraw / AFFiNE | 低 | **高** | 数据库侧已有 `userVersion` + 自愈的先例；画布 JSON 侧缺失，**改格式就砸存量**，应尽早补 |
| 2 | **语义色预设**（红/橙/黄/绿/青/紫，值由主题定） | JSON Canvas | 低 | 高 | 与我们的哨兵色/主题种子色理念同源 |
| 3 | **连线的端点形状开关**（箭头/无/双向） | JSON Canvas / Excalidraw | 低 | 中 | 字段可走 `props`，UI 挂在连线工具上 |
| 4 | **分组框**（把若干块框成一组，整组拖动） | JSON Canvas `group` / tldraw frame / AFFiNE frame | 中 | **高** | 三家都有 ⇒ 刚需；需要给 `CanvasItem` 引入层级或独立"组"对象 |
| 5 | **块的可迁移/可引用**（文档块 ↔ 画布卡片） | AFFiNE（块是原子单位） | 中 | **高** | 我们已有"半个桥"（卡片内容在 `blocks`），是**渐进融合**的关键一步 |
| 6 | **工具状态机化**（工具内嵌套子状态） | tldraw | 中 | 中 | 现在靠散落字段；工具再复杂就该改 |
| 7 | **连线标签** | JSON Canvas | 低 | 低 | 需要文本输入 UI（卡片已有先例） |
| 8 | **反向索引**（blockId → edgeIds） | Excalidraw | 低 | 低 | 规模上来再做（现在线性扫描够用） |

---

## 7. 明确不做的事

1. **不推翻 `flow/canvas` 双载体**去追 AFFiNE 的"同一棵树"——代价是全栈重写，收益需长期验证。走"渐进融合"（清单 #5）。
2. **不引入 tldraw / Excalidraw 的代码**——React/Web 栈 vs 我们 Flutter 自研内核；且 tldraw 为自定义许可。**只借设计**。
3. **不改图片存储为内嵌 base64**——我们的外置文件 + 相对引用更适合桌面端。
4. **不用数组顺序表达 z 序**——保留显式 `itemOrder`。

---

## 8. 来源

一手：

- AFFiNE 官方博客（Edgeless Mode，2025-03-07，含许可证页脚）：https://affine.pro/blog/why-you-should-try-affine-whiteboard-edgeless-mode
- AFFiNE 官方站（产品定位与 Edgeless 说明）：https://affine.pro/blog/affine-app
- tldraw 官方文档 Editor：https://tldraw.dev/docs/editor
- Excalidraw 官方开发文档 JSON Schema：https://docs.excalidraw.com/docs/codebase/json-schema
- JSON Canvas 1.0 规范：https://jsoncanvas.org/spec/1.0/

二手（仅作交叉参考，未作为结论依据）：

- BlockSuite Note Block 解析（`affine:note` 在 doc/edgeless 两端的角色）：https://blog.gitcode.com/a35ad640593ea56bc0b8f517b24990d2.html
- DeepWiki: Excalidraw Element Binding System（`startBinding`/`endBinding`/`boundElements`）：https://deepwiki.com/excalidraw/excalidraw/3.2-element-binding-system

---

## 附：本笔记对 sinan 最直接的三条行动

1. **补画布 schema 迁移链**（清单 #1）——它是"改格式不砸数据"的前提，成本最低、风险收益最高。
2. **做语义色预设**（清单 #2）——提升观感一致性，且与现有主题体系同源。
3. **把"卡片 ↔ 文档块"的桥走通**（清单 #5）——这才是 sinan 相对四家的**独特位置**：我们同时有"流式文档"和"无限画布"，而 AFFiNE 证明了这条路能走通。
