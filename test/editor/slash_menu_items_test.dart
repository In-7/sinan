import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:sinan/src/editor/toolbar/slash_menu_items.dart';
import 'package:sinan/src/theme/app_theme.dart';

/// 斜杠菜单的中文化，分两层：
/// - **条目名**：官方条目取 `AppFlowyEditorL10n.current.*`（中文表见
///   `editor_l10n_test.dart`）——locale 带国家码即中文，不需要我们重写条目；
/// - **过滤关键词**：官方只写死英文 ⇒ 中文用户打「待办」「引用」搜不到，
///   由 `_ensureChineseKeywords()` 在应用侧追加中文别名（零补丁）。
void main() {
  group('斜杠菜单配色跟随主题（官方默认是硬编码浅色盘）', () {
    /// WCAG 相对对比度。
    double contrast(Color a, Color b) {
      double linear(double c) => c <= 0.03928
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
      double luminance(Color c) =>
          0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
      final double la = luminance(a);
      final double lb = luminance(b);
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    // 背景：官方 `customSlashCommand` 的 `style` 默认 `SelectionMenuStyle.light`
    // ——硬编码白底 + 青蓝 `#00BCF0`，既不看种子色也不看明暗。视图必须把
    // 应用色板喂进去（`note_editor_view_appflowy.dart`），否则菜单不跟随主题。
    // 不写类型注解：本文件只 import widgets（不牵进任何一方的 Material），
    // 主题类型由 `AppTheme.light()/dark()` 推导。
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      final Brightness brightness = theme.brightness;
      final scheme = theme.colorScheme;

      test('$brightness：角色映射到应用色板，官方指纹色一个不留', () {
        final SelectionMenuStyle style = sinanSlashMenuStyle(
          background: scheme.surfaceContainerHigh,
          foreground: scheme.onSurface,
          muted: scheme.onSurfaceVariant,
          outline: scheme.outlineVariant,
          error: scheme.error,
        );

        expect(style.selectionMenuBackgroundColor, scheme.surfaceContainerHigh);
        expect(style.selectionMenuItemTextColor, scheme.onSurface);
        expect(style.selectionMenuItemSelectedTextColor, scheme.onSurface);
        expect(
          style.selectionMenuItemSelectedColor,
          scheme.onSurface.withValues(alpha: 0.10),
        );
        expect(style.selectionMenuInvalidLinkColor, scheme.error);

        // 官方那套硬编码盘的指纹色：出现了就说明又退回"没跟随主题"。
        const List<Color> officialFingerprints = <Color>[
          Color(0xFFFFFFFF), // light：白底
          Color(0xFF333333), // light：文字
          Color(0xFF00BCF0), // 青蓝强调色（分隔线/按钮/指示器）
          Color(0xFF282E3A), // dark：底
          Color(0xFFBBC3CD), // dark：文字
          Color(0xFFE0F8FF), // light：选中底
        ];
        final List<Color> ours = <Color>[
          style.selectionMenuBackgroundColor,
          style.selectionMenuItemTextColor,
          style.selectionMenuItemIconColor,
          style.selectionMenuItemSelectedColor,
          style.selectionMenuItemSelectedTextColor,
          style.selectionMenuButtonColor,
          style.selectionMenuTabIndicatorColor,
        ];
        for (final Color official in officialFingerprints) {
          expect(
            ours,
            isNot(contains(official)),
            reason: '官方硬编码色 $official 漏进来了 ⇒ 菜单没跟随主题',
          );
        }

        // 菜单文字对菜单底保持正文级对比（明暗各验一次）。
        expect(
          contrast(scheme.onSurface, scheme.surfaceContainerHigh),
          greaterThanOrEqualTo(4.5),
        );
      });
    }
  });

  group('斜杠菜单中文关键词', () {
    test('每个条目都至少有一个中文关键词（官方新增条目不会静默漏掉）', () {
      final List<String> missing = <String>[];
      for (final SelectionMenuItem item in sinanSelectionMenuItems()) {
        if (!item.keywords.any(_containsCjk)) {
          missing.add(item.keywords.join(' | '));
        }
      }
      expect(missing, isEmpty, reason: '这些条目只有英文关键词，中文搜不到：$missing');
    });

    test('按中文能搜到对应条目，且英文关键词原样保留', () {
      final List<SelectionMenuItem> items = sinanSelectionMenuItems();
      SelectionMenuItem itemWith(String keyword) => items.firstWhere(
        (SelectionMenuItem item) =>
            item.keywords.any((String k) => k.contains(keyword)),
      );

      expect(itemWith('todo list').keywords, contains('待办'));
      expect(itemWith('bulleted list').keywords, contains('无序列表'));
      expect(itemWith('numbered list').keywords, contains('有序列表'));
      expect(itemWith('quote').keywords, contains('引用'));
      expect(itemWith('image').keywords, contains('图片'));
      expect(itemWith('heading 1').keywords, contains('标题 1'));
      expect(itemWith('text').keywords, contains('正文'));

      // 英文照旧：中英都能搜（官方关键词没被替换，只是追加）。
      final List<String> todo = itemWith('todo list').keywords;
      expect(todo, contains('todo list'));
      expect(todo, contains('list'));
    });

    test('幂等：重复构造条目表不会重复追加（每次开笔记都会调一次）', () {
      final List<SelectionMenuItem> first = sinanSelectionMenuItems();
      final int before = first.first.keywords.where(_containsCjk).length;

      sinanSelectionMenuItems();
      sinanSelectionMenuItems();

      expect(first.first.keywords.where(_containsCjk).length, before);
    });

    test('表格 / 分隔线用自家条目（图标 Lucide），官方那两条不再出现', () {
      final List<SelectionMenuItem> items = sinanSelectionMenuItems();

      expect(items, contains(tableSlashMenuItem));
      expect(items, contains(dividerSlashMenuItem));
      // 官方那两条（图标是 Material 的 Icons.table_view / Icons.horizontal_rule）
      // 已被剔除——它们是全应用最后两处 Material 图标。
      expect(
        items.any((SelectionMenuItem i) => identical(i, tableMenuItem)),
        isFalse,
        reason: '官方 tableMenuItem 还在（图标是 Material）',
      );
      expect(
        items.any((SelectionMenuItem i) => identical(i, dividerMenuItem)),
        isFalse,
        reason: '官方 dividerMenuItem 还在（图标是 Material）',
      );

      // 图标换成了 Lucide（读 `SelectionMenuIconWidget.icon`，不依赖渲染）。
      IconData? iconOf(SelectionMenuItem item) {
        final Widget widget =
            item.icon(_state(), false, SelectionMenuStyle.light);
        return (widget as SelectionMenuIconWidget).icon;
      }

      expect(iconOf(tableSlashMenuItem), LucideIcons.table300);
      expect(iconOf(dividerSlashMenuItem), LucideIcons.minus300);
    });
  });
}

/// 只用来喂 `item.icon(...)`（那条路径不读 editorState）。
EditorState _state() => EditorState(document: Document.blank());

bool _containsCjk(String value) => RegExp(r'[\u4e00-\u9fa5]').hasMatch(value);
