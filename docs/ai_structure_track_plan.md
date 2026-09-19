# A 阶段落地方案：结构轨最小闭环（2026-09-19）

> 上游调研见 [`ai_canvas_research.md`](./ai_canvas_research.md)。本文只讲**怎么落地**。
> 结论口径沿用调研：**读可双轨，写只能结构化**。本阶段**只做写（结构轨）**，不碰像素轨。

## 一、范围

| | 内容 |
|---|---|
| **做** | 选区/视口 → 结构摘要 → LLM → **typed actions** → 净化 → 应用 → **一次撤销可回滚** |
| **不做** | 像素轨（栅格化 / SoM 编号 / 多模态模型）；新建 `blocks` 行（见 §5 的范围裁剪）；流式应用 |
| **验收** | 输入一句指令，画布上出现/移动/连线/删除若干元素，且 **Ctrl+Z 一次全撤销** |

## 二、前置：sinan 目前**没有任何 LLM 通道**（必须先补）

⚠️ 这一条我上一轮说错了（把 askia 的 Ollama 链路当成了 sinan 的）。**实际的 sinan**：

- `lib/` 下**没有** `rust/`、没有 Ollama/OpenAI 客户端、没有 `chat` 相关代码；
- 唯一的网络代码是内核里的 `HttpAiGenerator`（`canvas_ai.dart:229`，`dart:io HttpClient`，手写 multipart）；
- `database.dart:131` 的注释：「留到**接入 Ollama（含嵌入）**那一步」——即**计划中、未实现**。

所以 A 阶段多一个前置：**一个最小的 LLM 客户端**。好消息是它有现成范式可抄（`HttpAiGenerator`：`dart:io HttpClient` + 超时 + 手写 JSON，**零新依赖**）。

### 2.1 Ollama 的接口契约（已核实一手文档）

来源：<https://docs.ollama.com/api/chat>

| 要点 | 值 |
|---|---|
| 端点 | `POST http://localhost:11434/api/chat` |
| 必填 | `model`、`messages`（`{role, content}` 数组） |
| **`stream`** | **默认 `true`**；要一次性完整 JSON 必须**显式传 `false`**（否则拿到的是 NDJSON 流） |
| **`format`** | 传 `"json"`，**或直接传一个 JSON Schema 对象**来约束字段结构 |
| 响应 | `message.content`（另有 `thinking` / `tool_calls` / `images`） |
| 错误码 | 该页只记载 `200`（错误体在单独的 Errors 页，未核实） |

**关键红利**：`format` 接受 **JSON Schema** ⇒ 我们不必靠"请只输出 JSON"这种祈祷式提示词，而是把 action schema 直接钉进请求。**这是本阶段可靠性的一半来源。**

## 三、文件清单

### 新增

| 文件 | 职责 | 层 |
|---|---|---|
| `lib/src/ai/llm_client.dart` | `LlmClient` 抽象 + `OllamaLlmClient`（`/api/chat`，`stream:false`，`format: schema`）+ 两个纯函数（请求体 / 响应解析） | 基础设施 |
| `lib/src/canvas/ai/ai_action.dart` | `AiAction` 密封类族 + 容错解析（`tryParse` / `parseReply` / `extractJsonObject`）+ `NormPoint`/`NormRect` + **JSON Schema** | 纯数据 |
| `lib/src/canvas/ai/ai_inventory.dart` | 净化/应用共用的**画布现状快照**（item/卡片/连线/连线键 + 候选块白名单 + 视口） | 纯数据 |
| `lib/src/canvas/ai/ai_prompt.dart` | 系统提示词 + **上下文文本**（`buildCanvasContext`）+ 元素描述/归一化（纯函数） | 纯函数 |
| `lib/src/canvas/ai/ai_sanitize.dart` | 净化层（§4.4）+ 默认尺寸常量，**纯函数** | 纯函数 |
| `lib/src/canvas/ai/ai_apply.dart` | 把动作应用到 `CanvasDocument`（§4.5） | 内核侧 |
| `lib/src/canvas/ai/ai_run.dart` | 全链路编排：上下文 → 模型 → 解析 → 净化 → 应用（+ 修复重试） | 编排 |
| `lib/src/canvas/canvas_ai_button.dart` | 工具条「AI」按钮 + 一句话输入浮层 | UI |

> 注：schema 与提示词**刻意与各自的解析器/动作表放在一起**（`ai_action.dart` /
> `ai_prompt.dart`），因为它们必须同步演进——分开放迟早漂移，而漂移的症状
> （"模型照着输出、解析器认不出"）最难查。

### 改动

| 文件 | 改动 |
|---|---|
| `canvas_document.dart` | **新增批量命令** `batch()` + `_BatchCommands`（§4.6）——A 阶段的硬前置 |
| `domain/settings.dart` | 新增 `aiEnabled` / `aiEndpoint` / `aiModel` 三个字段 + `defaultAiEndpoint` + 三个 key |
| `app/providers.dart` | `llmClientProvider`（watch 设置 ⇒ 改端点/模型立刻换新客户端）+ 三个语义 setter |
| `canvas/canvas_note_view.dart` | 装配 AI 流程（搜候选块 / 取块文本 / 弹结果与「撤销」） |
| `canvas/canvas_surface.dart` | `onAiRun` 参数 + 工具条挂 `CanvasAiButton`（`onAiRun == null` 时不渲染） |
| `app/settings_panel.dart` | 新增「AI」分区（开关 + 服务地址 + 模型；文本框**提交时才落盘**） |
| `test/theme/app_theme_test.dart` | 修一条**过期断言**（见 §5 末）：浮层三件套改造后 Material 的 elevation 必须为 0、投影断言移到外层 `DecoratedBox` |

## 四、核心设计

### 4.1 送给模型什么（**纯文本，本阶段无像素**）

```
你是画布操作助手。只输出 JSON。

## 画布现状（坐标均为**视口归一化**，见下）
视口世界矩形: [l=−120.0, t=40.0, r=880.0, b=640.0]
元素:
  item-3  card    "番茄工作法"        rect=[0.10,0.10,0.30,0.22]  blockId=blk-7
  item-5  shape   rectangle           rect=[0.40,0.15,0.55,0.30]
  item-8  mindmap "学习法"（3 节点）   rect=[0.05,0.40,0.45,0.75]
  item-9  group   "方法论"            rect=[0.02,0.05,0.60,0.80]
连线: blk-7 → blk-11 (arrow)

## 可引用到画布的块（来自块库搜索）
  blk-12  "艾宾浩斯遗忘曲线…"
  blk-15  "间隔重复的三种实现…"

## 用户指令
把这两个概念摆到右边并连起来
```

三个要点：

1. **元素清单本身就是"结构摘要"**，字段只有 `id / type / 摘要文本 / 归一化 rect`——正是 tldraw agent 的 "视口内 shape 的简化表示"。
2. **候选块**由 `NoteStore.searchBlocks(query, limit:)` 提供（现成 API，全库扁平搜索）。模型只能引用**已存在**的块（§5）。
3. 笔迹只报"有条数 + 包围盒"，**不进文本**（笔迹没有语义，且量大）。

### 4.2 模型吐什么（action schema）

```json
{"actions":[
  {"op":"reference_block","blockId":"blk-12","at":[0.62,0.18]},
  {"op":"reference_block","blockId":"blk-15","at":[0.62,0.42]},
  {"op":"connect","from":"blk-12","to":"blk-15","endShape":"arrow"},
  {"op":"add_shape","kind":"rectangle","rect":[0.58,0.10,0.95,0.55],"color":"theme"},
  {"op":"set_text","id":"item-3","text":"番茄工作法的四条规则"},
  {"op":"move_item","id":"item-5","at":[0.05,0.60]},
  {"op":"add_mindmap","rect":[0.05,0.60,0.45,0.95],"root":"复习策略","children":["当天","隔日","一周后"]},
  {"op":"group","ids":["item-12","item-13"],"label":"概念"},
  {"op":"delete","ids":["item-5"]}
]}
```

| op | 参数 | 落到哪个既有 API | 状态 |
|---|---|---|---|
| `reference_block` | `blockId`, `at:[x,y]` | `document.addItem(CardItem(rect:, blockId:, text:))` | ✅ A3 |
| `add_shape` | `kind`, `rect` | `document.addItem(ShapeItem(..., color: kThemeInk))` | ✅ A3 |
| `add_mindmap` | `rect`, `root`, `children[]` | `document.addItem(MindMapItem(rect:, root: MindNode(...)))` | ✅ A3 |
| `move_item` | `id`, `at:[x,y]` | `document.setItemTransforms`（只挪位置、不改尺寸） | ✅ A3 |
| `connect` | `from`/`to`（**blockId**）, `endShape?` | `document.addEdge(CanvasEdge(...))` | ✅ A3 |
| `delete` | `ids[]` | `document.removeItems` | ✅ A3 |
| `set_text` | `id`, `text` | `item.text = ...` | ⚠️ **默认关闭**（见 §5） |
| `group` | `ids[]`, `label?` | `document.addItem(CanvasGroupItem(...))` + `document.setItemGroupIds` | ✅ A6 |
| `ungroup` | `ids[]`（填分组框 id） | 同上（解绑 + `removeItems`） | ✅ A6 |

**没有 `add_card{text}`** —— 理由见 §5。
**`group` / `ungroup` 在阶段 A 曾从 `kAiActionOps` 移除**（当时文档层还没有成员关系 API），**A6 已归队**。

### 4.3 坐标：**视口归一化 `[0..1]`**（本阶段最重要的一个决定）

模型给绝对坐标必错（LLM 空间能力弱，这是 OmniParser / SoM 两篇论文的出发点）。
所以**钉死**：所有 rect / at 都是**相对当前视口世界矩形**的 `0..1` 归一化值，由确定性代码换算：

```dart
Rect toWorld(Rect viewportWorld) => Rect.fromLTRB(
  viewportWorld.left + l * viewportWorld.width,
  viewportWorld.top  + t * viewportWorld.height,
  viewportWorld.left + r * viewportWorld.width,
  viewportWorld.top  + b * viewportWorld.height,
);
```

> 这条就是调研里 tldraw `removeOffsetFromShapePartial`（坐标空间转换）的对应物。
> 差别是 tldraw 让模型给**页面坐标**再转换；我们让它给**归一化坐标**，对 LLM 更友好。

### 4.4 净化层（照 tldraw 的 sanitization layer，**必做**）

`ai_sanitize.dart` 全部纯函数，规则：

| 规则 | 处理 |
|---|---|
| `op` 不认识 / 字段类型不对 | **丢弃**（不抛） |
| `id` 不存在于当前文档 | 丢弃该 action |
| `blockId` 不在候选集内 | 丢弃（**不允许凭空造块**） |
| 归一化值越界 | 先 `clamp(0,1)`；换算后再钳进 `内容包围盒 ∪ 视口`（外扩 25%） |
| `rect` 退化（宽/高 < 视口 1%） | 补到默认尺寸（视口 15%×10%） |
| 世界尺寸 < `CanvasHandles.minSize` | 提到下限 |
| `connect` 端点缺失 / 自连 | 丢弃（与 `edgesIn`「任一端缺失就不返回」的既有口径一致） |
| `group` 成员不足 2 或含 group 自身 | 丢弃 |
| action 总数 | 上限 **50**，超出截断并记 warning |
| 同一 `id` 上的重复 `move_item` | 取最后一条 |

返回值带 `warnings`，由宿主汇总成一条 SnackBar（**不做静默丢弃**）。

### 4.5 应用层与**一次撤销**

```dart
/// 一次调用 = **一条**撤销命令（见 §4.6 的 batch）。
AiApplyResult applyAiActions(
  CanvasDocument doc,
  List<AiAction> actions, {
  required Rect viewportWorld,
  required String Function(String blockId) blockTextOf,  // 仅 reference_block 取文本
});
```

要点：
- 全程**只走既有文档 API**（`addItem` / `setItemTransforms` / `addEdge` / `removeItems`），不新增存储语义；
- `reference_block` 造的是**引用卡片**（块仍留在文档，即"双链多视图"）——`CanvasNoteView` 已有的 `_syncedCardTexts` / `pullCardText` / `_replaceCardBlocks` 链路**自动接管**文本同步，无需新代码；
- 落盘时 `updateContent` → `_canvas.replaceCanvasRows` 会把新卡片投影进 `canvas_items`，其 `block_id` 指向**已存在**的块 ⇒ 外键成立。

### 4.6 硬前置：`CanvasDocument` 缺**批量命令**

现状（`canvas_document.dart:628`）：`CanvasCommand` 只有单条 `undo`/`redo`，`_push` 一次一条。
⇒ AI 应用 8 个 action 会产生 **8 条**撤销记录，用户要按 8 次 Ctrl+Z。这不可接受。

新增（约 25 行，照 tldraw 的 `editor.run()` 思路）：

```dart
/// 把 [body] 里产生的所有命令合并成**一条**。
///
/// 期间不清重做栈（留到收尾一次性清），也不做暂存回收——否则批中间态会被误判为垃圾。
void batch(void Function() body);

/// 组合命令：撤销**逆序**、重做**顺序**，retainedIds 取并集。
class _BatchCommand implements CanvasCommand { ... }
```

改 `_push`：批处理期间把命令收进 `_batching` 而不是入栈。

## 五、范围裁剪：为什么 A 阶段**不做** `add_card{新文本}`

数据层**没有**创建 `blocks` 行的 API（已核实：`data/` 下无 `createBlock` / `insertBlock` / `addBlock`）。
`blocks` 行是由**编辑器的块树**经 `BlockStore.replaceNoteBlocks(noteId, content)` 产出的。
`CardItem.blockId` 是指向 `blocks(id)` 的外键（`canvas_items.block_id ... ON DELETE CASCADE`），凭空造卡片会挂空。

所以 A 阶段：

- ✅ `reference_block`：把**已存在的块**引用到画布 → 复用 `NoteStore.searchBlocks` + `CardItem`，**零新 API**；
- ⏳ `add_card{text}`：留到 **A.2**。前置条件 = 数据层暴露一个 `createTextBlock(noteId, text) -> blockId`（约 30 行：插 `blocks` 行 + 追加进块树 JSON + `replaceNoteBlocks`）。

**而且 `reference_block` 本身就是高价值能力**：「把这些相关块摆成一张图」正是结构化 AI 对笔记应用的核心用途（tldraw 的 Mermaid→shape 同思路，只是我们的"DSL"是笔记库本身）。

### 实施中又撞到的两处缺口（A3 收口）

| 缺口 | 证据 | 处置 |
|---|---|---|
| ~~**分组做不到**~~ | ~~`CanvasItem.groupId` 是 **`final`**；全项目只在构造器 / `fromJson` 里写它，**没有**"把 item 加进分组框"的运行时 API~~ | ✅ **A6 已关闭**：`groupId` 改为可变（照 `colorSlot`）、文档层补 `setItemGroupIds`（带撤销命令）、应用层实现 `group` / `ungroup`、`kAiActionOps` 归队。**顺带修掉一个隐患**：删分组框时成员会留下指向不存在分组的悬空 `groupId` —— 现在 `removeItems` 把"解绑"与"删框"放进**同一条**命令（照它既有的"卡片被删连带删连线"范式） |
| **`set_text` 不可撤销** | 卡片文本不进撤销栈（`_replaceCardBlocks` 只在落盘时把 `text` 写回 `blocks`）；全应用**还没有**任何文本编辑的撤销通道 | 净化层加 `allowTextRewrite`（**默认 false**）：唯一会**覆盖用户已有内容**的动作，没得撤销就不该默认允许。它仍留在词汇表里（显式开闸即可用） |

### 顺带修掉的一条过期断言（与本阶段无关，但挡住了全绿）

`test/theme/app_theme_test.dart` 的「浮层三件套」还在断言 `Material.elevation ==
AppTheme.menuElevation`（=6）。但 `app_float_surface.dart` 已改为
**Material 归零 + 外层 `DecoratedBox` 双层软阴影**（注释写明理由：elevation 只有单层
固定投影，出不来"贴地影 + 环境影"，且与外层影子叠加会发脏）。于是断言按新意图更新为：
`elevation == 0`，并把"投影"这条断言移到外层 `DecoratedBox.boxShadow ==
AppTheme.floatShadows(brightness)`。

### 附带影响：画布视图现在依赖设置

`CanvasNoteView.build` 要 `ref.watch(settingsProvider)` 决定 AI 入口是否出现 ⇒
凡是 pump `CanvasNoteView` 的测试都必须注入 `settingsStoreProvider`（否则那个
"在 main 中 override"的守卫会直接抛）。已补：`canvas_import_test.dart`、
`canvas_note_save_path_test.dart`（`settings_panel_test` / `accessibility_test` 本就有）。

## 六、测试清单（闸门）

| 文件 | 覆盖 | 状态 |
|---|---|---|
| `test/canvas/canvas_batch_undo_test.dart` | 7 例：一次撤销回滚整批（含逆序）；批中途不入栈；嵌套只产生一条；**`retainedIds` 并集**（少了它撤销后元素回不来）；收尾才清重做栈；body 抛异常仍可撤销 | ✅ |
| `test/canvas/ai_sanitize_test.dart` | 31 例：未知 op / 越界坐标 / 反向与退化 rect / 缺失 id / 自连 / 重复 move / 重复引用 / 上限截断 / **批内投影态** / 两个政策闸门 —— **每条规则一个用例** | ✅ |
| `test/canvas/ai_apply_test.dart` | 12 例：每种 op 落到正确 API；引用卡片带对 `blockId` 与块文本；尺寸按视口比例；**一批 = 一条撤销命令**；应用期竞态不抛 | ✅ |
| `test/canvas/ai_action_test.dart` | 16 例：`parseReply`（围栏/闲话/**坏条目丢一条**/`null` 与 `[]` 的区别）+ `extractJsonObject` + `buildCanvasContext`（归一化 rect、笔迹只报条数、候选块、视口未知） | ✅ |
| `test/ai/llm_client_test.dart` | 14 例：请求体含 `stream:false` 与 `format` 对象、消息角色顺序；响应解析三种失败；**真起本地 HttpServer** 验请求形状 + 非 200 / 连不上 / 未配模型各自的报错 | ✅ |
| `test/canvas/ai_run_test.dart` | 8 例（假 `LlmClient` 跑通全链路）：正常一轮、**整轮一条撤销**、修复重试（含"不该白重试"）、重试后成功、后端异常原样抛、白名单外引用被丢但整批仍落地 | ✅ |

> 注：`batch` 是**文档层**能力（不专属 AI），所以它的闸门放在 `canvas_batch_undo_test.dart`
> 而不是 `ai_*` 系列里；将来别处用到 `batch` 也能被它守住。

> 沿用仓库既有做法：**纯函数优先**（sanitize / inventory / action 解析都是纯函数，不需要 widget 测试）。

## 七、落地顺序（每步可独立验证）

| 步 | 内容 | 验证 | 状态 |
|---|---|---|---|
| **A1** | `CanvasDocument.batch` + `_BatchCommands` | `canvas_batch_undo_test.dart`（一次撤销整批） | ✅ |
| **A2** | `ai_action.dart`（schema + 解析）+ `ai_sanitize.dart` + `ai_inventory.dart` | `ai_sanitize_test.dart`（31 例） | ✅ |
| **A3** | `ai_apply.dart`（各 op → 既有文档 API） | `ai_apply_test.dart`（12 例） | ✅ |
| **A4** | `llm_client.dart` + 设置项 + `llmClientProvider` | `llm_client_test.dart`（14 例，含真 HTTP） | ✅ |
| **A5** | `ai_prompt.dart` + `ai_run.dart` + `canvas_ai_button.dart` + 宿主装配 | `ai_action_test.dart` / `ai_run_test.dart` | ✅ |
| **A6** | 分组：`groupId` 改可变 + `setItemGroupIds` + 删框自动解绑 + 两个 op 归队 | `canvas_group_membership_test.dart` + `ai_apply_test.dart` 分组用例 | ✅ |

**全部完成（A1~A6）**：`flutter analyze` 零问题、`flutter test` **717 passed**。

### 怎么用起来

1. 本机跑 Ollama：`ollama pull qwen3.5`（或任意能输出 JSON 的模型）；
2. `设置 → AI`：打开**启用画布 AI**，服务地址默认 `http://localhost:11434`，填模型名；
3. 画布底部工具条出现 ✨ 按钮 → 输入一句话（如「把这两块摆到右边并连起来」）→ 运行；
4. 改动会**自动选中**（看得见改了哪些），SnackBar 上有「撤销」——**一次 Ctrl+Z 回滚整批**。

## 八、风险与未决

| 风险 | 缓解 |
|---|---|
| LLM 给出听不懂的指令 / 空 actions | 应用 0 个 action 时明确提示「未产生任何改动」，不回退成报错 |
| LLM 改写用户卡片文本（`set_text` 有破坏性） | ① 全部动作是**一条**撤销命令，SnackBar 上带「撤销」按钮；② 净化层可配置"`set_text` 默认关闭"开关 |
| `format: json` 仍可能返回坏 JSON | 一次**修复重试**（把坏输出 + 错误回传，要求只输出 JSON）；再失败则中止并提示 |
| 归一化坐标下元素重叠 | 净化层加**简易去重**：`reference_block` 的 `at` 相距 < 卡片默认宽高 50% 时，按 y 轴顺延排布 |
| Ollama 未运行 | `OllamaLlmClient` 抛明确异常（"Ollama 未运行：连不上 localhost:11434"），设置面板给可点链接 |
| 模型能力不足（本地小模型吐不出合规 JSON） | 这是 A 阶段最大的不确定性。**先用 `format` 传 JSON Schema** 兜；仍不行则换更大的本地模型或云端 API（`LlmClient` 是抽象，换实现不动上层） |

## 九、与调研文档的对应

| 调研里的结论 | 本方案里的落点 |
|---|---|
| 读可双轨、**写只能结构化** | 本阶段只做写（结构轨） |
| tldraw 的 sanitization layer 是结构派**全部工程难点** | §4.4 净化层 + 独立测试文件 |
| tldraw 的坐标空间转换 | §4.3 视口归一化 |
| typed action schemas | §4.2 |
| 一次操作 = 一次可撤销（`editor.run`） | §4.6 `CanvasDocument.batch` |
| 候选块 = 我们的"DSL"（对应 Mermaid→shape） | §5 `reference_block` |
| 像素轨（SoM / 栅格化 / mask） | **不在本阶段**，留 B/C |
