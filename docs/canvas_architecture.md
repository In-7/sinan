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
| `kernel/canvas_item.dart` | item 模型（形状/图片）+ 四角缩放手柄几何（屏幕常量尺寸） |
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
| L2 | 分块（瓦片）重放 + 空间索引换均匀网格 | ⬜ 笔迹 > 1w 条且 L1 不够时 |
| L3 | 卡片 LOD（TextPainter 替代 widget 挂载） | ⬜ 接入卡片时 |

> L1 的关键性质：`ui.Picture` 是**显示列表**不是位图 ⇒ 换个缩放重放仍是矢量清晰度，
> 这一点与"截图缓存"完全不同，也是敢在无限缩放的画布上用它的前提。

预算：1080p 视口、1w 条笔迹下，平移/缩放稳定 60fps；书写端到端延迟 < 1 帧。

## 六、落地顺序

1. ✅ 相机 + 文档模型 + 笔迹层（视口裁剪）+ 输入流水线（压感/掌拒/手势）
2. ✅ 页面与工具条（笔/橡皮/框选/抓手/撤销重做/缩放）+ 单测（11 个）
3. ⬜ 10k stroke 帧率实测（填满样本后 profile）
4. ✅ item 模型（形状/图片）+ 命中测试 + 变换手柄（单选缩放；多选整体拖动）
5. ⬜ 卡片文本：挂载/卸载单个 appflowy_editor 实例 + LOD 降级
6. 🟡 持久化：**先走 `notes.content` 存画布 JSON**（`canvas_note_view.dart` 防抖自动保存，2026-09-16）；
   目标形态见**第七章**（`canvas_items` / `canvas_meta` / `ink_shards`），按"双写 → 回填 → 校验 → 切读
   → 停写"推进（**第 1~2 步已实现**）——⚠️ 它是 `docs/data_layer.md` 八.6 里 v9 删列的**硬前置条件**
7. ⬜ 思维导图：树布局（Walker/Reingold–Tilford，~80 行）+ 端口贝塞尔连线
8. ✅ 接入 `NoteKind.canvas`（2026-09-16）：DB v6 已放行 `'canvas'`，Dart 侧枚举补齐，
   右栏按 kind 渲染（文档 → 块编辑器 / 画布 → 画布），侧栏「新建画布」直接建画布笔记

## 七、存储落点：画布对象落到哪些表（2026-09-17 设计）

**进度（2026-09-17）**：v8 建表 + **第 1~2 步（双写 + 回填）已实现**（`data/canvas_store.dart`：
双写在 `NoteStore.create` / `updateContent` 里与 blocks 投影并排调用；回填在启动首帧后分批跑）；
**读路径仍是 JSON**，第 3~5 步待做——按纪律要等双写/回填在真实数据上跑稳。

**现状**：整张画布（相机 + items + 笔迹）序列化成 JSON 存 `notes.content`
（见三章 `canvas_note_view.dart`）。这条路径能跑，但有三处硬伤：

1. **v9 会连坐**：`docs/data_layer.md` 八.6 计划删 `notes.content`，而画布**没有别的落点** ⇒ 一旦执行，整张画布失存；
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

### 表设计

```sql
-- 画布对象（形状 / 图片 / AI 图层）：z 序 + 空间几何 + 样式
CREATE TABLE canvas_items (
  id           TEXT NOT NULL,             -- CanvasItem.id（⚠️ **跨画布不保证唯一**，见下）
  note_id      TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL,             -- shape.rectangle / shape.ellipse / image / ai_image
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
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  fingerprint  TEXT NOT NULL,              -- 与 blocks 同口径（fp1）
  PRIMARY KEY (note_id, id)                -- ⚠️ 复合主键，见下
);
CREATE INDEX idx_canvas_items_note ON canvas_items (note_id, z);

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
| 3 | **校验**（新函数 `verifyCanvasRows`）：把行组装回 `toJson` 结构，与原文**深比较**（口径同 `verifyNoteBlocks`：不比字节、比数组顺序） | 不过就回退 JSON |
| 4 | **切读**：优先从表装回，校验不过静默回退 JSON | 这就是"降落伞" |
| 5 | **停写 JSON**：稳定后才允许，**且必须早于 v9 删列** | 此步不可逆 |

第 1 步的改口很小：`canvas_note_view._flush` 现在只调 `_controller.toJson`，双写只是多调一次
"拆分写入"。**内核不需要感知存储**——`toJson/fromJson` 仍是画布格式的唯一定义，表只是它的另一种物理布局。

### 与 v9 的关系

`docs/data_layer.md` 八.6 的前置条件就是本节：**本节 5 步走完之前，不许执行 v9 删 `notes.content`**。
（这一步原编号是 v8，因画布落点表先占了 v8，清理顺延为 **v9**。）

## 八、待拍板

1. ~~是否把 `canvas` 加成一种笔记类型~~ → **已定：做**（`docs/data_layer.md` 评审结论 1）。
   实现见落地顺序第 8 步：右栏按 kind 渲染，画布与块编辑器**同页共存**。
2. 卡片富文本是否复用 appflowy_editor（复用几乎零成本，但需严格"一次只挂一个"）。
3. **画布存储落点（见第七章）**：表（v8）与**第 1~2 步（双写 + 回填）已落地**，第 3~5 步待做。
   它是 `docs/data_layer.md` 八.6 里 **v9** 删 `notes.content` 的**前置条件**——不落地就不许删列。
4. ~~橡皮是"笔画橡皮"还是"部分擦除"~~ → **已定：保持笔画橡皮**（整条删）。
   不做像素橡皮与遮罩法；真要部分擦除走切分法，三条硬约束见第四章"橡皮"那段。

---

相关文档：`docs/data_layer.md`（存储 schema 与迁移；本章的 v9 前置条件见其八.6）、
`docs/editor_migration_spike.md`（编辑器格式演进）。
