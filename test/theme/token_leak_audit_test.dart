import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **令牌防泄漏闸门**（2026-10-08 令牌收口 ④）。
///
/// 令牌体系的缺口从来不是"缺令牌"，而是**裸字面量绕开令牌回流**：这里
/// 扫描 `lib/src`（令牌定义本营 `lib/src/theme/` 除外），按模式断言零泄漏，
/// 每个确实合理的例外都在 [_exemptions] 里**按文件登记理由**——测试即文档，
/// 新增裸字面量要么换令牌、要么显式登记，不许静默溜进去。
///
/// 五道闸门：
/// - `colorHex`：`Color(0x……)` 硬编码色；
/// - `namedColor`：`Colors.<命名色>`（transparent / black / white 三枚中性
///   原语除外——它们是"无色/黑白"，不是发明色值）；
/// - `duration`：`Duration(milliseconds: …)` 裸时长（动画三档走
///   [Tokens.durationFast] / [Tokens.durationNormal] / [Tokens.durationHover]；
///   防抖/轮询/语义时序等**行为时序**不是动画令牌，登记豁免）；
/// - `radius`：`BorderRadius.circular(<裸数字>)`；
/// - `fontSize`：`fontSize: <裸数字>`（UI 字阶走 TextTheme；编辑器块内固定
///   标签属块高预测标定区，登记豁免）。
///
/// ⚠️ 扫描前先剥注释：历史口径常写在注释里（如已退役的 boardFillHover 的
/// 百分比），注释不是代码泄漏。
void main() {
  const String root = 'lib/src';

  String norm(String p) => p.replaceAll(r'\', '/');

  /// 剥掉行注释与块注释（块注释按**原换行数**留空行，行号不失真）。
  String stripComments(String code) {
    final String noBlock = code.replaceAllMapped(
      RegExp(r'/\*.*?\*/', dotAll: true),
      (Match m) => '\n' * '\n'.allMatches(m[0]!).length,
    );
    return noBlock.replaceAllMapped(
      RegExp(r'(?:^|[^:])//.*', multiLine: true),
      (Match m) => m[0]!.startsWith('//') ? '' : m[0]![0],
    );
  }

  List<File> dartFiles() =>
      Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .map((File f) => File(norm(f.path)))
          // 令牌定义本营：字面量就该住在令牌层。
          .where((File f) => !f.path.startsWith('$root/theme/'))
          .toList();

  final Map<String, RegExp> patterns = <String, RegExp>{
    'colorHex': RegExp(r'Color\(\s*0x'),
    'namedColor': RegExp(r'Colors\.\w+'),
    'duration': RegExp(r'Duration\(milliseconds\s*:'),
    'radius': RegExp(r'BorderRadius\.circular\(\s*[0-9]'),
    'fontSize': RegExp(r'fontSize\s*:\s*[0-9]'),
  };

  /// `namedColor` 的中性原语白名单：无色/黑白不是"发明色值"。
  const Set<String> neutralPrimitives = <String>{
    'Colors.transparent',
    'Colors.black',
    'Colors.white',
  };

  bool isExempt(Map<String, String> exempt, String path) => exempt.keys.any(
    (String key) => key.endsWith('/') ? path.startsWith(key) : path == key,
  );

  List<String> violations(String key) {
    final RegExp re = patterns[key]!;
    final Map<String, String> exempt = exemptions[key]!;
    final List<String> hits = <String>[];
    for (final File f in dartFiles()) {
      if (isExempt(exempt, f.path)) continue;
      final List<String> lines = stripComments(f.readAsStringSync())
          .split('\n');
      for (int i = 0; i < lines.length; i++) {
        for (final Match m in re.allMatches(lines[i])) {
          final String text = m.group(0)!;
          if (key == 'namedColor' && neutralPrimitives.contains(text)) continue;
          hits.add('${f.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    return hits;
  }

  test('闸门 · colorHex：lib/src 不许出现 Color(0x… 硬编码色', () {
    expect(
      violations('colorHex'),
      isEmpty,
      reason:
          '硬编码色必须收进 Tokens/AppTheme/SurfaceLadder；'
          '确属独立域的按文件登记进 _exemptions',
    );
  });

  test('闸门 · namedColor：不许出现 Colors.<命名色>（黑白透三原语除外）', () {
    expect(
      violations('namedColor'),
      isEmpty,
      reason: '命名色是"发明色值"的快捷方式；要染色就走语义色方法',
    );
  });

  test('闸门 · duration：动画时长不许裸写 Duration(milliseconds: …)', () {
    expect(
      violations('duration'),
      isEmpty,
      reason:
          '动画走 Tokens.durationFast/Normal/Hover；'
          '防抖/轮询/语义时序等行为时序按文件登记豁免',
    );
  });

  test('闸门 · radius：圆角不许裸写 BorderRadius.circular(<数字>)', () {
    expect(
      violations('radius'),
      isEmpty,
      reason: '圆角走 Tokens.radiusXs/Sm/Md/Lg/Full',
    );
  });

  test('闸门 · fontSize：UI 字号不许裸写 fontSize: <数字>', () {
    expect(
      violations('fontSize'),
      isEmpty,
      reason:
          'UI 字阶走 TextTheme（bodyLarge 14 / bodyMedium 13 / '
          'bodySmall 11 / labelMedium 11 …）；'
          '编辑器块内固定标签按文件登记豁免',
    );
  });

  test('豁免清单纪律：每条都得有理由，且指向存在的文件/目录', () {
    for (final MapEntry<String, Map<String, String>> e in exemptions.entries) {
      for (final MapEntry<String, String> entry in e.value.entries) {
        expect(
          entry.value.trim(),
          isNotEmpty,
          reason: '${e.key} → ${entry.key} 没写豁免理由',
        );
        expect(
          entry.key.endsWith('/')
              ? Directory(entry.key).existsSync()
              : File(entry.key).existsSync(),
          isTrue,
          reason: '${e.key} → ${entry.key} 豁免对象已不存在（该条该删了）',
        );
      }
    }
  });
}

/// 豁免清单：**按文件（或 `…/` 目录前缀）登记，每条写清"为什么不入令牌"**。
///
/// 登记不是终点——它是一笔"已审阅"的账：未来这些文件里冒出**新的**裸字面量
/// 不会被拦（文件级豁免），所以改这些文件时要自己守住理由的边界。
const Map<String, Map<String, String>>
exemptions = <String, Map<String, String>>{
  'colorHex': <String, String>{
    'lib/src/window/window_service.dart':
        '窗口原生层参数（全透明底 Color(0x00000000)），是 OS 窗口通道的输入而非 UI 色',
    'lib/src/app/home_hub.dart': '状态点业务色（在线绿 #4ADE80 / #16A34A）：业务语义色不入 UI 令牌域',
    'lib/src/notes/note_editor_view_appflowy.dart':
        '浮动工具条底色显式透明：外观全由 AppTheme.neuFloatBar 涂，工具条底本身无色',
    'lib/src/canvas/kernel/':
        '画布内核独立度量域：内核不 import 主题层，ink/fallbackInk/调色板/导出底色都是内核数据',
  },
  'namedColor': <String, String>{
    'lib/src/notes/services/note_image_preview.dart':
        '图片灯箱是反相黑底域：黑遮罩 + white38 叠字灰阶是灯箱固定明度语言，不吃主题',
  },
  'duration': <String, String>{
    'lib/src/app/home_screen.dart': '右轨开合 200ms 专门转场节奏（与左轨同套），非交互态三档',
    'lib/src/app/hub_nav.dart': '切换器滑块 220ms（M3 滑块节奏档），非交互态三档',
    'lib/src/app/search_provider.dart': 'kSearchDebounce 输入防抖 250ms：行为时序不是动画令牌',
    'lib/src/app/settings_panel.dart': '弹层出入场 220ms 专门节奏，非交互态三档',
    'lib/src/notes/note_editor_view_appflowy.dart':
        '保存闪烁语义时序（淡出 220 / 停留 900 / 延迟 120）：行为时序',
    'lib/src/notes/services/note_media_service.dart':
        '磁盘等待轮询 20/10ms：IO 节流不是 UI 时长',
    'lib/src/editor/widgets/link_hover_tooltip.dart':
        'tooltip 显示延迟/隐藏宽限 220ms：行为时序',
    'lib/src/editor/core/note_save.dart': '保存防抖 500ms：行为时序',
    'lib/src/editor/blocks/toggle_block_component.dart': '折叠展开 200ms 专门节奏',
    'lib/src/canvas/canvas_note_view.dart': '自动保存观察窗 600ms：行为时序',
    'lib/src/canvas/kernel/': '画布内核时序（LOD 稳定 180 / 手掌窗 100 / 模拟推理 600）：独立域',
  },
  'radius': <String, String>{
    // 2026-10-08 收口后归零：新增圆角一律走 Tokens.radiusXs..Full。
  },
  'fontSize': <String, String>{
    'lib/src/notes/services/note_image_preview.dart': '灯箱叠字 13/14：反相黑底域的固定字阶',
    'lib/src/notes/services/formula_render.dart': '公式行内渲染 13：与编辑器正文对齐的标定值',
    'lib/src/editor/blocks/ref_block_component.dart':
        '编辑器块内固定标签（块高预测标定区），不吃 UI 字阶',
    'lib/src/editor/blocks/attachment_block_component.dart': '同上：块内固定标签',
    'lib/src/editor/blocks/formula_block_component.dart': '同上：块内固定标签',
    'lib/src/canvas/kernel/': '内核 ParagraphStyle 字号：独立度量域',
  },
};
