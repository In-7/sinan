import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/editor/core/editor_icons.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

/// `…/assets/images/toolbar/bold.svg` → `toolbar/bold`。
///
/// 官方 `EditorSvg` 用的名字就是"相对 `assets/images`、去掉 `.svg`"，
/// 所以资产文件名本身就是映射表的键。
String _iconNameOf(String path) => path
    .replaceAll(r'\', '/')
    .split('assets/images/')
    .last
    .replaceAll(RegExp(r'\.svg$'), '');

void main() {
  group('编辑器图标：全 Tabler', () {
    test('官方图标名全部有映射（缺一个就退回 SVG ⇒ 混排重现）', () {
      // 直接读 vendored 的资源目录，而不是手写清单：手写清单在**上游升级新增
      // 图标**时不会报错，而"新图标没登记"正是混排重现最可能的入口。
      final Directory dir = Directory(
        'third_party/appflowy_editor/assets/images',
      );
      expect(
        dir.existsSync(),
        isTrue,
        reason: '资产目录不存在（测试的工作目录应是项目根）',
      );

      final Set<String> onDisk = <String>{
        for (final FileSystemEntity entity in dir.listSync(recursive: true))
          if (entity is File && entity.path.endsWith('.svg'))
            _iconNameOf(entity.path),
      };
      expect(onDisk, isNotEmpty, reason: '一个 SVG 都没读到，这条测试就失去意义');

      final List<String> missing = onDisk
          .where((String name) => !kEditorIcons.containsKey(name))
          .toList()
        ..sort();
      expect(missing, isEmpty, reason: '这些官方图标还没换成 Tabler：$missing');
    });

    test('未登记的名字返回 null ⇒ 回落官方 SVG（上游新增图标不会坏）', () {
      installEditorIcons();
      expect(EditorSvg.iconOverride, isNotNull, reason: '钩子没装上，全在走 SVG');
      expect(
        EditorSvg.iconOverride!('toolbar/bold'),
        isA<tabler.Bold>(),
        reason: '登记的官方名应产出 Tabler 控件，而不是官方 SVG',
      );
      expect(
        EditorSvg.iconOverride!('upstream_new_icon'),
        isNull,
        reason: '未登记的名字应回落 SVG，而不是抛错或给个错字形',
      );
    });

    test('映射产出 Tabler 控件（描边 1.5 由 editor_icons 统一注入）', () {
      // Tabler 是 24×24 网格、2px 线稿的 **SVG 控件**（不是字体图标）：描边走
      // `strokeWidth` 参数，全表由 `editor_icons.dart` 的 `_b()` 统一注入 1.5。
      // 这里只锁死"映射确实指向 Tabler 字形"，描边一致性由该文件保障。
      expect(kEditorIcons['toolbar/bold']!(), isA<tabler.Bold>());
      expect(kEditorIcons['toolbar/h1']!(), isA<tabler.H1>());
    });
  });
}
