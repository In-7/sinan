// ignore_for_file: avoid_print
// ↑ 本文件输出的是**机器可读的诊断行**（`PERF <key> {...}` 一行 JSON，与
//   `integration_test/perf_test.dart` 同格式，供人直接 grep / 粘进文档），
//   不是给用户看的日志。`print` 正是这里要的通道。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kProfileMode;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// 人工场景的**帧探针**（`docs/perf_baseline.md` §2.1 的「大笔记连打」）。
///
/// ## 为什么必须在应用里做（两条都已核实，2026-09-21）
/// 1. **harness 代劳不了**：集成测试只能"整段替换"式输入，与真人逐键（IME 上屏、
///    光标动画、每次的编辑量）差得远，测出来的数字好看得没有意义；
/// 2. **DevTools 数不出来**：性能页只给逐帧柱状图 + 卡顿红色高亮，**不提供**
///    p90 / 均值 / 掉帧统计（官方文档确认）——而 `perf_baseline.md` §4 的判定
///    规则要的正是 p90。原配方写的"DevTools 取 p90"是读不出数的。
///
/// 于是把 `integration_test/perf_test.dart` 里那套 [FrameTiming] 统计搬进应用，
/// 由人按 `F9` 开关；[summarizeFrameDurations] 与自动场景**是同一份实现**，产出
/// 同形状的 JSON ⇒ 可以直接填进同一张复测表。
///
/// **只在 profile 构建里存在**：[kProfileMode] 是编译期常量，release 下整块被裁掉
/// （数字本来也只认 profile —— §4 规则 5）。
void installFrameProbe() {
  if (!kProfileMode || _installed) return;
  _installed = true;
  HardwareKeyboard.instance.addHandler(_onKey);
}

bool _installed = false;
bool _collecting = false;
final List<FrameTiming> _frames = <FrameTiming>[];

/// `F9` 开关。**刻意返回 false（不消费事件）**：探针不该改变应用行为——编辑器与
/// 画布该收到的按键照收（探针只是旁观）。`F9` 未被任何命令占用（`lib/src/command/`）。
bool _onKey(KeyEvent event) {
  if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.f9) {
    _toggle();
  }
  return false;
}

void _toggle() {
  if (_collecting) {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _collecting = false;
    _report();
    return;
  }
  _frames.clear();
  SchedulerBinding.instance.addTimingsCallback(_onTimings);
  _collecting = true;
  print('[perf] 采集开始 —— 连续输入几秒，再按 F9 结束。');
}

void _onTimings(List<FrameTiming> timings) => _frames.addAll(timings);

void _report() {
  if (_frames.isEmpty) {
    print('[perf] 没采到帧 —— 是不是没真的在输入？按 F9 重新开始。');
    return;
  }
  if (_frames.length < 20) {
    // p90 在小样本上等于"接近最差的那一帧"，抖得没有参考价值。样本量取决于
    // 打字速度：**每敲一键才出一帧**（应用只在有脏区时才渲染），所以打得慢
    // 就采得少。
    print(
      '[perf] ⚠️ 只采到 ${_frames.length} 帧（每敲一键出一帧），p90 会偏粗；'
      '建议再多打几秒重采一次。',
    );
  }
  final Map<String, Object?> summary = summarizeFrameTimings(
    _frames,
    'typing_manual',
  );
  print('PERF typing_manual ${jsonEncode(summary)}');
  try {
    final Directory dir = Directory('build/perf')..createSync(recursive: true);
    final File out = File('${dir.path}/typing_manual.json')
      ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));
    print('[perf] 已归档 ${out.path}');
  } on Object catch (error) {
    // 归档失败不影响已经打印出来的数字（相对路径取决于启动时的 CWD）。
    print('[perf] 归档失败（数字在上面那一行）：$error');
  }
}

/// 60 Hz 的帧预算（ms）。超过即"掉帧"。
const double _budgetMs = 1000 / 60;

/// 帧耗时摘要：**自动场景与人工探针共用这一份实现**。
///
/// 两个消费者填的是同一张复测表，各写一份 p90 迟早会漂移（比如某天有人只改了
/// 一边的取整或分位下标），所以统计只有这一个出口。
///
/// 入参是**毫秒**序列且**顺序无关**（内部排序）；除均值外还算 **p90** —— 卡顿
/// 看尾部，均值会把卡顿平均掉（`docs/perf_baseline.md` §4）。
Map<String, Object?> summarizeFrameDurations({
  required String key,
  required List<double> buildMs,
  required List<double> rasterMs,
}) {
  final List<double> build = List<double>.of(buildMs)..sort();
  final List<double> raster = List<double>.of(rasterMs)..sort();

  double avg(List<double> xs) =>
      xs.isEmpty ? 0 : xs.reduce((double a, double b) => a + b) / xs.length;
  double pct(List<double> xs, double p) =>
      xs.isEmpty ? 0 : xs[((xs.length - 1) * p).round()];
  double worst(List<double> xs) => xs.isEmpty ? 0 : xs.last;
  int missed(List<double> xs) => xs.where((double v) => v > _budgetMs).length;

  double round2(double v) => (v * 100).roundToDouble() / 100;

  return <String, Object?>{
    'scene': key,
    'frames': build.length,
    'build_avg_ms': round2(avg(build)),
    'build_p90_ms': round2(pct(build, 0.9)),
    'build_worst_ms': round2(worst(build)),
    'raster_avg_ms': round2(avg(raster)),
    'raster_p90_ms': round2(pct(raster, 0.9)),
    'raster_worst_ms': round2(worst(raster)),
    'missed_frames_build': missed(build),
    'missed_frames_raster': missed(raster),
  };
}

/// [FrameTiming] → [summarizeFrameDurations]（引擎对象的取值管道）。
Map<String, Object?> summarizeFrameTimings(
  List<FrameTiming> frames,
  String key,
) => summarizeFrameDurations(
  key: key,
  buildMs: <double>[
    for (final FrameTiming f in frames) f.buildDuration.inMicroseconds / 1000,
  ],
  rasterMs: <double>[
    for (final FrameTiming f in frames) f.rasterDuration.inMicroseconds / 1000,
  ],
);
