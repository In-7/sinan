import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/editor/core/block_height_predictor.dart';
import 'package:sinan/src/editor/core/editor_typography.dart';
import 'package:sinan/src/editor/core/note_document_adapter.dart';
import 'package:sinan/src/editor/core/word_count.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 打开一篇笔记的**耗时画像**（2026-09-18）。
///
/// 只量时间、不断言（基准不是门禁）。它要回答"第一次点开慢、点过一遍就快"
/// 到底慢在哪 —— 因此每个指标都量**冷（首次）**与**热（同一份内容第二次）**：
/// 两者的差就是"预热 / 缓存"那部分。
///
/// ⚠️ 测试环境用默认字体（没加载 11MB 的霞鹜新晰黑），所以**排版那一项的绝对值
/// 与真机不同**，但"各项之间的比例"和"冷 vs 热"仍然说明问题。
///
/// 跑法：`flutter test test/perf/note_open_benchmark_test.dart --reporter expanded`
void main() {
  test('打开笔记的耗时画像（冷 vs 热）', () {
    for (final int blocks in <int>[200, 2000]) {
      final String content = _contentOf(blocks);
      // 同一份内容连测两次 ⇒ 冷 / 热。
      final Map<String, double> cold = _measure(content, blocks);
      final Map<String, double> warm = _measure(content, blocks);
      _report(blocks, cold, warm);
    }
  });

  test('自定义字体：加载成本 vs 排版成本', () async {
    TestWidgetsFlutterBinding.ensureInitialized();

    // ⓿ **先**量 pubspec 声明的那一族（= `ThemeData.fontFamily`，全应用主字体）。
    //    必须放在 [\_loadFont] 之前：那一步会把同一份文件的 asset 读进缓存，
    //    之后这里的"首次"就不再干净了。
    //
    //    它要回答的是：这笔钱到底付在**首帧**（列表就在用它），还是付在
    //    "第一次打开笔记正文"？
    //
    //    ⚠️ **这一项在测试环境里读不出真机结论**：实测内置族冷 0.344ms，
    //    与默认字体（0.263ms）同量级；而真正吃到中文字形的自定义族是 1.211ms
    //    ⇒ 说明测试里 pubspec 声明的那一族**没有真正生效**（渲染回了默认字体）。
    //    真机的加载时机请看代码证据：`ThemeData.fontFamily = AppTheme.editorFont`
    //    （app_theme.dart）⇒ 全应用（含列表）都用它 ⇒ 钱付在**首帧**。
    final double builtinCold = _layoutParagraph(AppTheme.editorFont);
    final double builtinWarm = _layoutParagraph(AppTheme.editorFont);

    // ① 字体**解码/注册**（11MB）——显式 `FontLoader` 主动付这笔钱的成本。
    final double loadCold = await _loadFont('FontBenchA');
    final double loadWarm = await _loadFont('FontBenchB');

    // ② 加载**之后**的排版：默认字体 vs 自定义字体（回答"持续渲染会不会更慢"）。
    final double sysCold = _layoutParagraph(null);
    final double sysWarm = _layoutParagraph(null);
    final double cusCold = _layoutParagraph('FontBenchA');
    final double cusWarm = _layoutParagraph('FontBenchA');

    final StringBuffer out = StringBuffer(
      '\n──── 自定义字体（11MB 中英字体）────',
    )
      ..write(
        '\n  排版·内置族（首用） 冷 ${builtinCold.toStringAsFixed(3).padLeft(8)} ms'
        '   热 ${builtinWarm.toStringAsFixed(3).padLeft(8)} ms',
      )
      ..write(
        '\n  FontLoader.load   冷 ${loadCold.toStringAsFixed(1).padLeft(8)} ms'
        '   热 ${loadWarm.toStringAsFixed(1).padLeft(8)} ms',
      )
      ..write(
        '\n  排版·默认字体     冷 ${sysCold.toStringAsFixed(3).padLeft(8)} ms'
        '   热 ${sysWarm.toStringAsFixed(3).padLeft(8)} ms',
      )
      ..write(
        '\n  排版·自定义字体   冷 ${cusCold.toStringAsFixed(3).padLeft(8)} ms'
        '   热 ${cusWarm.toStringAsFixed(3).padLeft(8)} ms',
      );
    // ignore: avoid_print
    debugPrint(out.toString());
  });
}

/// 造一份 v2 块树正文（[blocks] 个段落，每块约 40 字）。
String _contentOf(int blocks) => jsonEncode(<String, Object?>{
      'v': 2,
      'format': 'blocks',
      'document': <String, Object?>{
        'id': 'root',
        'type': 'page',
        'children': <Object?>[
          for (int i = 0; i < blocks; i++)
            <String, Object?>{
              'id': 'b$i',
              'type': 'paragraph',
              'data': <String, Object?>{
                'delta': <Object?>[
                  <String, Object?>{
                    'insert': '第 $i 段：这是一段用于基准测试的中文正文，'
                        '长度大致相当于真实笔记里的一个段落。',
                  },
                ],
              },
            },
        ],
      },
    });

/// 一次完整的"打开"：解析 → 建树 → 取纯文本/字数 → 块高预算。返回各项耗时（ms）。
Map<String, double> _measure(String content, int blocks) {
  final Map<String, double> out = <String, double>{};

  // ① 只 jsonDecode（把"解析"从"建树"里分出来）。
  final Stopwatch s1 = Stopwatch()..start();
  jsonDecode(content);
  out['jsonDecode'] = s1.elapsedMicroseconds / 1000;

  // ② 存储内容 → Document（含 ①）。
  final Stopwatch s2 = Stopwatch()..start();
  final Document doc = NoteDocumentAdapter.documentFromStoredContent(content);
  out['→ Document（含解析）'] = s2.elapsedMicroseconds / 1000;

  // ③ 全树递归取纯文本 + 字数（`initState` 里的第二遍全树遍历）。
  final Stopwatch s3 = Stopwatch()..start();
  final int words = countWords(NoteDocumentAdapter.plainTextFromDocument(doc));
  out['纯文本 + 字数'] = s3.elapsedMicroseconds / 1000;
  expect(words, greaterThan(0), reason: '字数不该为 0（基准数据本身有误）');

  // ④ 块高表整体重建的核心：对每一块干跑一次 TextPainter 预算。
  final Stopwatch s4 = Stopwatch()..start();
  final BlockHeightPredictor predictor = BlockHeightPredictor(
    typography: const EditorTypography(fontSize: 17, lineHeight: 1.5),
    textStyleConfiguration: const TextStyleConfiguration(),
    maxWidth: 800,
    blockPadding: const EdgeInsets.symmetric(vertical: 4),
  );
  int predicted = 0;
  for (final Node node in doc.root.children) {
    if (predictor.predict(node, availableWidth: 800) != null) predicted++;
  }
  out['块高预算（全树）'] = s4.elapsedMicroseconds / 1000;
  expect(predicted, blocks, reason: '每一块都该预测出高度');

  return out;
}

/// 一次排版（`TextPainter` 干跑）；[fontFamily] 为 null 时用默认字体。
///
/// 注意：这里量的是"**已加载**字体之后的排版"，不是字体解码 —— 解码由
/// [\_loadFont] 单独量。
double _layoutParagraph(String? fontFamily) {
  final Stopwatch sw = Stopwatch()..start();
  final TextPainter painter = TextPainter(
    text: TextSpan(
      text: '中英混排 ABC 123 —— 用于字体基准的一行正文，长度与真实段落相当，'
          '再补一句让它需要折行，从而触发完整的段落布局。',
      style: TextStyle(fontSize: 17, fontFamily: fontFamily),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: 800);
  final double ms = sw.elapsedMicroseconds / 1000;
  expect(painter.height, greaterThan(0));
  return ms;
}

/// 用 [FontLoader] 显式加载**打包的那份 11MB 中英字体**，返回耗时（ms）。
///
/// [family] 每次传不同名字：已注册过的族重复 `load()` 没有意义（也没法量
/// "第二次加载"），而另起族名能同时避开 pubspec 里已声明的
/// `LXGWNeoXiHeiScreen`。
Future<double> _loadFont(String family) async {
  final Stopwatch sw = Stopwatch()..start();
  final FontLoader loader = FontLoader(family)
    ..addFont(rootBundle.load('assets/fonts/LXGWNeoXiHeiScreen.ttf'));
  await loader.load();
  return sw.elapsedMicroseconds / 1000;
}

/// 打印冷 / 热对照表。
void _report(int blocks, Map<String, double> cold, Map<String, double> warm) {
  final StringBuffer out = StringBuffer('\n──── 打开笔记 · $blocks 块 ────');
  for (final MapEntry<String, double> e in cold.entries) {
    final double w = warm[e.key] ?? 0;
    final String ratio =
        w <= 0 ? '—' : '冷/热 = ${(e.value / w).toStringAsFixed(1)}×';
    out.write(
      '\n  ${e.key.padRight(20)} 冷 ${e.value.toStringAsFixed(1).padLeft(8)} ms'
      '   热 ${w.toStringAsFixed(1).padLeft(8)} ms   $ratio',
    );
  }
  final double coldTotal = cold.values.fold<double>(0, (double a, double b) => a + b);
  final double warmTotal = warm.values.fold<double>(0, (double a, double b) => a + b);
  out.write(
    '\n  ${'合计'.padRight(20)} 冷 ${coldTotal.toStringAsFixed(1).padLeft(8)} ms'
    '   热 ${warmTotal.toStringAsFixed(1).padLeft(8)} ms',
  );
  // ignore: avoid_print
  debugPrint(out.toString());
}
