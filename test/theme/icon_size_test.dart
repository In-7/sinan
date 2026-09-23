import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// tabler 图标 `height:` 的**允许取值**（2026-09-23 全项目统一之后）。
///
/// 统一前实测：139 处 tabler 图标横跨 **10 / 12 / 14 / 16 / 18 / 24 / 40** 七档，
/// 其中 24 占 55% —— 而 24 是 Tabler 的**固有画板尺寸**，属于迁移时"照抄包内
/// 尺寸"的遗留，不是设计选择。收敛后只剩下面这几档（见 `Tokens` 的图标段）。
const Set<String> _allowedSizes = <String>{
  'Tokens.iconXxs', // 10：行内装饰记号（下拉箭头）—— 30px 槽位的算术逼出来的
  'Tokens.iconXs', // 14：次级小图标（勾选 / 关闭 / 星标 / 外链）
  'Tokens.iconSm', // 18：**编辑器官方容器内**专用（SVGIconItemWidget / 斜杠菜单）
  'Tokens.iconMd', // 20：应用侧常规交互图标（主力）
  'Tokens.iconXl', // 40：空状态大图标
};

/// 少数**动态**取值。每条都逐一看过，各自有明确理由 —— 收紧时不要随手往里加。
const Set<String> _allowedDynamic = <String>{
  // 标题栏菜单按钮：桌面显式传 20 与窗控对齐，移动端走默认（见 [AppMenuButton]）。
  'iconSize',
  // 折叠块箭头：被块高预算器消费（`BlockHeightPredictor._toggleHeightOf`），
  // 动它要连预测器一起验。
  'toggleArrowIconSize',
  // 色板勾选：跟着色板格子大小走（勾号必须随格子缩放，不能取固定档）。
  'size * 0.58',
};

/// 扫 `lib/` 下所有 Dart 源码里的 `tabler.Xxx(height: …)`，把回调喂给 [check]。
void _scanTablerHeight(
  void Function(String path, int line, RegExpMatch match) check,
) {
  final RegExp call = RegExp(r'tabler\.\w+\(height:\s*([^,\)]+)');
  for (final FileSystemEntity entity in Directory(
    'lib',
  ).listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) {
      continue;
    }
    final String source = entity.readAsStringSync();
    for (final RegExpMatch match in call.allMatches(source)) {
      final int line =
          '\n'.allMatches(source.substring(0, match.start)).length + 1;
      check(entity.path.replaceAll(r'\', '/'), line, match);
    }
  }
}

void main() {
  test('tabler 图标的尺寸只用 Tokens 三档（或白名单里的动态值）', () {
    final List<String> offenders = <String>[];
    _scanTablerHeight((String path, int line, RegExpMatch match) {
      final String value = match.group(1)!.trim();
      if (_allowedSizes.contains(value) || _allowedDynamic.contains(value)) {
        return;
      }
      offenders.add('$path:$line → height: $value');
    });

    expect(
      offenders,
      isEmpty,
      reason:
          '写死/越档的图标尺寸又出现了。改用 Tokens.iconXs(14) / iconSm(18) / '
          'iconXl(40)；或者干脆**不写** height+width —— 交给容器，'
          '`IconButton.iconSize` 会经 AppIconTheme 转发给 tabler：\n'
          '${offenders.join('\n')}',
    );
  });

  test('height 与 width 必须同值（图标不该被压扁）', () {
    final List<String> offenders = <String>[];
    final RegExp call = RegExp(
      r'tabler\.\w+\(height:\s*([^,\)]+),\s*width:\s*([^,\)]+)',
    );
    for (final FileSystemEntity entity in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final String source = entity.readAsStringSync();
      for (final RegExpMatch match in call.allMatches(source)) {
        if (match.group(1)!.trim() == match.group(2)!.trim()) {
          continue;
        }
        final int line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        offenders.add(
          '${entity.path.replaceAll(r'\', '/')}:$line → '
          '${match.group(1)!.trim()} / ${match.group(2)!.trim()}',
        );
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'height 与 width 不一致（图标会被压扁）：\n${offenders.join('\n')}',
    );
  });
}
