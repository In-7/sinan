# 画布架构（无限画布 + 思维导图）

目标：**OneNote 桌面端**的能力面（无限画布、压感手写、橡皮、图片、文本容器、框选、
思维导图），当前**只做桌面端**（Windows 优先）。2026-09-14 立项。

## 一、结论：自研内核 + 只依赖 perfect_freehand

### 为什么不用第三方画布底座（2026-09-14 实测数据）

| 包 | 版本 / 热度 | 否决点 |
|---|---|---|
| `infinity_canvas` | 0.11.0 / 29 downloads·wk | item 是真 Flutter widget，撑不住密集墨迹 |
| `canvas_kit` | 0.6.1 / 155·wk（同作者） | 同上；自述 early、可能有 breaking |
| `fldraw`（Flutter 版 tldraw） | 0.1.0 / 37·wk，13 个月未更新、单人、37 commits | 无橡皮/图片/自动布局；富文本只是字符串；BLoC + shadcn_flutter 与本项目 Riverpod + M3/Tokens 冲突；核心 RenderObject 黑盒 |
| `flutter_fabric` | 0.1.0 / 29·wk，1 like | 橡皮是"刷背景色"（假橡皮）；无压感；无裁剪；`onChangeJsonData` 每帧触发 |
| `zeba_academy_whiteboard_ui` | 1.0.1 / 5·wk | **GPL-3.0 传染性**；且只是预设 UI 组件皮 |
| `simple_painter` | 1.4.0 / 22·wk，16 个月未更新 | 固定画布语义（不是无限世界） |
| `flutter_drawing_board` | 1.0.1+2 / **2.21k·wk**，269 likes | 固定画布 + InteractiveViewer；0.3.0 后无文本 |

最根本的一条：**OneNote 级画布的核心是"密集墨迹 + 少量大对象"，而所有现成库都是
"widget 粒度"或"固定画布"**，模型不对；剩下的（fldraw）成熟度与黑盒风险不可接受。

### 采用的依赖

- **`perfect_freehand` 2.5.2**（6.37k·wk、MIT、零第三方依赖）：tldraw 笔迹算法的
  Dart 移植。点列 + 压感 → 变宽轮廓多边形。已核实源码：
  `getStroke(List<PointVector>) → List<Offset>`；`PointVector extends Offset` 且带
  `pressure`；`getStrokePoints/getStrokeOutlinePoints` 两级 API 便于缓存。
- 其余一律用 `dart:ui` / `package:flutter/widgets.dart`：坐标换算只有缩放+平移，
  **不需要 Matrix4 / vector_math**（少一个依赖、每帧少一次 4×4 乘法）。

## 二、分层架构

```
Listener（原始指针事件：压感 / 笔类型 / 接触面）
  └ MouseRegion（光标）
    └ ListenableBuilder（控制器变化即重建）
      ├ 背景层   CustomPaint  点阵网格（屏幕坐标，随相机自适应密度）
      ├ 内容层   CustomPaint  笔迹（世界坐标，按相机变换；只画视口内的）
      └ 浮层     CustomPaint  框选矩形 / 橡皮光标
```

后续要加的三层（架构已留位）：

```
├ 卡片层   TextPainter LOD：非聚焦卡片不挂载 widget
├ 活动编辑层 同一时刻只挂 1 个 appflowy_editor 实例（复用块编辑器全部富文本能力）
└ item 层  图片 / 形状 / 思维导图节点（少量大对象，与笔迹分开裁剪）
```

三层拆开的目的只有一个：**重绘隔离**。平移/缩放时只有背景层必重绘；写字时只重绘
内容层与浮层。项目 Impeller 规范要求的高频局部刷新即此（禁 Opacity/BackdropFilter）。

## 三、模块清单

| 文件 | 职责 |
|---|---|
| `kernel/canvas_camera.dart` | 世界↔屏幕换算（scale + translation）、焦点缩放、fit |
| `kernel/ink_stroke.dart` | 笔迹模型：点列（世界坐标 + 压感）、抽稀、轮廓缓存、命中测试 |
| `kernel/canvas_item.dart` | item 模型（形状/图片/分组框）+ 四角缩放手柄几何（屏幕常量尺寸） |
| `kernel/canvas_document.dart` | 笔迹 + item 集合、视口裁剪、擦除、撤销/重做命令栈 |
| `kernel/canvas_painters.dart` | 网格 / 笔迹 / 浮层三个 CustomPainter |
| `kernel/canvas_controller.dart` | 工具状态 + **输入流水线**（掌拒、手势竞争、压感归一化） |
| `kernel/canvas_view.dart` | 输入层 + 三层绘制的组装（不依赖 Material） |
| `canvas_surface.dart` | 工具条 + 画布 + 键盘（空格抓手 / Delete / Ctrl+Z）的**可嵌入**面板（无 Scaffold / 路由） |
| `canvas_note_view.dart` | 画布**笔记**视图：按 `noteId` 载入 + 防抖自动保存（画布 JSON） |
| `canvas_brush_panel.dart` | 笔刷设置浮层（颜色 / 笔迹粗细 / 橡皮大小）+ 工具条按钮（叠当前墨色圆点） |
| `canvas_insert_panel.dart` | 插入形状（矩形/椭圆）与图片的入口 + 插入逻辑（落视口中心、世界尺寸按缩放折算） |
| `canvas_switch.dart` | 画布视图的唯一入口工厂（与 `editor/core/editor_switch.dart` 对称） |

## 四、关键设计决定

**坐标**：笔迹存**世界坐标**，轮廓（perfect_freehand 结果）也按世界坐标缓存 ⇒
平移/缩放只重放变换，不重算轮廓。

**抽稀**：`InkStroke.minPointDistance = 0.75`（世界单位），位移过小直接丢弃且不重绘
（借鉴 `flutter_drawing_board` 的 `minPointDistance`，可省 30~50% 的点）。

**掌拒**：两条判据（照 `flutter_drawing_board` 实测值）——接触面 > 15 判为手掌；
100ms 内落下的第二根手指也判为手掌。

**手势竞争**（桌面语义，官方手势栈裁决不了这套）：
- 中键 / 空格 / 抓手工具 ⇒ 平移（优先级最高）；
- 笔的橡皮端（`PointerDeviceKind.invertedStylus`）⇒ 无条件橡皮，与当前工具无关；
- 滚轮 = 平移，Ctrl/Cmd + 滚轮 = **以光标为焦点缩放**；
- 压感：`stylus` 且 `pressure > 0` 才用真压感并按 `pressureMin/Max` 归一化，
  否则交 `simulatePressure` 按速度模拟（鼠标/触摸也能有粗细变化）。

**颜色**：`CanvasView` 不读 Theme，颜色由页面传入 ⇒ 内核在两套主题
（material_ui / 官方 material）下都能用。

**橡皮：笔画橡皮（命中即整条删除），这是定案、不是妥协**（2026-09-17 拍板）。
判据已有（`InkStroke.hitTest(world, radius)`：点到线段的距离 ≤ `radius + baseWidth/2`），
保持"整条删"的理由：语义 O(1)、撤销干净（一条 `_RemoveStrokes`）、不动轮廓缓存与
`ui.Picture` 失效口径——与现有架构完全自洽；OneNote 桌面端本身也是笔画橡皮。

**明确不做**（将来若有人想"优化"成下面两种，先读这段）：

| 方案 | 为什么不做 |
|---|---|
| **像素橡皮**（遮罩位图 + `BlendMode.clear`） | 需要 `saveLayer`（违项目 Impeller 规范）、缩放会失真、**导出失去矢量清晰度**、且与"世界坐标 + `ui.Picture` 显示列表"的架构不兼容 —— 拿整个渲染架构与导出质量换一个手感 |
| **遮罩法**（笔迹存擦除区间） | 数据最省、可无损恢复，但 `InkStroke.outline` 的分段缓存会让**接缝处形状变化**（须补端点处理），命中/包围盒也要跟着考虑区间——侵入内核三处 |

真要"擦掉碰到的部分"，走**切分法**（把笔迹按命中段切成两段 / 截头去尾，继承颜色与宽度，
原笔迹删除）。它不改数据格式、不动绘制算法，但有**三条硬约束**，落地方案就写在这里：

1. **一次手势只算一条撤销命令**——否则拖动过程中每条被碰的笔迹都进栈，撤销栈立刻爆掉；
   需要新增一种"复合擦除"命令（现有 `_RemoveStrokes` 只处理纯删除）；
2. **抬手时才落切分**——手势期间累积"擦过的区间"，否则每帧都对同一批笔迹重算轮廓，会抖；
3. **切分产生新 id**（沿用 `stroke-N` 计数器即可：笔迹 id 不像 item id 那样有跨会话引用需求）；
   另注意 `ink_shards` 会把整片判为变了（256 笔重写），局部擦除密集时写量会放大。

以及一个顺带项：`InkStroke.color/baseWidth` 目前是 `final`。若将来同时要"擦完还能改色/改粗细"，
做切分法时把它们一并放开更省事（现在改样式必须先删再画）。

## 五、性能预算与优化阶梯

| 阶段 | 手段 | 状态 |
|---|---|---|
| L0 | 视口裁剪（包围盒粗筛）+ 轮廓缓存 + 抽稀 | ✅ 已实现 |
| L1 | 已完笔迹按**世界坐标**录成 `ui.Picture`（显示列表），平移/缩放只 `drawPicture` 一次；`document.revision` 变化时重录。笔迹 < 200 条时退回逐条画 | ✅ 已实现 |
| L2 | **item 层 LOD 代理渲染**（2026-09-19）：块在屏幕上**短边 < 20px** 时只画身份色块，跳过文本排版 / 图片采样，并**不触发**图片解码（`ItemPainter.onImageMissing`）。选中 / 编辑中的 item（`pinnedIds`）永不代理；判据用 `CanvasController.lodScale`（缩放中冻结、停稳 180ms 才跳一次，item ≥ 500 才启用冻结）。`lod: true` 只有实时视图传，导出 / AI 栅格化保持默认全保真 | ✅ 已实现 |
| L3 | 分块（瓦片）重放 + 空间索引换均匀网格 | ⬜ **约 2w 条笔迹**时（实测推导，见 [`canvas_perf_baseline.md`](./canvas_perf_baseline.md)：1w 条时单帧仅 383μs、落一笔重录 4.5ms ⇒ 还不到时候；先撞墙的是"落一笔要重录全量 Picture"，不是帧率）。⚠️ 到时**先做"两代缓存"（~40 行，约 35 倍收益）**，瓦片只在 10w 条量级才值得——两方案的对比见同一文档 |
| L4 | 卡片 LOD（TextPainter 替代 widget 挂载） | ⬜ 接入卡片时 |
| — | ~~item 侧空间索引~~ | ❌ **不做**（实测，见 `canvas_perf_baseline.md`）：3000 个 item 的视口扫描仅 93μs；"缩小 ⇒ 全量可见"已由 L2 的 LOD 压到 3.0ms（关掉要 10.2ms）。item 本就是"少量大对象"，线性扫描比索引维护便宜 |

> **L0 与 L2 的关系（易混）**：L0 的视口裁剪只在 item 落在视口**外**时省事；
> 一旦**缩小**，`visibleWorld` 会包住整张画布 ⇒ 裁剪失效、退化成全量全保真绘制。
> L2 承接的正是这个裁剪救不了的场景，两者互补而非重复。
> 回归闸门：`test/canvas/canvas_lod_test.dart`（缩小不解码 + 导出仍全保真）。

> L1 的关键性质：`ui.Picture` 是**显示列表**不是位图 ⇒ 换个缩放重放仍是矢量清晰度，
> 这一点与"截图缓存"完全不同，也是敢在无限缩放的画布上用它的前提。

预算：1080p 视口、1w 条笔迹下，平移/缩放稳定 60fps；书写端到端延迟 < 1 帧。

## 六、落地顺序

1. ✅ 相机 + 文档模型 + 笔迹层（视口裁剪）+ 输入流水线（压感/掌拒/手势）
2. ✅ 页面与工具条（笔/橡皮/框选/抓手/撤销重做/缩放）+ 单测（11 个）
3. 🟡 10k stroke 实测：已有**可复现的绘制成本基准**（`test/canvas/canvas_perf_bench_test.dart`，数据见 `canvas_perf_baseline.md`）；真实端到端帧率 profile 仍待上机
4. ✅ item 模型（形状/图片）+ 命中测试 + 变换手柄（单选缩放；多选整体拖动）
5. 🟡 **卡片（v9，2026-09-18）**：内核 `CardItem` 已落地——几何 + `blockId` + 文本，
   画在 CustomPaint 里（与笔迹共用视口裁剪与相机变换），文本用**官方普通文本**、
   不挂 appflowy。待做 = 插入入口 + 编辑时挂载输入框（严格"一次只挂一个"）
6. 🟡 持久化：**先走 `notes.content` 存画布 JSON**（`canvas_note_view.dart` 防抖自动保存，2026-09-16）；
   目标形态见**第七章**（`canvas_items` / `canvas_meta` / `ink_shards`），按"双写 → 回填 → 校验 → 切读
   → 停写"推进（**第 1~2 步已实现**）——⚠️ 它是 `docs/data_layer.md` 八.6 里 v10 删列的**硬前置条件**
7. ⬜ 思维导图：树布局（Walker/Reingold–Tilford，~80 行）+ 端口贝塞尔连线
8. ✅ 接入 `NoteKind.canvas`（2026-09-16）：DB v6 已放行 `'canvas'`，Dart 侧枚举补齐，
   右栏按 kind 渲染（文档 → 块编辑器 / 画布 → 画布），侧栏「新建画布」直接建画布笔记

## 七、存储落点：画布对象落到哪些表（2026-09-17 设计）

**进度（2026-09-18）**：v8 建表 + **第 1~3 步（双写 + 回填 + 校验）已实现**
（`data/canvas_store.dart`：双写在 `NoteStore.create` / `updateContent` 里与 blocks
投影并排调用；回填在启动首帧后分批跑；校验是 `verifyCanvasRows` / `readVerifiedCanvas`）。
**读路径已切到表**（第 4 步：`NoteStore.noteById` 对两条投影都切读，都带降落伞）。
**第 5 步（停写 JSON）刻意暂缓**——它不可逆，且纪律要求"切读在真实数据上跑稳之后"；
更要紧的是：停写后 `notes.content` 就不再更新，而降落伞回退的正是这一列 ⇒
**在切读被证明可靠之前停写，会把"回退"变成"回退到过期内容"**。

第 3 步的三条实测要点（都已进 `test/data/canvas_store_test.dart`），**条条都是"不做就
整类画布校验失败"**，且失败表现统一是"静默回退 JSON"——不报错、只是切读永远不生效：

1. **`media` 侧表必须剔除**：真实存档走 `toJson(media: _media)` ⇒ 原文的 `document`
   带 `media` 清单，而它刻意不落库（真源是各 item 的 `src`）⇒ 不剔除则**所有**画布失败；
2. **笔迹点必须按 Float32 量化**：blob 存 Float32 而原文是 double（`1.1` 往返成
   `1.100000023841858`）⇒ 不量化则**所有带笔迹的**画布失败。`rect` / `angle` /
   `stroke_width` 存在 REAL 列（SQLite REAL = double）**没有**这个问题；
3. **空 `meta` 要补回 `{}`**：落库时空 meta 不进 `props_json`（见 `_itemRowOf`），
   而 `ShapeItem.toJson` 总是写 `meta` ⇒ 还原时不补就永远差一个键。

**现状**：整张画布（相机 + items + 笔迹）序列化成 JSON 存 `notes.content`
（见三章 `canvas_note_view.dart`）。这条路径能跑，但有三处硬伤：

1. **v10 会连坐**：`docs/data_layer.md` 八.6 计划删 `notes.content`，而画布**没有别的落点** ⇒ 一旦执行，整张画布失存；
2. **写放大**：一张画布几千笔时，改一笔要重序列化整篇（O(篇) 而非 O(块)）；
3. **格式版本无处存**：`CanvasDocument.toJson` 的 `schemaVersion: 2` 没有独立落点，将来改画布 schema 无从判别。

**结论：画布对象不进 `blocks`，用独立表 + 复用同一套"实体约定"。**

### 为什么画布不进 `blocks`

`blocks` 的每一列都编码**文档树**的语义（`ord` = 阅读顺序、`parent_id` = 层级）；
画布要的是 **z 序 + 空间几何 + 样式**。两者唯一共享的不变量**只有归属（note_id）**，
而物理表的边界应该画在"共享不变量"上。硬塞一张表的具体代价：

- `ord` 一列两种含义 ⇒ 看表/写查询前必须先看 `type` 前缀才知道怎么读；
- AI 管道处处要过滤：`chunks_fts` / `index_state` 都建在 `blocks` 上，而画布对象没有可索引文本；
- **"复用三件套"是假收益**：`replaceNoteBlocks` / `readNoteDocument` / `verifyNoteBlocks` 是
  "块树 ⇄ 树 JSON"的专用转换，画布要的是"行 ⇄ 空间对象"——是**另一套**转换，能复用的只有 INSERT/CASCADE 那些机械部分；
- 画布的 `rect/angle/color/fill/stroke_width` 要么塞进 `props_json`（丢掉可查性与约束，
  "所有宽 > 500 的矩形"这类查询就没了），要么加列 ⇒ 退化成多态宽表，正是块级方案要避免的。

### 卡片为什么是**例外**（v9，2026-09-18 拍板）

上面四条**全部针对形状 / 图片**。画布要承载"卡片"（可编辑文本块）之后，第 2 条直接反转：

> 卡片**有**可索引文本 ⇒ 它恰恰**必须**进 `blocks`。

不进的代价，对一个定位"帮人思考"的应用是致命的：画布上的想法**搜不到**
（`chunks_fts` 建在 `blocks` 上）、**引不到**（块引用目标是 `block_id`）、
**AI 索引不到**（`index_state` 也挂在 `blocks` 上）——画布会沦为信息孤岛。

于是卡片**分裂存储**，边界照旧画在"共享不变量"上：

| 半边 | 落点 | 为什么 |
|---|---|---|
| 内容（文本） | `blocks` | 共享文本 / 树（`parent_id`）/ AI 检索语义 |
| 几何（rect、z 序） | `canvas_items` | 视口裁剪每帧要用，必须是**真列** |

这与"形状 / 图片留在 `canvas_items`"并不矛盾——判据从来不是"是不是画布对象"，
而是**有没有可索引文本**。

**连线**另起一张 `canvas_edges`，且**只做自由连线**：思维导图是树，用 `blocks.parent_id`
表达即可（布局算法跑在 blocks 树上），两者各自用最合适的方案，不混一张表。
边存的是 **id 而不是坐标**（tldraw 的 binding）⇒ 拖走卡片连线自动跟随、删卡片时
连线随外键级联消失。这是"块结构画布"与"画画画布"的分水岭。

### 分组框：为什么是**一等结构**（而非 meta 字段）

三家标杆**都有**"把一组元素框在一起"的节点，且都是**结构性**的：

| 标杆 | 节点 | 关系的表达 |
|---|---|---|
| JSON Canvas 1.0 | `group` | 子节点 `group` 字段指向 group id |
| tldraw | `parentId` | shape 的父是另一个 shape（frame） |
| AFFiNE / BlockSuite | frame | doc 与 edgeless 共用同一批 block，frame 是容器 |
| Excalidraw | `startBinding` / `boundElements` | 元素绑定到 frame，跟着移动 / 删除 |

**定案（2026-09-18）**：分组是**结构性关系**（一组元素的整体），不是"附加属性"。
若塞进 `meta`，将来必然要挖出来提为字段，届时仍是一次结构迁移——既然标杆三证刚需，
现在就立为一等结构，免得返工。

**内核契约**（`kernel/canvas_item.dart`）：

- `CanvasItem.groupId`（`String?`）：成员 item 用它指向分组框的 `id`；`null` = 不属于任何组。
  落在存储层走 `canvas_items.props_json` 的 `groupId` 扩展位（**不占独立列**），
  与 `meta` / `nodes` 同思路。
  - **可变**（2026-09-19）：与 `rect` / `colorSlot` 同性质，由 `CanvasDocument.setItemGroupIds`
    就地改 + 记一条撤销命令。此前是 `final` ⇒ "把元素加进分组框"在**运行时**做不到，
    分组框只有存档与测试能造（AI 的 `group` 动作因此一度被摘出词汇表）。
  - **删框自动解绑**：`removeItems` 会顺带清掉成员归属，且**与删框同处一条命令**
    （照"卡片被删连带删连线"的既有范式）——否则成员会留下指向不存在分组的悬空
    `groupId`，从此进不了别的组；分成两条命令则会出现"撤销后框回来、归属没了"的怪状态。
- `CanvasGroupItem`（`type:'group'`）：一个**普通 `CanvasItem`**，因此自动获得增删、撤销、
  序列化、落库。它只多带一个 `label`（顶部标题条，空则不画）。成员用 `groupId` 找到它，
  "整组拖动 / 删除解绑"只需按 `groupId` 聚拢，**文档层不维护额外层级树**。
- 绘制顺序：分组框是**容器**，必须画在成员**下方**。由 `ItemPainter` 在绘制前把
  `group` 类型排到其余 item 之前（各自仍保持原 z 序），否则框会被自己的成员盖住。
- 语义色与卡片 / 思维导图同口径：`CanvasGroupItem` 覆写 `colorSlot`，画底色 / 描边时加深。

**与标杆的有意偏差**（记录在册，不视为缺陷）：

1. **没有树 / 嵌套层级**：JSON Canvas 与 tldraw 都支持 group 嵌套 group。本项目**只做
   单层分组**（一个 item 至多属于一个组，组本身不再含子组）。理由：个人画布场景下嵌套
   分组的真实需求极稀，而懒层级会引入"父 move 要不要带着子树、子树越界要不要重定父"
   一整套状态机——属过度工程（清单 #6 工具状态机化时再评估）。
2. **分组不是裁剪 / 遮罩容器**：Excalidraw / tldraw 的 frame 会裁剪超出部分。本项目分组框
   **只是背景框 + 标题**，成员可溢出框外（对齐参考用）。理由：裁剪要动绘制裁剪区、导出
   剪裁，且与"item 各自命中"的架构冲突，收益不值。
3. **整组拖动的实现靠 `groupId` 聚拢**：落点只存 `groupId`，文档层在无操作时不需要子树索引；
   与"连线的 binding 只存 id"是同一套哲学（坐标从不落库，绘制时现算 / 移动时现查）。

### 卡片的读写（`CanvasStore`，v9 已实现）

存档 JSON 里卡片是**自包含**的（带 `text`，可读、可导出），落库时才拆成两半：

| 半边 | 写 | 读（还原） |
|---|---|---|
| 几何 | `canvas_items`（`kind='card'` + `block_id`） | 按 `z` 序读出 |
| 内容 | `blocks`（`type='card'`，`props_json={"text":…}`） | 按 `block_id` 取回，拼回 JSON |

三条实现约束，**都是实测出来的**：

1. **内容必须先于几何写**：`canvas_items.block_id` 外键到 `blocks(id)`，先插几何会因
   "指向一个尚不存在的块"而违反外键。删卡片时顺序天然正确（几何行先被删，blocks 才失去引用）；
2. **内容的指纹只看文本**：拖动 / 缩放卡片不该重写 `blocks` 行，否则会让 AI 索引误判
   （`index_state` 是按 fingerprint 比对来决定"要不要重算嵌入"的）；
3. **`ord` 填 0**：画布卡片的顺序权威在 `canvas_items.z`，`ord` 保持"阅读顺序"这一个含义。

⚠️ **校验必须覆盖文本**。分裂存储最危险的失败不是报错，而是"**两边都看着正常、文本却没了**"
——几何行还在、结构也对得上，只是内容丢了；若校验放过它，切读会静默返回一框空白卡片，
用户以为想法还在。`test/data/canvas_store_test.dart` 有一条专门钉这个：
删掉 `blocks` 行 ⇒ 校验**必须**失败。

### 连线的读写（v9 已实现）

连线**只做自由连线**（思维导图是树，走 `blocks.parent_id`），存的是
**端点的 id 而不是坐标**（binding）：

| | 端点用什么 id |
|---|---|
| 内核 `CanvasEdge.fromId` | 卡片的 **`blockId`** |
| 存储 `canvas_edges.from_id` | 外键 **`blocks(id)`** |

两边刻意是**同一个 id**，于是两件事都是自动的：拖走卡片 ⇒ 端点位置在绘制时现算，
连线自己跟随（没有任何同步代码）；删卡片 ⇒ 外键级联把连线一并删掉，运行时找不到
端点就**不画**（悬空边不是独立内容，画出来只会指向虚无）。

⚠️ **统一到 `blockId` 是刻意的选择**。内核原本按 item id 查找，与存储外键的
`blocks(id)` 不是同一个 id —— 两者不一致，"还原出来的连线"就对不上卡片。
这个不一致是**测试抓出来的**：删除时匹配用 item id、查找用 blockId ⇒ 连线没被删掉；
现在删除匹配同时覆盖两种 id。

**序列化**：连线是**可选键**，为空时**不写** `edges` —— 与内核 `toJson` 同口径。
否则所有老画布（本来没有这个键）都会被深比较判成"原文无 / 还原有 {}"，
结果是静默回退 JSON。

### 表设计

```sql
-- 画布对象（形状 / 图片 / AI 图层）：z 序 + 空间几何 + 样式
CREATE TABLE canvas_items (
  id           TEXT NOT NULL,             -- CanvasItem.id（⚠️ **跨画布不保证唯一**，见下）
  note_id      TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL,             -- shape.rectangle / shape.ellipse / image / ai_image / group
  z            INTEGER NOT NULL,          -- z 序（底→顶），替代 itemOrder 数组
  x1 REAL NOT NULL, y1 REAL NOT NULL,      -- rect 的**四条边**（世界坐标）：
  x2 REAL NOT NULL, y2 REAL NOT NULL,      -- ⚠️ 刻意不存 x/y/w/h
  angle        REAL NOT NULL DEFAULT 0,
  color        INTEGER,                    -- ARGB；等于哨兵值 ⇒ 跟随主题（见四章"颜色"）
  filled       INTEGER,                    -- 0/1（形状专用）
  stroke_width REAL,
  src          TEXT,                       -- 图片：相对引用（media/xxx.png）
  props_json   TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(props_json)),
                                           -- 扩展位：kind 细节 / AI 配方（与 blocks.props_json 同思路）
  block_id     TEXT REFERENCES blocks(id) ON DELETE CASCADE,
                                           -- v9：仅 kind='card'。**卡片的内容在 blocks**，
                                           -- 这里只存几何，靠它关联（见上「卡片为什么是例外」）
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  fingerprint  TEXT NOT NULL,              -- 与 blocks 同口径（fp1）
  PRIMARY KEY (note_id, id)                -- ⚠️ 复合主键，见下
);
CREATE INDEX idx_canvas_items_note ON canvas_items (note_id, z);

-- 自由连线（v9）：**存 id，不存坐标**（binding）
CREATE TABLE canvas_edges (
  id         TEXT NOT NULL,
  note_id    TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  from_id    TEXT NOT NULL REFERENCES blocks(id) ON DELETE CASCADE,
  to_id      TEXT NOT NULL REFERENCES blocks(id) ON DELETE CASCADE,
  from_side  TEXT,                         -- 端口吸附：top/right/bottom/left
  to_side    TEXT,
  props_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(props_json)),
  fingerprint TEXT NOT NULL,               -- 与 canvas_items 同口径：判变只写变动的行
  PRIMARY KEY (note_id, id)                -- 与 canvas_items 同口径：带归属
);
CREATE INDEX idx_canvas_edges_note ON canvas_edges (note_id);

-- 画布单例元数据：相机 + 画布格式版本
CREATE TABLE canvas_meta (
  note_id        TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
  camera_json    TEXT NOT NULL DEFAULT '{}',   -- {scale, translation}
  schema_version INTEGER NOT NULL,             -- ← 现在没有落点，见下
  updated_at     INTEGER NOT NULL
);
```

⚠️ **`canvas_items` 的主键必须是 `(note_id, id)`**：`CanvasItem.id` 是内核里的**进程内
自增计数器**（`item-0`、`item-1`…），应用重启后从头的值重新开始 ⇒ 两张画布同时存在
`item-1` 是**常态**。单列主键 + `ON CONFLICT(id)` 会让后写的画布把前一行的 `note_id`
一起改走（实测：回填两条画布时被测试抓出）。这与 `ink_shards` 用 `(note_id, shard_index)`
是同一思路——**凡是"归属 + 局部 id"的表，主键都要带归属**。

笔迹**沿用已建好的 `ink_shards`**（`docs/data_layer.md` 第五节）：256~512 笔一片，
`points_blob` 是 Float32 的 `(x, y, pressure)`，`style_json` 存每笔的颜色/宽度。

### 列与现有 JSON 的映射

| 现在（`CanvasDocument.toJson`） | 落点 |
|---|---|
| `items[id]` | `canvas_items` 一行（由 `kind` 判别子类） |
| `itemOrder: [...]` | 变成 `canvas_items.z` ⇒ **顺序不再是独立数据**（这是收益） |
| `strokes[id]` | `ink_shards` 分片 |
| `strokeOrder: [...]` | 分片边界 + 片内顺序 |
| `camera` | `canvas_meta.camera_json` |
| `schemaVersion: 2` | `canvas_meta.schema_version`（**已落地**：v8 起有落点，否则改画布 schema 无从判别） |
| `media: {ref: {mime}}` | **不落库**：它是派生索引（真源是各 item 的 `src`），载入时按需重建 |

### 迁移纪律：照抄文档笔记那套（双写 → 回填 → 校验 → 切读 → 停写）

| 步 | 动作 | 回退点 |
|---|---|---|
| 1 | ✅ **双写**（已实现）：写 `notes.content` 的同时写 `canvas_items` / `canvas_meta` / `ink_shards` | 随时可停写新表 |
| 2 | ✅ **回填**（已实现）：启动首帧后分批（50 篇/次）把"正文是画布 JSON 但表里没行"的存量补齐；**空白画布不进候选**（否则每次启动白占名额） | 幂等、可重跑 |
| 3 | ✅ **校验**（`verifyCanvasRows` / `readVerifiedCanvas`）：把行组装回 `toJson` 结构，与原文**深比较**（口径同 `verifyNoteBlocks`：不比字节、比数组顺序）。深比较器与块树**共用一份**（`json_deep_eq.dart`），两边只各写自己的归一化 | 不过就回退 JSON |
| 4 | ✅ **切读**：`NoteStore.noteById` 优先从表装回，校验不过静默回退 `notes.content` | 这就是"降落伞"（见上方"第 5 步暂缓"的说明） |
| 5 | **停写 JSON**：稳定后才允许，**且必须早于 v10 删列** | 此步不可逆 |

第 1 步的改口很小：`canvas_note_view._flush` 现在只调 `_controller.toJson`，双写只是多调一次
"拆分写入"。**内核不需要感知存储**——`toJson/fromJson` 仍是画布格式的唯一定义，表只是它的另一种物理布局。

### 与 v10 的关系

`docs/data_layer.md` 八.6 的前置条件就是本节：**本节 5 步走完之前，不许执行 v10 删 `notes.content`**。
（这一步原编号是 v8，因画布落点表先占了 v8，清理顺延为 **v10**。）

## 八、待拍板

1. ~~是否把 `canvas` 加成一种笔记类型~~ → **已定：做**（`docs/data_layer.md` 评审结论 1）。
   实现见落地顺序第 8 步：右栏按 kind 渲染，画布与块编辑器**同页共存**。
2. ~~卡片富文本是否复用 appflowy_editor~~ → **已定：用官方普通文本**（2026-09-18 拍板）。
   画布的定位是"帮人思考"而不是富文本排版，卡片用不上块编辑器的全部能力；
   编辑时挂一个普通输入框即可，省掉"一次只挂一个"那一整套复杂度。
3. **画布存储落点（见第七章）**：表（v8）与**第 1~2 步（双写 + 回填）已落地**，第 3~5 步待做。
   它是 `docs/data_layer.md` 八.6 里 **v10** 删 `notes.content` 的**前置条件**——不落地就不许删列。
4. ~~橡皮是"笔画橡皮"还是"部分擦除"~~ → **已定：保持笔画橡皮**（整条删）。
   不做像素橡皮与遮罩法；真要部分擦除走切分法，三条硬约束见第四章"橡皮"那段。

---

## 九、块可迁移（#5，2026-09-18）

文档块 ↔ 画布卡片是**同一份内容**：卡片用 `blockId` 指向 `blocks` 里的一行（见第七章
"卡片是例外"）。于是"搬动"只是改这块的**归属**——在文档块树里、还是在画布上——块内容
永不动，可逆、不丢字。

### 可逆操作（数据层，已落地 + 单测）
- `NoteStore.moveBlockToCanvas(blockId)`：把块从文档块树摘除（块内容留在 `blocks`，由画布卡片托管）。
- `NoteStore.moveBlockToDocument(blockId)`：把块重新挂回它所属文档块树的根部。
- 两者用 `blocks.note_id` 反查归属笔记，`moveBlockToDocument` 幂等（已在树里则不重复加）。
- 表记：`test/data/block_migration_test.dart`（4 项，含"被卡片引用则 `replaceNoteBlocks` 不删孤儿块"）。

### 关键陷阱：块投影的删除集
`BlockStore.replaceNoteBlocks` 把"不在文档块树里"的块当**孤儿删除**。若"搬去画布"后
下一次文档保存走这套逻辑，会把这块连同卡片一起删掉。

**解法**：删除集排除 `canvas_items.block_id` 已引用的块（见
`BlockStore._canvasReferencedBlockIds`）。⚠️ 调用顺序铁律：**先建好引用该块的画布卡片、
再摘除块**——否则那一瞬块的 `blocks` 行会被误删。（没人引用的块仍照常删除，避免孤儿堆积。）

### 交互入口（已落地：画布 → 文档）
选中**单张**卡片时，工具条出现「发回文档」：
- 控制器 `detachSelectedCard()` 把卡片从内存摘除并清空选区，返回 `blockId`；
- `CanvasNoteView` 把 `blockId` 交给 `NoteStore.moveBlockToDocument` 落进文档块树；
- 画布侧靠现有防抖保存把卡片移除持久化。按钮显隐在 `canvas_surface.dart` 的
  `_SendCardToDocumentButton`。

### 待做：文档 → 画布（反向）
文档编辑器里"把某块抬到画布"的入口尚未做——需要块编辑器的块级选中 + 触发
`moveBlockToCanvas` + 在画布新建引用该 `blockId` 的卡片。数据层已就绪，只差编辑器侧触发。

---

相关文档：`docs/data_layer.md`（存储 schema 与迁移；本章的 v10 前置条件见其八.6）、
`docs/editor_migration_spike.md`（编辑器格式演进）。
