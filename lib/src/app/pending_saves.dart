import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';

/// 退出前等待落盘的**上限**。
///
/// 不能等到底：一次落盘要经过"快照 → （长文）isolate 编码 → SQLite 写入"，
/// 任何一环卡住都会让**窗口关不掉**——那比"丢最后一次编辑"严重得多。超时也照常
/// 退出，且因为 `SaveDebounce` 的硬上界也是 2s（`kSaveMaxWait`），两处同量级，
/// 用户感知一致：最坏情况永远只是"丢掉最后这一段"。
const Duration kExitFlushTimeout = Duration(seconds: 2);

/// 未落盘编辑的**退出前落盘登记处**。
///
/// ## 解决什么
/// 防抖（`SaveDebounce`）只在"停顿"或"到上限"时写库，而关窗口是一次**进程级
/// 退出**：走不到 widget `dispose` 里的兜底落盘，防抖计时器也再没有机会触发。
/// 于是"改完立刻关窗口"丢掉的就是最后一次编辑——2026-09-17 用户实测报回：
/// **删掉一段文字、马上关窗口，重开后那段文字又回来了**。
///
/// 这里让各视图在挂载时登记一个"能**等到写完**的落盘动作"，退出路径
/// （[flushThenExit]，挂在官方的可取消退出请求上）在真正关窗口之前调用 [flushAll]。
///
/// ## 为什么不复用 dispose 的兜底落盘
/// 那条路是 fire-and-forget——`dispose` 时进程已经在走，等也等不到结果。这里
/// 返回的 Future 会被 await，所以"库确实写下去了"是**可断言**的（见
/// `test/window/exit_coordinator_test.dart` 与两处视图的退出前落盘用例）。
class PendingSaves {
  final List<Future<void> Function()> _flushers = <Future<void> Function()>[];

  /// 登记一个落盘动作（约定：调用即开始写，返回的 Future 写完即完成）。
  ///
  /// 返回**注销句柄**：视图 `dispose` 时必须调用，否则已在内存里消失的视图
  /// 仍会在退出时被落盘——那时它的 `Document` / 控制器已经不在，轻则白写一次，
  /// 重则写回一份空内容。
  void Function() register(Future<void> Function() flush) {
    _flushers.add(flush);
    // 按**引用**移除：一个视图只登记一次，列表里不会有重复项。
    return () => _flushers.remove(flush);
  }

  /// 等待所有已登记的动作写完。
  ///
  /// 三条护栏，缺一不可：
  /// - **单个失败不连累其它**：一个视图写不进去，不该让另一个视图也丢；
  /// - **异常不外泄**：抛给调用方就等于让窗口关不掉；
  /// - **超时兜底**：见 [kExitFlushTimeout]。
  Future<void> flushAll({Duration timeout = kExitFlushTimeout}) async {
    if (_flushers.isEmpty) return;
    // 先快照再遍历：落盘过程中可能有视图卸载并注销，边遍历边改会抛并发修改。
    final List<Future<void> Function()> snapshot = <Future<void> Function()>[
      ..._flushers,
    ];
    final List<Future<void>> pending = <Future<void>>[
      for (final Future<void> Function() flush in snapshot) _guarded(flush),
    ];
    try {
      await Future.wait(pending).timeout(timeout);
    } on TimeoutException {
      debugPrint('退出前落盘超时（${timeout.inMilliseconds}ms）：仍有写入未完成，照常退出');
    }
  }

  /// 跑一个落盘动作；异常只记日志（见 [flushAll] 的护栏）。
  static Future<void> _guarded(Future<void> Function() flush) async {
    try {
      await flush();
    } on Object catch (e) {
      debugPrint('退出前落盘失败（已忽略，继续退出）: $e');
    }
  }

  /// 当前登记数量（测试用：钉住"视图卸载后必须注销"）。
  @visibleForTesting
  int get registeredCount => _flushers.length;
}

/// 退出请求的应答：把未落盘的编辑写完，再放行退出。
///
/// 接在**官方**的可取消退出请求上（`WidgetsBindingObserver.didRequestAppExit`）。
///
/// ## 官方机制长什么样（Windows，`windows_lifecycle_manager.cc` 已核实）
/// 1. `WM_CLOSE`（X / Alt+F4 / 关闭按钮）到了引擎，若是进程最后一个窗口 → 引擎
///    **消费**这条消息，异步把 `System.requestAppExit` 发给 Dart（`return true`，
///    平台线程**不阻塞** ⇒ 等待期间窗口照常响应）；
/// 2. 框架问遍所有 observer 的 `didRequestAppExit()`：任一 `cancel` ⇒ 不退出；
///    全部 `exit` ⇒ 引擎补发**第二个** `WM_CLOSE`，这一条才真正销毁窗口。
///
/// 这套机制由 `WidgetsFlutterBinding` 初始化时自动开启（`System.initializationComplete`
/// ⇒ 引擎 `BeginProcessingExit`），我们不需要注册任何窗口消息钩子。
///
/// ## ⚠️ 为什么**不**自己拦关闭（2026-09-17 实测教训）
/// 上一版用 `window_manager.setPreventClose(true)` + 自己 `destroy()`
/// （原生 `PostQuitMessage(0)`）：preventClose 会**先吞掉** WM_CLOSE，引擎的官方流程
/// 根本没被触发；而 `PostQuitMessage` 是在 Dart 侧还有未完成的落盘与通道往返时把
/// 应用推进拆解流程 —— 结果是窗口既不销毁、也不再处理消息，用户实拍标题栏
/// **"sinan (未响应)"**。改用官方机制后，"先落盘再关窗"由引擎保证，我们只负责回答。
///
/// ## ⚠️ 永远答 `exit`，绝不 `cancel`
/// 落盘超时或失败也不该把用户困在一个**关不掉**的窗口里。`flushAll` 的全部护栏
/// （超时兜底、单个失败不连累、异常不外泄）都服务于"一定会返回"这一条。
Future<AppExitResponse> flushThenExit(
  PendingSaves saves, {
  Duration timeout = kExitFlushTimeout,
}) async {
  await saves.flushAll(timeout: timeout);
  return AppExitResponse.exit;
}
