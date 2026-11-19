import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:appflowy_editor/src/editor/find_replace_menu/search_algorithm.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

const selectionExtraInfoDisableToolbar = 'selectionExtraInfoDisableToolbar';

class SearchServiceV3 {
  SearchServiceV3({
    required this.editorState,
  });

  final EditorState editorState;

  // matchWrappers.value will contain a list of matchWrappers of the matched patterns
  // the position here consists of the match and the node path of
  // matched pattern. We will use this to traverse between the matched patterns.
  ValueNotifier<List<MatchWrapper>> matchWrappers = ValueNotifier([]);
  SearchAlgorithm searchAlgorithm = DartBuiltIn();
  String targetString = '';
  Pattern queriedPattern = RegExp('');

  bool _regex = false;
  bool get regex => _regex;
  set regex(bool value) {
    _regex = value;
    findAndHighlight(targetString);
  }

  bool _caseSensitive = false;
  bool get caseSensitive => _caseSensitive;
  set caseSensitive(bool value) {
    _caseSensitive = value;
    findAndHighlight(targetString);
  }

  int _selectedIndex = 0;
  int get selectedIndex => _selectedIndex;
  set selectedIndex(int index) {
    _selectedIndex = matchWrappers.value.isEmpty
        ? -1
        : index.clamp(0, matchWrappers.value.length - 1);
    currentSelectedIndex.value = _selectedIndex;
  }

  ValueNotifier<int> currentSelectedIndex = ValueNotifier(0);

  Pattern _getPattern(String targetString) {
    if (regex) {
      return RegExp(targetString, caseSensitive: caseSensitive);
    } else {
      // [sinan 补丁 11] 全半角归一（④）：中文输入法常出全角字母/数字/标点/空格，
      // 搜「Ａｐｐｌｅ」应命中「Apple」。归一是**逐字符 1:1**（全角 U+FF01–FF5E
      // → 半角 U+0021–007E，全角空格 U+3000 → 空格），长度不变 ⇒ 匹配偏移可直接
      // 映射回原文（见 [_getMatchWrappers] 里对 text 做同样归一）。
      // 只在**字面**模式归一；正则模式原样（用户可能有意写全角，归一会破坏正则）。
      return RegExp(
        RegExp.escape(_normalizeWidth(targetString)),
        caseSensitive: caseSensitive,
      );
    }
  }

  /// 全角 → 半角归一（长度 1:1 保持，偏移可直接映射回原文）。
  ///
  /// 只覆盖 ASCII 可映射的全角区（U+FF01–FF5E）与全角空格（U+3000）；
  /// 其余（CJK、emoji）原样不动。
  static String _normalizeWidth(String s) {
    if (s.isEmpty) return s;
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final int c = s.codeUnitAt(i);
      if (c == 0x3000) {
        sb.writeCharCode(0x20); // 全角空格 → 空格
      } else if (c >= 0xFF01 && c <= 0xFF5E) {
        sb.writeCharCode(c - 0xFEE0); // 全角字母/数字/标点 → 半角
      } else {
        sb.writeCharCode(c);
      }
    }
    return sb.toString();
  }

  String _getRegexReplaced(String replaceText, Match match) {
    List<String?> groups = match
        .groups(List<int>.generate(match.groupCount + 1, (index) => index));

    String replacedText = replaceText;
    for (int i = 0; i <= match.groupCount; i++) {
      replacedText = replacedText.replaceAll('\\$i', groups[i] ?? '');
    }

    return replacedText;
  }

  void dispose() {
    matchWrappers.dispose();
    currentSelectedIndex.dispose();
  }

  // Public entry method for _findAndHighlight, do necessary checks
  // and clear previous highlights before calling the private method
  String findAndHighlight(String target) {
    Pattern pattern;

    try {
      pattern = _getPattern(target);
    } on FormatException {
      matchWrappers.value.clear();
      return 'Regex';
    }

    if (queriedPattern != pattern) {
      // this means we have a new pattern, but before we highlight the new matches,
      // lets unhighlight the old pattern
      _findAndHighlight(queriedPattern, unHighlight: true);
      matchWrappers.value.clear();
      queriedPattern = pattern;
      targetString = target;
    }

    if (target.isEmpty) return 'Empty';

    _findAndHighlight(pattern);

    return '';
  }

  /// Finds the pattern in editorState.document and stores it in matchedPositions.
  /// Calls the highlightMatch method to highlight the pattern
  /// if it is found.
  void _findAndHighlight(
    Pattern pattern, {
    bool unHighlight = false,
  }) {
    matchWrappers.value = _getMatchWrappers(
      pattern: pattern,
      nodes: editorState.document.root.children,
    );

    if (matchWrappers.value.isEmpty || unHighlight) {
      editorState.updateSelectionWithReason(
        null,
        reason: SelectionUpdateReason.searchHighlight,
        extraInfo: {
          selectionExtraInfoDoNotAttachTextService: true,
        },
      );
    } else {
      selectedIndex = selectedIndex;
      _highlightCurrentMatch(
        pattern,
      );
    }
  }

  List<MatchWrapper> _getMatchWrappers({
    required Pattern pattern,
    Iterable<Node> nodes = const [],
  }) {
    final List<MatchWrapper> result = [];
    for (final node in nodes) {
      if (node.delta != null) {
        // [sinan 补丁 11] 字面模式下把正文也做全半角归一（与 [_getPattern] 同口径）。
        // 归一 1:1 保持长度 ⇒ `match.start/end` 仍是原文偏移，可直接用于
        // 选区 / replaceText。正则模式不归一（同 _getPattern）。
        final String raw = node.delta!.toPlainText();
        final text = regex ? raw : _normalizeWidth(raw);
        final matches = searchAlgorithm.searchMethod(pattern, text);
        // we will store this list of offsets along with their path,
        // in a list of positions.
        for (Match match in matches) {
          result.add(
            MatchWrapper(match, node.path),
          );
        }
      }
      result.addAll(
        _getMatchWrappers(pattern: pattern, nodes: node.children),
      );
    }
    return result;
  }

  void _highlightCurrentMatch(
    Pattern pattern,
  ) {
    final MatchWrapper(:selection, :path) = matchWrappers.value[selectedIndex];

    // [sinan 补丁] 查找跳转 reveal 到视野上 1/3（留点上文、命中醒目），对齐
    // VS Code；原 `jumpTo(path.first)` 无 alignment ⇒ 置顶且"可见就不滚"，
    // 同屏多命中跳转时页面纹丝不动，看不出跳到哪了。
    editorState.scrollService?.jumpTo(path.first, alignment: 0.35);

    editorState.updateSelectionWithReason(
      selection,
      reason: SelectionUpdateReason.searchHighlight,
      extraInfo: {
        selectionExtraInfoDisableToolbar: true,
        selectionExtraInfoDoNotAttachTextService: true,
      },
    );
  }

  /// This method takes in a boolean parameter moveUp, if set to true,
  /// the match located above the current selected match is newly selected.
  /// Otherwise the match below the current selected match is newly selected.
  void navigateToMatch({bool moveUp = false}) {
    if (matchWrappers.value.isEmpty) return;

    if (moveUp) {
      selectedIndex = selectedIndex <= 0
          ? matchWrappers.value.length - 1
          : selectedIndex - 1;
    } else {
      selectedIndex = selectedIndex >= matchWrappers.value.length - 1
          ? 0
          : selectedIndex + 1;
    }

    _highlightCurrentMatch(queriedPattern);
  }

  /// Replaces the current selected word with replaceText.
  /// After replacing the selected word, this method selects the next
  /// matched word if that exists.
  Future<void> replaceSelectedWord(String replaceText) async {
    if (replaceText.isEmpty ||
        queriedPattern.isEmpty ||
        matchWrappers.value.isEmpty) {
      return;
    }

    final matchWrap = matchWrappers.value[selectedIndex];
    final node = editorState.getNodeAtPath(matchWrap.path)!;

    final String replaced;
    if (regex) {
      replaced = _getRegexReplaced(replaceText, matchWrap.match);
    } else {
      replaced = replaceText;
    }

    final transaction = editorState.transaction
      ..replaceText(
        node,
        matchWrap.selection.start.offset,
        matchWrap.selection.length,
        replaced,
      );
    await editorState.apply(transaction);

    matchWrappers.value.clear();
    _findAndHighlight(queriedPattern);
  }

  /// Replaces all the found occurrences of pattern with replaceText
  void replaceAllMatches(String replaceText) {
    if (replaceText.isEmpty ||
        queriedPattern.isEmpty ||
        matchWrappers.value.isEmpty) {
      return;
    }

    // _highlightAllMatches(queriedPattern.length, unHighlight: true);
    for (final matchWrap in matchWrappers.value.reversed) {
      final node = editorState.getNodeAtPath(matchWrap.path)!;
      final String replaced;
      if (regex) {
        replaced = _getRegexReplaced(replaceText, matchWrap.match);
      } else {
        replaced = replaceText;
      }

      final transaction = editorState.transaction
        ..replaceText(
          node,
          matchWrap.selection.startIndex,
          matchWrap.selection.length,
          replaced,
        );

      editorState.apply(transaction);
    }
    matchWrappers.value.clear();
  }
}

class MatchWrapper {
  MatchWrapper(this.match, this.path);

  final Match match;
  final Path path;

  Selection get selection => Selection(
        start: Position(path: path, offset: match.start),
        end: Position(path: path, offset: match.end),
      );
}

extension on Pattern {
  bool get isEmpty {
    if (this is String) {
      return (this as String).isEmpty;
    } else if (this is RegExp) {
      return (this as RegExp).pattern.isEmpty;
    } else {
      return toString().isEmpty;
    }
  }
}
