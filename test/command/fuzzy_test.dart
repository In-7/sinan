import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/command/command.dart';
import 'package:sinan/src/command/fuzzy.dart';

/// 命令面板的**匹配**（`docs/ui_rewrite_plan.md` §3.5）：纯函数，所以这里能直接
/// 钉住分档与稳定性——它们错了不会崩，只会"搜不到"或"顺序乱跳"。
Command _cmd(
  String id,
  String title, {
  String? hint,
  CommandGroup group = CommandGroup.file,
}) => Command(
  id: id,
  title: title,
  hint: hint,
  group: group,
  run: (CommandContext _) async {},
);

void main() {
  group('searchKey：拼音首字母检索键', () {
    test('汉字取首字母、英文数字原样保留（小写）、标点丢弃', () {
      expect(searchKey('新建笔记'), 'xjbj');
      expect(searchKey('收藏 / 取消收藏'), 'scqxsc');
      expect(searchKey('AI 设置'), 'aisz');
    });

    test('未覆盖的汉字被报出来（而不是静默丢弃）', () {
      expect(uncoveredHanChars('新建笔记'), isEmpty);
      expect(uncoveredHanChars('新建笔记骉'), <String>['骉']);
    });
  });

  group('commandMatchScore：分档', () {
    final Command c = _cmd('note.new', '新建笔记', hint: '创建一篇新笔记');

    test('标题前缀 < 标题包含 < 拼音前缀 < 拼音包含 < 说明 < id', () {
      expect(commandMatchScore(c, '新建'), 0, reason: '标题前缀');
      expect(commandMatchScore(c, '笔记'), 1, reason: '标题包含');
      expect(commandMatchScore(c, 'xjbj'), 2, reason: '拼音键整串');
      expect(commandMatchScore(c, 'bj'), 3, reason: '拼音键包含（非前缀）');
      expect(commandMatchScore(c, '创建'), 4, reason: '说明');
      expect(commandMatchScore(c, 'new'), 5, reason: 'id 兜底：中文标题的英文入口');
      expect(commandMatchScore(c, 'zzz'), noMatch);
    });

    test('查询两端空白不影响（用户常在中文输入法后留个空格）', () {
      expect(commandMatchScore(c, ' 新建 '), 0);
    });
  });

  group('matchCommands：过滤与排序', () {
    final List<Command> all = <Command>[
      _cmd('a', '新建笔记'),
      _cmd('b', '新建画布'),
      _cmd('c', '设置', group: CommandGroup.app),
      _cmd('d', '收藏 / 取消收藏'),
    ];

    test('空查询返回原序（调用方已按分组排好）', () {
      expect(
        <String>[for (final Command c in matchCommands(all, '  ')) c.id],
        <String>['a', 'b', 'c', 'd'],
      );
    });

    test('只留匹配项', () {
      expect(
        <String>[for (final Command c in matchCommands(all, '新建')) c.id],
        <String>['a', 'b'],
      );
    });

    test('同分时保持传入顺序（Dart 的 sort 不稳定，所以这条是"要守住"的）', () {
      // 两条标题都含"新建"且都是"包含"档 ⇒ 同分 ⇒ 必须按传入顺序。
      expect(
        <String>[for (final Command c in matchCommands(all, '新')) c.id],
        <String>['a', 'b'],
      );
    });

    test('拼音键可检索：xjhb → 新建画布', () {
      expect(
        <String>[for (final Command c in matchCommands(all, 'xjhb')) c.id],
        <String>['b'],
      );
    });

    test('无匹配返回空（面板据此显示"没有匹配的命令"）', () {
      expect(matchCommands(all, 'zzzz'), isEmpty);
    });
  });
}
