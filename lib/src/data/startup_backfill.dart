import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqlite3/sqlite3.dart';

import 'database.dart';
import 'note_store.dart';

/// 启动期**存量回填**的后台执行器（阶段 A，2026-10-01）。
///
/// ## 为什么需要独立 isolate
/// 三件活——`backfillBlocks`（v2 块树拆 `blocks`）、`backfillCanvas`（画布
/// JSON 拆 canvas 三表）、`ensureKeywordIndex`（补 `chunks_fts`）——全是
/// **同步** SQLite + JSON 解析。它们只对**存量未投影**的老笔记有活干，新库
/// 是几条 `NOT EXISTS` 空探测；但老用户升级到大版本时，首批 50 篇的解析与
/// 多表事务会在主 isolate 同步卡 UI 数百毫秒到数秒。挪到这里后首帧之后界面
/// 立即可交互，回填静默完成。
///
/// ## 为什么这样做是安全的
/// - **只写派生表，不碰真源**：`notes.content` 永远只由主 isolate 的保存
///   路径改；worker 崩溃/被杀都不影响数据。
/// - **幂等 + 每篇独立短事务 + 可续跑**：这次没做完下次启动接着来。
/// - **WAL 已就位**（见 [AppDatabase.applyConnectionPragmas]）：第二连接
///   一写多读，与主连接的写冲突由 `busy_timeout=5000` 排队。
/// - **并发守卫在投影方法内部**：逐篇投影前重读"已落表"标记并取最新正文
///   （`pendingBackfillContent` / `isKeywordIndexPending`），不覆盖用户刚
///   保存的新投影；残留亚毫秒窗口撞上也由读侧 verify/srcfp 闸门降落伞 +
///   下次保存自愈。
/// - **不需要向量扩展**：三任务只写 blocks / canvas 三表 / chunks_fts，
///   worker 不加载 sqlite_vector（跨 isolate 注册 native 扩展的麻烦全省）。
///
/// ## Web
/// Web 无 `dart:isolate`，[runStartupBackfill] 直接返回（保存即双写，回填
/// 只惠及存量库，移动端/桌面是当前目标）。

/// 在后台 isolate 跑完三件存量回填。返回的 Future 在 worker 关闭连接并回报
/// 后完成；调用方**无需 await**（启动路径不等待它），但测试可以。
///
/// 失败语义与旧实现一致——派生数据回填失败不影响使用（保存路径的双写会在
/// 用户下次编辑时把该篇补齐），错误经 Future 抛给调用方决定如何记录。
Future<void> runStartupBackfill(String dbPath) async {
  if (kIsWeb) return;

  final ReceivePort replyPort = ReceivePort();
  final Isolate isolate;
  try {
    isolate = await Isolate.spawn(_backfillIsolateMain, (
      path: dbPath,
      reply: replyPort.sendPort,
    ));
  } on Object {
    replyPort.close();
    rethrow;
  }

  final Completer<void> done = Completer<void>();
  late final StreamSubscription<Object?> sub;
  sub = replyPort.listen((Object? message) {
    // 消息只此一条：取消订阅即收尾。cancel() 的 Future 与完成通知无顺序依赖，
    // 显式 unawaited 标明。
    unawaited(
      sub.cancel().whenComplete(() {
        replyPort.close();
        // worker 回报后已无事可做，立即回收；正常路径下它本已自行退出。
        isolate.kill(priority: Isolate.immediate);
        if (message is _BackfillError) {
          done.completeError(message.error, message.stackTrace);
        } else {
          done.complete();
        }
      }),
    );
  });
  return done.future;
}

/// worker 回传失败的载荷（普通类，可跨 isolate 发送）。
class _BackfillError {
  _BackfillError(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

/// isolate 入口（必须是顶层函数）。在**独立连接**上打开同一 db 文件。
void _backfillIsolateMain(({String path, SendPort reply}) request) {
  Database? db;
  void fail(Object e, StackTrace st) {
    db?.close();
    request.reply.send(_BackfillError(e, st));
  }

  try {
    db = sqlite3.open(request.path);
    // 第二连接同样要过连接级配置：busy_timeout 防与主连接写冲突、外键打开；
    // requestWal 在已切 WAL 的文件上读回 `wal`，synchronous 随之 NORMAL。
    AppDatabase.applyConnectionPragmas(db, requestWal: true);
    // 防御性空迁移：正常时序主连接早已迁完，这里 userVersion 已最新、秒退。
    AppDatabase.ensureSchema(db);

    final NoteStore store = NoteStore(db);
    // 顺序沿用旧 main.dart：先块树、再画布，最后关键词索引（索引读 blocks，
    // 必须在块回填之后）。
    store.backfillBlocks();
    store.backfillCanvas();
    store.ensureKeywordIndex();
  } on Object catch (e, st) {
    fail(e, st);
    return;
  }
  // 先关连接（顺带让 SQLite 在最后一个连接关闭时 checkpoint 回 -wal），
  // 再回报：主 isolate 收到完成消息时派生数据已落盘可见。
  db.close();
  request.reply.send(null);
}
