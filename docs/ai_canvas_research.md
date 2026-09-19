# AI 画布：像素派 / 结构派 / 双轨（2026-09-19 调研）

> A 阶段的落地方案见 [`ai_structure_track_plan.md`](./ai_structure_track_plan.md)。

结论先行：**「像素 + 结构化双轨」不是折中，而是当前唯一被一手文档明确背书的做法。**
tldraw 官方 AI 文档原文（Reading canvas content 节）：

> "Sending both to the model works best: the image shows spatial relationships and styling,
> and the structured data gives exact text and positions."
> —— https://tldraw.dev/docs/ai （Last edited on Jan 31, 2026）

本文把两派各自的**模型契约**（模型吃什么 / 吐什么）查清，找出两者的**桥**，再映射到 sinan。
所有关键论断都标了来源；本轮未能核实的一律列在 §9，不当作事实使用。

---

## 一、为什么必须双轨：两派解决的是**不同的问题**

| | 像素派 | 结构派 |
|---|---|---|
| 模型看到的 | 位图（+ 掩码 + 指令） | 纯文本 / JSON（元素的 id、类型、文本、坐标） |
| 模型吐出的 | 位图 | 结构化对象（shape / 图层 / DSL） |
| 独有能力 | **空间关系、风格、手绘线条、视觉意图**——这些在结构化数据里根本不存在 | **精确文本、精确坐标、可编辑、可检索、可 diff、可撤销** |
| 天花板（致命短板） | 输出是**不可编辑的位图**；不受你文档模型约束；改一个字要重绘整块 | 模型**没有空间直觉**，坐标能力差；看不懂手绘线稿的"意思" |
| 代表 | OpenAI `images.edit`、FLUX.2 Image Editing / FLUX.1 Kontext、tldraw Image pipeline（ControlNet / IP-Adapter） | tldraw AI agents（typed actions）、Figma First Draft、Mermaid→shape |

一句话：**像素派给"感觉"，结构派给"精度"**。少任何一条，能力面都缺一半。

---

## 二、像素派：代表与「模型吃什么」的契约

### 2.1 输入契约（这直接决定我们栅格化该怎么出图）

| 提供方 | 证据 | 关键约束 |
|---|---|---|
| OpenAI `gpt-image` 系列（Image Edit API） | Microsoft Learn, *Azure OpenAI image generation models*，更新于 **2026-04-17**（OpenAI 自家 docs 对本次抓取返回 403，故引同一 API 的 Azure 一手文档） | **mask 里「完全透明（alpha=0）」的像素 = 要模型编辑的区域**；`image` 最多 **16 张**、每张 **<50MB**、PNG/JPG；**mask 必须是 PNG 且与输入图尺寸完全相同**；请求是 `multipart/form-data`；`dall-e-3` 已于 **2026-03-04 退役** |
| 同上 · 输出尺寸 | 同上 | `gpt-image-1` 只支持三档：**1024×1024 / 1024×1536 / 1536×1024**；`gpt-image-2` 支持任意分辨率但**两边须为 16 的倍数、长边 ≤3840、宽高比 ≤3:1、总像素 655,360–8,294,400**；响应统一 base64 |
| Black Forest Labs（FLUX） | https://docs.bfl.ai/ （首页索引级核实） | FLUX 模型"generate **and edit** images and video"；**FLUX.2 有独立「Image Editing」章节且官方声明 fully supported for production**；FLUX.1 Kontext 已被归入 **LEGACY MODELS** |

> **对 sinan 的两条直接推论**（可以立刻落地，不依赖任何模型选型）：
> 1. 现在 `rasterizeRegion` 的 `maxPixels = 1024` 是"等比铺满、长边 1024"，而像素派模型的输出档位是**固定长宽比**（1024²、1024×1536、1536×1024）。选区不是这些比例时，要么补边（pad）要么裁切，**必须在调用前归一化**，否则模型会把你的内容拉伸/裁掉。
> 2. mask 的语义是 **透明 = 编辑区**（不是白=编辑）。这是最容易写反的一条，且写反的后果是"模型改了你不想改的地方"。

### 2.2 tldraw 的像素派：Image pipeline starter kit

来源：https://tldraw.dev/starter-kits/image-pipeline （Last edited on Feb 08, 2026）

- 形态是**节点式 DAG**：`节点 → Cloudflare Worker → 第三方 Provider（Replicate 等）`，Worker 里按 `ImageProvider` 接口分发。
- 能力节点含 **ControlNet-guided generation**（用输入图做结构条件）与 **IP-Adapter reference images**（参考图注入风格/主体）——**实质就是 img2img 这一类**。
- 端口类型 6 种：`image` / `text` / `model` / `number` / `latent` / `any`；**连接本身也是 shape**，走 tldraw 的 binding 系统。
- 官方提供占位 SVG 后端，**无 API Key 也能跑通整套 UI**（这条值得抄：内核与后端解耦）。

⚠️ **该页没有出现"栅格化画布选区喂模型"的机制**（图片怎么进管线、Generate 节点是否接受 `image` 端口，页面未交代）——见 §9。

### 2.3 最早的那次：Make Real（2023-11-18）

来源：https://tldraw.dev/blog/make-real-the-story-so-far （Steve Ruiz，2023-11-18）

- 原文："use the tldraw component to draw a user interface, **export the drawing as a picture**, send the picture to GPT-4V, and get back the HTML/CSS"
  ⇒ **一开始就是栅格化**。
- 关键细节：画布上的 **iframe 抓不到**（"embedded content shows up in our image exports only as empty rectangles"），于是他们把**上一轮产出的 HTML 文本**一起发给模型，并附一句"用这段 HTML 把那个白方块填上"。
  ⇒ **这已经是一次无意识的"像素 + 结构化"双轨**：图给位置，文本给内容。

---

## 三、结构派：代表与「模型吐什么」的契约

### 3.1 tldraw AI agents（typed action schemas）

来源：https://tldraw.dev/docs/ai

- **写 = 纯结构化**：模型先用**简化格式**描述 shape → 再 `convertPartialFocusedShapeToTldrawShape(...)` 转成真实 record → 最终 `editor.createShape(result.shape)`。
- **有坐标空间转换**：`helpers.removeOffsetFromShapePartial(shape)` 把模型坐标转回页面坐标。
- **有专门的净化层（sanitization layer）**处理 LLM 的典型错误：修正不存在的 shape ID、保证新 ID 唯一、归一化坐标。
- **流式**把结果画到画布上（streaming），聊天历史跨 prompt 保留。
- agent 读画布 = **5 类上下文**：① 当前视口**截图**（像素）② 视口内 shape 的**简化表示**（结构化）③ 视口外 shape 聚类信息 ④ 用户当前选择与近期操作 ⑤ 会话历史。
- 另有官方立场（§开头引文）：两者**一起发最好**。

> **净化层 + 坐标转换这两件事是结构派的全部工程难点所在**，不是"调个 API 就完事"。
> LLM 必然给出不存在的 id、重复 id、越界坐标——不修就是崩溃/丢数据。

### 3.2 Figma First Draft（结构化生成的工业级样本）

来源：https://help.figma.com/hc/en-us/articles/23955143044247-Use-First-Draft-with-Figma-AI

- 产出是**可编辑的线框图/设计**（"editable wireframes or designs"），**不是位图**。
- 生成机制："Figma AI uses **Figma-built wireframing and design libraries** as the foundation"，每个库由 **building blocks（组件堆叠）** 拼装
  ⇒ **输出是组件/图层结构**，因此可以继续像普通设计一样改属性。
- **后续修改两条路**：① 用提示词改（可分别改 Theme / Content / Structure）；② 用样式控件（Color / Border Radius / Spacing / Typography）。
- **支持"选中局部再下指令"**：*选中设计中的一个或多个部分后输入提示词，改动只作用于所选元素*。
  ⇒ 这正是"空间指代"落到 UI 上的形态：**用户用选区替模型解决了指代问题**。
- 限制：**不能用你自己的设计系统生成**；只适合常见 Web/移动端模式；关闭 Actions 面板后就不能再用库来改了，只能改属性。
- 时间信息：自 **2026-05-20** 起 Figma agent 成为该功能的新入口。

### 3.3 结构派的另一条便宜路子：文本 DSL → 图

tldraw 官方 AI 文档把 **Mermaid diagrams**（"把模型生成的图表文本转为 shape"）列为推荐延伸路径。
⇒ 让 LLM 吐 Markdown/Mermaid，再由确定性代码转 shape。**避开了"模型直接吐坐标"这个最不靠谱的环节**，对树/流程图类内容性价比最高。

---

## 四、双轨怎么接：本调研最有价值的部分

### 4.1 读（模型看画布）——两条轨 + **一个桥**

| 轨 | 内容 | 解决什么 |
|---|---|---|
| 像素 | 视口/选区**截图** | 空间关系、样式、手绘线条的"意思" |
| 结构 | 元素的 `{id, type, text, bounds}` 列表 | 精确文本、精确坐标、可寻址 |

**桥 = 编号标注**。这是让"像素"与"结构"指向同一实体的唯一可靠手段。

**一手依据（两篇论文，均已核实摘要）：**

| 工作 | 来源 | 机制与结论 |
|---|---|---|
| **Set-of-Mark (SoM)** | arXiv:2310.11441，Jianwei Yang 等，2023-10 | 用现成分割模型（SEEM / SAM）把图像切成不同粒度区域，**在区域上叠加字母数字标记 / 掩码 / 边界框**，再把带标记的图像作为 prompt 给 GPT-4V。效果：零样本下在 **RefCOCOg 上超过完全微调的 SOTA** 指代理解与分割模型 |
| **OmniParser** | arXiv:2408.00203，Yudong Lu 等，2024-08 | 把 UI 截图解析为**结构化元素列表**（每个元素带**语义 + 空间坐标**）：检测模型定位可交互区域，描述模型抽取功能语义。效果：**只用截图输入**，在 Mind2Web / AITW 上超过需要额外信息的 GPT-4V 基线 |

**这两篇合计说明的事：**
- 视觉模型**天生不擅长定位**，必须靠"图上可指代的符号（编号/框）"来桥接；
- 而符号 ↔ 实体的对应表**我们天然就有**（每个 item 有稳定 `id` + `rect`）——tldraw 需要自建，sinan **白拿**；
- OmniParser 的价值场景是"结构未知的外部截图"；**我们的画布结构已知**，所以不需要检测/描述模型，直接用自己的文档模型生成对应表即可——这是 sinan 相对通用方案的**结构性优势**。

### 4.2 写（模型改画布）——**只能走结构化**

理由：像素派无法"改一个字的文本"、"挪一个卡片 10px 而不重绘"、"加一条连接到指定卡片"。
所以写入路径必须是 typed actions + 净化层（§3.1）。

### 4.3 再生成（像素写回）——走像素派

"把这块重新画一下 / 换个风格 / 补全背景" = 选区 → 栅格化 + mask → 模型 → **新图层**（不覆盖原件）。
tldraw 的做法正是"AI 生成的东西作为 shape 放到画布上"（Canvas as output）；sinan 的 `AiImageItem` 已经是这个形态。

---

## 五、tldraw 方案全景（一张表）

| 模式 | 读什么 | 写什么 | 用栅格化？ |
|---|---|---|---|
| Canvas as output | — | 图片 asset → `createShape({type:'image'})`；或自定义 shape + `HTMLContainer` + iframe 预览 | 产物是像素，但**不读画布** |
| Visual workflows | 上游节点的输出（含 `image` / `latent` 端口） | 节点执行结果 → 下游节点 → 最终产出 shape | 视节点而定（ControlNet / IP-Adapter 是像素） |
| AI agents | **截图 + 简化 shape 表示 + 聚类 + 选择/历史（5 类）** | **typed action schemas → 坐标转换 → `createShape`；含净化层** | **读：是**；写：否 |
| Reading canvas content（只读） | `getSvgString()` / `toImage({format:'png'})` + `getCurrentPageShapes()` 的文本与 bounds | — | **是，且官方推荐"两者一起发"** |

---

## 六、映射到 sinan：具体落点

### 6.1 现有资产盘点（已核实调用点）

| 资产 | 位置 | 双轨里扮演什么 |
|---|---|---|
| `Region{id, bbox, prompt, nodeRef, maskRef}` | `canvas_ai.dart` | **选区的统一载体**——双轨的天然锚点 |
| `rasterizeRegion(document, world, maxPixels:1024)` | `canvas_raster.dart:91` | **像素轨的现成实现**（白底、无网格、等比铺满、无留边） |
| `rasterizeWithCamera` | `canvas_raster.dart:51` | 导出用（保留），也是"给整张画布出图"的复用点 |
| `AiImageItem` / `GenRecipe` / `AiGenerator` / `LocalStubGenerator` | `canvas_item.dart` / `canvas_ai.dart` | **像素写回**的现成通道（生成层 = 新 shape，不覆盖原件） |
| `AiCache` + `inputFingerprint` + `refreshStaleness` | `canvas_ai_cache.dart` / `canvas_raster.dart:175` | 生成结果的**可复现 + 过期判定**（结构化轨没有这层，需要新建等价物） |
| `blocks` / `CardItem` / `CanvasEdge` / `MindMapItem` / `groupId` | 数据层 | **结构轨的读写目标**——已经是"typed"的，缺的是 action schema |
| Ollama（本地 LLM，已接好） | `native/src/chat.rs` + Ollama 管理面板 | 结构轨的推理后端，**零新增依赖** |
| `inputFingerprint(document, bbox)` | `canvas_raster.dart:175` | 已经是"这个选区里有什么"的**结构摘要雏形**（id + 几何 + src），可扩展成给模型的上下文 |

### 6.2 读：Region → 双份输入（照 tldraw 官方口径）

```
Region.bbox
  ├─ 像素轨：rasterizeRegion(document, bbox)          ← 已有，一行
  └─ 结构轨：itemsIn(bbox) → [{id,type,text,bounds}]   ← 新增，约 20 行
             strokesIn(bbox) → [{id, 点数, 包围盒}]     ← 笔迹不进文本，只报数量/位置
  桥：把结构轨的序号画到像素轨的图上（Set-of-Mark 式）
```

**桥这一环是 sinan 的便宜处**：`itemsIn` 返回的顺序稳定、item 有稳定 `id`、`rect` 已知，
所以"在图上叠编号 + 给编号→id 表"是**十行级**的工作，而通用方案（OmniParser）需要训练检测+描述两个模型。

### 6.3 写：typed actions（需新建）

建议最小 action 集（对齐现有内核能力，不新增文档概念）：

| action | 落到哪个既有 API |
|---|---|
| `create_card{text,x,y,w?,h?}` | `document.addItem(CardItem(...))` + 上层写 `blocks`（与既有卡片路径一致） |
| `update_card_text{id,text}` | 卡片文本同步链（`card_text_sync`） |
| `move_item{id,dx,dy, x?,y?}` | `document.setItemRects` |
| `connect{fromId,toId,startShape?,endShape?}` | `document.addEdge(CanvasEdge(...))`（端点按 **blockId** 反查，见 `edgesIn` 注释） |
| `group{ids,label?}` / `ungroup` | `CanvasGroupItem` + 成员 `groupId` |
| `add_mindmap_node{parentId,text}` | `blocks.parent_id` 树 + `MindMapItem.invalidateLayout()` |

**净化层（照 tldraw，必须做）**：id 不存在 → 丢弃该 action 而非抛；id 重复 → 重编；坐标越界 → 钳到
内容包围盒 ∪ 视口；尺寸小于 `CanvasHandles.minSize` → 提到下限；`connect` 端点缺失 → 丢弃（与 `edgesIn`
"任一端缺失就不返回"的既有口径一致）。

### 6.4 像素写回：尺寸归一化（可立即落地）

§2.1 的推论：调用像素派模型前，把 `Region.bbox` 的长宽比**吸附到模型的输出档位**
（1024² / 1024×1536 / 1536×1024，或 16 的倍数 + ≤3:1），两侧用背景色补边，生成后再按原比例裁回。
否则内容会被拉伸或裁切。这一步与"选哪个模型"无关，**现在就能写**。

---

## 七、建议的落地顺序

| 阶段 | 内容 | 依赖 | 说明 |
|---|---|---|---|
| **A** | **结构轨最小闭环**：Region → 结构摘要 → Ollama → typed actions → 应用 + 撤销 | 无新增依赖（复用 Ollama + 既有内核 API） | 价值最高、成本最低；且**不需要栅格化**，可先跑通 |
| **B** | 桥：SoM 编号（结构轨序号叠到像素轨图上） | A + 一个多模态模型（本地 Qwen-VL 系或云端） | 让"指哪打哪"从"靠坐标猜"变成"靠编号指" |
| **C** | 像素写回：`AiImageItem` 通道接回 UI + 尺寸归一化（§6.4） + mask 语义（透明=编辑区） | 本地扩散模型或云端 API | 重资产，最后做 |

**A 阶段就能验证双轨的地基**：typed actions + 净化层 + 撤销。B/C 都是在这个地基上加轨，
不会推翻 A。

---

## 八、给 sinan 的五条硬结论

1. **双轨是对的**，且 tldraw 官方文档明确背书（"两者一起发效果最好"）——不是我们的折中发明。
2. **读可以双轨，写只能结构化**。像素派无法"改一个字"，这是硬边界。
3. **桥是编号标注**（Set-of-Mark 思路），而 sinan 因为文档结构已知，**不需要 OmniParser 那套检测/描述模型**——这是相对通用方案的结构性优势。
4. **结构派的全部工程难点 = 净化层 + 坐标空间转换**（tldraw 为此专门写了 sanitization layer 与坐标 helper）。不是"调 API"。
5. **像素派的全部工程难点 = mask 语义（透明=编辑区）+ 尺寸档位归一化**。这两条与模型选型无关，现在就能做。

---

## 九、本轮**未能核实**（不作为事实使用）

| 项 | 原因 |
|---|---|
| Gemini 原生图像生成/编辑的输入契约（多图参考、局部编辑、输出尺寸） | `ai.google.dev` 与 `cloud.google.com` 两次抓取均超时 |
| Vertex AI Imagen 编辑 API 的 mask 语义（白/黑代表哪一侧） | 同上，超时 |
| Anthropic computer use 的输入输出契约 | `docs.claude.com` / `docs.anthropic.com` 均超时或地区不可用 |
| tldraw Image pipeline 是否支持"从画布选区栅格化"作为输入 | 官方页无此描述；需读其 GitHub `src/nodes/types/` 源码 |
| Make Real 具体调用的导出 API 名 | 官方博客为叙事文，未出现任何 API 名 |
| Miro AI / Napkin AI / Whimsical AI 的输出是结构化还是位图 | 本轮未抓取，不引 |

---

## 十、来源清单（一手）

| # | 来源 | 取用内容 |
|---|---|---|
| 1 | https://tldraw.dev/docs/ai （Last edited Jan 31, 2026） | 三种 AI 模式；agent 5 类上下文；typed actions + 坐标转换 + 净化层；`toImage`/`getSvgString`；**"两者一起发最好"原文** |
| 2 | https://tldraw.dev/starter-kits/image-pipeline （Last edited Feb 08, 2026） | DAG → Worker → Replicate；ControlNet / IP-Adapter；6 种端口类型；占位后端可无 Key 跑通 |
| 3 | https://tldraw.dev/blog/make-real-the-story-so-far （2023-11-18，Steve Ruiz） | "export the drawing as a picture" → GPT-4V；iframe 抓不到 ⇒ 回传上轮 HTML 文本 |
| 4 | https://tldraw.dev/sdk-features/performance （Last edited Jan 31, 2026） | （相邻议题）signals / culling / debounced zoom / LOD 全套 |
| 5 | arXiv:2310.11441 Set-of-Mark Prompting（2023-10） | 分割 + 标记叠加 → GPT-4V；零样本超全微调 SOTA（RefCOCOg） |
| 6 | arXiv:2408.00203 OmniParser（2024-08） | 截图 → "语义 + 坐标"结构化元素；只靠截图超过需额外信息的基线 |
| 7 | https://help.figma.com/hc/en-us/articles/23955143044247 （Figma Learn） | First Draft 输出可编辑设计（库 building blocks）；提示词可局部作用于选中元素；不能用自有设计系统 |
| 8 | https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/dall-e （更新 2026-04-17） | **mask 透明 = 编辑区**；≤16 张输入、<50MB、mask 须 PNG 且同尺寸；输出尺寸档位；dall-e-3 已退役 |
| 9 | https://docs.bfl.ai/ （索引级） | FLUX 可生成**并编辑**图像；FLUX.2 有独立 Image Editing 章节且生产可用；Kontext 属 LEGACY |
