# 数据层设计（AI 时代的存储）

目标：让**流式文档（flow）与无限画布（canvas）共用一套数据模型**，且这条路能自然长出
块级检索（AI）。2026-09-16 立项。

**进度（2026-09-17 更新）**：v6（表重建）、v7（建表 + 双写 + 回填 + 校验 + 切读）**已完成**；
`vec_chunks` / `vec_map` 按 6.2 刻意未建；**v8 = 画布落点表（已建）+ 双写与回填（已实现）**；
**v9（删 `notes.content`）待办，且必须先满足八.6 的前置条件**。一~七章的设计已按代码现状核对过；
五章的墨迹接管时机与八章 v9 的前置条件需要一起定。

## 一、结论

**单文件 SQLite + 块级表 + 同库内的 FTS5 / 向量扩展**，并且这条路**不需要 Rust**。

| 决策 | 结论 |
|---|---|
| 存储引擎 | SQLite 单文件（现状就是，继续用） |
| 正文粒度 | **块（row per block）**，不再是整篇 JSON blob |
| 墨迹粒度 | **分片 blob**（独立于 blocks），不按笔存行 |
| 块内容格式 | **不透明 JSON**（存储层不解析） |
| 关键词路 | FTS5 虚拟表（**中文 bigram 预处理**） |
| 语义路 | sqlite-vec（vec0）扩展，Dart 侧直接加载 |
| 是否要 Rust | **不需要**（AI 走 Ollama；向量检索引擎是 SQLite 扩展） |

## 二、现状盘点（已核实）

`lib/src/data/database.dart`：

- `notes(id, kind CHECK IN ('spark','note'), title, content, content_hash, plain_text,
  created_at, revised_at, promoted_at)`，`userVersion = 5`
- `settings(key, value)`；`snapshots` 在 v2 已 DROP
- pragma 只有 `PRAGMA foreign_keys = ON`（`:26`）
- 存储位置：`getApplicationSupportDirectory()/sinan.db`

`lib/src/data/note_store.dart`：

- **整篇判变**：`content_hash` 是整篇内容的指纹（2026-09-16 起是 `fp1:` 廉价指纹，
  不再是 SHA-256），没变则不写
- 列表查询刻意**不带 `content` 列**（`:107-115`），正文按 id 单取
- 排序：`(promoted_at IS NULL) ASC, promoted_at DESC, revised_at DESC, created_at DESC, id ASC`
  —— 末尾两级兜底键是刻意加的（毫秒时间戳会并列，无兜底键列表会莫名抖动）

`lib/src/editor/core/note_document_adapter.dart`：

- 落库格式已是 **v2 块树**，且**每个节点自带稳定 `id`**（`:179-187` 为此自写了序列化，
  因为 appflowy 的 `Node.toJson()` 不写 id、`fromJson` 会重发 nanoid）

> 🔑 **这一条决定了迁移成本**：块 id 已经存在且稳定 ⇒ 迁到 row-per-block 时可以直接沿用，
> 将来 AI 索引里的 `block_id` 在迁移后**依然对得上**，不必重建索引。

## 三、为什么必须走出"整篇 blob"

| 维度 | 整篇 blob（现状） | 块级（目标） |
|---|---|---|
| 检索粒度 | 命中"整篇"，用户还要自己找在哪 | **命中块 + 跳到块**（唯一可用的体验） |
| 自动保存 | 改一个字 → 重写整篇 | 只写变动的那个块：写量从 O(篇) 降到 O(块) |
| 画布放大 | 一张画布几千笔 → 每次保存写 MB | 分片写，只写最后变动的分片 |
| 判变粒度 | 整篇指纹，一处改动就要落整篇 | 块级指纹，真正跳过未变部分 |
| 引用 / 反链 | 无法指向块 | `block_id` 天然可作为引用目标 |

**反过来——什么时候不该拆**：如果只需要"按标题搜笔记"，整篇 blob 完全够用。
拆块的唯一理由是**块级粒度本身**（AI 检索、增量写、块引用），不是为了"规范化"。

## 四、目标 schema（v6）

```sql
-- ── 笔记元数据（列表查询只读这张表）──────────────────────────────
CREATE TABLE notes (
  id            TEXT PRIMARY KEY,
  kind          TEXT NOT NULL CHECK (kind IN ('spark','note','canvas')),
  title         TEXT NOT NULL DEFAULT '',
  plain_text    TEXT NOT NULL DEFAULT '',      -- 派生：列表预览/Tooltip/搜索
  created_at    INTEGER NOT NULL,
  revised_at    INTEGER NOT NULL,
  promoted_at   INTEGER,
  deleted_at    INTEGER                        -- 预留软删，当前仍硬删
);
CREATE INDEX idx_notes_order ON notes (promoted_at DESC, revised_at DESC, created_at DESC, id ASC);

-- ── 内容与实体统一为"块" ────────────────────────────────────────
CREATE TABLE blocks (
  id          TEXT PRIMARY KEY,                -- 沿用 v2 块树里已有的 node.id
  note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  type        TEXT NOT NULL,                   -- paragraph/heading/code/image/…
  props_json  TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(props_json)),
                                               -- ⚠️ 存储层不解析（见下）
  ord         INTEGER NOT NULL,                -- 稀疏整数步长 1024
  parent_id   TEXT REFERENCES blocks(id) ON DELETE CASCADE,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  fingerprint TEXT NOT NULL                    -- 块级判变（同 fp1 方案）
);
CREATE INDEX idx_blocks_note ON blocks (note_id, ord);
CREATE INDEX idx_blocks_parent ON blocks (parent_id, ord);

-- ── 墨迹：不走 blocks ──────────────────────────────────────────
CREATE TABLE ink_shards (
  note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  shard_index INTEGER NOT NULL,                -- 0,1,2… 每片约 256~512 笔
  points_blob BLOB NOT NULL,                   -- Float32List：x,y,pressure 三元组
  style_json  TEXT NOT NULL DEFAULT '{}',      -- 每笔的颜色/宽度/流派
  count       INTEGER NOT NULL,
  fingerprint TEXT NOT NULL,
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (note_id, shard_index)
) WITHOUT ROWID;
```

**三条设计原则**

1. **透明的块边界 + 不透明的块内容**。SQL 层只认 `type` 和一串 JSON；加新块类型
   **不改表、不迁移、不影响任何查询**。这条是从 askia 的 blocks 表验证过来的，
   是整个方案里最值钱的一条。
2. **`ord` 用稀疏整数（步长 1024）**：两块之间有空隙可用，插入不必重排；只有当某个
   缝隙被连续插入耗尽时，才对这一篇的 `ord` 做一次局部重排（renormalize）。文档的
   块数量级是几百，一次批量 `UPDATE` 在事务内是微秒级，不值得引入 LexoRank 的复杂度。
3. **`kind` 多了 `canvas`** ⚠️：SQLite **不能直接改 CHECK 约束**，v6 迁移必须
   **重建 notes 表**（建新表 → 拷数据 → DROP → RENAME）。这条容易被忽略，列进迁移步骤。

## 五、墨迹为什么独立成分片表

墨迹有两个特性：**写入频率极高**（一笔画完一次写）、**单笔没有语义检索价值**
（不会有人要搜"某一条单独的笔迹"）。塞进 `blocks` 会让表瞬间膨胀到几万行。

> 📌 **落地现状（2026-09-16）**：画布刚接进右侧内容区时，**先**把整张画布序列化成
> JSON 存进 `notes.content`（见 `canvas_note_view.dart`）——画布是独立的笔记形态
> （`kind='canvas'`），其 `content` 不与块树冲突，且 `BlockStore` 对非 v2 内容安全
> 跳过。`ink_shards` 是笔迹规模上来后的目标形态，两者不冲突：切换只改存储适配层。
>
> ⚠️ **2026-09-17 补充**：上面那句"切换只改存储适配层"只对**笔迹**成立。对文档笔记
> `notes.content` 是过渡列（真相源已切到 `blocks`），但对**画布它是唯一真相源**——
> 所以 v9 删列之前，画布必须先在表里有落点，见**八.6 的前置条件**。

- **分片（256~512 笔/片）而非整张画布一条**：保存时只重写"最后变动的那一片"，
  这是真正的增量保存粒度
- **二进制而非 JSON**：`(x, y, pressure)` 用 Float32 编码，体积约为 JSON 的 1/4，
  且反序列化是内存拷贝级别的快
- **与现有缓存机制对齐**：`CanvasController` 已经用 `revision` 驱动 `ui.Picture`
  缓存（`canvas_controller.dart:151-159`），分片与之天然对齐

## 六、AI 层：必须放在**同一个库文件**里

```sql
-- 关键词路（⚠️ 中文必须 bigram 预处理）
CREATE VIRTUAL TABLE chunks_fts USING fts5(
  search_text,                       -- 分词后的 bigram 串，参与索引
  block_id   UNINDEXED,
  note_id    UNINDEXED,
  chunk_text UNINDEXED,              -- 原文，供结果摘要
  tokenize = 'unicode61'
);

-- 语义路（sqlite-vec）
CREATE VIRTUAL TABLE vec_chunks USING vec0(embedding float[1024]);
CREATE TABLE vec_map (vec_rowid INTEGER PRIMARY KEY, block_id TEXT NOT NULL UNIQUE);

-- 进度/版本/模型指纹等
CREATE TABLE rag_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

**为什么不能拆成"笔记库 + 索引库"两个文件**：漂移。笔记删了索引还在、编辑器回滚了
向量还是旧的——两边无法在一个事务里保持一致性。同库是唯一能让"删除"做到原子的方案。

### 6.1 FTS5 的中文坑（硬性）

默认 `unicode61` 分词器会把连续中文**当成一个 token**：存了"番茄工作法"，用"番茄"
去 `MATCH` 命中为 0。解法是写入和查询**两侧都做同样的预处理**：
`search_text` 存 bigram 空格串（"番茄 茄工 工作 作法"），查询串同样 bigram 后 
用 `"t1" OR "t2"` 组合（宽容召回，精确性交给融合阶段把控）。
原文保留在 `chunk_text`（`UNINDEXED`，不参与索引）。

### 6.2 向量侧：不需要 Rust

已核实 `sqlite3: ^3.5.2` 提供：

```dart
SqliteExtension.inLibrary(DynamicLibrary library, String symbol)
```

即 `DynamicLibrary.open('vec0.dll')` + 入口符号即可加载 sqlite-vec，
**整个语义检索链路可以留在 Dart 侧**。

⚠️ **但 `vec_chunks` / `vec_map` 不在 v7 建表**：此刻项目还没引入 sqlite-vec 的 DLL，
缺模块时 `CREATE VIRTUAL TABLE` 会**直接失败**（不是降级）。两张表**成对**引入，
留到「接入 Ollama（含嵌入）」那一步一起加。FTS5 是 SQLite 自带的，所以现在就建。
`test/data/database_v7_test.dart` 里有一条断言专门钉住"vec 表缺席"，防止有人提前加回来。

容量估算（Ollama 的嵌入模型，dim 常见 768/1024）：

| 块数 | float32 | int8 量化 |
|---|---|---|
| 1 万 | ~30-40 MB | ~10 MB |
| 10 万 | ~300-400 MB | ~100 MB |

这个量级 SQLite 内暴力 cosine 是毫秒级，**不需要 ANN，也不需要独立向量数据库**。

### 6.3 删除一致性（三个必须知道的点）

1. `PRAGMA foreign_keys = ON` **必须开**（已开），否则 `ON DELETE CASCADE` 不生效
2. **FTS5 虚拟表不支持外键** ⇒ 删 block/笔记时**必须手工删 FTS 行**
3. `vec0` 用 rowid 定位，而 `block_id` 是 TEXT ⇒ 需要 `vec_map` 做双向映射
   （实现阶段请以 sqlite-vec 当时的文档核对一遍，它有版本差异）

### 6.4 融合

检索 = dense top-K + FTS top-K → **RRF（k=60）**，分数 `Σ 1/(k + rank + 1)`，
两路都命中的自然排到最前。嵌入模型未就位时关键词路仍可独立工作（降级而非不可用）。

### 6.5 嵌入的触发时机：**用户手动按钮**（2026-09-16 定）

不用后台自动地/空闲批处理器，而是给一个「**建立 / 更新索引**」的按钮，理由是：

- **机械复杂度最低**：不需要调度器、队列、背压、节流、退出时的中断安全。
  AI 是整个应用里唯一「有外部依赖」的部分，把它做成**显式、可预期、可取消**的动作，
  比偷偷跑要好排查得多。
- **性能上其实没有损失**：嵌入请求是 HTTP IO（`Ollama /api/embed`），它是**异步事件**
  而非阻塞计算，Dart 侧等待期间 UI 照常。唯一重的是……没有了。不像本地 ONNX 推理
  那样要抢 CPU、要和编辑器的渲染帧竞争。
- **是一条单向的上坡路**：先把手按钮做对（**增量 + 幂等 + 可取消 + 有进度**），
  以后想改成「空闲自动」，只是换一个调用方触发同一个函数。反过来（先做自动再降级
  成手动）则要拆掉一堆机械件。

**设计要点（决定是否好用的地方）**

1. **必须是增量、幂等的** —— 靠一张状态表记录「已索引时的指纹」，重复点开销是 0：
   ```sql
   CREATE TABLE index_state (
     block_id    TEXT PRIMARY KEY REFERENCES blocks(id) ON DELETE CASCADE,
     fingerprint TEXT NOT NULL,               -- 索引时块的指纹；与 blocks 不同 ⇒ 需重算
     model       TEXT NOT NULL,               -- 换了嵌入模型 ⇒ 全部失效
     updated_at  INTEGER NOT NULL
   );
   ```
2. **按钮上要显示待处理数量**（`fingerprint 不匹配 或 无索引记录` 的块数），
   否则用户不知道该不该点。
3. **分批请求**：Ollama 的 `/api/embed` 的 `input` 支持数组，一次 32~64 条，
   既省请求开销又能出进度。
4. **可取消 + 有进度**：`N / 总数`，取消即停止后续批次（已算出的已经写进去了，幂等）。
5. **失败可重试**：失败块记为「未索引」，下次点继续；不要因为一块错了就整体回滚。

> 「以后要不要改成空闲自动」交给真实使用数据决定：手动点到厌倦了再自动化，
> 那时我们已经知道「空闲多久算空闲」的答案了。反过来先写策略、再靠猜参数调优，是浪费。

### 6.6 云端嵌入（可选后端）：要补三处，但**正文格式不用改**

主路径仍是**本地**（Ollama + sqlite-vec，见 6.2）；但用户可能选云端嵌入。能同时支撑两种后端的，
正是已有的三件事：`blocks` 的**行级稳定 id**、块级 **`fingerprint`**、**`index_state`**（增量 + 幂等）。
要补的是下面三处，**都不动正文存储**：

1. **过期判据补全**：`index_state` 现在只有 `model`。加 **`chunker_version`**——切块规则变了而
   模型没变时，旧向量必须失效，否则会留下"用旧策略切的块"。
2. **删除要能传到远端**（⚠️ 唯一会出真 bug 的地方）：本地靠 `ON DELETE CASCADE` + 手工清 FTS 行
   （6.3），但**远端向量库没有事务与级联**。需要一个**出网队列 / 墓碑**（`pending_delete` 表或
   `index_state.remote_state` 列）把删除同步出去，否则会"搜到已删的笔记"。
3. **后端抽象 + 显式开关**：把嵌入与检索抽成接口（`EmbeddingBackend`：`index` / `delete` / `query`），
   本地实现 = 同库 sqlite-vec，云端实现 = HTTP——与画布内核的 `AiGenerator` 是同一套依赖倒置手法。
   同时要能回答"**哪些笔记允许出网**"：出网的只有**文本**，绝不含墨迹与图片字节，且能一键清除远端副本。

降级要求不变：云端不可达时**退回关键词路（FTS5）**，而不是不可用（见 6.4）。

#### ① `chunker_version`：只加一列，加在 `index_state` 上

```sql
-- 随 vec 表一起加（这张表现在还没有 UI 消费，加列零风险）
ALTER TABLE index_state ADD COLUMN chunker_version TEXT NOT NULL DEFAULT '';
```

- 代码里放一个常量 `kChunkerVersion = 'ck1'`（沿用 `fp1:` 的"版本前缀"风格，便于 grep）；
  **切块规则一变就 +1**（例如以后把相邻短段合并成一块）。
- `''`（旧行 / 尚未写）= 永远过期 ⇒ 首次接入时全量重算一次，之后走增量。
- 判定：`需要索引 = 行不存在 ‖ fingerprint 变了 ‖ model 不匹配 ‖ chunker_version 不匹配`。
- **`model` 的含义升级为"嵌入身份"**（不加列）：存 `provider:model:dim`（如
  `ollama:nomic-embed-text:768`）而不是裸模型名——换 provider 或换维度都会自动全量失效，
  避免"同一个模型名、不同向量空间"混用（这类脏数据最隐蔽：不报错，只是召回变差）。

#### ② `pending_delete`：一张**孤岛表**，专门把删除传到远端

```sql
CREATE TABLE pending_delete (
  kind       TEXT NOT NULL,        -- 'chunk' | 'note' | 'all'
  ref        TEXT NOT NULL,        -- chunk: block_id / note: note_id / all: '*'
  note_id    TEXT,                 -- 便于按笔记清理与审计
  queued_at  INTEGER NOT NULL,
  attempts   INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  PRIMARY KEY (kind, ref)
) WITHOUT ROWID;
```

四条设计约束，每条都有理由：

1. **必须与删除动作在同一个事务里入队**：本地删除立即生效、远端异步追平——本地永不阻塞在网络
   上（本地优先），且进程崩溃也不会漏掉"该删的远端副本"。
2. **这张表不能挂 `blocks` 外键、不能参与级联**：`index_state` 是挂在 `blocks(id)` 上的，删笔记时
   `ON DELETE CASCADE` 会把"需要去远端删哪些块"的信息**一起删掉**——结果就是远端副本永久残留、
   搜索仍能搜到已删内容。所以墓碑必须放在**删不掉的地方**：这是"孤岛表"的全部意义。
3. **远端 id 由本地 id 确定性派生**（`block_id` 直接当远端 id，upsert 覆盖即可）⇒ **不需要维护
   远端映射表**；删除请求做成**幂等**（远端删不存在的 id 视为成功）⇒ 队列里有冗余项无害。
4. **失败不静默丢**：`attempts` / `last_error` 支撑退避重试；超过上限后**保留并告警**，绝不丢弃
   （丢弃 = 永久残留）。`kind = 'all'` 用于"切换 provider / 用户退出云端"时清空远端副本。

> 📌 **画布侧入检索的形状**：只有**文本对象**值得向量化（文本卡 / 便签 / 图片 OCR 文本）；
> 几何描述（"x=100 的红圆"）没有检索价值。因此**文本卡落地时必须给它全局唯一的 id**——
> 现在的 `CanvasItem.id` 是进程内计数器、跨会话会重复（见 `docs/canvas_architecture.md` 第七与第八章）。

## 七、写入路径的变化

| | 现在 | v6 之后 |
|---|---|---|
| 判变对象 | 整篇 `content` | **每个块**各自的 fingerprint |
| 一次输入触发的写 | 1 次 UPDATE（整篇） | N 次 UPDATE（仅变动的块），N 通常为 1 |
| 防抖 | 500ms（`_saveDebounce`） | 保持；画布走分片级防抖 |
| 指纹成本 | 977K 字符 ≈ 0.8ms（已实测） | 块级后每次只算几百字符，**微秒级，不必进 isolate** |

### 7.1 落盘时机：暴露窗口封顶 + 退出前落盘（2026-09-17 收口）

"异常退出最多丢多少"原先有两个洞，同日都堵上了：

| 洞 | 现象 | 收口 |
|---|---|---|
| 纯防抖在**连续输入**下一次都不落盘（每次变更都重置计时器 ⇒ "停顿"永不成立） | 狂打字 / 不停运笔三分钟，暴露窗口就线性涨到三分钟 | 防抖加**上限** `kSaveMaxWait = 2s`（**不可重置**，只在落盘时清）——见 `app/save_debounce.dart` |
| 关窗口**没有显式 flush** | 用户实测：删掉一段文字、马上关窗口，重开后那段文字**又回来了**——防抖没到期，而进程退出时 widget `dispose` 的兜底落盘是 fire-and-forget（来不及写完，甚至根本不会被调用） | 用**官方的可取消退出请求**：`WM_CLOSE` 由引擎消费（非阻塞）→ `System.requestAppExit` → `didRequestAppExit` 里等落盘写完（`flushThenExit` → `PendingSaves.flushAll`，上限 2s）→ 答 `exit` 后引擎补发第二个 `WM_CLOSE` 才真正销毁窗口 |

注册方：编辑器（正文 + 标题两个防抖）与画布（`CanvasNoteView`）挂载时 `register`、
`dispose` 时注销——**不注销就会对已销毁的视图落盘**。判据与各自 `dispose` 一致
（只有未落盘变更才写），所以"打开看一眼就关窗口"不会重写正文。

⚠️ 边界：**任务管理器强杀 / 断电**仍然无法保证，那两类只能靠上限把窗口收到秒级。
关闭按钮与菜单里的"退出"走同一条路（`WM_SYSCOMMAND/SC_CLOSE` → `WM_CLOSE`）。

⚠️ **不要再用 `window_manager.setPreventClose(true)` 自己拦关闭**（2026-09-17 试过并
弃用）：它会**先吞掉** `WM_CLOSE`（原生 `return -1`），引擎的官方流程根本收不到，
只能退回自研 `PostQuitMessage` 拆应用——实测症状是窗口卡在标题栏 **"(未响应)"**
（Dart 侧还有未完成的落盘与通道往返时，应用被推进半拆解状态：窗口既不销毁、也不再
处理消息）。引擎的方案天然非阻塞，等待落盘期间窗口是**响应**的。

## 八、迁移计划（v6，可分发布）

原则：**可回滚 + 可校验**，不做一次性不可逆操作。

**版本对应与进度**（2026-09-17 更新）：第 0 步 = **v6**（已完成）、第 1~5 步 =
**v7**（已完成：建表 + 双写 + 回填 + 校验 + 切读）、第 6 步清理 = **v9**（待办；
原编号 v8，被画布落点表占用而顺延。建议先跑一段时间真实数据再删旧列）。
另：**v8 = 画布落点表**（`canvas_items` / `canvas_meta`，已建；画布侧双写与回填已实现，
见 `docs/canvas_architecture.md` 第七章）。

0. **v6 `notes` 表重建**（决策 1 的必然结果）：SQLite 改不了 CHECK 约束，只能
   建新表（含 `canvas` 取值 + `deleted_at` 列）→ `INSERT INTO … SELECT` →
   `DROP` → `RENAME`。必须**先跑这一步**，后续新表才能外键到它。
   注意顺序：重建期间 `PRAGMA foreign_keys` 会影响 DROP 的行为，教科书做法是
   `foreign_keys=OFF` → 重建 → 校验数量一致 → `foreign_keys=ON` 并检查
   `PRAGMA foreign_key_check`。
1. **v7 加新表**（`blocks` / `ink_shards` / `chunks_fts` / `index_state` / `rag_meta`）
   ——纯增量，随时可回滚。⚠️ `vec_chunks` + `vec_map` **不在此列**，见 6.2
2. **双写**：新格式写入的同时，**保留 `notes.content` / `content_hash` / `plain_text`**
   原样不动一个版本
3. **回填**：应用启动时把尚未拆分的笔记解析成 blocks，**沿用原节点 id**
   （这是前面说的红利：将来 AI 索引不必重建）
4. **校验**（已实现，`BlockStore.verifyNoteBlocks`）：把 blocks **还原成树**，
   与 `notes.content` 里的原始块树做**结构深比较**。
   - 不比字节：JSON 对象的键顺序无语义（appflowy 的 `_nodeToJson` 是
     先 `type/data` 后 `id`，与我们还原的顺序不同）；
   - **比数组顺序**：`children` 是数组，顺序就是文档顺序；
   - 比较前归一化：节点缺 `data` 键时补 `{}`，否则这类笔记会永远校验失败。
5. **切读**（已实现，"带降落伞"）：`NoteStore.noteById` **优先从 blocks 还原**，
   但**只在校验通过时采用**，否则静默回退到 `notes.content`。

   > 这是整个迁移里唯一能直接毁掉用户内容的一步，所以刻意做成"最坏情况是
   > 还没切过去，而不是切坏了"。校验 + 回退的代价是一次解析（≪1ms），换来的是
   > 出任何还原偏差时应用仍然无感。等 v9 删旧列时，这个回退才一并移除。
6. **v9 清理**（留到双写校验通过之后）：删 `notes.content` + `content_hash`

   ⚠️ **硬前置：画布必须先有落点**。`notes.content` 对文档笔记只是过渡列，对**画布却是
   唯一真相源**（见五章落地现状）——照当前 schema 直接执行 v9，**画布会整体失存**：
   相机 / 形状 / 图片引用 / AI 配方没有任何表承接，笔迹也还内联在 JSON 里。

   **落点方案（2026-09-17 定方向，详见 `docs/canvas_architecture.md` 第七章）**：画布对象
   **不进 `blocks`**，而是三处落点——
   - `canvas_items`：形状 / 图片 / AI 图层（z 序 + 空间几何 + 样式列）；
   - `canvas_meta`：相机 + **画布 `schema_version`**（这个版本号现在无处可存）；
   - `ink_shards`：笔迹（已建，见五章）。

   **为什么不进 `blocks`**：两者唯一共享的不变量**只有归属（note_id）**，而 `blocks` 的
   `ord` / `parent_id` 是**文档树**语义（阅读序 + 层级），画布要的是 z 序 + 空间几何。
   硬塞一张表的代价：`ord` 一列两种含义、AI 管道（`chunks_fts` / `index_state`）处处要按
   type 过滤，且"复用文档侧三件套"（`replaceNoteBlocks` / `readNoteDocument` /
   `verifyNoteBlocks`）是**假收益**——那是"块树 ⇄ 树 JSON"的专用转换，画布是另一套转换。
   物理表的边界应画在"共享不变量"上：共用**约定**（稳定 id、`note_id` 级联、`fingerprint`、
   `*_json` 扩展位），不共用**物理表**。

   实施按既有五步纪律走（双写 → 回填 → 校验 → 切读 → 停写），细节与列清单见画布文档第七章。
   "删列前必须有落点"这条**是硬前置**，不随实施顺序变化。

   SQLite 的 `ALTER TABLE DROP COLUMN` 需要 3.35+，Windows 版自带足够新。

## 九、容量与性能预算

| 场景 | 现在 | v6 之后 |
|---|---|---|
| 打开一篇 500 块的笔记 | 读 1 行，解析整篇 JSON | 读 500 行，**但无 JSON 解析**（props 直接用） |
| 改一个块 | 重写整篇 | 更新 1 行 |
| 列表滚动 | 与现在一致（`allNotes()` 仍不取正文） | 不变 |
| 全文/语义检索 | 现在没有（列表只有标题匹配） | 同库 FTS5 + vec0，毫秒级 |

⚠️ **待实测**：行数从"每篇 1 行"变成"每篇几百行"，首屏加载是否需要
`SELECT ... WHERE note_id = ?` 之外再加一层预取，要靠实机 profile 决定，不建议提前优化。

## 十、明确不做

- ❌ **不上独立向量数据库**（Qdrant / Milvus / Weaviate）：这个量级不值一个额外进程
- ❌ **不让 Rust 连这个库文件**：截图用的 Rust 核心只管像素，完全不碰 `-sinan.db`
- ❌ **不做按需同步 / CRDT**：单人本地优先，等产品真有同步需求再说
- ❌ **不引入 LexoRank 这类排序方案**：`ord` 稀疏整数够用
- ❌ **正文不落独立文件**（`.md` / `.txt` + 库里只存路径）：块级增量写、与元数据同事务、
  `block_id` 关联的检索、原子删除四件事都依赖正文在库里。"可携带 / 外部编辑器"用**导出**满足
  （画布已有自包含 `.canvas.json`），比搬存储便宜一个数量级（2026-09-17 评估外部方案后的结论）。
- ❌ **不引入第二套存储引擎**（SharedPreferences / Hive / Isar）：桌面本地优先场景下引擎越多，
  备份、跨引擎一致性、双真源漂移的成本越高；媒体文件是唯一必要例外（二进制 + 相对引用入库）。
- ❌ **撤销历史不持久化**：撤销栈留在内存（命令已按 id 寻址、可序列化，是刻意为"将来可重放"铺的
  路，但**不落盘**）。落盘换来"重启后还能撤销"，代价是一张只增不减的表 + 每次编辑多一次写；
  真要做崩溃恢复，正确形态是**会话级快照**而非全量撤销日志（2026-09-17 定）。

## 十一、评审结论（2026-09-16 已定）

| # | 议题 | 结论 | 影响 |
|---|---|---|---|
| 1 | canvas 是否作为 `notes.kind` 第三个值 | **做** | ⚠️ 触发 `notes` 表重建（改不了 CHECK），见迁移第 0 步 |
| 2 | `deleted_at` 软删 | **加列，暂不使用** | 迁移里加列；读路径仍按硬删语义 |
| 3 | 嵌入的计算时机 | **用户手动按钮**（含增量/幂等/进度/取消），见 6.5 | 不引入调度器；将来可平滑升级为空闲自动 |
| 4 | AI 三表是否先建 | **先建表**，UI 后做 | v6 一起建；无 UI 时不影响任何现有路径 |
| 5 | `props_json` 加 `CHECK(json_valid(...))` | **加** | schema 里已体现 |

> ⚠️ **待拍板（2026-09-17）**：画布落点**方向已定 = 独立表**（`canvas_items` + `canvas_meta`
> + `ink_shards`，见八.6 与 `docs/canvas_architecture.md` 第七章），待确认后实施。
> 它决定 v9 能否执行：不先落点，v9 删 `notes.content` 会删掉整张画布。与之同批待定的还有
> 五章的墨迹接管时机（`ink_shards` 何时真正启用）。

## 十二、待补强（2026-09-17）

1. **收口两处 View 越界**（"不要在业务代码里拼 SQL/操作文件"这条原则已满足：SQL 只在 `data/` 四个文件里）：
   - `canvas_note_view.dart:85` 直接持有 `NoteStore`、`:120` 直读库、`:179-186` 兜底**直写库**；
   - `note_editor_view_appflowy.dart:334-336` 直接 `ref.read(noteStoreProvider).noteById(...)`。
   ⚠️ 兜底直写是**有意的保命路径**（容器先于 widget 拆除的极端时序），收口前必须先设计替代方案。
2. **定期导出快照（容灾）**：单文件 SQLite 的好处是"拷一个文件"，代价是"坏了全丢"。
   低成本补强 = 定期把 blocks / 画布导成 Markdown / `.canvas.json` 快照，**而不是把存储拆成文件**。

---

相关文档：`docs/canvas_architecture.md`（画布侧的对象模型）、
`docs/editor_migration_spike.md`（编辑器格式演进）。
