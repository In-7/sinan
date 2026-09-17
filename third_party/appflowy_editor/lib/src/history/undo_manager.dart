import 'dart:collection';

import 'package:appflowy_editor/src/core/location/selection.dart';
import 'package:appflowy_editor/src/core/transform/operation.dart';
import 'package:appflowy_editor/src/core/transform/transaction.dart';
import 'package:appflowy_editor/src/editor_state.dart';
import 'package:appflowy_editor/src/infra/log.dart';

/// A [HistoryItem] contains list of operations committed by users.
/// If a [HistoryItem] is not sealed, operations can be added sequentially.
/// Otherwise, the operations should be added to a new [HistoryItem].
final class HistoryItem extends LinkedListEntry<HistoryItem> {
  final List<Operation> operations = [];
  Selection? beforeSelection;
  Selection? afterSelection;
  bool _sealed = false;

  HistoryItem();

  /// Seal the history item.
  /// When an item is sealed, no more operations can be added
  /// to the item.
  ///
  /// The caller should create a new [HistoryItem].
  void seal() {
    _sealed = true;
  }

  bool get sealed => _sealed;

  void add(Operation op) {
    operations.add(op);
  }

  void addAll(Iterable<Operation> iterable) {
    operations.addAll(iterable);
  }

  /// Create a new [Transaction] by inverting the operations.
  Transaction toTransaction(EditorState state) {
    final builder = Transaction(document: state.document);
    for (var i = operations.length - 1; i >= 0; i--) {
      final operation = operations[i];
      final inverted = operation.invert();
      builder.add(inverted, transform: false);
    }
    builder.afterSelection = beforeSelection;
    builder.beforeSelection = afterSelection;
    return builder;
  }
}

class FixedSizeStack {
  final _list = LinkedList<HistoryItem>();
  final int maxSize;

  FixedSizeStack(this.maxSize);

  void push(HistoryItem stackItem) {
    if (_list.length >= maxSize) {
      _list.remove(_list.first);
    }
    _list.add(stackItem);
  }

  HistoryItem? pop() {
    if (_list.isEmpty) {
      return null;
    }
    final last = _list.last;

    _list.remove(last);

    return last;
  }

  void clear() {
    _list.clear();
  }

  HistoryItem get last => _list.last;

  bool get isEmpty => _list.isEmpty;

  bool get isNonEmpty => _list.isNotEmpty;
}

class UndoManager {
  final FixedSizeStack undoStack;
  final FixedSizeStack redoStack;
  EditorState? state;

  /// [sinan 补丁 12] 是否正在执行"重做"。
  ///
  /// `redo()` 用 `recordUndo: true` 应用事务（重做出来的内容应当成为一条新的
  /// 撤销历史），于是也会走 [getUndoHistoryItem]；而那条路径上有一条
  /// "**新的用户编辑**作废重做栈"的规则（`redoStack.clear()`）——它对"重做自身"
  /// 不该生效，否则重做一次之后**剩余的重做历史全被清掉**（用户实测："重做好像
  /// 只能重做一次"；实测 3 步撤销后只能重做 2 步，最后一步静默失效）。
  bool _applyingRedo = false;

  UndoManager([int stackSize = 20])
      : undoStack = FixedSizeStack(stackSize),
        redoStack = FixedSizeStack(stackSize);

  HistoryItem getUndoHistoryItem() {
    if (undoStack.isEmpty) {
      final item = HistoryItem();
      undoStack.push(item);
      return item;
    }
    final last = undoStack.last;
    if (last.sealed) {
      // [sinan 补丁 12] 重做不是"新的用户编辑"⇒ 不清重做栈。
      if (!_applyingRedo) {
        redoStack.clear();
      }
      final item = HistoryItem();
      undoStack.push(item);
      return item;
    }
    return last;
  }

  void undo() {
    AppFlowyEditorLog.editor.debug('undo');
    final s = state;
    if (s == null) {
      return;
    }
    final historyItem = undoStack.pop();
    if (historyItem == null) {
      return;
    }
    final transaction = historyItem.toTransaction(s);
    s.apply(
      transaction,
      options: const ApplyOptions(
        recordUndo: false,
        recordRedo: true,
      ),
    );
  }

  void redo() {
    AppFlowyEditorLog.editor.debug('redo');
    final s = state;
    if (s == null) {
      return;
    }
    final historyItem = redoStack.pop();
    if (historyItem == null) {
      return;
    }
    final transaction = historyItem.toTransaction(s);
    // [sinan 补丁 12] 标记"正在重做"：本次 `apply` 的**同步段**里就会走到
    // `getUndoHistoryItem()`（`applyTransaction` 在第一个 await 之前就记录历史），
    // 用 try/finally 括住整次调用即可覆盖那个窗口。
    _applyingRedo = true;
    try {
      s.apply(
        transaction,
        options: const ApplyOptions(
          recordUndo: true,
          recordRedo: false,
        ),
      );
    } finally {
      _applyingRedo = false;
    }
  }

  void forgetRecentUndo() {
    AppFlowyEditorLog.editor.debug('forgetRecentUndo');
    if (state != null) {
      undoStack.pop();
    }
  }
}
