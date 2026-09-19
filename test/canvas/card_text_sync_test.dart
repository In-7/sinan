import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/card_text_sync.dart';

/// 双链多视图（#5）「库 → 内存」的拉新决策（见 `card_text_sync.dart`）。
///
/// 这条规则短、但写反的两种后果都是**静默吃数据**，所以要逐种情形钉死：
/// 判错一边抹掉用户刚敲的字，判错另一边把旧快照写回、吃掉文档侧的修改。
void main() {
  group('pullCardText：库里的文本该不该覆盖内存里那份', () {
    test('内存没被本地改过 + 库里更新了 ⇒ 采纳（别人改的，该拉新）', () {
      expect(
        pullCardText(current: '旧', baseline: '旧', latest: '新'),
        '新',
      );
    });

    test('内存有未落盘的本地编辑 ⇒ 不采纳（用户的输入优先）', () {
      expect(
        pullCardText(current: '用户刚敲的', baseline: '旧', latest: '别人改的'),
        isNull,
      );
    });

    test('两边一样 ⇒ 不动（无谓的写入会白掉一次重排）', () {
      expect(
        pullCardText(current: '一样', baseline: '一样', latest: '一样'),
        isNull,
      );
    });

    test('库里没有这一块（被删了 / 还没落行）⇒ 不动，不把文本清空', () {
      expect(
        pullCardText(current: '还是我', baseline: '还是我', latest: null),
        isNull,
      );
    });

    test('没有基线（新卡 / 刚导入）⇒ 不覆盖，宁可等第一次落盘建立基线', () {
      expect(
        pullCardText(current: '导入的', baseline: null, latest: '库里的'),
        isNull,
      );
    });

    test('本地改成与库里一致的值 ⇒ 不算变化', () {
      expect(
        pullCardText(current: '碰巧一样', baseline: '旧', latest: '碰巧一样'),
        isNull,
      );
    });
  });
}
