import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 官方编辑器文案的中文化（回归钉）。
///
/// ## 根因（实测，别改回去）
/// 官方**自带** zh-CN / zh-TW 两份消息表（`lib/src/l10n/intl/messages_zh-CN.dart`
/// 共 117 条），但 `AppFlowyEditorLocalizations.load()` 是用
/// `locale.toString()`（即 **`zh_CN`**）去查表的：
///
/// ```dart
/// final name = (locale.countryCode?.isEmpty ?? false)
///     ? locale.languageCode
///     : locale.toString();          // Locale('zh') → 'zh' ✗ 查不到
/// ```
///
/// 于是 `MaterialApp.supportedLocales` 里写成 `Locale('zh')`（无国家码）时，
/// 解析出的 locale 就是 `zh`，官方文案**整条链**回落英文——占位符、斜杠菜单、
/// 右键菜单、查找替换全在这条链上。修法：`supportedLocales` 里带国家码
/// （见 `main.dart`）。
///
/// ## zh-CN 的缺口
/// zh-CN 比 en 少 67 条键：65 条 `cmd*`（快捷键命令描述，只在官方快捷键面板
/// 显示，本项目没接）——**无影响**；另 2 条是用户可见占位符
/// （`listItemPlaceholder` / `toDoPlaceholder`），已由补丁 5 补上
/// （见 `third_party/appflowy_editor/PATCHES.md`）。
void main() {
  group('编辑器文案中文化', () {
    test('Locale("zh","CN") 命中 zh_CN 消息表 ⇒ 全中文', () async {
      await AppFlowyEditorLocalizations.load(const Locale('zh', 'CN'));
      // 注：`AppFlowyEditorL10n` 是访问入口，实例类型是
      // `AppFlowyEditorLocalizations`（两者不是同一个类型）。
      final AppFlowyEditorLocalizations l10n = AppFlowyEditorL10n.current;

      // 行内格式
      expect(l10n.bold, '粗体');
      expect(l10n.underline, '下划线');
      // 块样式 / 斜杠菜单条目名（官方 `standardSelectionMenuItems` 的
      // getName 就是取这些 key ⇒ 这里绿了，斜杠菜单就是中文）
      expect(l10n.bulletedList, '无序列表');
      // 右键菜单
      expect(l10n.cut, '剪切');
      expect(l10n.copy, '复制');
      // 查找替换
      expect(l10n.caseSensitive, '区分大小写');
      // 链接
      expect(l10n.link, '链接');
    });

    test('补丁 5：zh-CN 原本缺的两条可见占位符已是中文', () async {
      await AppFlowyEditorLocalizations.load(const Locale('zh', 'CN'));
      final AppFlowyEditorLocalizations l10n = AppFlowyEditorL10n.current;

      // 修之前：空的列表项显示 "List item"、空的待办项显示 "To-do"。
      expect(l10n.listItemPlaceholder, '列表项');
      expect(l10n.toDoPlaceholder, '待办');
    });

    test('繁体 locale 也能命中（zh_TW 表存在）', () async {
      await AppFlowyEditorLocalizations.load(const Locale('zh', 'TW'));
      // 不断言具体译法（繁简用词不同），只断言"不是回落英文"。
      expect(AppFlowyEditorL10n.current.bold, isNot('Bold'));
    });
  });
}
