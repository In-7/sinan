import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_vector/sqlite_vector.dart';

import '../domain/note.dart';

/// 数据库层：只负责「打开 + schema + 迁移」，不碰业务查询。
///
/// 沿用手写 SQL 的轻量路线（无 codegen），便于将来演进更复杂的 schema
/// （标签、双向链接、AI 缓存、embedding 等）。
///
/// 存储位置用 [getApplicationSupportDirectory]，跟着当前用户走，
/// 不污染可执行文件目录。
class AppDatabase {
  AppDatabase._(this.path, this.db);

  /// 数据库文件的绝对路径（后台 isolate 要用同一文件**另开连接**，不能发送
  /// [Database] 句柄本身——它绑定创建它的 isolate）。
  final String path;

  final Database db;

  /// 向量扩展（sqlite_vector，机制 A）是否加载成功。
  ///
  /// false ⇒ 检索层**降级纯 FTS**（6.4：降级而非不可用），向量路只是缺一条
  /// 召回路。R4 的查询侧以它为闸。
  static bool vectorExtensionAvailable = false;

  /// 文件库是否成功切到 WAL（网络盘等不支持的环境会静默回退 delete，
  /// 此时此值为 false，诊断用；功能不受影响）。
  static bool walEnabled = false;

  /// 异步只发生在「定位存储目录」这一步；打开与之后所有查询都是本地同步。
  static Future<AppDatabase> open() async {
    final Directory dir = await getApplicationSupportDirectory();
    final File file = File(p.join(dir.path, 'sinan.db'));
    // 向量扩展在任何连接打开**之前**做进程级注册（机制 A 的 native asset 由
    // 构建钩子编译，见 docs/data_layer.md 6.7）。失败不阻断启动——扩展缺席时
    // 建表/迁移照常成功（普通 DDL），只在真正跑向量 SQL 时才不可用。
    try {
      sqlite3.loadSqliteVectorExtension();
      vectorExtensionAvailable = true;
    } on Object {
      vectorExtensionAvailable = false;
    }
    final Database db = sqlite3.open(file.path);
    walEnabled = applyConnectionPragmas(db, requestWal: true) == 'wal';
    ensureSchema(db);
    return AppDatabase._(file.path, db);
  }

  /// 每个新连接都必须执行的 PRAGMA 配置（连接级属性不会随 db 文件继承，
  /// 将来若开第二连接/后台 isolate 也要调它）。
  ///
  /// - `busy_timeout=5000`：第二连接出现时防 SQLITE_BUSY（单连接下无副作用）。
  /// - `foreign_keys=ON`：级联删除的前提。
  /// - `journal_mode=WAL`（仅 [requestWal]，文件级持久属性）：写只追加
  ///   `-wal`、读不阻塞写；也为将来多连接（后台 isolate）铺路。不支持的
  ///   文件系统（如 SMB 重定向的 AppData）会**静默回退** `delete` 而非报错，
  ///   返回值如实反映，调用方按现状继续跑即可。
  /// - `synchronous`：**仅 WAL 成功时降 NORMAL**——WAL 下掉电最多丢最后一个
  ///   事务而库不损坏，本项目保存幂等（contentHash 判变 + 下次编辑补写）可接受；
  ///   DELETE 回滚模式必须保持 FULL，NORMAL 在该模式下有掉电损坏风险。
  ///
  /// 返回实际生效的 journal_mode（`wal` 或回退值 `delete`；内存库请求时
  /// SQLite 原样返回 `memory`）。未传 [requestWal] 时不读回，固定按 `delete`
  /// 口径返回（即保守使用 FULL 同步）。
  static String applyConnectionPragmas(Database db, {bool requestWal = false}) {
    db.execute('PRAGMA busy_timeout = 5000;');
    db.execute('PRAGMA foreign_keys = ON;');
    String journal = 'delete';
    if (requestWal) {
      final Row row = db.select('PRAGMA journal_mode = WAL;').single;
      journal = (row.values.first as String).toLowerCase();
    }
    db.execute(
      journal == 'wal'
          ? 'PRAGMA synchronous = NORMAL;'
          : 'PRAGMA synchronous = FULL;',
    );
    return journal;
  }

  /// 确保连接背后的库具备最新 schema（增量迁移；已是最新时为空操作）。
  ///
  /// 生产侧的第二个连接（启动回填后台 isolate）打开同一文件后也要调一次：
  /// 正常时序下主连接早已迁完、这里秒退，但不能假设 worker 永远晚于迁移。
  static void ensureSchema(Database db) => _migrate(db);

  /// 让测试能在**内存库**上建出同一份 schema（单一来源，避免测试里
  /// 抄一份 schema 后与真实迁移漂移）。
  @visibleForTesting
  static void migrateForTesting(Database db) => _migrate(db);

  /// 增量迁移。新增表 / 列时，把 version 往上加，补对应分支即可。
  static void _migrate(Database db) {
    if (db.userVersion < 1) {
      db.execute('''
        CREATE TABLE notes (
          id           TEXT PRIMARY KEY,
          kind         TEXT NOT NULL CHECK (kind IN ('spark','note')),
          title        TEXT NOT NULL DEFAULT '',
          content      TEXT NOT NULL DEFAULT '',
          content_hash TEXT NOT NULL,
          created_at   INTEGER NOT NULL,
          revised_at   INTEGER NOT NULL,
          promoted_at  INTEGER
        );

        CREATE TABLE snapshots (
          id           INTEGER PRIMARY KEY AUTOINCREMENT,
          note_id      TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
          day          TEXT NOT NULL,
          content      TEXT NOT NULL,
          content_hash TEXT NOT NULL,
          created_at   INTEGER NOT NULL,
          UNIQUE (note_id, day)
        );

        CREATE INDEX idx_snap_note_day ON snapshots (note_id, day DESC);
      ''');
      db.userVersion = 1;
    }

    // v2：移除按天快照功能（产品方向调整）。
    // 旧库：删除 snapshots 表及其中的历史数据；
    // 新库：v1 刚按旧 schema 建了 snapshots，这里顺带清掉。
    if (db.userVersion < 2) {
      db.execute('DROP TABLE IF EXISTS snapshots;');
      db.userVersion = 2;
    }

    // v3：富文本（Quill Delta JSON）。plain_text 存从 Delta 提取的
    // 纯文本，供列表预览 / Tooltip / 全文搜索（以及将来的向量化）使用，
    // 避免每次都解析 JSON。旧纯文本笔记：plain_text 先等于 content，
    // 保证预览不空；首次编辑时才转换为 Delta。
    if (db.userVersion < 3) {
      db.execute(
        "ALTER TABLE notes ADD COLUMN plain_text TEXT NOT NULL DEFAULT '';",
      );
      db.execute('UPDATE notes SET plain_text = content;');
      db.userVersion = 3;
    }

    // v4：清理历史纯文本示例笔记（产品确认无需保留）。
    // 只删旧格式（content 非 Delta JSON 开头），富文本数据不受影响。
    if (db.userVersion < 4) {
      db.execute("DELETE FROM notes WHERE content NOT LIKE '[%';");
      db.userVersion = 4;
    }

    // v5：应用设置（key-value）。首个使用者 = 外观/编辑器偏好
    // （主题种子色、明暗模式、正文宽度、正文字号、行高），必须跨
    // 会话持久化——每次开应用都要恢复用户选择。
    if (db.userVersion < 5) {
      db.execute('''
        CREATE TABLE settings (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
      ''');
      db.userVersion = 5;
    }

    // v6：**notes 表重建**。这是 `docs/data_layer.md` 里定下的**迁移第 0 步**，
    // 两件事一次性解决：
    // 1. `kind` 加第三个取值 `'canvas'`——画布成为正式的笔记形态（评审结论 1）；
    // 2. 预留软删列 `deleted_at`（评审结论 2：加列但**暂不使用**，读路径仍是硬删）。
    //
    // ⚠️ 为什么是"建新表 → 拷数据 → 删旧表 → 改名"：SQLite **不能修改 CHECK
    // 约束**，`ALTER TABLE ADD COLUMN` 也加不出新的 CHECK。要动约束就只能重建整表。
    //
    // ⚠️ `notes.content` / `content_hash` / `plain_text` **原样保留**：
    // 读路径还在用它们，删列留到 **v10**（原计划的"v8 清理"因画布落点表占了 v8 而
    // 顺延为 v9，v9 又被块结构画布的扩表占用，故再顺延为 v10；且必须先满足画布
    // 五步走完这个前置条件，见 `docs/data_layer.md` 八.6）。
    if (db.userVersion < 6) {
      _rebuildNotesForV6(db);
      db.userVersion = 6;
    }

    // v7：块级表 + AI 检索的事实表（`docs/data_layer.md` 迁移第 1 步）。
    //
    // 评审结论 ④「AI 表先建表、UI 后做」、⑤「props_json 加 CHECK(json_valid)」
    // 都在这一版落地。此刻**没有任何 UI 消费**这些表，纯增量、随时可回滚。
    //
    // ⚠️ 这一版**刻意不建** `vec_chunks` / `vec_map`：
    // 它们依赖 sqlite-vec 扩展，而项目此刻还没引入它的 DLL——没有这个模块时
    // `CREATE VIRTUAL TABLE` 会直接失败（不是降级）。两张表**成对**引入，
    // 留到「接入 Ollama（含嵌入）」那一步。FTS5 则不同：它是 SQLite **自带**
    // 的，所以现在就建。
    // （已兑现：v10 落地了 `vec_chunks`——但机制换成了 A，**没有** `vec_map`，见下。）
    if (db.userVersion < 7) {
      db.execute('''
        -- ── 内容与实体统一为"块" ──────────────────────────────────
        CREATE TABLE blocks (
          id          TEXT PRIMARY KEY,          -- 沿用 v2 块树里已有的 node.id
          note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
          type        TEXT NOT NULL,
          props_json  TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(props_json)),
          ord         INTEGER NOT NULL,          -- 稀疏整数，步长 1024
          parent_id   TEXT REFERENCES blocks(id) ON DELETE CASCADE,
          created_at  INTEGER NOT NULL,
          updated_at  INTEGER NOT NULL,
          fingerprint TEXT NOT NULL              -- 块级判变（fp1 方案）
        );
        CREATE INDEX idx_blocks_note   ON blocks (note_id, ord);
        CREATE INDEX idx_blocks_parent ON blocks (parent_id, ord);

        -- ── 墨迹：分片 blob，不进 blocks ──────────────────────────
        CREATE TABLE ink_shards (
          note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
          shard_index INTEGER NOT NULL,
          points_blob BLOB NOT NULL,             -- Float32：x,y,pressure 三元组
          style_json  TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(style_json)),
          count       INTEGER NOT NULL,
          fingerprint TEXT NOT NULL,
          updated_at  INTEGER NOT NULL,
          PRIMARY KEY (note_id, shard_index)
        ) WITHOUT ROWID;

        -- ── 关键词路（SQLite 自带 FTS5）──────────────────────────
        -- ⚠️ 中文必须 bigram 预处理后写进 search_text：默认 unicode61
        -- 会把连续中文当成一个 token（存了"番茄工作法"，查"番茄"命中 0）。
        -- 原文留在 chunk_text（UNINDEXED）供结果摘要。
        -- ⚠️ 虚拟表**不支持外键** ⇒ 删 block 时必须手工删这里的行。
        CREATE VIRTUAL TABLE chunks_fts USING fts5(
          search_text,
          block_id   UNINDEXED,
          note_id    UNINDEXED,
          chunk_text UNINDEXED
        );

        -- ── 索引进度（手动建索引按钮的增量依据，见设计文档 6.5）───
        CREATE TABLE index_state (
          block_id    TEXT PRIMARY KEY REFERENCES blocks(id) ON DELETE CASCADE,
          fingerprint TEXT NOT NULL,             -- 索引时块的指纹；与 blocks 不同 ⇒ 需重算
          model       TEXT NOT NULL,             -- 换嵌入模型 ⇒ 全部失效
          updated_at  INTEGER NOT NULL
        );

        CREATE TABLE rag_meta (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
      ''');
      db.userVersion = 7;
    }

    // v8：画布落点表（`docs/canvas_architecture.md` 第七章）。这是 `docs/data_layer.md`
    // 八.6 那个**硬前置条件**的第一步——v10 想删 `notes.content`，画布必须先有落点。
    //
    // 为什么画布**不进 `blocks`**：两者唯一共享的不变量只有归属（note_id），而
    // `blocks.ord` 是**阅读顺序**、画布要的是 **z 序**；硬塞一张表会让 `ord` 一列两义，
    // 且 AI 管道（`chunks_fts`/`index_state` 都建在 blocks 上）处处要按 type 过滤。
    // 完整取舍见画布文档第七章；这里只落表。
    //
    // ⚠️ 这一版**不动读路径**：画布仍从 `notes.content` 读，`notes.content` 列照旧。
    // ⚠️ rect 用**四条边**（x1,y1,x2,y2）而不是 x/y/w/h：`w = r - l` 再 `l + w` 会引入
    // 浮点误差，而五步纪律的第 3 步要做**深比较**（行 ⇄ 原文），必须能原样还原。
    if (db.userVersion < 8) {
      // 画布对象表的 DDL 抽成常量：主键自愈要重建同一张表（见 [_canvasItemsDdl]）。
      db.execute(_canvasItemsDdl);
      db.execute('''
        -- ── 画布单例元数据：相机 + **画布格式版本** ──────────────────
        -- `schema_version` 是这次顺带补上的落点：它此前只存在于 JSON 里，迁到表后
        -- 若不存下来，将来改画布 schema 就无从判别。
        CREATE TABLE canvas_meta (
          note_id        TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
          camera_json    TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(camera_json)),
          schema_version INTEGER NOT NULL,
          updated_at     INTEGER NOT NULL
        );
      ''');
      db.userVersion = 8;
    }

    // v9：块结构画布的地基 —— **卡片落点 + 自由连线**（2026-09-18 用户拍板）。
    //
    // 背景：画布的定位从"画画"转为"帮人思考" ⇒ 画布上要有**卡片**（可编辑文本块）。
    // 卡片与形状/图片的根本差别是**它有可索引文本**，所以它**不适用**第七章
    // "画布不进 blocks"的结论——那四条理由针对的是形状/图片（没有可索引文本）：
    // - 内容必须进 `blocks`：否则搜不到、引不到、AI 索引不到（`chunks_fts` 与
    //   `index_state` 都建在 blocks 上）。对"帮人思考"的应用，画布沦为信息孤岛是致命的；
    // - 几何与 z 序仍属画布：视口裁剪每帧要用，必须是**真列**（塞进 props_json 就没法查了）。
    // ⇒ 卡片**分裂存储**：内容在 blocks、几何在本表，靠 block_id 关联。这正是
    //   "共享不变量画边界"——内容共享 blocks 的文本/树/AI 语义，几何共享画布的空间语义。
    //
    // ⚠️ `canvas_edges` **只做自由连线**：思维导图是树，用 `blocks.parent_id` 表达
    //   即可（布局跑在 blocks 树上）。两者各自用最合适的连线方案，不混在一张表里。
    // ⚠️ 边存的是 **id 而不是坐标**（tldraw 的 binding）：拖走卡片连线自动跟随、
    //   删卡片时连线随外键级联消失。这是"块结构画布"与"画画画布"的分水岭。
    if (db.userVersion < 9) {
      // 已升到 v8 的**存量库**：表是旧 DDL 建的、缺 block_id ⇒ 补列。
      // （新库经 `_canvasItemsDdl` 建表**已经带**这一列，故必须先判存在——
      //  重复 ADD COLUMN 会抛 "duplicate column name"。）
      if (!_hasColumn(db, 'canvas_items', 'block_id')) {
        db.execute(
          'ALTER TABLE canvas_items ADD COLUMN block_id TEXT '
          'REFERENCES blocks(id) ON DELETE CASCADE;',
        );
      }
      // DDL 抽成常量：列自愈（[_repairCanvasEdgesTable]）要重建同一张表。
      db.execute(_canvasEdgesDdl);
      db.userVersion = 9;
    }

    // v10：检索层向量路 + 远端删除墓碑（`docs/data_layer.md` 6.7 的 R1）。
    //
    // 机制 A（sqlite_vector，sqlite.ai 官方扩展）：**无虚拟表**——向量放普通表
    // 的 BLOB 列（float32 little-endian），查询用 `vector_full_scan` 表值函数
    // 暴力扫描，与 6.2 容量预算同一口径（无 ANN）。两个结构收益：
    // - vec0 时代的 `vec_map`（rowid 映射）**整个不需要**；
    // - 普通表**可挂外键** ⇒ 删笔记时向量行随 CASCADE 消失，6.3 的删除一致性
    //   坑再消一个（FTS5 虚拟表那条除外，它仍要手工清）。
    //
    // ⚠️ 本迁移是**纯 DDL，不依赖扩展**：扩展没加载成功时（见
    // [vectorExtensionAvailable]）建表照样成功，语义路只是整条缺席——
    // 「降级而非不可用」从 schema 层就成立。
    // ⚠️ 维度不钉死在 schema：嵌入模型决定维度（记在 `rag_meta.model` 的
    // 身份串里），换模型 = 全量重算，普通表天然不怕维度变。
    if (db.userVersion < 10) {
      // 与 v9 的补列同口径（见 [_hasColumn] 的说明）：迁移要能**幂等重入**——
      // 版本号被回拨的存量库、只造了部分表的测试夹具，都会让门闩再次触发，
      // 所以建表带 IF NOT EXISTS、加列先判表与列的存在。
      db.execute('''
        CREATE TABLE IF NOT EXISTS vec_chunks (
          block_id  TEXT PRIMARY KEY REFERENCES blocks(id) ON DELETE CASCADE,
          embedding BLOB NOT NULL              -- float32 LE；维度随 rag_meta.model
        );
      ''');
      if (_hasTable(db, 'index_state') &&
          !_hasColumn(db, 'index_state', 'chunker_version')) {
        // 切块规则版本（6.6①）：切块规则变了而模型没变时，旧向量同样必须失效。
        // `''`（存量行）= 永远过期 ⇒ 首次建索引时全量重算，之后走增量。
        db.execute(
          "ALTER TABLE index_state "
          "ADD COLUMN chunker_version TEXT NOT NULL DEFAULT '';",
        );
      }
      db.execute('''
        -- 远端删除墓碑（6.6②）：**孤岛表**——刻意不挂任何外键、不参与级联。
        -- 删笔记时 CASCADE 会把"该去远端删哪些块"的线索一起带走，所以墓碑必须
        -- 放在删不掉的地方；入队与删除动作必须在同一事务里（6.6② 约束 1）。
        -- kind = 'all' 用于"退出云端 provider"时整库清理。
        CREATE TABLE IF NOT EXISTS pending_delete (
          kind       TEXT NOT NULL,            -- 'chunk' | 'note' | 'all'
          ref        TEXT NOT NULL,            -- chunk: block_id / note: note_id / all: '*'
          note_id    TEXT,                     -- 便于按笔记清理与审计
          queued_at  INTEGER NOT NULL,
          attempts   INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          PRIMARY KEY (kind, ref)
        ) WITHOUT ROWID;
      ''');
      db.userVersion = 10;
    }

    // v11：`vec_chunks` 由**块粒度**升到 **chunk 粒度**（`docs/data_layer.md`
    // 6.7 R3：切块器只对超长块二次切，一个块可能有多个 chunk）。
    //
    // 粒度分工：**chunk 是检索单元**（`vec_chunks` 与 `chunks_fts` 都按 chunk 存），
    // **block 是新鲜度单元**（`index_state` 仍按 block 记指纹/模型/切块版本）——
    // 这样两条召回路的排名口径一致（RRF 才可比），而"这一块要不要重算"的判据
    // 不会因为切法变化而变复杂。
    //
    // ⚠️ 重建是安全的：v10 到今天之间 `vec_chunks` **没有任何写入方**（索引任务
    // 正是本次才落地，之前无 UI 入口）⇒ 表必为空。判据用列存在性，保证幂等
    // 重入（沿 v9/v10 的补列口径）。
    // ⚠️ 必须是 rowid 表：`vector_full_scan` 返回 rowid，JOIN 回原表靠它。
    if (db.userVersion < 11) {
      if (_hasTable(db, 'vec_chunks') &&
          !_hasColumn(db, 'vec_chunks', 'chunk_index')) {
        db.execute('DROP TABLE vec_chunks;');
      }
      db.execute('''
        CREATE TABLE IF NOT EXISTS vec_chunks (
          block_id    TEXT NOT NULL REFERENCES blocks(id) ON DELETE CASCADE,
          chunk_index INTEGER NOT NULL,        -- 块内序号，0 起（chunker 产出）
          embedding   BLOB NOT NULL,           -- float32 LE；维度随 rag_meta.vec_dim
          PRIMARY KEY (block_id, chunk_index)
        );
      ''');
      db.userVersion = 11;
    }

    // v12：笔记标签（方案 A：`notes` 单列 JSON 字符串数组，见 [Note.tags]）。
    //
    // 为什么不建 `tags` / `note_tags` 关联表：真多对多留给"按标签组织列表 /
    // 统计"需求出现的那天——关联表后补迁移并不痛苦（v6 的整表重建都走过来了），
    // 反倒是它起步会把 MVP 拖成一周。个人笔记量级下"按标签聚合"扫全列可接受。
    //
    // 标签**跨 kind 一套池子**：kind 已是类型维度，标签是正交的另一层。
    //
    // 幂等走 [_hasColumn]（存量库门闩回拨 / 测试夹具都安全，同 v10 的口径）。
    if (db.userVersion < 12) {
      if (!_hasColumn(db, 'notes', 'tags')) {
        db.execute(
          "ALTER TABLE notes ADD COLUMN tags TEXT NOT NULL DEFAULT '[]';",
        );
      }
      db.userVersion = 12;
    }

    // v13：列表快照投影列 `summary` = `plain_text` 的前 160 个字符。
    //
    // 动机（2026-09-30 用户拍板）：`allNotes()` 为了卡片摘要把**整篇**
    // plain_text 拖进内存，万篇级笔记的快照要背约 20MB。卡片只展示 4 行，
    // 投影一份短字符串即可把快照内存降一个量级；`plain_text` 全文照旧保留
    // （FTS 之外的字数统计 / 单行懒取仍在用）。
    //
    // 纯增量、与写路径同口径（Note.summarize 也是前 160 字符）：
    // SQLite `substr` 按字符计数，回填一次性毫秒级。门闩幂等沿 v10/v12
    // 口径（列已存在则跳过——版本号回拨 / 半成品测试夹具都安全）。
    if (db.userVersion < 13) {
      if (!_hasColumn(db, 'notes', 'summary')) {
        db.execute(
          "ALTER TABLE notes ADD COLUMN summary TEXT NOT NULL DEFAULT '';",
        );
        db.execute(
          'UPDATE notes SET summary = substr(plain_text, 1, ${Note.summaryLength});',
        );
      }
      db.userVersion = 13;
    }

    // 主键自愈：早期 v8（本会话中途修正过）把 `canvas_items` 的主键建成了单列 id。
    // 表是**影子副本**（只写不读，画布仍从 `notes.content` 读）⇒ 重建不丢用户数据，
    // 下一轮保存或回填会把它重新写满。见 [_canvasItemsDdl] 的主键说明。
    _repairCanvasItemsPrimaryKey(db);
    // 同类修复：存量库的 `userVersion` 已是 8/9 ⇒ 迁移门闩不再触发，早期 DDL
    // 缺的列要在这里补（否则首次保存就抛 "no such column"，见用户 2026-09-18 报错）。
    _repairCanvasEdgesTable(db);
    _repairCanvasItemsBlockId(db);
  }

  /// `canvas_items` 的建表 DDL（**v8 建表与主键自愈共用**，避免两处漂移）。
  ///
  /// ⚠️ 主键是 **(note_id, id)** 而非单列 `id`：`CanvasItem.id` 是内核里的**进程内
  /// 自增计数器**（`item-0`、`item-1`…，见 `canvas_item.dart`），应用重启后从头的值
  /// 重新开始——两张画布同时存在 `item-1` 是**常态**（实测：回填两条画布时后一条把
  /// 前一条的行抢走）。单列主键 + `ON CONFLICT(id)` 会让后写的那张连 `note_id` 一起改。
  /// 与 `ink_shards` 的 `(note_id, shard_index)` 同一思路。
  static const String _canvasItemsDdl = '''
    CREATE TABLE canvas_items (
      id           TEXT NOT NULL,             -- CanvasItem.id（**跨画布不保证唯一**）
      note_id      TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
      kind         TEXT NOT NULL,             -- shape.rectangle / shape.ellipse / image / ai_image
      z            INTEGER NOT NULL,          -- z 序（底→顶）= itemOrder 的下标
      x1           REAL NOT NULL,             -- rect 的**四条边**（世界坐标）
      y1           REAL NOT NULL,
      x2           REAL NOT NULL,
      y2           REAL NOT NULL,
      angle        REAL NOT NULL DEFAULT 0,
      color        INTEGER,                   -- ARGB；哨兵值 ⇒ 跟随主题
      filled       INTEGER,                   -- 0/1（形状专用）
      stroke_width REAL,                      -- 形状专用
      src          TEXT,                      -- 图片：相对引用（media/xxx.png）
      props_json   TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(props_json)),
                                              -- {meta?, gen?}：扩展位，缺省不写
      block_id     TEXT REFERENCES blocks(id) ON DELETE CASCADE,
                                              -- v9：仅 kind='card'。卡片的**内容**
                                              -- 在 blocks（要能被 AI 索引与引用），
                                              -- 这里只存几何，靠 block_id 关联
      created_at   INTEGER NOT NULL,
      updated_at   INTEGER NOT NULL,
      fingerprint  TEXT NOT NULL,             -- 与 blocks 同口径（fp1）
      PRIMARY KEY (note_id, id)
    );
    CREATE INDEX idx_canvas_items_note ON canvas_items (note_id, z);
  ''';

  /// `canvas_edges` 的建表 DDL（**v9 建表与列自愈共用**，避免两处漂移）。
  static const String _canvasEdgesDdl = '''
    CREATE TABLE IF NOT EXISTS canvas_edges (
      id          TEXT NOT NULL,
      note_id     TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
      from_id     TEXT NOT NULL REFERENCES blocks(id) ON DELETE CASCADE,
      to_id       TEXT NOT NULL REFERENCES blocks(id) ON DELETE CASCADE,
      from_side   TEXT,                  -- 端口吸附：top/right/bottom/left（null = 自动）
      to_side     TEXT,
      props_json  TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(props_json)),
      fingerprint TEXT NOT NULL,         -- 与 canvas_items 同口径：判变只写变动的行
      PRIMARY KEY (note_id, id)          -- 与 canvas_items 同口径：带归属
    );
    CREATE INDEX IF NOT EXISTS idx_canvas_edges_note ON canvas_edges (note_id);
  ''';

  /// 主键自愈（见 [_canvasItemsDdl] 的主键说明）。
  ///
  /// 判据取 `sqlite_master` 里的 DDL 文本（空白归一化后比对）——那是 SQLite 里唯一
  /// 能反映"主键长什么样"的地方。
  static void _repairCanvasItemsPrimaryKey(Database db) {
    final ResultSet rs = db.select(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'canvas_items'",
    );
    if (rs.isEmpty) return;
    final String ddl = ((rs.single['sql'] as String?) ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
    if (ddl.contains('primary key (note_id, id)')) return;
    db.execute('DROP TABLE canvas_items;');
    db.execute(_canvasItemsDdl);
  }

  /// 列自愈：早期 v9 的 `canvas_edges` DDL **没有 `fingerprint` 列**，而
  /// `userVersion` 已经被写成 9 ⇒ v9 迁移门闩不再触发，于是
  /// `SELECT id, fingerprint FROM canvas_edges` 直接抛 "no such column"。
  ///
  /// 与 [_repairCanvasItemsPrimaryKey] 同一思路：表是**影子副本**（只写不读，
  /// 画布从 `notes.content` 读）⇒ 重建不丢用户数据，下次保存会重新写满。
  static void _repairCanvasEdgesTable(Database db) {
    final ResultSet rs = db.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'canvas_edges'",
    );
    if (rs.isEmpty) return; // 全新库：交给 v9 迁移建表
    if (_hasColumn(db, 'canvas_edges', 'fingerprint')) return;
    db.execute('DROP TABLE canvas_edges;');
    db.execute(_canvasEdgesDdl);
  }

  /// 补 `canvas_items.block_id`（早期 v8 DDL 没有它、而 userVersion 已是 9 时，
  /// v9 迁移同样不会跑）。判据与 [_repairCanvasEdgesTable] 一致。
  static void _repairCanvasItemsBlockId(Database db) {
    final ResultSet rs = db.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'canvas_items'",
    );
    if (rs.isEmpty) return;
    if (_hasColumn(db, 'canvas_items', 'block_id')) return;
    db.execute(
      'ALTER TABLE canvas_items ADD COLUMN block_id TEXT '
      'REFERENCES blocks(id) ON DELETE CASCADE;',
    );
  }

  /// 表有没有这一列（存量库**补列**的幂等判据）。
  ///
  /// 迁移要同时服务两类库：**新库**走建表 DDL（已经带这一列），**存量库**是旧
  /// DDL 建的（缺这一列）⇒ 补列前必须判存在，否则抛 "duplicate column name"。
  static bool _hasColumn(Database db, String table, String column) {
    for (final Row r in db.select('PRAGMA table_info($table)')) {
      if (r['name'] == column) return true;
    }
    return false;
  }

  /// 表是否存在（v10 的 ALTER 前置判据：存量库夹具可能只造了部分表，
  /// `PRAGMA table_info` 对缺失的表返回空集而不是报错，故需先判表本身）。
  static bool _hasTable(Database db, String table) {
    return db.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[table],
    ).isNotEmpty;
  }

  /// v6 的 `notes` 表重建（详见调用处的说明）。
  ///
  /// 顺序上有三个坑，都写在代码里了：
  static void _rebuildNotesForV6(Database db) {
    // ⚠️ `PRAGMA foreign_keys` 在**事务内是空操作**，所以必须在 `BEGIN` 之前关。
    db.execute('PRAGMA foreign_keys = OFF;');
    try {
      db.execute('BEGIN;');
      db.execute('''
        CREATE TABLE notes_v6 (
          id           TEXT PRIMARY KEY,
          kind         TEXT NOT NULL CHECK (kind IN ('spark','note','canvas')),
          title        TEXT NOT NULL DEFAULT '',
          content      TEXT NOT NULL DEFAULT '',
          content_hash TEXT NOT NULL,
          plain_text   TEXT NOT NULL DEFAULT '',
          created_at   INTEGER NOT NULL,
          revised_at   INTEGER NOT NULL,
          promoted_at  INTEGER,
          deleted_at   INTEGER
        );
      ''');
      db.execute('''
        INSERT INTO notes_v6 (id, kind, title, content, content_hash, plain_text,
                              created_at, revised_at, promoted_at)
          SELECT id, kind, title, content, content_hash, plain_text,
                 created_at, revised_at, promoted_at
            FROM notes;
      ''');
      // 先删旧表、再改名（顺序反过来会撞同名）。
      db.execute('DROP TABLE notes;');
      db.execute('ALTER TABLE notes_v6 RENAME TO notes;');
      db.execute('COMMIT;');
    } on Object {
      db.execute('ROLLBACK;');
      rethrow;
    } finally {
      // 事务结束后记得恢复，否则整座会话的外键都失效。
      db.execute('PRAGMA foreign_keys = ON;');
    }

    // 完整性校验：宁可当场抛，也不留一座坏库继续跑。
    if (db.select('PRAGMA foreign_key_check;').isNotEmpty) {
      throw StateError('v6 迁移后外键校验未通过（foreign_key_check 非空）');
    }
  }

  void close() => db.close();
}
