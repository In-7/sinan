import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:sinan/src/theme/app_theme.dart';

/// **生产同一份**字体资产的路径（与 `pubspec.yaml` 的 fonts 段一一对应）。
///
/// ⚠️ 换字体时改这里 + pubspec 即可，别在测试里写死路径。
String get appFontAsset => switch (AppTheme.editorFont) {
  'SourceHanSansSC-VF' => 'assets/fonts/SourceHanSansSC-VF.otf',
  'LXGWNeoXiHeiScreen' => 'assets/fonts/LXGWNeoXiHeiScreen.ttf',
  _ => throw UnsupportedError('未登记的字体族：${AppTheme.editorFont}'),
};

/// 测试里加载真实字体（族名默认 = [AppTheme.editorFont]）。
///
/// ## 为什么抽出来
/// 此前有 5 个测试文件各自抄了一份 `FontLoader + rootBundle.load('…ttf')`、
/// **路径写死** ⇒ 换字体要改 5 处；漏掉的那处不会报错，而是**安静地退回 Flutter
/// 测试字体**（每个字符都是 1em 方格），于是"块高预测精度""手柄宽度"这些数字
/// 照样打印出来、却外推不到生产——正是最坏的那种测试失败。
///
/// [family] 传别的值可以给基准测试另起族名（量"冷加载"需要未注册过的族）。
Future<void> loadAppFont({String? family, String? asset}) async {
  final FontLoader loader = FontLoader(family ?? AppTheme.editorFont)
    ..addFont(rootBundle.load(asset ?? appFontAsset));
  await loader.load();
}
