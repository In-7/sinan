/// 应用元信息的**唯一来源**（「关于」对话框、设置里的关于分区、许可页共用）。
///
/// 为什么是常量而不是读 `pubspec.yaml`：读它要引 `package_info_plus`（一个平台
/// 插件），而这里只有三个字符串。权衡下来**手工同步**更划算 —— 代价是发版时
/// 要记得改这里（见 [version] 的警告）。
abstract final class AppInfo {
  const AppInfo._();

  static const String name = 'sinan';

  /// ⚠️ **与 `pubspec.yaml` 的 `version:` 手工同步**（当前 `0.1.0+1`）。
  /// 改版本号要同时改两处；不一致的现象是"关于"与安装包版本对不上。
  static const String version = '0.1.0';

  /// 一句话简介（设置 → 关于分区的副标题）。
  static const String tagline = '本地优先的流式写作工具：侧栏管理笔记，主区为沉浸式编辑器。';

  /// 完整描述（关于面板的简介那一格用它 —— 它此前是官方 `showAboutDialog`
  /// 的 `applicationLegalese`，2026-09-22 换成自绘玻璃面板后仍由它承担）。
  static const String description = '$tagline所有数据存于本机，无云端同步。';
}
