import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// 数据库层：只负责「打开 + schema + 迁移」，不碰业务查询。
///
/// 沿用手写 SQL 的轻量路线（无 codegen），便于将来演进更复杂的 schema
/// （标签、双向链接、AI 缓存、embedding 等）。
///
/// 存储位置用 [getApplicationSupportDirectory]，跟着当前用户走，
/// 不污染可执行文件目录。
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  /// 异步只发生在「定位存储目录」这一步；打开与之后所有查询都是本地同步。
  static Future<AppDatabase> open() async {
    final Directory dir = await getApplicationSupportDirectory();
    final File file = File(p.join(dir.path, 'sinan.db'));
    final Database db = sqlite3.open(file.path);
    // 外键开启后才能让快照随笔记删除而级联清理。
    db.execute('PRAGMA foreign_keys = ON;');
    _migrate(db);
    return AppDatabase._(db);
  }

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
