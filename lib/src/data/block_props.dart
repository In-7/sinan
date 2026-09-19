import 'dart:convert';

/// `blocks.props_json` 的**读口**（块级属性只有一份 JSON，读法却有好几处）。
///
/// 存在的理由：卡片（画布）与段落/标题（文档）都把可见文本放在 `props_json.text`
/// 里，而"双链多视图"（块可迁移 #5）下**同一个块**会同时被文档树与画布卡片引用，
/// 两边都要读它。若各写一份 `jsonDecode + ['text']`，迟早有一处忘了兜底而在
/// 脏数据上抛 —— 这里统一静默降级成空串（读一个属性不值得让调用方崩）。
String textOfProps(String? propsJson) {
  if (propsJson == null || propsJson.trim().isEmpty) return '';
  try {
    final Object? decoded = jsonDecode(propsJson);
    if (decoded is! Map) return '';
    final Object? text = decoded['text'];
    return text is String ? text : '';
  } on FormatException {
    return '';
  }
}
