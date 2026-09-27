// ignore_for_file: avoid_print
// ↑ 与 frame_probe.dart 同约定：输出**机器可读的诊断行**（`PERF startup {...}`
//   一行 JSON），不是给用户看的日志。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kProfileMode;

/// 冷启动**分段计时**：把「`main()` → 首帧」拆成若干段，回答"897ms 花在哪"。
///
/// ## 为什么要在应用里做（与 [installFrameProbe] 同一条理由）
/// 冷启动的 897ms 里，[AppDatabase.open] / [WindowService.init] / 首帧渲染
/// 各自占多少，**DevTools 的时间线给不出这个分段**（它只给逐帧柱子 + 卡顿
/// 高亮）。要归因就得自己在 `main()` 里按段打点。
///
/// ## 用法
/// ```dart
/// StartupProbe.start();
/// WidgetsFlutterBinding.ensureInitialized();
/// StartupProbe.mark('ensureInitialized');
/// ...
/// runApp(...);
/// StartupProbe.mark('runAppCalled');        // runApp 只是"排队"，不含首帧
/// WidgetsBinding.instance.addPostFrameCallback((_) {
///   StartupProbe.mark('firstFrame');        // 首帧已上屏
///   StartupProbe.report();
/// });
/// ```
///
/// ## ⚠️ 归档到文件是**必需通道**，不是可选备份
/// Windows 的 runner 是 GUI 子系统（无控制台），独立跑 exe 时 `print` 的
/// stdout 会丢。数字要留得下来，只能落盘（与 [frame_probe] 的做法一致）。
///
/// **只在 profile 构建里存在**：[kProfileMode] 是编译期常量，release 下整块
/// 被裁掉（数字本来也只认 profile —— `docs/perf_baseline.md` §4 规则 5）。
class StartupProbe {
  StartupProbe._();

  static final Stopwatch _sw = Stopwatch();
  static final List<_Mark> _marks = <_Mark>[];

  /// 是否在采集。**编译期常量**：release 下整段被裁掉，零成本。
  static const bool enabled = kProfileMode;

  static bool _reported = false;

  /// 开始计时（放在 `main()` 第一行）。
  static void start() {
    if (!enabled) return;
    _sw
      ..reset()
      ..start();
  }

  /// 打一个点：记录**距上一个点**的耗时（段耗时）与**距起点**的累计（绝对时刻）。
  static void mark(String label) {
    if (!enabled) return;
    _marks.add(_Mark(label, _sw.elapsedMicroseconds));
  }

  /// 输出并归档一次（幂等：只报一次）。
  static void report() {
    if (!enabled || _reported || _marks.isEmpty) return;
    _reported = true;
    _sw.stop();

    final Map<String, Object?> summary = <String, Object?>{
      'scene': 'cold_start',
      'total_ms': _round2(_marks.last.atUs / 1000),
      'segments_ms': <String, Object?>{
        for (int i = 0; i < _marks.length; i++)
          _marks[i].label: _round2(
            (_marks[i].atUs - (i == 0 ? 0 : _marks[i - 1].atUs)) / 1000,
          ),
      },
      'at_ms': <String, Object?>{
        for (final _Mark m in _marks) m.label: _round2(m.atUs / 1000),
      },
    };

    print('PERF cold_start ${jsonEncode(summary)}');
    try {
      final Directory dir = Directory('build/perf')..createSync(recursive: true);
      final File out = File('${dir.path}/cold_start.json')
        ..writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(summary),
        );
      print('[perf] 已归档 ${out.path}');
    } on Object catch (error) {
      // 归档失败不影响已经打印的数字（相对路径取决于启动时的 CWD）。
      print('[perf] 归档失败（数字在上面那一行）：$error');
    }
  }

  static double _round2(double v) => (v * 100).roundToDouble() / 100;
}

class _Mark {
  const _Mark(this.label, this.atUs);

  final String label;
  final int atUs;
}
