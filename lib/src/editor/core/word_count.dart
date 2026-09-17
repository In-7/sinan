/// 字数统计（纯函数，无 Flutter 依赖 ⇒ 可脱离 widget 单测）。
///
/// ## 口径
/// **CJK 逐字 + 拉丁/数字按词**：
/// - CJK（统一表意 + 扩展 A + 兼容表意 + 日文假名）每个字符算 1；
/// - 连续的字母数字串算 1 个词（`foo_bar` 算 2 —— 下划线是分隔符）。
///
/// 全角标点（，。！）不在 CJK 区间内，因此不计入——与主流中文编辑器一致。
///
/// ## 为什么抽出来
/// 这两个正则与算法原先埋在 `note_editor_view_appflowy.dart` 的
/// `_NoteEditorViewAppFlowyState`（约 1200 行的 State）里。规则本身与 UI
/// 无关，却只能靠 widget test 间接验证；2026-09-17 抽到此处并补了单测。
library;

/// CJK 字符（含扩展 A 区 / 统一表意 / 兼容表意 / 日文假名）。
final RegExp _cjkChar = RegExp(
  r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3040-\u30ff]',
);

/// 拉丁字母与数字的连续串（一个串算一个词）。
final RegExp _latinWord = RegExp(r'[A-Za-z0-9]+');

/// 统计 [plainText] 的字数（口径见库注释）。
int countWords(String plainText) =>
    _cjkChar.allMatches(plainText).length +
    _latinWord.allMatches(plainText).length;
