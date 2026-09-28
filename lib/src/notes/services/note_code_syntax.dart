import 'package:highlight/highlight.dart' as hl;
import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import 'lru_cache.dart';

/// 代码块语法高亮（**纯渲染层**）：把一整块代码文本转成多色 span。
/// **不改文档数据**，高亮随明暗切换。
///
/// 限制（有意的折衷，与多数逐行高亮器一致）：
/// - 跨行 token（块注释 /* */、多行字符串）按行独立解析会断色；
/// - 语言自动检测（highlight 的 autoDetection）对小行文本开销可忽略。
///
/// 历史：这里原有两个入口——[buildCodeAwareSpan] 供 quill 的 textSpanBuilder
/// 按文本段调用，[buildHighlightedCodeSpan] 供 appflowy 块组件按整块调用，
/// 两者共用下面的解析缓存与配色表。quill 视图退役后逐段入口随之归档
/// （`archive/quill/src/notes/note_code_syntax.dart` 保留了含它的整份原件）。

/// **appflowy 块组件入口**：把一整块代码文本高亮成多色 span（纯渲染层）。
///
/// 按行切分后逐行解析——跨行 token 会断色（与归档的 quill 侧同一折衷）。
TextSpan buildHighlightedCodeSpan(
  BuildContext context,
  String text,
  TextStyle? baseStyle,
) {
  final Brightness brightness = Theme.of(context).brightness;
  final List<InlineSpan> children = <InlineSpan>[];
  final List<String> lines = text.split('\n');
  for (int i = 0; i < lines.length; i++) {
    if (i > 0) children.add(const TextSpan(text: '\n'));
    final String line = lines[i];
    if (line.isEmpty) continue;
    final List<hl.Node>? nodes = _parseCached(line);
    if (nodes == null) {
      // 无 token / 解析异常：该行回退纯文本，不崩渲染。
      children.add(TextSpan(text: line));
      continue;
    }
    _appendTokenSpans(nodes, brightness, children);
  }
  return TextSpan(children: children, style: baseStyle);
}

/// token 节点 → 彩色 span（quill 与 appflowy 两条路径共用）。
///
/// ⚠️ highlight 的解析树里，className 挂在**分支节点**上、叶子节点只有
/// value（className=null）——如 `keyword → (child) "import"`。因此递归时
/// 必须把父级的 className 传下去，否则叶子永远拿不到类别、全部无色
/// （2026-09-16 修复的"代码块从不高亮"就是这个原因）。
void _appendTokenSpans(
  List<hl.Node> nodes,
  Brightness brightness,
  List<InlineSpan> out, [
  String? inheritedClass,
]) {
  for (final hl.Node n in nodes) {
    final String? className = n.className ?? inheritedClass;
    final List<hl.Node>? kids = n.children;
    if (kids != null && kids.isNotEmpty) {
      _appendTokenSpans(kids, brightness, out, className);
    } else if (n.value != null && n.value!.isNotEmpty) {
      out.add(
        TextSpan(text: n.value, style: _tokenStyle(className, brightness)),
      );
    }
  }
}

/// 语言白名单：常见的成熟语言定义（**刻意不用 autoDetection**——
/// 它会遍历全部 190+ 语言并逐个编译，其中冷门语言的 keywords 定义
/// 含 "=" 与空段，highlight 包内部对编译异常只做 `print(err)`——
/// 每次重启后首次渲染代码块就会往控制台打两条 FormatException）。
/// 白名单里的定义成熟无噪音，且只试十几个语言，比全量探测更快。
const List<String> _tryLanguages = <String>[
  'dart',
  'javascript',
  'typescript',
  'python',
  'java',
  'kotlin',
  'json',
  'yaml',
  'sql',
  'cpp',
  'c',
  'go',
  'rust',
  'swift',
  'cs',
  'php',
  'bash',
  'shell',
  'html',
  'css',
  'xml',
  'markdown',
  'ini',
  'properties',
  'dockerfile',
];

/// 解析结果缓存（文本 → token 节点）。
///
/// 必要性：代码块按**文本段**调用解析，而一次击键只改变一行——
/// 不缓存的话 30 行的代码块每敲一个字符就要重跑 30×26 次语言解析
/// （白名单逐个试）。缓存后只有被修改那一段真正解析，其余命中缓存。
///
/// 解析结果的记忆化（文本 → token 节点）
///
/// 必要性：代码块按**文本段**调用解析，而一次击键只改变一行——不缓存的话
/// 30 行的代码块每敲一个字符就要重跑 30×26 次语言解析（白名单逐个试）。
/// 纯函数结果的记忆化：输入相同则输出必相同，无失效风险。
///
/// ## 三件事（2026-09-17）
/// - **LRU** 淘汰（原为 FIFO）：交替编辑两段文本时，FIFO 会踢掉"仍在用但插入
///   较早"的热条目，下一帧又要重跑 26 种语言；
/// - **否定缓存**：无 token / 解析异常也记（哨兵空列表），否则纯文本段（一行
///   `---`）每帧都要重试 26 种语言；
/// - **[parse] 可注入**：于是"同一段文本有没有被重复解析"在测试里可直接断言，
///   而不必靠推理。
class CodeTokenCache {
  CodeTokenCache({required this.parse, this.maxSize = 512})
    : _entries = LruCache<String, List<hl.Node>>(maxSize: maxSize);

  /// 真正的解析（生产上是 [_detectAndParse]；测试注入计数替身）。
  final List<hl.Node>? Function(String text) parse;

  final int maxSize;
  final LruCache<String, List<hl.Node>> _entries;

  /// "已试过、但没有 token" 的哨兵。
  ///
  /// 用空列表而不是 `null`：[LruCache] 用 `null` 表示**未命中**，无法表达
  /// "缓存了'没有结果'"。
  static const List<hl.Node> _noTokens = <hl.Node>[];

  @visibleForTesting
  int get length => _entries.length;

  /// 命中或解析；无 token / 解析失败返回 `null`（并**记住**这次结果）。
  List<hl.Node>? of(String text) {
    final List<hl.Node>? hit = _entries[text];
    if (hit != null) return hit.isEmpty ? null : hit;

    List<hl.Node> nodes;
    try {
      nodes = parse(text) ?? _noTokens;
    } on Object catch (_) {
      // 解析是纯函数（同输入必同结果），失败同样可以安全记忆——记下来就不会
      // 每次渲染都再试一轮 26 种语言。
      nodes = _noTokens;
    }
    _entries.put(text, nodes);
    return nodes.isEmpty ? null : nodes;
  }
}

/// 全局记忆化实例（白名单检测 + LRU 512 条）。
final CodeTokenCache _parseCache = CodeTokenCache(
  // 只关心 token 节点；`Result` 的其它字段（language/relevance）这里用不上。
  parse: (String text) => _detectAndParse(text).nodes,
);

/// 取某段代码的 token 节点（命中缓存则零成本）；无结果返回 null。
List<hl.Node>? _parseCached(String text) => _parseCache.of(text);

/// 语言自动检测（白名单 + 相关度择优）：解析每个候选语言取
/// relevance 最高者；全部 0 分（纯文本）回退第一个成功结果。
hl.Result _detectAndParse(String text) {
  hl.Result? best;
  for (final String language in _tryLanguages) {
    final hl.Result result;
    try {
      result = hl.highlight.parse(text, language: language);
    } on Object catch (_) {
      continue;
    }
    if (best == null || (result.relevance ?? 0) > (best.relevance ?? 0)) {
      best = result;
    }
  }
  // 白名单全失败（理论上不会）：裸解析兜底，仍失败由调用方 catch。
  return best ?? hl.highlight.parse(text, language: 'plaintext');
}

/// token 类名 → 颜色（明暗两套）。**色表在 [AppTheme.syntaxColors]**——
/// 明度全部按 APCA 定过（`test/theme/apca_audit_test.dart` 体检表与它同源，
/// 这里不再自带一份，避免"两处各说一套"）。
/// hljs 的 className 可能是空格分隔的多类（如 "title function"），
/// 用 contains 匹配主要类别。
TextStyle? _tokenStyle(String? className, Brightness brightness) {
  if (className == null || className.isEmpty) return null;
  final Map<String, Color> colors = AppTheme.syntaxColors(brightness);

  if (className.contains('keyword')) {
    return TextStyle(color: colors['keyword'], fontWeight: FontWeight.w600);
  }
  if (className.contains('string') || className.contains('regexp')) {
    return TextStyle(color: colors['string']);
  }
  if (className.contains('number') || className.contains('literal')) {
    return TextStyle(color: colors['number']);
  }
  if (className.contains('comment')) {
    return TextStyle(color: colors['comment'], fontStyle: FontStyle.italic);
  }
  if (className.contains('title')) {
    return TextStyle(color: colors['title']);
  }
  if (className.contains('attr') || className.contains('variable')) {
    return TextStyle(color: colors['attr']);
  }
  if (className.contains('built_in') || className.contains('type')) {
    return TextStyle(color: colors['built_in']);
  }
  if (className.contains('meta')) {
    return TextStyle(color: colors['meta']);
  }
  return null;
}
