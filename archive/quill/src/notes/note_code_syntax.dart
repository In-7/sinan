import 'package:flutter/gestures.dart' show GestureRecognizer;
import 'package:highlight/highlight.dart' as hl;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;

/// 代码块语法高亮（**纯渲染层**）：quill 的 textSpanBuilder 扩展点
/// 按文本段调用本函数——代码块行用 highlight 包解析后生成多色
/// TextSpan；普通文本行原样透传。**不改文档数据**，高亮随明暗切换。
///
/// 限制（有意的折衷，与多数逐行高亮器一致）：
/// - 跨行 token（块注释 /* */、多行字符串）按行独立解析会断色；
/// - 行内混用其他格式的代码行，非本段 token 不参与解析；
/// - 语言自动检测（highlight 的 autoDetection）对小行文本开销可忽略。
InlineSpan buildCodeAwareSpan(
  BuildContext context,
  quill.Node node,
  String text,
  TextStyle? style,
  GestureRecognizer? recognizer,
) {
  // 判定该文本段是否属于代码块行（leaf 的 parent 即所属 Line）。
  final Object? parent = node.parent;
  final bool inCodeBlock =
      parent is quill.Line &&
      parent.style.attributes.containsKey(quill.Attribute.codeBlock.key);

  if (!inCodeBlock) {
    // 普通行：原样透传（保留链接点击的 recognizer/cursor 行为）。
    return TextSpan(
      text: text,
      style: style,
      recognizer: recognizer,
      mouseCursor: recognizer != null ? SystemMouseCursors.click : null,
    );
  }

  final List<hl.Node>? nodes = _parseCached(text);
  if (nodes == null) {
    // 无 token / 解析异常：回退纯文本，不崩渲染。
    return TextSpan(text: text, style: style, recognizer: recognizer);
  }

  final Brightness brightness = Theme.of(context).brightness;
  final List<InlineSpan> children = <InlineSpan>[];
  _appendTokenSpans(nodes, brightness, children);
  return TextSpan(children: children, style: style, recognizer: recognizer);
}

/// **appflowy 块组件入口**：把一整块代码文本高亮成多色 span（纯渲染层）。
///
/// 与 [buildCodeAwareSpan] 只差"上游形态"：quill 按文本段调用，
/// appflowy 给的是整块（可能多行），这里按行切分后逐行解析——与 quill 侧
/// 同样的折衷（跨行 token 会断色）。两者**共用同一份解析缓存与配色表**，
/// 因此迁移前后 token 配色与明暗表现一致。
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
void _appendTokenSpans(
  List<hl.Node> nodes,
  Brightness brightness,
  List<InlineSpan> out,
) {
  for (final hl.Node n in nodes) {
    final List<hl.Node>? kids = n.children;
    if (kids != null && kids.isNotEmpty) {
      _appendTokenSpans(kids, brightness, out);
    } else if (n.value != null && n.value!.isNotEmpty) {
      out.add(
        TextSpan(text: n.value, style: _tokenStyle(n.className, brightness)),
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
  'dart', 'javascript', 'typescript', 'python', 'java', 'kotlin', 'json',
  'yaml', 'sql', 'cpp', 'c', 'go', 'rust', 'swift', 'cs', 'php', 'bash',
  'shell', 'html', 'css', 'xml', 'markdown', 'ini', 'properties', 'dockerfile',
];

/// 解析结果缓存（文本 → token 节点）。
///
/// 必要性：代码块按**文本段**调用解析，而一次击键只改变一行——
/// 不缓存的话 30 行的代码块每敲一个字符就要重跑 30×26 次语言解析
/// （白名单逐个试）。缓存后只有被修改那一段真正解析，其余命中缓存。
///
/// 纯函数结果的记忆化：输入相同则输出必相同，无失效风险。
/// 容量上限 + FIFO 淘汰，避免长文档累积占内存。
const int _parseCacheLimit = 512;
final Map<String, List<hl.Node>> _parseCache = <String, List<hl.Node>>{};

/// 取某段代码的 token 节点（命中缓存则零成本）；无结果返回 null。
List<hl.Node>? _parseCached(String text) {
  final List<hl.Node>? hit = _parseCache[text];
  if (hit != null) return hit;

  final hl.Result result;
  try {
    result = _detectAndParse(text);
  } catch (_) {
    // 解析异常：按无结果处理（回退纯文本），不缓存失败结果。
    return null;
  }
  final List<hl.Node>? nodes = result.nodes;
  if (nodes == null || nodes.isEmpty) return null;

  if (_parseCache.length >= _parseCacheLimit) {
    _parseCache.remove(_parseCache.keys.first);
  }
  _parseCache[text] = nodes;
  return nodes;
}

/// 语言自动检测（白名单 + 相关度择优）：解析每个候选语言取
/// relevance 最高者；全部 0 分（纯文本）回退第一个成功结果。
hl.Result _detectAndParse(String text) {
  hl.Result? best;
  for (final String language in _tryLanguages) {
    final hl.Result result;
    try {
      result = hl.highlight.parse(text, language: language);
    } catch (_) {
      continue;
    }
    if (best == null || (result.relevance ?? 0) > (best.relevance ?? 0)) {
      best = result;
    }
  }
  // 白名单全失败（理论上不会）：裸解析兜底，仍失败由调用方 catch。
  return best ?? hl.highlight.parse(text, language: 'plaintext');
}

/// token 类名 → 颜色（明暗两套，参考 Material/One Dark 的观感）。
/// hljs 的 className 可能是空格分隔的多类（如 "title function"），
/// 用 contains 匹配主要类别。
TextStyle? _tokenStyle(String? className, Brightness brightness) {
  if (className == null || className.isEmpty) return null;
  final bool dark = brightness == Brightness.dark;
  Color pick(int light, int darkC) => Color(dark ? darkC : light);

  if (className.contains('keyword')) {
    return TextStyle(
      color: pick(0xFF7C4DFF, 0xFFC792EA),
      fontWeight: FontWeight.w600,
    );
  }
  if (className.contains('string') || className.contains('regexp')) {
    return TextStyle(color: pick(0xFF2E7D32, 0xFFC3E88D));
  }
  if (className.contains('number') || className.contains('literal')) {
    return TextStyle(color: pick(0xFFF57C00, 0xFFF78C6C));
  }
  if (className.contains('comment')) {
    return TextStyle(
      color: pick(0xFF8A9199, 0xFF5C6370),
      fontStyle: FontStyle.italic,
    );
  }
  if (className.contains('title')) {
    return TextStyle(color: pick(0xFF0288D1, 0xFF82AAFF));
  }
  if (className.contains('attr') || className.contains('variable')) {
    return TextStyle(color: pick(0xFFD81B60, 0xFFFF5370));
  }
  if (className.contains('built_in') || className.contains('type')) {
    return TextStyle(color: pick(0xFF0277BD, 0xFF89DDFF));
  }
  if (className.contains('meta')) {
    return TextStyle(color: pick(0xFF616161, 0xFF89DDFF));
  }
  return null;
}
