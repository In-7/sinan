import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_vector/sqlite_vector.dart';
import 'package:uuid/uuid.dart';

import '../domain/note.dart';
import 'fingerprint.dart';
import 'stream_store.dart';

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
    // 启动兜底：清掉"盘上有、库里没"的孤儿附件副本（导入中途崩溃可能留下）。
    StreamStore.sweepOrphans(db, p.join(dir.path, 'stream_media'));
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

    // v14：notes 表重建——`kind` 加第四个取值 `'stream'`（灵感收件箱的系统容器，
    // 隐藏，不进文库/搜索/日历）。SQLite 不能改 CHECK ⇒ 同 v6 整表重建，但这次把
    // v6 之后新增的 `deleted_at` / `tags` / `summary` 一并拷过去。
    if (db.userVersion < 14) {
      _rebuildNotesForV14(db);
      db.userVersion = 14;
    }

    // v15：`md_mirror` 侧表——Markdown **单向镜像**的导出账本（2026-10-17）。
    //
    // 一行 = 一篇笔记当前导出到哪个 .md 文件、以及导出时笔记的 `revised_at`。
    // 扫描条件就靠它：`notes.revised_at > md_mirror.revised_at`（或无行）即待导出，
    // 幂等可续、崩溃后自愈，不需要内存态。CASCADE 随笔记删除清行；磁盘文件由
    // `MdMirror.removeForNote` 显式删（SQL 级联管不到文件系统）。
    if (db.userVersion < 15) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS md_mirror (
          note_id    TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
          path       TEXT NOT NULL,
          revised_at INTEGER NOT NULL
        );''');
      db.userVersion = 15;
    }

    // v16：灵感**独立存储**（2026-10-17 用户定）。
    //
    // 此前灵感是"一篇隐藏笔记（`kind='stream'`）+ 一串段落块"，每处下游都要写
    // `kind != 'stream'` 的特例，且灵感会混进块选择器 / 反链上下文。现在搬进
    // 独立表 `stream_items`（无外键指向 notes/blocks），**id 沿用旧块 id**，
    // 于是已有的 `ref` 引用只需把 `ref_type` 改成 `'stream'` 就不断链。
    if (db.userVersion < 16) {
      _migrateStreamV16(db);
      db.userVersion = 16;
    }

    // v17：**处理台账**（2026-10-18 定）。
    //
    // 「已处理」原本只是个能拿回来的仓库（＝可撤销的删除），它没回答灵感真正要
    // 的那件事：这条灵感最后**变成了什么**。现在每次导出（引用 / 复制 / 转新 /
    // 合并）写一行 `stream_exports`，回收列举时就能念出
    // `一条想法 → 笔记《周五的闲聊》`。
    //
    // 刻意**不加外键**：目标被删了，台账那条记录还应该留在那里（它是回忆录，
    // 不是导航索引）；标题也是当时的快照，不跟着目标改名。
    if (db.userVersion < 17) {
      db.execute(_streamExportsDdl);
      db.userVersion = 17;
    }

    // v18：台账记下**落点块**（2026-10-18 P2：双链的实质）。
    //
    // v17 只记"流去了哪篇"，点过去还得自己找那段；现在把导出时**真正写入的那个块**
    // （ref 块 / 第一个段落 / 画布卡的块）一并记下，点流向可直接定位并高亮。
    // 可空：老行没有这个信息（照旧只跳笔记），合并/转新的目标块按首个段落记。
    if (db.userVersion < 18) {
      if (!_hasColumn(db, 'stream_exports', 'target_block_id')) {
        db.execute(
          'ALTER TABLE stream_exports ADD COLUMN target_block_id TEXT;',
        );
      }
      db.userVersion = 18;
    }

    // v19：灵感**媒体附件**（2026-10-18 加：输入框可贴图片/视频）。
    //
    // 只存"app 私有目录里那份独立副本"的路径——源截图被删也不影响（[StreamStore.remove]
    // 级联删文件）。二进制不进 SQLite（视频太大）。`kind` 枚举在应用层约束，
    // 这里用 CHECK 兜底；`sort` 是同条目内的展示顺序。
    if (db.userVersion < 19) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS stream_attachments (
          id          TEXT PRIMARY KEY,
          stream_id   TEXT NOT NULL,
          kind        TEXT NOT NULL CHECK (kind IN ('image', 'video')),
          path        TEXT NOT NULL,
          width       INTEGER,
          height      INTEGER,
          duration_ms INTEGER,
          sort        INTEGER NOT NULL,
          created_at  INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_stream_attachments_stream
          ON stream_attachments (stream_id);
      ''');
      db.userVersion = 19;
    }

    // v20：灵感**回收站**（2026-10-18 定）：删除 = 软删（`deleted_at` 非空），
    // 列表默认过滤；回收站里可恢复或彻底删除。归档仍走 `archived_at`。
    if (db.userVersion < 20) {
      if (!_hasColumn(db, 'stream_items', 'deleted_at')) {
        db.execute('ALTER TABLE stream_items ADD COLUMN deleted_at INTEGER;');
      }
      db.execute(
        'CREATE INDEX IF NOT EXISTS idx_stream_items_trash '
        'ON stream_items (deleted_at) WHERE deleted_at IS NOT NULL;',
      );
      db.userVersion = 20;
    }

    // v21：全局回收站查询索引（`notes.deleted_at` 列 v6 已有，这里只补索引）。
    if (db.userVersion < 21) {
      db.execute(
        'CREATE INDEX IF NOT EXISTS idx_notes_deleted '
        'ON notes (deleted_at) WHERE deleted_at IS NOT NULL;',
      );
      db.userVersion = 21;
    }

    // 主键自愈：早期 v8（本会话中途修正过）把 `canvas_items` 的主键建成了单列 id。
    // 表是**影子副本**（只写不读，画布仍从 `notes.content` 读）⇒ 重建不丢用户数据，
    // 下一轮保存或回填会把它重新写满。见 [_canvasItemsDdl] 的主键说明。
    _repairCanvasItemsPrimaryKey(db);
    // 同类修复：存量库的 `userVersion` 已是 8/9 ⇒ 迁移门闩不再触发，早期 DDL
    // 缺的列要在这里补（否则首次保存就抛 "no such column"，见用户 2026-09-18 报错）。
    _repairCanvasEdgesTable(db);
    _repairCanvasItemsBlockId(db);
    // 同一条教训：`userVersion` 已是 20 但列缺失时补列（幂等）。
    _repairStreamDeletedAt(db);
  }

  /// 存量库 `userVersion` 已是 20 但 `stream_items.deleted_at` 缺失时补列。
  /// （新建表走 [StreamStore.ddl] 已含该列；这里只护历史库。）
  static void _repairStreamDeletedAt(Database db) {
    final bool tableExists = db
        .select(
          "SELECT name FROM sqlite_master "
          "WHERE type = 'table' AND name = 'stream_items';",
        )
        .isNotEmpty;
    if (tableExists && !_hasColumn(db, 'stream_items', 'deleted_at')) {
      db.execute('ALTER TABLE stream_items ADD COLUMN deleted_at INTEGER;');
    }
  }

  static const Uuid _uuid = Uuid();

  /// 处理台账的表（`note_store.dart` 的导出方法写、界面读）。
  ///
  /// `IF NOT EXISTS`：迁移必须能幂等重入（版本号被回拨的存量库、只造了部分表的
  /// 测试夹具都会让门闩再次触发）。
  static const String _streamExportsDdl = '''
    CREATE TABLE IF NOT EXISTS stream_exports (
      id           TEXT PRIMARY KEY,
      stream_id    TEXT NOT NULL,
      target_type  TEXT NOT NULL,
      target_id    TEXT NOT NULL,
      target_title TEXT NOT NULL,
      kind         TEXT NOT NULL,
      created_at   INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_stream_exports_stream
      ON stream_exports (stream_id);
    CREATE INDEX IF NOT EXISTS idx_stream_exports_created
      ON stream_exports (created_at DESC);
  ''';

  /// v16：把旧的"隐藏灵感笔记 + 段落块"搬进独立表 `stream_items`。
  ///
  /// 四件事，顺序不能换：
  /// 1. 建表；把容器里的段落逐条搬过去（**id 沿用旧块 id**，`created_at` 优先
  ///    取块行的时间，"最新在上"的排序不飘）；
  /// 2. 笔记里指向这些块的 `ref` 块：`ref_type` 由 `block` 改为 `stream`
  ///    （id 没变 ⇒ 引用不断）；
  /// 3. 画布上指向这些块的卡片：转成**独立复制卡**（v16 起灵感不做画布活链，
  ///    详见方案"画布只复制、不引用"）——不先处理，删容器时它们会变成空框；
  /// 4. 删容器（CASCADE 清它的块）。删前把原文备份进 `settings`，可人工找回。
  ///
  /// 幂等：建表与插入都带 `IF NOT EXISTS` / `OR REPLACE`；容器不存在时是空转。
  static void _migrateStreamV16(Database db) {
    // 四步（搬条目 → 改引用 → 重指向画布卡 → 删容器）必须**同进同退**：
    // 中途异常若只做了一半，容器可能已删、条目只搬了一部分，用户数据就残了。
    db.execute('BEGIN;');
    try {
      _migrateStreamRowsV16(db);
      db.execute('COMMIT;');
    } on Object {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  static void _migrateStreamRowsV16(Database db) {
    db.execute(StreamStore.ddl);
    final ResultSet containers = db.select(
      "SELECT id, content, created_at FROM notes WHERE kind = 'stream'",
    );
    for (final Row c in containers) {
      final String containerId = c['id'] as String;
      final String raw = (c['content'] as String?) ?? '';
      // 备份（回滚 / 人工核对用）。容器马上要删，这是唯一的原文。
      db.execute(
        'INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)',
        <Object?>['stream.migration.backup', raw.isEmpty ? '{}' : raw],
      );

      final List<_LegacyStream> items = _legacyStreamItems(raw);
      final Map<String, int> createdOf = <String, int>{
        for (final Row r in db.select(
          'SELECT id, created_at FROM blocks WHERE note_id = ?',
          <Object?>[containerId],
        ))
          r['id'] as String: r['created_at'] as int,
      };
      final int base = (c['created_at'] as int?) ?? 0;
      final Set<String> movedIds = <String>{};
      for (int i = 0; i < items.length; i++) {
        final _LegacyStream item = items[i];
        final String text = item.text.trim();
        if (text.isEmpty) continue;
        movedIds.add(item.id);
        // 兜底时间戳按"容器创建 + 序位"给，保证与文档序（新在前）一致。
        final int ts = createdOf[item.id] ?? (base + (items.length - i));
        db.execute(
          'INSERT OR REPLACE INTO stream_items '
          '(id, text, created_at, updated_at) VALUES (?, ?, ?, ?)',
          <Object?>[item.id, text, ts, ts],
        );
      }

      if (movedIds.isNotEmpty) {
        // ② 引用块：只改类型，id 沿用。
        db.execute(
          "UPDATE blocks SET props_json = "
          "json_set(props_json, '\$.ref_type', 'stream') "
          "WHERE type = 'ref' AND json_valid(props_json) "
          "AND json_extract(props_json, '\$.ref_type') = 'block' "
          "AND json_extract(props_json, '\$.ref_id') IN "
          "(SELECT id FROM stream_items)",
        );
        // ③ 画布卡片：转为独立复制卡。
        _repointStreamCardsV16(db, movedIds);
      }

      // ④ 删容器（块的 CASCADE 一并清）。
      db.execute('DELETE FROM notes WHERE id = ?', <Object?>[containerId]);
    }
  }

  /// 旧灵感容器的一块：id + 文本（`data.text` 优先，回退 `delta` 拼接）。
  static List<_LegacyStream> _legacyStreamItems(String raw) {
    if (raw.trim().isEmpty) return const <_LegacyStream>[];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const <_LegacyStream>[];
    }
    if (decoded is! Map) return const <_LegacyStream>[];
    final Object? document = decoded['document'];
    if (document is! Map) return const <_LegacyStream>[];
    final Object? children = document['children'];
    if (children is! List) return const <_LegacyStream>[];
    return <_LegacyStream>[
      for (final Object? n in children)
        if (n is Map && n['id'] is String)
          _LegacyStream(
            n['id'] as String,
            _legacyText(n['data'] is Map ? n['data'] as Map : const <String, Object?>{}),
          ),
    ];
  }

  static String _legacyText(Map<Object?, Object?> data) {
    final Object? text = data['text'];
    if (text is String && text.trim().isNotEmpty) return text;
    final Object? delta = data['delta'];
    if (delta is List) {
      final StringBuffer sb = StringBuffer();
      for (final Object? op in delta) {
        if (op is Map && op['insert'] is String) sb.write(op['insert'] as String);
      }
      return sb.toString();
    }
    return '';
  }

  /// 把画布上**指向旧灵感块**的卡片转成独立复制卡：换一个新块 id（块行当场建好）、
  /// 保留文本，再删掉旧投影行（指向即将消失的块）。缩略图快路径会因行数不符自动
  /// 回落到 JSON，下一次保存/回填重建投影。
  static void _repointStreamCardsV16(Database db, Set<String> streamIds) {
    final List<String> ids = streamIds.toList(growable: false);
    final String marks = List<String>.filled(ids.length, '?').join(',');
    final ResultSet canvases = db.select(
      "SELECT DISTINCT note_id FROM canvas_items "
      "WHERE kind = 'card' AND block_id IN ($marks)",
      ids,
    );
    for (final Row row in canvases) {
      final String noteId = row['note_id'] as String;
      final ResultSet rs = db.select(
        'SELECT content FROM notes WHERE id = ?',
        <Object?>[noteId],
      );
      if (rs.isEmpty) continue;
      final String content = (rs.first['content'] as String?) ?? '';
      final Map<String, dynamic>? doc = _decodeCanvasJson(content);
      if (doc == null) continue;
      final Object? documentRaw = doc['document'];
      final Object? itemsRaw = documentRaw is Map ? documentRaw['items'] : null;
      if (itemsRaw is! Map) continue;
      final Map<String, dynamic> items = itemsRaw.cast<String, dynamic>();

      final List<MapEntry<String, String>> copies = <MapEntry<String, String>>[];
      for (final MapEntry<String, dynamic> e in items.entries.toList()) {
        final Object? v = e.value;
        if (v is! Map) continue;
        final Map<String, dynamic> card = v.cast<String, dynamic>();
        if (card['type'] != 'card') continue;
        final Object? blockId = card['blockId'];
        if (blockId is! String || !streamIds.contains(blockId)) continue;
        final String newId = _uuid.v4();
        card['blockId'] = newId;
        copies.add(MapEntry<String, String>(newId, (card['text'] as String?) ?? ''));
      }
      if (copies.isEmpty) continue;

      final int now = DateTime.now().millisecondsSinceEpoch;
      int ord = 1024;
      for (final MapEntry<String, String> copy in copies) {
        final String props = jsonEncode(<String, Object?>{
          'delta': <Object?>[
            <String, Object?>{'insert': copy.value},
          ],
          'text': copy.value,
        });
        db.execute(
          'INSERT OR REPLACE INTO blocks '
          '(id, note_id, type, props_json, ord, parent_id, created_at, '
          'updated_at, fingerprint) VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?)',
          <Object?>[
            copy.key,
            noteId,
            'card',
            props,
            ord,
            now,
            now,
            contentFingerprint(props),
          ],
        );
        ord += 1024;
      }

      final String next = jsonEncode(doc);
      db.execute(
        'UPDATE notes SET content = ?, content_hash = ? WHERE id = ?',
        <Object?>[next, contentFingerprint(next), noteId],
      );
      // 旧几何行指向马上要消失的块 ⇒ 删行（下次保存按新 JSON 重建）。
      db.execute(
        "DELETE FROM canvas_items WHERE note_id = ? AND kind = 'card' "
        "AND block_id IN ($marks)",
        <Object?>[noteId, ...ids],
      );
    }
  }

  static Map<String, dynamic>? _decodeCanvasJson(String content) {
    if (content.trim().isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(content);
      if (decoded is! Map) return null;
      final Map<String, dynamic> doc = decoded.cast<String, dynamic>();
      return doc['document'] is Map ? doc : null;
    } on FormatException {
      return null;
    }
  }

  /// 低频维护：刷新查询规划器统计（SQLite 对**长连接**的推荐节奏）。
  ///
  /// `PRAGMA optimize` 统计新鲜时基本是 no-op，只在需要时补跑 ANALYZE；长生命
  /// 周期连接不定期跑，`sqlite_stat1` 过期后规划器可能选错索引。FTS5 虚表不参与
  /// ANALYZE，受益的主要是 notes / blocks / canvas 几张普通表。
  ///
  /// 调用方 fire-and-forget（失败不惊动用户，下个周期再来）——见 `main.dart`
  /// 的 30 分钟维护定时器。
  static void optimize(Database db) => db.execute('PRAGMA optimize;');

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

  /// v14：`notes.kind` 的 CHECK 加 `'stream'`（灵感系统容器，见 [NoteKind.stream]）。
  /// 同 v6 整表重建，但拷贝**当前全部列**（含 v6 之后的 `deleted_at` / `tags` / `summary`）。
  static void _rebuildNotesForV14(Database db) {
    db.execute('PRAGMA foreign_keys = OFF;');
    try {
      db.execute('BEGIN;');
      db.execute('''
        CREATE TABLE notes_v14 (
          id           TEXT PRIMARY KEY,
          kind         TEXT NOT NULL CHECK (kind IN ('spark','note','canvas','stream')),
          title        TEXT NOT NULL DEFAULT '',
          content      TEXT NOT NULL DEFAULT '',
          content_hash TEXT NOT NULL,
          plain_text   TEXT NOT NULL DEFAULT '',
          created_at   INTEGER NOT NULL,
          revised_at   INTEGER NOT NULL,
          promoted_at  INTEGER,
          deleted_at   INTEGER,
          tags         TEXT NOT NULL DEFAULT '[]',
          summary      TEXT NOT NULL DEFAULT ''
        );
      ''');
      db.execute('''
        INSERT INTO notes_v14 (id, kind, title, content, content_hash, plain_text,
                              created_at, revised_at, promoted_at, deleted_at, tags, summary)
          SELECT id, kind, title, content, content_hash, plain_text,
                 created_at, revised_at, promoted_at, deleted_at, tags, summary
            FROM notes;
      ''');
      db.execute('DROP TABLE notes;');
      db.execute('ALTER TABLE notes_v14 RENAME TO notes;');
      db.execute('COMMIT;');
    } on Object {
      db.execute('ROLLBACK;');
      rethrow;
    } finally {
      db.execute('PRAGMA foreign_keys = ON;');
    }
    if (db.select('PRAGMA foreign_key_check;').isNotEmpty) {
      throw StateError('v14 迁移后外键校验未通过（foreign_key_check 非空）');
    }
  }

  void close() => db.close();
}

/// v16 迁移用：旧灵感容器里的一条（块 id + 文本）。
class _LegacyStream {
  const _LegacyStream(this.id, this.text);

  final String id;
  final String text;
}
