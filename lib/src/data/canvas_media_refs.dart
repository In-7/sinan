import 'dart:convert';

/// 扫出画布正文里引用到的媒体路径（**纯函数**：只吃字符串，不碰 DB / 文件 / UI）。
///
/// ## 用途
/// AI 结果缓存按内容寻址，其文件**同时是文档里的图片本体**——淘汰掉仍被引用的
/// 文件等于删用户的正文。这个函数产出的集合就是"淘汰保护集"。
///
/// ## 为什么是纯函数
/// 这条逻辑此前写在 `app/providers.dart` 的 DI 层里（`_referencedCanvasMedia`），
/// 直接依赖 `NoteStore` + `MediaResolver` ⇒ 只能靠集成测试间接验证。而它一旦
/// 算错，后果是**静默删掉用户还在用的图片**——这种逻辑必须能被直接测。
/// 现在它只依赖"正文 JSON 字符串"与一个 `toPath` 换算回调，两者都可注入。
///
/// ## 解析而不是正则
/// 路径里含 `\`，在 JSON 文本里是转义过的 `\\`；用文本匹配就得自己反解转义。
/// 解析一次反而更简单也更可靠。
///
/// ## 容错
/// 脏数据（旧格式 / 半截 JSON / 非画布正文）一律跳过：引用扫描不值得为此抛错
/// ——漏扫的后果只是"少保护一个文件"，而抛错会让保存路径整体失败。
Set<String> referencedCanvasMedia(
  Iterable<String> canvasContents, {
  required String Function(String ref) toPath,
}) {
  final Set<String> referenced = <String>{};

  void add(String refOrPath) {
    if (refOrPath.isEmpty) return;
    referenced.add(toPath(refOrPath));
  }

  for (final String content in canvasContents) {
    if (content.isEmpty) continue;
    try {
      final dynamic decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) continue;
      final dynamic document = decoded['document'];
      if (document is! Map<String, dynamic>) continue;

      // 侧表（派生索引）与 items 取并集：旧存档可能只有其中一侧。
      final dynamic manifest = document['media'];
      if (manifest is Map<String, dynamic>) {
        for (final String ref in manifest.keys) {
          add(ref);
        }
      }
      final dynamic items = document['items'];
      if (items is Map<String, dynamic>) {
        for (final dynamic item in items.values) {
          if (item is! Map<String, dynamic>) continue;
          final dynamic src = item['src'];
          if (src is String) add(src);
        }
      }
    } on FormatException {
      continue;
    }
  }
  return referenced;
}
