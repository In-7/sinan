import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/app/stream_view.dart';
import 'package:sinan/src/domain/note.dart';

Note _note(String id, DateTime revised, {DateTime? promotedAt}) => Note(
  id: id,
  kind: NoteKind.note,
  title: id,
  content: '',
  plainText: '',
  summary: '',
  contentHash: '',
  createdAt: revised,
  revisedAt: revised,
  promotedAt: promotedAt,
);

/// 心流流的**分组规则**（纯函数 [groupByRecency]）。
///
/// 钉的是三条结构性事实：① 五组的判定边界；② 空组不出现（今天没写过就不
/// 显示"今天"这个头）；③ **收藏不提升置顶**——时间线的纯度优先，收藏有
/// 自己的 favorites 视图。
void main() {
  // 周四（2026-10-08）⇒ 本周 = 周一起（10-05）、昨天 = 周三（10-07），
  // 本周桶里能同时装下 10-05 / 10-06 两天，边界才测得到。
  final DateTime now = DateTime(2026, 10, 8, 12);
  final DateTime today = DateTime(2026, 10, 8);
  final DateTime yesterday = DateTime(2026, 10, 7);

  test('五组判定：今天 / 昨天 / 本周 / 本月 / 更早', () {
    final List<Note> notes = <Note>[
      _note('更早', DateTime(2026, 9)),
      _note('本月', DateTime(2026, 10)), // 同月但在本周之前
      _note('本周b', DateTime(2026, 10, 6)),
      _note('本周a', DateTime(2026, 10, 5)), // 周一 = 本周之始
      _note('昨天', yesterday),
      _note('今天', today),
    ];

    final List<StreamGroup> groups = groupByRecency(notes, now: now);
    expect(
      groups.map((StreamGroup g) => g.label).toList(),
      <String>['今天', '昨天', '本周', '本月', '更早'],
    );
    expect(groups[0].notes.map((Note n) => n.id).toList(), <String>['今天']);
    expect(groups[1].notes.map((Note n) => n.id).toList(), <String>['昨天']);
    expect(
      groups[2].notes.map((Note n) => n.id).toList(),
      <String>['本周b', '本周a'],
      reason: '组内顺序沿用入参（已按 revisedAt 排好），不重排',
    );
    expect(groups[3].notes.map((Note n) => n.id).toList(), <String>['本月']);
    expect(groups[4].notes.map((Note n) => n.id).toList(), <String>['更早']);
  });

  test('空组不出现：只有今天的内容时只有一个「今天」头', () {
    final List<StreamGroup> groups = groupByRecency(
      <Note>[_note('a', today), _note('b', today)],
      now: now,
    );
    expect(groups.map((StreamGroup g) => g.label).toList(), <String>['今天']);
    expect(groups.single.notes.length, 2);
  });

  test('收藏不提升置顶：顺序就是入参顺序（时间线纯度优先）', () {
    final List<Note> notes = <Note>[
      _note('旧', DateTime(2026, 10, 6, 9)),
      _note('新但收藏', DateTime(2026, 10, 6, 10), promotedAt: now),
      _note('新', DateTime(2026, 10, 6, 11)),
    ];
    final List<StreamGroup> groups = groupByRecency(notes, now: now);
    expect(
      groups.single.notes.map((Note n) => n.id).toList(),
      <String>['旧', '新但收藏', '新'],
      reason: '收藏没有插队——收藏走 favorites 视图，不污染时间线',
    );
  });
}
