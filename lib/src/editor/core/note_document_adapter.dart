import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/foundation.dart';

import '../blocks/attachment_block_component.dart';
import '../blocks/code_block_component.dart';
import '../blocks/formula_block_component.dart';

/// 内容格式适配：**我们的存储格式（块树 JSON）** ⇄ appflowy [Document]。
///
/// ## 存储格式（v2：块树 + 块 id）
/// ```json
/// {
///   "v": 2,
///   "format": "blocks",
///   "document": {
///     "id": "r00t01", "type": "page",
///     "children": [
///       {"id": "a1b2c3", "type": "paragraph",
///        "data": {"delta": [{"insert": "你好"}]}},
///       {"id": "x9y8z7", "type": "heading",
///        "data": {"level": 1, "delta": [{"insert": "标题"}]}}
///     ]
///   }
/// }
/// ```
/// 结构与 appflowy 原生 `Document.toJson()` **完全一致**（`type` / `data` /
/// `children`），只额外多写一个字段：**每个节点的 `id`**。
///
/// ## 为什么必须自己序列化 id（不能直接 `jsonEncode(document.toJson())`）
/// appflowy 的 `Node.toJson()` 只写 `type`/`data`/`children`，**不写 id**；
/// `Node.fromJson` 也不读 id（节点 id 由 `nanoid(6)` 每次重新生成），
/// `Node.copyWith` 更是显式 `id: nanoid(6)`。照搬它的序列化 = 每次加载所有
/// 块都是全新 id——**块身份在重启后归零**，AI 增量索引、块级引用（「跳到
/// 引用来源那一段」）、按块增量重嵌入全部失去锚点。故本适配器自己遍历节点
/// 树，把 id 写进去、读回来；因为它的 `fromJson` 会忽略未知字段，产出仍是
/// **合法的 appflowy JSON**（超集，不是另立格式）。
///
/// ## 落库格式：**已是 v2 块树**
/// 编辑器只剩 appflowy 一个（quill 视图 2026-09-10 退役归档，见
/// `docs/editor_migration_spike.md`），所以保存一律走本适配器的**写出方向**
/// （块树）。存量 Delta 笔记在读入时被转换，**一旦编辑保存即改写成块树、
/// 不可逆**（只打开不编辑不会动它）。
///
/// **不能提前切**：落库格式由**当前编辑器**决定——quill 只会产出 Delta，
/// 写不出块树；切换点只能是"编辑器替换完成的那一刻"。（读入侧的保真度已
/// 收口，见下方「读入保真度」——那是"能切"的前提，不是"提前切"的理由。）
///
/// ## 读取兼容（三种历史格式都能打开，写出统一为 v2 块树）
/// - **v2 块树**（当前写出格式，含块 id）；
/// - **appflowy 原生** `{"document":{...}}`（无 id → 现场补发，不崩）；
/// - **存量 quill Delta** `{"ops":[...]}`（首次编辑时自动升级为块树）。
///
/// ## 为什么不用 appflowy 自带的 `quillDeltaEncoder`
/// 它的输入解析 `Delta.fromJson` 只处理 `insert` 为**字符串**的操作，
/// 嵌入对象（`{"insert":{"image":..}}`）会被**静默丢弃**——直接用会
/// 悄悄丢掉笔记里的图片/附件/公式。故自写双向转换，完整覆盖：
/// 文本、行内标记、块级样式、以及全部自定义嵌入。
///
/// ## 读入保真度（**仅指存量 Delta**；v2 块树自身无损往返）
/// 各项均已覆盖（2026-09-10 收口，无遗留有损项）：
/// - 文本与行内标记：bold / italic / underline / strike / code / link /
///   **color / background**（颜色值两边同为 `#RRGGBB` 或 `#AARRGGBB`——
///   实测 appflowy 的 8 位 hex 即 AARRGGBB，故 1:1 透传）；
/// - 块级样式：标题 / 三种列表 / 待办 / 引用 / **align**（同名同值透传；
///   quill 独有的 `justify` 也原样保留——官方 align mixin 只认 left/center/
///   right，渲染回退左对齐，但**不丢数据**）/ **indent**（转成嵌套 children，
///   缩进跳级时挂到可用的最深父节点）；
/// - `code-block` → 连续多行合并为一个 `code` 块（数据形态实测自 quill：
///   块级属性挂在**换行段**上；Delta 侧无语言元数据，往返无信息可丢）；
/// - 嵌入：图片 / 分隔线（官方块）+ 公式 / 附件（自定义块，见 `blocks/`，
///   注册表见 `custom_block_components.dart`）。
abstract final class NoteDocumentAdapter {
  /// 存储格式版本：1 = quill Delta（存量），2 = 块树（含块 id）。
  static const int _kSchemaVersion = 2;

  /// `format` 字段的取值：块树格式。公开给数据层做格式识别
  /// （`note_content.dart` 的 `NoteContentFormat.blocks`）。
  static const String blocksFormat = 'blocks';
  static const String _kVersionKey = 'v';
  static const String _kFormatKey = 'format';
  static const String _kDocumentKey = 'document';
  static const String _kIdKey = 'id';
  static const String _kChildrenKey = 'children';
  static const String _kTypeKey = 'type';
  static const String _kDataKey = 'data';

  /// 存储内容 → Document（自动识别格式；无法解析时退回空文档不崩）。
  static Document documentFromStoredContent(String? content) {
    if (content == null || content.trim().isEmpty) {
      return Document.blank(withInitialText: true);
    }
    try {
      final Object? decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        final Object? document = decoded[_kDocumentKey];
        // ① 我们的块树格式（v2，块节点自带 id）。
        if (decoded[_kFormatKey] == blocksFormat && document is Map) {
          return _documentFromBlockJson(document.cast<String, dynamic>());
        }
        // ② appflowy 原生 Document JSON（无 id → 读取时现场补发）。
        if (document is Map) return Document.fromJson(decoded);
        // ③ 存量格式（quill Delta JSON）。
        final Object? ops = decoded['ops'];
        if (ops is List) return documentFromQuillOps(ops);
        // 兼容：裸根节点 JSON（无 document 包裹）。
        if (decoded[_kTypeKey] != null) {
          return _documentFromBlockJson(decoded);
        }
      }
      if (decoded is List) return documentFromQuillOps(decoded);
    } on Object catch (error) {
      // 解析失败不抛：内容仍在数据库里，界面以空文档兜底可继续编辑。
      debugPrint('NoteDocumentAdapter: 内容解析失败，退回空文档：$error');
    }
    return Document.blank(withInitialText: true);
  }

  /// 存储内容 → 纯文本（列表预览 / 字数 / 搜索 / 将来的向量化输入）。
  ///
  /// 三种格式通吃，且与 [documentFromStoredContent] **同一份读取实现**——
  /// 于是"取纯文本"不再需要编辑器库（这是「数据层解耦」的一半：
  /// 旧实现走 `quill.Document.fromJson(...).toPlainText()`）。
  /// 也做成门面，让数据层只依赖本适配器、不直接依赖 appflowy 类型。
  /// 文本组织成**每个块一行**（而不是首尾相接）：块内的换行会被去掉，
  /// 没有文字的块（图片/分隔线）不占行。这样得到的是"人类可读的正文"，
  /// 适合预览 / 搜索 / 将来的向量化切块。
  static String plainTextOfStoredContent(String? content) =>
      plainTextFromDocument(documentFromStoredContent(content));

  /// 内存 [Document] → 纯文本（**不经 JSON 往返**）。
  ///
  /// 与 [plainTextOfStoredContent] 同一份抽取实现，但输入是已解析的
  /// Document——保存落盘时文档刚在内存里，再走一遍 encode→decode 纯属
  /// 浪费（大文档一次完整 JSON 序列化往返就是几毫秒，全在 UI isolate）。
  /// 文本组织成**每个块一行**（而不是首尾相接）：块内的换行会被去掉，
  /// 没有文字的块（图片/分隔线）不占行。
  static String plainTextFromDocument(Document document) {
    final List<String> lines = <String>[];
    // **递归整棵树**（2026-09-14）：折叠块这类**容器块**的正文住在 children
    // 里，只扫顶层会把它们整段漏掉——字数统计、AI 增量索引、全文检索都吃这个
    // 方法，漏了就是"搜不到、算少"。顺序仍是文档顺序（父在前、子随其后）。
    //
    // 折叠态**不影响**这里：`collapsed` 只是视图状态，文字仍在文档里
    // （用户展开了就能看到），所以一律计入。
    void walk(Iterable<Node> nodes) {
      for (final Node node in nodes) {
        final String text = (node.delta?.toPlainText() ?? '')
            .replaceAll(RegExp(r'\n+$'), '');
        if (text.isNotEmpty) lines.add(text);
        walk(node.children);
      }
    }

    walk(document.root.children);
    return lines.join('\n');
  }

  /// Document → 待落库 JSON **Map**（v2 块树，块节点带 id；见类注释）。
  ///
  /// 与 [storedContentFromDocument] 的区别：不做字符串编码。落盘前若想把
  /// `jsonEncode` 挪去后台 isolate（大文档编码几毫秒，都在 UI isolate 上），
  /// 就先在编辑器侧取这个 Map（纯 JSON 值，可跨 isolate 发送），再在
  /// isolate 里 encode。
  static Map<String, Object> documentToJsonMap(Document document) =>
      <String, Object>{
        _kVersionKey: _kSchemaVersion,
        _kFormatKey: blocksFormat,
        _kDocumentKey: _nodeToJson(document.root),
      };

  /// Document → 待落库字符串（**v2 块树 JSON，块节点带 id**；见类注释）。
  static String storedContentFromDocument(Document document) =>
      jsonEncode(documentToJsonMap(document));

  /// 节点 → JSON：字段照抄 appflowy（`type` / `data` / `children`）以免
  /// 自创术语，额外写入 `id`；子节点自己递归（`toJson` 不会带上 id）。
  static Map<String, Object> _nodeToJson(Node node) {
    final Map<String, Object> json = node.toJson();
    json[_kIdKey] = node.id;
    if (node.children.isNotEmpty) {
      json[_kChildrenKey] =
          node.children.map(_nodeToJson).toList(growable: false);
    }
    return json;
  }

  /// JSON → 节点：恢复块 id（带去重保护）。id 缺失或不合法时交给 [Node]
  /// 构造器现场补发——库内容仍能正常打开，只是该块失去锚点。
  static Node _nodeFromJson(Map<String, dynamic> json, Set<String> seenIds) {
    final Object? rawId = json[_kIdKey];
    final String? id = rawId is String && rawId.isNotEmpty && seenIds.add(rawId)
        ? rawId
        : null;
    final Object? rawChildren = json[_kChildrenKey];
    return Node(
      id: id,
      type: json[_kTypeKey] as String? ?? 'paragraph',
      attributes: Attributes.from(json[_kDataKey] as Map? ?? const {}),
      children: rawChildren is List
          ? rawChildren
                .whereType<Map>()
                .map(
                  (Map<dynamic, dynamic> raw) =>
                      _nodeFromJson(raw.cast<String, dynamic>(), seenIds),
                )
                .toList(growable: false)
          : const <Node>[],
    );
  }

  /// 块树 JSON → Document。
  ///
  /// **根节点必须是 `page`**：appflowy 的 `Document.blank()` 就是
  /// `Node(type: 'page')`，页面由 `PageBlockComponentBuilder`（只认
  /// `PageBlockKeys.type`）渲染——根写成 `document` 会让编辑器**整页空白**
  /// （spike 验证实测）。历史数据、裸根 JSON 一律在此归一化。
  static Document _documentFromBlockJson(Map<String, dynamic> json) {
    final Node parsed = _nodeFromJson(json, <String>{});
    if (parsed.children.isEmpty) return Document.blank(withInitialText: true);
    if (parsed.type == PageBlockKeys.type) return Document(root: parsed);
    return Document(
      root: Node(
        id: parsed.id,
        type: PageBlockKeys.type,
        attributes: parsed.attributes,
        children: parsed.children,
      ),
    );
  }

  // ────────────── 存量兼容：quill Delta → Document（只读） ──────────────
  //
  // 落库格式已切为 v2 块树，Delta **只作为历史数据的读入路径**保留
  // （首次编辑后即升级为块树）。原「Document → Delta」写出方向已随格式
  // 切换移除——需要时从 git 历史取回。

  /// quill Delta 操作列表 → appflowy [Document]。
  ///
  /// 逐 op 处理：文本片段按 `\n` 断行，换行所在 op 的属性即该**行**的
  /// 块级属性（quill 语义：属性作用于整段插入，含末尾换行）。
  @visibleForTesting
  static Document documentFromQuillOps(List<dynamic> ops) {
    final List<Node> roots = <Node>[];
    // 缩进栈（quill 的行级 `indent` → appflowy 的**嵌套 children**）：
    // stack[i] = 当前第 i 层的节点，可作为第 i+1 层的父节点。
    final List<Node> stack = <Node>[];

    /// 落一个块：按 quill 的 indent 值决定挂到顶层还是挂在上一层的
    /// children 上（appflowy 的缩进就是嵌套——官方 indentCommand 即把节点
    /// 挪进前一个兄弟节点的 children）。
    void addNode(Node node, int indent) {
      if (indent <= 0 || stack.isEmpty) {
        roots.add(node);
        stack
          ..clear()
          ..add(node);
        return;
      }
      // 缩进跳级（如 0 → 2）时挂到"可用的最深父节点"上，**不丢内容**。
      final int parentIndex = indent - 1 < stack.length
          ? indent - 1
          : stack.length - 1;
      stack[parentIndex].insert(node);
      stack
        ..removeRange(parentIndex + 1, stack.length)
        ..add(node);
    }

    Delta lineDelta = Delta();
    Map<String, dynamic> lineAttributes = <String, dynamic>{};
    // 刚落下独占一行的嵌入节点，等待其后的换行「收尾」——quill 里
    // 嵌入字符后必跟一个换行，若把它当空行处理会多出一个空段落。
    bool embedLineOpen = false;
    // code-block 在 quill 里是**行级属性**（连续多行同属一个代码块），
    // 这里先攒住，遇到非代码行（或文档结束）再合成**一个** code 块。
    final List<String> codeLines = <String>[];
    int codeIndent = 0;

    void flushCodeBlock() {
      if (codeLines.isEmpty) return;
      addNode(
        codeBlockNode(delta: Delta()..insert(codeLines.join('\n'))),
        codeIndent,
      );
      codeLines.clear();
      codeIndent = 0;
    }

    void flushLine() {
      if (lineAttributes['code-block'] == true) {
        // 只攒文本：代码块内的行内标记不参与渲染（与 highlight 侧同样的
        // 折衷），且 Delta 里本来就没有语言元数据可丢。
        codeLines.add(lineDelta.toPlainText());
        codeIndent = _indentOf(lineAttributes);
      } else {
        flushCodeBlock();
        addNode(_buildNode(lineDelta, lineAttributes), _indentOf(lineAttributes));
      }
      lineDelta = Delta();
      lineAttributes = <String, dynamic>{};
    }

    for (final Object? rawOp in ops) {
      if (rawOp is! Map) continue;
      final Object? insert = rawOp['insert'];
      final Map<String, dynamic>? attributes =
          (rawOp['attributes'] as Map?)?.cast<String, dynamic>();

      // ① 嵌入对象（图片 / 分隔线 / 公式 / 附件）。
      if (insert is Map) {
        final Node? embed = _buildEmbedNode(insert.cast<String, dynamic>());
        if (embed != null) {
          // 嵌入独占一行：先落当前行，再落嵌入。
          if (lineDelta.isNotEmpty) flushLine();
          addNode(embed, _indentOf(attributes ?? <String, dynamic>{}));
          embedLineOpen = true;
        }
        continue;
      }

      if (insert is! String || insert.isEmpty) continue;

      // ② 文本：按换行切分，最后一段留给下一行。
      final List<String> segments = insert.split('\n');
      for (int i = 0; i < segments.length; i++) {
        final String segment = segments[i];
        if (segment.isNotEmpty) {
          // 嵌入后接了文本 → 该文本另起一行（本项目嵌入均为块级）。
          embedLineOpen = false;
          lineDelta.insert(segment, attributes: _inlineMarks(attributes));
        }
        if (i < segments.length - 1) {
          // 该换行属于刚落的嵌入行，收尾即可，不产生新行。
          if (embedLineOpen) {
            embedLineOpen = false;
            continue;
          }
          // 该 op 携带换行 → 其属性即本行的块级属性。
          lineAttributes = attributes ?? <String, dynamic>{};
          flushLine();
        }
      }
    }

    // 尾部残留（quill 文档末尾总有换行，正常不会走到）。
    if (lineDelta.isNotEmpty || roots.isEmpty) flushLine();
    // 文档以代码块结尾时内容还在缓冲里，需显式落块。
    flushCodeBlock();

    // 根节点是 `page`（**不是 `document`**）：appflowy 的页面类由
    // PageBlockComponentBuilder 渲染，根类型不对会整页空白。
    return Document(root: pageNode(children: roots));
  }

  /// 行内标记映射（quill 属性名 → appflowy 富文本键）。
  static Map<String, dynamic> _inlineMarks(Map<String, dynamic>? attributes) {
    if (attributes == null || attributes.isEmpty) {
      return <String, dynamic>{};
    }
    final Map<String, dynamic> marks = <String, dynamic>{};
    void copy(String from, String to, [Object? value]) {
      if (attributes.containsKey(from)) {
        marks[to] = value ?? attributes[from];
      }
    }

    copy('bold', AppFlowyRichTextKeys.bold, true);
    copy('italic', AppFlowyRichTextKeys.italic, true);
    copy('underline', AppFlowyRichTextKeys.underline, true);
    copy('strike', AppFlowyRichTextKeys.strikethrough, true);
    copy('code', AppFlowyRichTextKeys.code, true);
    copy('link', AppFlowyRichTextKeys.href);
    // 字体颜色 / 背景高亮：hex 串**原样透传**——两边格式相同
    // （`#RRGGBB` 或 `#AARRGGBB`；实测 appflowy 的 8 位 hex 即 AARRGGBB，
    // 与工具栏 _toHex 的写法一致）。
    copy('color', AppFlowyRichTextKeys.textColor);
    copy('background', AppFlowyRichTextKeys.backgroundColor);
    return marks;
  }

  /// quill 的行级 `indent`（int ≥ 1；缺省/0 = 顶层）→ 嵌套层级。
  static int _indentOf(Map<String, dynamic> attributes) {
    final Object? indent = attributes['indent'];
    return indent is int && indent > 0 ? indent : 0;
  }

  /// 按块级属性构造行节点（含对齐等与块类型无关的通用属性）。
  static Node _buildNode(Delta delta, Map<String, dynamic> attributes) {
    final Node node = _buildBaseNode(delta, attributes);

    // 对齐：quill 与 appflowy **同名同值**（`align`：left/center/right），
    // 原样透传即可。`justify` 是 quill 独有（官方 align mixin 只认三种），
    // 也**原样保留**以免丢数据——渲染回退左对齐，将来官方支持即自动生效。
    final Object? align = attributes['align'];
    if (align is String && align.isNotEmpty) {
      node.updateAttributes(<String, dynamic>{blockComponentAlign: align});
    }
    return node;
  }

  /// 与块类型无关地构造基础节点（不含通用属性）。
  static Node _buildBaseNode(Delta delta, Map<String, dynamic> attributes) {
    // 标题：quill `header` 值为 int 1~6（本项目工具栏产出 1~3）。
    final Object? header = attributes['header'];
    if (header is int && header > 0) {
      return headingNode(level: header.clamp(1, 6), delta: delta);
    }

    final Object? list = attributes['list'];
    if (list is String) {
      switch (list) {
        case 'bullet':
          return bulletedListNode(delta: delta);
        case 'ordered':
          return numberedListNode(delta: delta);
        case 'checked':
          return todoListNode(checked: true, delta: delta);
        case 'unchecked':
          return todoListNode(checked: false, delta: delta);
      }
    }

    if (attributes.containsKey('blockquote')) {
      return quoteNode(delta: delta);
    }

    // 注意：`code-block` **不在这里**处理——它要把连续多行合并成一个块，
    // 已在 flushLine 里单独攒批（见 flushCodeBlock）。
    return paragraphNode(delta: delta);
  }

  /// 嵌入对象 → 块节点（对齐 sinan 既有的四类嵌入）。
  static Node? _buildEmbedNode(Map<String, dynamic> data) {
    if (data['image'] is String) {
      return imageNode(url: data['image'] as String);
    }
    // 分隔线：quill 侧为 BlockEmbed.hr（值可为空字符串）。
    if (data.containsKey('hr')) {
      return dividerNode();
    }
    // 公式：自定义节点（渲染组件见 blocks/formula_block_component.dart）。
    if (data['formula'] is String) {
      return formulaBlockNode(latex: data['formula'] as String);
    }
    // 附件：自定义节点（meta 为 jsonEncode 的元数据串）。
    if (data['attachment'] is String) {
      return attachmentBlockNode(metaJson: data['attachment'] as String);
    }
    debugPrint('NoteDocumentAdapter: 未知嵌入类型，已跳过：${data.keys}');
    return null;
  }
}
