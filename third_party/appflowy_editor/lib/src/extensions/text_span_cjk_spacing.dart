/// 中文显示层排版 —— **中西文自动间距 + 连续标点互挤**（sinan 补丁 20/21
/// 共用的核心纯函数）。
///
/// 两条规则都只改**字形步进**（尾随 `letterSpacing`），不动任何文本内容：
///
/// ## 规则一：中西文自动间距（补丁 20）
/// 在汉字与拉丁字母/数字**直接相邻**的边界处，给前一个字符加尾随间隙
/// （[kCjkLatinGapEm] em），渲染出中西文之间的留白（CLREQ / pangu 方向，
/// CSS `text-autospace` 的语义同款）。
///
/// ## 规则二：连续标点互挤（补丁 21，jiya「行内可判」子集）
/// 全角标点自带半宽空白，两个标点相邻时空隙成倍出现（`。」`、`』，`、
/// `！？`）。按 `text-spacing-trim` 的**减法规则**（CSS Text 4 / Han.css jiya
/// 同源）：对相邻的标点对删去之间的半宽空——即给前一个标点加**负**尾随
/// 字距（`-`[kPunctSqueezeEm] em）。只做「行内可判」的部分：
/// 连续开标点、连续闭标点、相邻句逗-引括（含闭-开、句终-闭、中点-开等
/// 任意**两个可挤标点**相邻）。行首/行尾的收紧需要折行信息，不在此列
/// （编辑器实时重排代价过高，见 `docs/editor_migration_spike.md`）。
///
/// ## 四条硬性质
/// 1. **不改变任何文本内容**：`toPlainText()` 逐字节不变 ⇒ 光标/选区/IME
///    的字符索引映射不漂移、复制/落盘不被污染。这是"用尾随 letterSpacing
///    而不是插入空格字符"的根本原因——插字符会让编辑器的位置映射全错。
/// 2. **已有空白不叠加**：只处理"直接相邻"，"使用 API"（中间有空格）不动。
/// 3. **调整只挂在边界前那一个字符上**：`letterSpacing` 作用于 span 内
///    **每个**字形，所以带调整的字符必须独占一个单字 span；其余字符按
///    原样成段。段内字距不被撑开。两条规则在同一边界上**互斥**
///    （间距要拉丁侧，互挤要两侧皆标点），单字符至多一个尾随调整。
/// 4. **确定性**：同样的 span 树永远得到同样的结果——块高预测器
///    （`BlockHeightPredictor._heightOfSpan`）复用本函数，预测与渲染
///    才能逐像素对齐。
///
/// ## 整像素
/// 调整量取 `(fontSize × em).roundToDouble()`（负向同规）——逻辑像素取整后
/// 其后的汉字仍落在整数 x 上（汉字步进 = 整数字号），符合项目 Impeller
/// 锐度纪律（半像素取样会让笔画发灰）。
///
/// ## 已知边界
/// "text 与 children 并存"的 span（本编辑器管线里不产生）只递归 children、
/// 自带文字不动；跨这种节点的边界调整会丢——可接受的罕见退化。
library;

import 'package:flutter/painting.dart';

/// 中西文边界的推荐间隙（em）。CLREQ：汉字与西文之间约 ¼ em 留白。
const double kCjkLatinGapEm = 0.25;

/// 相邻标点互挤的收窄量（em，负向）。
///
/// `palt`（正文样式已开）先做静态压缩（全角标点 1em → 0.5em 步进）；这里再收
/// 两标点之间**残余的墨缝**。量值由实测定（2026-10-25 像素探针，思源黑体 SC
/// VF @ palt）：`。」` 对残余墨缝 ≈ 0.15–0.17em（ls=0 时对墨迹跨 79px/100px
/// 字号），收窄到 ≈0.15em 起两字笔画**相触** ⇒ 取 0.1em 留 25–40% 余量
/// （17px 正文 round 出 2px；30px 大字 3px；全程不撞）。改此常量前先重跑
/// 像素探针（方法见 git 历史 `punct_squeeze_probe_test.dart`）。
const double kPunctSqueezeEm = 0.1;

/// 开启符號（ink 在左、右侧留空）。
const String _kPunctOpen = '「『（〔［｛〈《【';

/// 結束符號（ink 在右、左侧留空）。
const String _kPunctClose = '」』）〕］｝〉》】';

/// 句終 / 中點（、。，．！？；：——单侧或双侧留空）。
const String _kPunctStop = '、。，．！？；：';

// 連接 / 省略（`——……～〜・`，U+2014/2015/2026/2025/FF5E/301C/30FB 等）：
// 语义上连写，**不挤**；它们不在可挤集里 ⇒ 天然打断相邻链（「……」不触发）。

final Set<int> _squeezablePunct = <int>{
  ..._kPunctOpen.codeUnits,
  ..._kPunctClose.codeUnits,
  ..._kPunctStop.codeUnits,
};

/// 表意文字侧（汉字 / CJK 标点 / 全角形式）。
///
/// 全角字母数字（ａｂ１２ 等）落在全角形式段内 ⇒ 按表意侧处理
/// （它们自带 1em 视觉间隙，不再加）。
bool _isIdeographic(int unit) =>
    (unit >= 0x2E80 && unit <= 0x303F) || // CJK 部首补充 ~ CJK 符号和标点
    (unit >= 0x3400 && unit <= 0x4DBF) || // CJK 扩展 A
    (unit >= 0x4E00 && unit <= 0x9FFF) || // CJK 基本区
    (unit >= 0xF900 && unit <= 0xFAFF) || // CJK 兼容表意文字
    (unit >= 0xFF00 && unit <= 0xFF60) || // 全角形式（含全角标点）
    (unit >= 0xFFE0 && unit <= 0xFFE6); // 全角符号

/// 西文侧只认 ASCII 字母/数字——最常见的"中西文直接相邻"场景
/// （`使用API`、`2026年`）。其余符号（含半角标点）不触发间隙。
bool _isLatinAlnum(int unit) =>
    (unit >= 0x30 && unit <= 0x39) || // 0-9
    (unit >= 0x41 && unit <= 0x5A) || // A-Z
    (unit >= 0x61 && unit <= 0x7A); // a-z

/// 相邻两字符之间是否需要中西文间隙（任一方向的"表意 ↔ 西文"交界）。
bool _needsGapBetween(int a, int b) =>
    (_isIdeographic(a) && _isLatinAlnum(b)) ||
    (_isLatinAlnum(a) && _isIdeographic(b));

/// 可互挤的全角标点（开启/結束/句終中點；連接省略除外）。
bool _isSqueezablePunct(int unit) => _squeezablePunct.contains(unit);

/// 边界表取值（em）：`+gapEm` = 中西文留白；`-squeezeEm` = 标点互挤；0 = 无。
/// 两规则在同一边界上互斥：间距要拉丁侧，互挤要两侧皆标点。
double _adjustAfter(int a, int b, double gapEm, double squeezeEm) {
  if (_needsGapBetween(a, b)) return gapEm;
  if (_isSqueezablePunct(a) && _isSqueezablePunct(b)) return -squeezeEm;
  return 0;
}

/// 对整棵 span 树施加中文显示层排版调整（见库文档）。无调整点时原样返回。
TextSpan applyCjkTextSpacing(
  TextSpan root, {
  double gapEm = kCjkLatinGapEm,
  double squeezeEm = kPunctSqueezeEm,
}) {
  // ── 第一趟：按绘制顺序（自身 text 先于 children）收集带文字的节点 ──
  final List<TextSpan> leaves = <TextSpan>[];
  final List<int> starts = <int>[];
  int total = 0;
  void collect(InlineSpan span) {
    if (span is! TextSpan) return;
    final String text = span.text ?? '';
    if (text.isNotEmpty) {
      leaves.add(span);
      starts.add(total);
      total += text.length;
    }
    span.children?.forEach(collect);
  }

  collect(root);
  if (leaves.isEmpty) return root;

  final String full = leaves.map((TextSpan s) => s.text!).join();

  // ── 边界表：adjustAfter[i] ⇒ full[i] 的尾随步进调整（em，带符号）──
  final List<double> adjustAfter = List<double>.filled(full.length, 0);
  bool any = false;
  for (int i = 0; i + 1 < full.length; i++) {
    final double v = _adjustAfter(
      full.codeUnitAt(i),
      full.codeUnitAt(i + 1),
      gapEm,
      squeezeEm,
    );
    if (v != 0) {
      adjustAfter[i] = v;
      any = true;
    }
  }
  if (!any) return root;

  // ── 第二趟：同样顺序重建，叶子按边界切段 ──
  // 索引对账：凡带文字的节点都占一个叶子槽位（与第一趟一致）；
  // "text 与 children 并存"的罕见节点只递归 children、自带文字不拆
  // （见库文档「已知边界」），但槽位照常消耗，免得后续叶子全错位。
  int leafIndex = 0;
  InlineSpan rebuild(InlineSpan span) {
    if (span is! TextSpan) return span;
    final String text = span.text ?? '';
    final List<InlineSpan>? kids = span.children;
    final bool hasKids = kids != null && kids.isNotEmpty;
    if (text.isEmpty) {
      if (!hasKids) return span;
      return TextSpan(
        style: span.style,
        recognizer: span.recognizer,
        mouseCursor: span.mouseCursor,
        semanticsLabel: span.semanticsLabel,
        children: <InlineSpan>[for (final InlineSpan k in kids) rebuild(k)],
      );
    }
    final int start = starts[leafIndex++];
    if (hasKids) {
      // text 与 children 并存的罕见节点：自带文字不拆（见库文档「已知边界」），
      // 但**必须保留**（绘制顺序 = 自身 text 先于 children）。
      return TextSpan(
        text: text,
        style: span.style,
        recognizer: span.recognizer,
        mouseCursor: span.mouseCursor,
        semanticsLabel: span.semanticsLabel,
        children: <InlineSpan>[for (final InlineSpan k in kids) rebuild(k)],
      );
    }
    return _splitLeaf(span, start, adjustAfter);
  }

  return rebuild(root) as TextSpan;
}

/// 把一个叶子按边界表切成若干子段；叶子内无调整点时原样返回。
///
/// 切法：**带调整的字符独占一个单字 span**（letterSpacing 会作用于段内
/// 每个字形，多字段会把段内字距也撑开——这是本函数最容易写错的地方），
/// 其余连续字符合成无调整段。
TextSpan _splitLeaf(TextSpan leaf, int start, List<double> adjustAfter) {
  final String text = leaf.text!;
  bool hasAdjust = false;
  for (int i = 0; i < text.length; i++) {
    if (adjustAfter[start + i] != 0) {
      hasAdjust = true;
      break;
    }
  }
  if (!hasAdjust) return leaf;

  final double fontSize = leaf.style?.fontSize ?? 16;

  final List<InlineSpan> pieces = <InlineSpan>[];
  final StringBuffer run = StringBuffer();
  void flush() {
    if (run.isNotEmpty) {
      pieces.add(_piece(leaf, run.toString(), 0));
      run.clear();
    }
  }

  for (int i = 0; i < text.length; i++) {
    final double em = adjustAfter[start + i];
    if (em != 0) {
      flush();
      pieces.add(_piece(leaf, text[i], (fontSize * em).roundToDouble()));
    } else {
      run.write(text[i]);
    }
  }
  flush();

  // 容器持有 recognizer / semanticsLabel，文字与样式下沉到各子段。
  return TextSpan(
    style: leaf.style,
    recognizer: leaf.recognizer,
    mouseCursor: leaf.mouseCursor,
    semanticsLabel: leaf.semanticsLabel,
    children: pieces,
  );
}

/// 一个子段。[letterSpacing] ≠ 0 时挂尾随字距（在原字距上**叠加**，可负）。
TextSpan _piece(TextSpan leaf, String text, double letterSpacing) => TextSpan(
  text: text,
  style: letterSpacing == 0
      ? leaf.style
      : (leaf.style ?? const TextStyle()).copyWith(
          letterSpacing: (leaf.style?.letterSpacing ?? 0) + letterSpacing,
        ),
  recognizer: leaf.recognizer,
  mouseCursor: leaf.mouseCursor,
);
