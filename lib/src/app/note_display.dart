import '../domain/note.dart';

/// 笔记在**列表 / 卡片 / 灵感流**里的**显示口径**。
///
/// 2026-10-06 从 `home_hub.dart` 抽出：灵感流（[StreamView]）与卡片网格是
/// 同一篇笔记的两种投影，**标题兜底与相对时间必须是同一套**——否则同一篇在
/// 两个视图里长得不一样（一处借正文首行、另一处显示「无标题」），那正是
/// "投影"该避免的分裂。
///
/// ⚠️ 这里只管"怎么显示"，不管"取哪些"（那是 homeItemsProvider 的事）。
/// 也不含配色 / 字号——那些归 ThemeData 与 Tokens。

/// **显示标题**：用户标题优先；无标题时借**正文第一个非空行**（Notion 惯例
/// ——一排「无标题」长得一模一样，扫读时等于没有信息）。正文也空才落
/// 「无标题」。
String noteDisplayTitle(Note note) {
  final String t = note.title.trim();
  if (t.isNotEmpty) return t;
  for (final String line in note.summary.split('\n')) {
    final String l = line.trim();
    if (l.isNotEmpty) return l;
  }
  return '无标题';
}

/// **相对时间**：关心的是"多久没碰了"，不是精确时刻。
///
/// ⚠️ 与 `hub_nav.dart` 里那份同名实现同口径（那份服务导航板内联列表）。
/// 改这里请一并确认那边——两处漂移过一次，修的是同一处认知。
String relativeTime(DateTime at) {
  final Duration d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  if (d.inDays < 7) return '${d.inDays} 天前';
  return '${at.month}-${at.day.toString().padLeft(2, '0')}';
}

/// **日期分组标签**（今天 / 昨天 / `12 月 31 日` / `2025 年 12 月 31 日`）。
///
/// 列表列与灵感页共用同一套分段词：组头替行内日期说话（2026-10-21 用户定，
/// 列表行里的"2 天前"整列取消——它把右缘占成一条竖列，且每行重复同一天）。
///
/// ⚠️ 灵感页 `stream_view.dart` 的 `_dayLabel` 是同一口径；两处要一起改。
String dayLabel(DateTime at) {
  final DateTime now = DateTime.now();
  final DateTime day = DateTime(at.year, at.month, at.day);
  final DateTime today = DateTime(now.year, now.month, now.day);
  final int diff = today.difference(day).inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '昨天';
  if (day.year == today.year) return '${day.month} 月 ${day.day} 日';
  return '${day.year} 年 ${day.month} 月 ${day.day} 日';
}
