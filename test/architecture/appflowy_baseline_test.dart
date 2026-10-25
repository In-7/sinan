import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// appflowy_editor **vendored 基线与补丁指纹**闸门（"版本锁"的可见形态）。
///
/// ## 为什么不是 pub 版本锁
/// `appflowy_editor` 是 `path:` 依赖（`third_party/appflowy_editor`，见
/// 根 `pubspec.yaml`）——pub 升级/降级**碰不到它**，`pub upgrade` 也改不了
/// 它。"锁版本"在这里天然成立：目录内容**就是**版本。
///
/// ## 真正的风险与本测试的职责
/// 风险是**人**：手动跟上游（PATCHES.md「同步上游的操作指南」）时把基线
/// 目录整体覆盖、或换了版本却忘了重放补丁。这类事故**编译期不报错**
/// （补丁多是行为差异），却会静默退化成旧 bug。这里钉两件事：
/// 1. **基线版本 = 6.2.0**：换版本必须是有意决定——同步改这里、重放全部
///    补丁、更新 `PATCHES.md`，三件事缺一红。
/// 2. **关键补丁指纹还在**：丢了立刻红，而不是等用户撞上旧行为。
///
/// ⚠️ 路径相对项目根（`flutter test` 工作目录约定，同
/// `architecture_test.dart`）。
void main() {
  const String root = 'third_party/appflowy_editor';

  String read(String rel) =>
      File('$root/$rel').readAsStringSync();

  group('vendored 基线', () {
    test('appflowy_editor pubspec 基线版本 = 6.2.0（换版本必须过升级流程）', () {
      expect(
        read('pubspec.yaml'),
        contains('version: 6.2.0'),
        reason: 'vendored 基线是 6.2.0（PATCHES.md 文首）。'
            '换成新上游版本前：先在临时仓库重放 21 个补丁、再更新 PATCHES.md'
            '与本断言——这是「手动跟进更新」的唯一正路。',
      );
    });

    test('PATCHES.md 在位且记载基线（补丁台账不能丢）', () {
      final String doc = read('PATCHES.md');
      expect(doc, contains('6.2.0'), reason: '补丁台账须注明上游基线版本');
      expect(doc, contains('同步上游的操作指南'), reason: '升级流程必须可查');
    });
  });

  group('补丁指纹（丢了 ⇒ 立刻红，而不是静默退化）', () {
    // 每条 = 一个补丁的最小可查痕迹。选"丢了编译期不报错、但行为会退化"
    // 的点；纯注释类补丁不在此列（丢了无行为差异）。
    const List<(String, String, String)> fingerprints =
        <(String, String, String)>[
      (
        'lib/src/editor/block_component/rich_text/appflowy_rich_text.dart',
        'applyCjkTextSpacing',
        '补丁 20/21：中西文间距 + 标点互挤挂在 adjustTextSpan 尾部',
      ),
      (
        'lib/src/extensions/text_span_cjk_spacing.dart',
        'kPunctSqueezeEm',
        '补丁 21：标点互挤纯函数（含实测标定的挤压量常量）',
      ),
      (
        'lib/src/service/shortcut_event/keybinding.dart',
        'keyCodeOrNull',
        'keybinding 未映射键名的空断言防护（否则快捷键匹配直接崩）',
      ),
      (
        'lib/src/editor/selection_menu/selection_menu_widget.dart',
        'deletedIndex < 0',
        '斜杠菜单 _deleteSlash 的 -1 越界防护（点菜单项即崩的旧 bug）',
      ),
      (
        'lib/src/infra/flowy_svg.dart',
        'iconOverride',
        '图标覆盖色（应用侧 tabler 图标主题化钩子）',
      ),
      (
        'lib/src/editor/block_component/quote_block_component/quote_block_component.dart',
        '#00BCF0',
        '引用块竖条 = **官方原版**（主题色走应用侧 iconBuilder）——'
            '此处若被改成 Theme.of 之类，说明又在改 vendored 源码，回退它',
      ),
    ];

    for (final (String file, String marker, String why) in fingerprints) {
      test('指纹在位：$marker', () {
        expect(
          read(file),
          contains(marker),
          reason: '$why\n文件：$root/$file\n'
              '若这是有意的补丁变更，同步更新 PATCHES.md 与本指纹。',
        );
      });
    }
  });
}
