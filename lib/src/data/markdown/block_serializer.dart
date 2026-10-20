/// 块树 → Markdown 的**单向序列化器**（纯 Dart：零 Flutter、零 SQL、零 IO）。
///
/// 定位：权威在 `blocks` 表（`docs/data_layer.md`），Markdown 只是**磁盘镜像**
/// （Obsidian 兼容 + "文件在我手里"）。单向：只写不读，绝不做双向合并——用户手改
/// 过的 .md 不会被回收，下次保存即以库为准覆写。
///
/// 输入 = `BlockStore.readNoteDocument` 解出的 v2 块树 `document` 节点
/// （`{'type':'page','children':[…]}`，每个节点的 `data` 里是 **delta ops 数组**
/// ——粗体/斜体/删除线/行内码/链接全在里面，故导出**不丢内联格式**）。
/// 笔记还没有块行（存量 Delta、从未编辑过）时 [document] 传 null，正文退化为
/// [plainFallback] 纯文本段（一旦编辑保存即升级为块树，之后导出即完整）。
library;

import 'dart:convert';

/// 引用块（`type='ref'`）的目标 → Markdown 链接的**解析结果**。
///
/// 序列化器不知道库长什么样（零 SQL），所以标题由宿主点查后注入；
/// 这里只描述"怎么写进 Markdown"。
class MdRefLink {
  const MdRefLink(this.label, {this.linked = true});

  /// [linked] 时 = **镜像文件名**（不带 `.md`，Obsidian 用 `[[文件名]]` 解析）；
  /// 否则 = 给读者看的纯文本（可带形态后缀，如「标题（画布）」）。
  final String label;

  /// 目标有没有镜像文件：`false`（画布 / 灵感）写纯文本——链过去只会是死链。
  final bool linked;
}

/// 引用解析器：`(ref_type, ref_id)` → [MdRefLink]；`null` = 目标已不存在。
typedef RefLinkResolver = MdRefLink? Function(String refType, String refId);

/// 一篇笔记 → 完整 Markdown 文本（YAML 头 + H1 + 块正文）。
///
/// YAML 头里的 `id` 是稳定标识：用户改文件名/标题也能对回笔记；`created` / `updated`
/// 供排序与阅读。标题为空时落「无标题」（与列表口径一致）。
///
/// [refLink] 解引用块（`type='ref'`）：解得出就写成 Obsidian 的 `[[目标]]`
/// （`ref_view='embed'` ⇒ `![[目标]]`），解不出落一行「引用已失效」——
/// **绝不静默丢块**。
String noteToMarkdown({
  required String noteId,
  required String title,
  required int createdAt,
  required int revisedAt,
  required Map<String, Object?>? document,
  String plainFallback = '',
  RefLinkResolver? refLink,
}) {
  final _MdWriter w = _MdWriter(refLink: refLink);
  w
    ..line('---')
    ..line('id: $noteId')
    ..line('created: ${_iso(createdAt)}')
    ..line('updated: ${_iso(revisedAt)}')
    ..line('---')
    ..line('');
  final String t = title.trim();
  w..line('# ${t.isEmpty ? '无标题' : _escapeInline(t)}')..line('');

  final List<Object?> children =
      document == null ? const <Object?>[] : _childrenOf(document);
  if (children.isEmpty) {
    final String plain = plainFallback.trim();
    if (plain.isNotEmpty) {
      // 存量 Delta：整篇纯文本成段（块级结构不可得，文本不丢）。
      w.line(plain);
    }
    return w.toString();
  }
  for (final Object? child in children) {
    if (child is Map<String, Object?>) w.block(child, 0);
  }
  return w.toString();
}

// ─────────────────────────── 块渲染 ───────────────────────────

class _MdWriter {
  _MdWriter({this.refLink});

  /// 引用块解析器（宿主注入；为 null 时引用块一律落「引用已失效」）。
  final RefLinkResolver? refLink;

  final StringBuffer _sb = StringBuffer();
  bool _bodyStarted = false;
  bool _lastWasListItem = false;

  void line(String s) => _sb.writeln(s);

  @override
  String toString() => _sb.toString();

  List<Object?> _kids(Map<String, Object?> node) => _childrenOf(node);

  /// 渲染一个块（含其子孙；子孙缩进一级，折叠块的正文住在 children 里）。
  void block(Map<String, Object?> node, int depth) {
    final String type = (node['type'] ?? 'paragraph').toString();
    final Map<String, Object?> data =
        node['data'] is Map<String, Object?>
            ? node['data']! as Map<String, Object?>
            : const <String, Object?>{};
    final String pad = '  ' * depth;
    final bool listish = switch (type) {
      'bulleted_list' || 'numbered_list' || 'todo_list' => true,
      _ => false,
    };
    // 块间空行：连续列表项之间**不留**（紧凑列表），其余都留（Markdown 语法要求）。
    if (_bodyStarted && !(listish && _lastWasListItem)) line('');
    _bodyStarted = true;
    _lastWasListItem = listish;

    switch (type) {
      case 'heading':
        final int level = data['level'] is int
            ? (data['level']! as int).clamp(1, 6)
            : 1;
        // 文本已由 _inlineOf 转义并加好标记 ⇒ 直接输出，别再转义。
        final String text = _inlineOf(data).trim();
        if (text.isNotEmpty) line('$pad${'#' * level} $text');

      case 'bulleted_list':
        line('$pad- ${_inlineOf(data)}');

      case 'numbered_list':
        // 一律 `1.`：CommonMark 渲染器自动编号，且增删项不用重排名次。
        line('${pad}1. ${_inlineOf(data)}');

      case 'todo_list':
        final bool checked = data['checked'] == true;
        line('$pad- [${checked ? 'x' : ' '}] ${_inlineOf(data)}');

      case 'quote':
        final String text = _inlineOf(data);
        if (text.trim().isNotEmpty) {
          for (final String l in text.split('\n')) {
            line(l.isEmpty ? '$pad>' : '$pad> $l');
          }
        }

      case 'code':
        final String lang = data['language'] is String
            ? (data['language']! as String).trim()
            : '';
        line('$pad```$lang');
        line(_plainOf(data));
        line('$pad```');

      case 'divider':
        line('$pad---');

      case 'image':
        final String url = data['url'] is String
            ? data['url']! as String
            : (data['src'] is String ? data['src']! as String : '');
        if (url.isNotEmpty) line('$pad![]($url)');

      case 'callout':
        // 提示块 → 引用块，emoji 冠首（appflowy 的 callout 把 emoji 放 data.emoji）。
        final String emoji = data['emoji'] is String
            ? (data['emoji']! as String).trim()
            : '';
        final String text = _inlineOf(data);
        final String head = emoji.isEmpty ? '>' : '> $emoji';
        if (text.trim().isNotEmpty) {
          for (final String l in text.split('\n')) {
            line(l.isEmpty ? '$pad$head' : '$pad$head $l');
          }
        } else if (emoji.isNotEmpty) {
          line('$pad$head');
        }

      case 'formula':
        final String latex = data['formula'] is String
            ? data['formula']! as String
            : '';
        if (latex.trim().isNotEmpty) line('$pad\$\$${latex.trim()}\$\$');

      case 'attachment':
        // 自定义附件块：meta 是 jsonEncode 的元数据串（name/path）。取不到就落一行
        // 回形针，**绝不静默丢块**。
        final Object? meta = data['attachment'];
        String? name;
        String? path;
        if (meta is String && meta.isNotEmpty) {
          try {
            final Object? decoded = jsonDecode(meta);
            if (decoded is Map) {
              final Object? n = decoded['name'];
              final Object? pth = decoded['path'];
              if (n is String) name = n;
              if (pth is String) path = pth;
            }
          } on Object {
            // 脏数据：走下面的占位分支。
          }
        }
        if (path != null && path.isNotEmpty) {
          line('$pad[${name ?? '附件'}]($path)');
        } else {
          line('$pad📎 ${name ?? '附件'}');
        }

      case 'ref':
        line('$pad${_refOf(data)}');

      default:
        // 未知块类型（含 sub_page 等）：有文本按段落导出，没文本只递归子孙——
        // 宁可少一种排版，不可丢内容。文本已由 _inlineOf 处理好，直接输出。
        final String text = _inlineOf(data);
        if (text.trim().isNotEmpty) line('$pad$text');
    }

  for (final Object? kid in _kids(node)) {
    if (kid is Map<String, Object?>) block(kid, depth + 1);
  }
}

  /// 引用块 → 一行 Markdown（三种落法，见 [MdRefLink]）。
  ///
  /// - 有镜像文件：`[[文件名]]`；`ref_view='embed'` ⇒ `![[文件名]]`
  ///   （Obsidian 的嵌入语法，正好对应编辑器里的"就地展开"）；
  /// - 目标是画布 / 灵感（没有 .md）：纯文本，**不造死链**；
  /// - 目标已删：`引用已失效（<id8>）`——与编辑器里那块「引用已失效」同口径。
  String _refOf(Map<String, Object?> data) {
    final String refType =
        data['ref_type'] is String ? data['ref_type']! as String : 'note';
    final String refId =
        data['ref_id'] is String ? data['ref_id']! as String : '';
    final MdRefLink? link = refLink?.call(refType, refId);
    if (link == null) {
      final String tail = refId.length >= 8 ? refId.substring(0, 8) : refId;
      return tail.isEmpty ? '引用已失效' : '引用已失效（$tail）';
    }
    if (!link.linked) return _escape(link.label, leading: true);
    // 空目标名会写出 `[[]]`（Obsidian 视作坏链）⇒ 兜到未命名。
    final String target = link.label.trim().isEmpty
        ? '未命名'
        : link.label.trim();
    // 目标名直接进 `[[…]]`：**不转义**（`[` `]` 是语法本身）。
    return data['ref_view'] == 'embed' ? '![[$target]]' : '[[$target]]';
  }
}

List<Object?> _childrenOf(Map<String, Object?> node) {
  final Object? c = node['children'];
  return c is List ? c : const <Object?>[];
}

// ─────────────────────────── Delta → 内联 Markdown ───────────────────────────

/// `data` → 带内联标记的文本。**优先 `delta`**（ops 数组，属性全在）；
/// 回退 `text`（纯字符串——画布卡片的块用这个键）。
///
/// 产出即**最终安全文本**（每段都已转义、标记已加）⇒ 块分支直接输出，
/// **不要再转义**（会把 `**` 标记本身转掉）。
String _inlineOf(Map<String, Object?> data) {
  final Object? delta = data['delta'];
  if (delta is List) {
    final StringBuffer sb = StringBuffer();
    bool leading = true; // 首个非空 op 处在块文本行首（段首防护只对它生效）
    for (final Object? op in delta) {
      if (op is! Map) continue;
      final Object? insert = op['insert'];
      if (insert is! String || insert.isEmpty) continue;
      final Object? attrs = op['attributes'];
      sb.write(
        _styled(
          insert,
          attrs is Map ? attrs : const <Object?, Object?>{},
          leading: leading,
        ),
      );
      leading = false;
    }
    return sb.toString();
  }
  final Object? text = data['text'];
  return text is String
      ? _styled(text, const <Object?, Object?>{}, leading: true)
      : '';
}

/// delta ops → 纯文本（代码块用：不要任何行内标记，也不转义）。
String _plainOf(Map<String, Object?> data) {
  final Object? delta = data['delta'];
  if (delta is List) {
    final StringBuffer sb = StringBuffer();
    for (final Object? op in delta) {
      if (op is! Map) continue;
      final Object? insert = op['insert'];
      if (insert is String) sb.write(insert);
    }
    final String s = sb.toString();
    return s.endsWith('\n') ? s.substring(0, s.length - 1) : s;
  }
  final Object? text = data['text'];
  return text is String ? text : '';
}

String _styled(String text, Map<Object?, Object?> attrs, {required bool leading}) {
  final Object? href = attrs['href'];
  if (href is String && href.isNotEmpty) {
    // 链接：文字侧转义后包 [ ]( )。其它标记叠在链接外（码优先，码内不加标记）。
    if (attrs['code'] == true) return _codeSpan(text);
    String s = '[${_escape(text, leading: leading)}]($href)';
    if (attrs['bold'] == true) s = '**$s**';
    if (attrs['italic'] == true) s = '*$s*';
    if (attrs['strikethrough'] == true) s = '~~$s~~';
    if (attrs['underline'] == true) s = '<u>$s</u>';
    return s;
  }
  // 行内码优先：码Span内不加其它标记（CommonMark 里码内无排版）。
  if (attrs['code'] == true) return _codeSpan(text);
  String s = _escape(text, leading: leading);
  if (attrs['bold'] == true) s = '**$s**';
  if (attrs['italic'] == true) s = '*$s*';
  if (attrs['strikethrough'] == true) s = '~~$s~~';
  if (attrs['underline'] == true) s = '<u>$s</u>';
  return s;
}

/// 行内码 Span：**内容不转义**（码内是字面量）。含反引号时按 CommonMark 约定
/// 用双反引号围栏 + 两侧空格。
String _codeSpan(String text) =>
    text.contains('`') ? '`` $text ``' : '`$text`';

// ─────────────────────────── 转义 ───────────────────────────

/// 行内转义。处处转义：`\ ` `` ` `` `*` `[` `]` `~`（任出现都破坏排版）；
/// `_` 与行首的 `# > - +` 只在**段首**转义（CommonMark 词内 `_` 不成强调，
/// 全转会是噪声；行首特殊符才会被误判成标题/引用/列表）。
String _escapeInline(String s) {
  final StringBuffer sb = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    final String ch = s[i];
    switch (ch) {
      case '\\':
      case '`':
      case '*':
      case '[':
      case ']':
      case '~':
        sb.write('\\$ch');
      case '_':
      case '#':
      case '>':
      case '-':
      case '+':
        sb.write(i == 0 ? '\\$ch' : ch);
      default:
        sb.write(ch);
    }
  }
  return sb.toString();
}

/// 段内转义 + 段首防护（仅 [leading] 段做行首防护）。
///
/// 处处转义：`\ ` `` ` `` `*` `[` `]` `~`（任出现都破坏排版）；`_` 与行首的
/// `# > - +` 只在**段首**转义（CommonMark 词内 `_` 不成强调，全转会是噪声；
/// 行首特殊符才会被误判成标题/引用/列表）。段首再防 `1. `（有序列表标记）。
String _escape(String s, {required bool leading}) {
  String out = _escapeInline(s);
  if (leading) out = out.replaceFirst(RegExp(r'^(\d+)\.'), r'$1\.');
  return out;
}

// ─────────────────────────── 小工具 ───────────────────────────

String _iso(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();
