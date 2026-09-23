import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/dev/frame_probe.dart';

/// 帧耗时统计的**纯函数**测试（`lib/src/dev/frame_probe.dart`）。
///
/// 为什么值得测：自动场景（harness）与人工场景（F9 探针）填的是同一张复测表，
/// 而 p90 的**分位下标**是最容易写错又最不容易发现的地方——它错了数字照样出来，
/// 只是悄悄偏了。这里把口径钉死。
void main() {
  group('summarizeFrameDurations', () {
    test('p90 = 升序第 ((n-1)*0.9).round() 个，且与入参顺序无关', () {
      final Map<String, Object?> s = summarizeFrameDurations(
        key: 'k',
        // 乱序入参：统计内部必须自己排序（调用方是"帧到达顺序"）。
        buildMs: const <double>[7, 3, 10, 1, 9, 2, 8, 4, 6, 5],
        rasterMs: const <double>[1, 1, 1],
      );
      expect(s['scene'], 'k');
      expect(s['frames'], 10);
      expect(s['build_avg_ms'], 5.5);
      // 下标 = ((10-1)*0.9).round() = 8 ⇒ 升序第 9 个 = 9
      expect(s['build_p90_ms'], 9.0);
      expect(s['build_worst_ms'], 10.0);
    });

    test('掉帧判据是 60Hz 预算且为严格大于（正好等于预算不算掉）', () {
      final Map<String, Object?> s = summarizeFrameDurations(
        key: 'k',
        buildMs: const <double>[1000 / 60, 17, 16],
        rasterMs: const <double>[1000 / 60, 1000 / 60, 1000 / 60],
      );
      expect(s['missed_frames_build'], 1);
      expect(s['missed_frames_raster'], 0);
    });

    test('空样本不炸（返回全 0），不抛异常', () {
      final Map<String, Object?> s = summarizeFrameDurations(
        key: 'k',
        buildMs: const <double>[],
        rasterMs: const <double>[],
      );
      expect(s['frames'], 0);
      expect(s['build_avg_ms'], 0.0);
      expect(s['build_p90_ms'], 0.0);
      expect(s['raster_worst_ms'], 0.0);
      expect(s['missed_frames_build'], 0);
    });

    test('数值取两位小数（与既有 json 的小数位一致，表格才可比）', () {
      final Map<String, Object?> s = summarizeFrameDurations(
        key: 'k',
        buildMs: const <double>[1.234],
        rasterMs: const <double>[1.0],
      );
      expect(s['build_avg_ms'], 1.23);
      expect(s['raster_avg_ms'], 1.0);
    });
  });
}
