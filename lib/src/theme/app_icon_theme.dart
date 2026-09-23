/// tabler 图标的**主题桥**：让 tabler 控件继承 Material 的图标色语义。
///
/// ## 要解决的病（2026-09-23 用户实报）
/// 症状两句话：**「图标不随明暗变色」+「没有未激活的浅色（全是一个黑）」**。
/// 根因有四层，缺一层就治不好：
///
/// **① tabler 不读 Material 的 `IconTheme`。** `tabler_icons_next` 的图标控件自带
/// 一套**独立的** `IconTheme` —— 包内 `IconTheme` / `IconThemeData`，且它的
/// `icon.dart` 用 `import 'package:flutter/widgets.dart' hide IconTheme,
/// IconThemeData` 把 Flutter 的同名类**藏掉了**。于是 Material 组件
/// （`IconButton` / `FilledButton` / `ListTile` / `Chip` / `AppBar` … 统统经
/// `IconTheme.merge` 下发图标色）给出的颜色，对 tabler 图标**完全无效**；
/// `color` 为 null 时它恒定回落到 `IconThemeData.fallback().color` = 纯黑。
///
/// **② Material 侧给的"默认图标色"其实是文字色。** 没有更近的 `IconTheme` 时，
/// `IconTheme.of(context)` 会从 `Typography` 派生（实测亮色 `black87`、暗色纯白）
/// —— 那不是图标色，`ThemeData.iconTheme` 的意图会被它顶掉。
///
/// **③ 裸放的图标没有色源。** 外面没有会 `merge` 的 Material 组件时（图标直接放
/// 在 `Stack`/`Column` 里），上面那个派生值就是图标唯一能拿到的色，明暗主题下
/// 会落到"黑/白"这种与主题无关的两极。
///
/// **④ `InheritedTheme` 不通知。** tabler 的 `IconTheme` 靠
/// `data != oldWidget.data` 决定要不要通知子树。桥接 data 若是个**恒定实例**
/// （例如 `const` 一个），明暗切换时它"相等" ⇒ **不通知** ⇒ 图标不重建 ⇒
/// 颜色不变。这一层最隐蔽——它让①②③都修好之后图标**依然**不变色。
///
/// ## 做法
/// 在 `MaterialApp.builder` 里包一层（见 `main.dart`），**两侧各显式给一次色**：
///
/// - **Material 侧** `IconTheme.merge(color: onSurfaceVariant)` —— 压掉②那个
///   文字色派生值，让裸放图标拿到真正的"未激活浅色"（治②③）。局部
///   `IconTheme.merge`（`IconButton` 等）在更内层，照常胜出。
/// - **tabler 侧** [_BridgedIconThemeData] —— 它 override `resolve`，在**每次**
///   `IconTheme.of` 时按**图标自己的 context** 去 Material 侧问色（治①）：
///
///   ```
///   Material IconTheme.color → ThemeData.iconTheme.color → colorScheme.onSurfaceVariant
///   ```
///
///   因为解析用的是图标自己的 context，按钮里未激活的图标、选中态图标、各语义
///   槽位依旧各自拿到 Material 给它们算好的色——这是它优于"根层写死一个颜色"
///   的地方。
/// - data 与 `ThemeData.iconTheme`（`app_theme.dart` 里显式给了
///   `color: onSurfaceVariant`，那是"全应用图标默认色源"的唯一出处）取同一个值，
///   并因此**随主题变化**（治④）。
///
/// 顺带把描边默认值定成 [Tokens.iconStroke]（1.5），让没显式传描边的 tabler
/// 图标与应用其余图标一致（tabler 自己的 fallback 是 2.0）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'tokens.dart';

/// 在 `MaterialApp.builder` 里包一层（见 `main.dart`），把 Material 的图标色
/// 语义桥接给 tabler 控件。
///
/// 必须在 `MaterialApp` **之内**（要能读到 `Theme` / `IconTheme`），
/// 且要包在**所有**页面之上。无状态，重复包也无害。
class AppIconTheme extends StatelessWidget {
  const AppIconTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 这个 color 非有不可，有三个理由：
    //   ① tabler 图标的兜底色（治①③）；
    //   ② 压掉 Material 从 `Typography` 派生的文字色（治②）；
    //   ③ 它是桥接 data 的"随主题变化"字段 —— 明暗一切两个 data 实例就不相等
    //      ⇒ `InheritedTheme` 才会通知子树（治④；恒定实例会让图标颜色永远停在
    //      旧主题上，这正是第一版栽的坑）。
    final Color fallback = _defaultIconColor(context);
    return IconTheme.merge(
      data: IconThemeData(color: fallback),
      child: tabler.IconTheme(
        data: _BridgedIconThemeData(color: fallback),
        child: child,
      ),
    );
  }
}

/// 全应用图标的默认色：`ThemeData.iconTheme.color`
/// （`app_theme.dart` 里显式设为 `onSurfaceVariant`），缺失时直接兜 `onSurfaceVariant`。
Color _defaultIconColor(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  return theme.iconTheme.color ?? theme.colorScheme.onSurfaceVariant;
}

/// 桥接 data：把 tabler 的取色动作改道去 Material 侧问。
///
/// 只有**本类**会 override `resolve` —— 所以应用里若有别处显式包了
/// `tabler.IconTheme(data: tabler.IconThemeData(color: X))`，那个 data 走父类的
/// 默认 `resolve`（原样返回）⇒ **显式色依旧优先**，不被桥接覆盖。
class _BridgedIconThemeData extends tabler.IconThemeData {
  const _BridgedIconThemeData({required Color color})
    : super(color: color, strokeWidth: Tokens.iconStroke);

  /// tabler 的 `IconTheme.of` 会调它 ⇒ 每次取图标**色与尺寸**都按当前 context 解析。
  ///
  /// ## 预留的扩展点：无障碍字号（**现在故意不乘**）
  /// 要让图标跟随系统"文字大小"，就是把下面两行尺寸换成
  /// `MediaQuery.textScalerOf(context).scale(material.size!)` —— 全应用 **132 处**
  /// tabler 图标**一次生效**（它们全都经这里取尺寸），不必逐个调用点改。
  ///
  /// 之所以现在不乘：Flutter 桌面（Windows）**不读**系统的文本大小设置，
  /// `MediaQuery.textScalerOf(context)` 在目标平台上恒为 1.0 —— 为一个触发不了的
  /// 分支写代码属过度工程。编辑器内**已经**跟了（官方 `EditorSvg.build` 先把尺寸
  /// 乘上 `editorStyle.textScaleFactor` 再交给换皮钩子），所以真到那一天，缺口只
  /// 会出现在应用侧，也就是这里。
  ///
  /// 另外两条相关的判断（为什么图标**不**随窗口缩放、窄窗口为什么该"藏功能"而
  /// 不是"缩图标"）见 `note_editor_view_appflowy.dart` 的 `wideEnough`。
  @override
  tabler.IconThemeData resolve(BuildContext context) {
    final IconThemeData material = IconTheme.of(context);
    return copyWith(
      color: material.color ?? _defaultIconColor(context),
      // ⚠️ 尺寸也得接过来：Material 组件（`IconButton` / 各类按钮…）正是靠
      // `IconTheme` 下发图标尺寸的，而 tabler 不读它 ⇒ 组件的 `iconSize`
      // **全线失效**（图标恒为调用点写死的那个值）。2026-09-23 由编辑页三个
      // "小耳朵"实测到：`iconSize: Tokens.iconSm`(18) 声明着、实际渲染 24。
      // 接过来后，调用点**不写** height/width 的 tabler 图标就能跟随组件尺寸。
      height: material.size,
      width: material.size,
    );
  }
}
