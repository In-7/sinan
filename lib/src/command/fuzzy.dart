import 'command.dart';

/// 命令面板的匹配与排序（`docs/ui_rewrite_plan.md` §3.5）：**纯函数、可单测**。
///
/// ## 为什么自己带一张拼音表，而不是引一个拼音依赖
/// 这里只需要**命令标题/说明里出现过的汉字**的首字母（当前 26 个字）。引一个
/// 完整拼音库要背上几百 KB 与一个新依赖，而收益是零——命令标题是本项目自己写的，
/// 字表能穷举。
///
/// 维持它的机制是**元测试**：注册表里出现表未覆盖的汉字 ⇒ 测试红（见
/// `test/command/command_meta_test.dart`）。所以"新增命令时忘了补拼音"这件事
/// 不会静默发生——它会让拼音检索无声失效，那正是最该被拦住的一类退化。
///
/// ⚠️ 表只收汉字，**不收多音字**：这里的用途是"检索键"而不是"读音"，
/// 一个字固定一个首字母即可（`行` 取 `x`）。
const Map<int, String> _initialByRune = <int, String>{
  0x547D: 'm', // 命
  0x4EE4: 'l', // 令
  0x9762: 'm', // 面
  0x677F: 'b', // 板
  0x641C: 's', // 搜
  0x7D22: 's', // 索
  0x5E76: 'b', // 并
  0x6267: 'z', // 执
  0x884C: 'x', // 行
  0x65B0: 'x', // 新
  0x5EFA: 'j', // 建
  0x7B14: 'b', // 笔
  0x8BB0: 'j', // 记
  0x753B: 'h', // 画
  0x5E03: 'b', // 布
  0x8BBE: 's', // 设
  0x7F6E: 'z', // 置
  0x6536: 's', // 收
  0x85CF: 'c', // 藏
  0x53D6: 'q', // 取
  0x6D88: 'x', // 消
  0x9876: 'd', // 顶
  0x5230: 'd', // 到
  0x5217: 'l', // 列
  0x8868: 'b', // 表
  0x90E8: 'b', // 部
  0x5148: 'x', // 先
  0x5728: 'z', // 在
  0x91CC: 'l', // 里
  0x9009: 'x', // 选
  0x4E00: 'y', // 一
  0x7BC7: 'p', // 篇
};

/// **检索键**：汉字取首字母，ASCII 字母/数字原样小写，其余（空格、标点）丢弃。
///
/// 例：`新建笔记` → `xjbj`（于是 `xjbj` 能搜到它）；`AI 生成` → `ai生成`→`aisc`。
String searchKey(String text) {
  final StringBuffer out = StringBuffer();
  for (final int rune in text.runes) {
    final String? initial = _initialByRune[rune];
    if (initial != null) {
      out.write(initial);
      continue;
    }
    if (_isAsciiLetter(rune)) {
      out.writeCharCode(rune | 0x20); // A-Z → a-z
    } else if (_isAsciiDigit(rune)) {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

bool _isAsciiLetter(int rune) =>
    (rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A);

bool _isAsciiDigit(int rune) => rune >= 0x30 && rune <= 0x39;

bool _isHan(int rune) =>
    (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK 基本区
    (rune >= 0x3400 && rune <= 0x4DBF); // 扩展 A

/// [text] 里**表未覆盖**的汉字（去重）。正常情况下应恒为空——元测试就是它的
/// 唯一消费者：它红了说明"有人加了带新汉字的命令，而拼音表没跟上"。
List<String> uncoveredHanChars(String text) {
  final Set<int> seen = <int>{};
  for (final int rune in text.runes) {
    if (_isHan(rune) && !_initialByRune.containsKey(rune)) seen.add(rune);
  }
  return <String>[for (final int r in seen) String.fromCharCode(r)];
}

/// 一条命令对查询的**匹配得分**：越小越靠前；[noMatch] = 不匹配。
///
/// 分档的意图（越靠前越"像用户想找的"）：
/// 标题前缀 → 标题包含 → 拼音键前缀 → 拼音键包含 → 说明包含 → id 包含。
///
/// ⚠️ 最后一档（`id`）是给中文界面留的英文入口：标题是「新建笔记」而 id 是
/// `note.new`，用户敲 `new` 也该找得到——否则中文用户只有背拼音键一条路。
int commandMatchScore(Command command, String query) {
  final String q = query.trim().toLowerCase();
  final String title = command.title.toLowerCase();
  if (title.startsWith(q)) return 0;
  if (title.contains(q)) return 1;

  final String keys = searchKey(command.title);
  if (keys.startsWith(q)) return 2;
  if (keys.contains(q)) return 3;

  if (command.hint != null && command.hint!.toLowerCase().contains(q)) return 4;
  if (command.id.toLowerCase().contains(q)) return 5;
  return noMatch;
}

/// 不匹配。
const int noMatch = -1;

/// 过滤 + 排序。空查询返回**原序**（调用方已按分组排好，见
/// `docs/ui_rewrite_plan.md` §3.5 的排序规格）。
///
/// 同分时保持传入顺序：Dart 的 `List.sort` **不稳定**，所以这里用下标兜住——
/// 否则"同样的查询两次打开面板顺序不同"，用户会以为面板在乱跳。
List<Command> matchCommands(List<Command> commands, String query) {
  if (query.trim().isEmpty) return List<Command>.of(commands);

  final List<({Command command, int score, int index})> hits =
      <({Command command, int score, int index})>[];
  for (int i = 0; i < commands.length; i++) {
    final int score = commandMatchScore(commands[i], query);
    if (score != noMatch) {
      hits.add((command: commands[i], score: score, index: i));
    }
  }
  hits.sort(
    (
      ({Command command, int score, int index}) a,
      ({Command command, int score, int index}) b,
    ) => a.score != b.score
        ? a.score.compareTo(b.score)
        : a.index.compareTo(b.index),
  );
  return <Command>[
    for (final ({Command command, int score, int index}) h in hits) h.command,
  ];
}
