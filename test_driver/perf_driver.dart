import 'package:integration_test/integration_test_driver.dart';

/// `flutter drive` 的**宿主侧入口**——刻意保持空壳。
///
/// ## 为什么它什么都不做
/// 1. **桌面端必须用 `flutter drive`**：`flutter test` 没有 `--profile`（只有
///    debug），而 debug 的帧耗时不具参考价值（`docs/perf_baseline.md` §4）。
/// 2. **但 drive 的上报通道在桌面端是坏的**：运行期会警告
///    `integration_test plugin was not detected`，`traceAction`/`reportData`
///    一路都拿不到东西（实测：测试全过、数字全无）。
///
/// 于是分工改成：**设备侧（`integration_test/perf_test.dart`）自己用
/// `addTimingsCallback` 采集并写 `build/perf/*.json`**；本文件只负责让
/// `flutter drive` 有东西可挂（它的默认行为即可）。
///
/// ⚠️ 所以：**别把采集逻辑写到这里**——它拿不到数据，只会让人以为"测试没跑"。
Future<void> main() => integrationDriver();
