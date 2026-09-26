import 'dart:async';

/// 落盘防抖的**上限**（两个消费方共用同一个数字）：文档编辑器与画布。
///
/// 2 秒的取法：暴露窗口 = 上限 + 一次写入耗时，而"停顿时长"仍由各自的防抖窗口
/// （500 / 600ms）决定，所以**即时性不变**；写放大由下层判变（`content_hash` /
/// 块指纹 / 画布行指纹）吸收——内容没变就不写。
const Duration kSaveMaxWait = Duration(seconds: 2);

/// **带上限**的落盘防抖：一停顿就落盘，且持续输入也不会无限推迟。
///
/// ## 为什么必须有上限
/// 纯防抖（每次变更都 `cancel()` 再重设一个 Timer）在**连续输入**下**一次都不会落盘**：
/// 用户狂打字或不停运笔时，"停顿 [window]"这个条件永远不成立，暴露窗口会随时间**线性
/// 增长**（打三分钟就丢三分钟）。这是 2026-09-17 评估崩溃恢复时实测到的两个洞之一
/// ——另一个是"关窗口没有显式 flush"（用户实测：删掉一段文字、马上关窗口，重开后
/// 那段文字又回来了），同日一起收口：见 `docs/data_layer.md` 7.1、
/// `window/exit_coordinator.dart` 与 `app/pending_saves.dart`。
///
/// 加上 [maxWait] 后：**从第一次未落盘的变更起算**，最多 [maxWait] 必落一次盘。
/// 两个计时器的分工：
/// - [window]：可重置 —— 保证"停顿即落盘"，即时性不变；
/// - [maxWait]：**不可重置**（只在落盘时才清）—— 给暴露窗口封顶。
///
/// 典型用法（两处调用点一致）：
/// ```dart
/// void _onChanged() => _save.bump();
/// // dispose：`if (_save.pending) _flush(); _save.cancel();`
/// ```
class SaveDebounce {
  SaveDebounce({
    required this.window,
    required this.maxWait,
    required this.onFlush,
  }) : assert(maxWait >= window, 'maxWait 不该短于防抖窗口：否则上限总在停顿之前触发，防抖本身就没意义了');

  /// 停顿多久落盘（每次变更重置）。
  final Duration window;

  /// 从"第一次未落盘的变更"起算，最多多久必落一次盘（**不可重置**）。
  final Duration maxWait;

  /// 落盘动作。异步编排由调用方负责（例如 `() => unawaited(_flush())`）。
  final void Function() onFlush;

  Timer? _pauseTimer;
  Timer? _capTimer;

  /// 有变更发生：重设停顿计时器；上限计时器**只在第一次挂上**。
  void bump() {
    _pauseTimer?.cancel();
    _pauseTimer = Timer(window, flushNow);
    // `??=` 就是"不重置"的全部实现——落盘之前它一直不换。
    _capTimer ??= Timer(maxWait, flushNow);
  }

  /// 立刻落盘（并清空两个计时器）。
  void flushNow() {
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _capTimer?.cancel();
    _capTimer = null;
    onFlush();
  }

  /// 是否有**未落盘**的变更（dispose 兜底落盘的判据，替代过去"计时器是否为 null"）。
  bool get pending => _pauseTimer != null || _capTimer != null;

  /// 取消并丢弃（**不**触发落盘）：dispose 里已经手动落过盘时用。
  void cancel() {
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _capTimer?.cancel();
    _capTimer = null;
  }
}
