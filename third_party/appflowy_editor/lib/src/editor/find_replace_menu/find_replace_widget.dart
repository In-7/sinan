import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

import 'find_replace_menu_icon_button.dart';

const double _iconButtonSize = 30;

class FindAndReplaceMenuWidget extends StatefulWidget {
  const FindAndReplaceMenuWidget({
    super.key,
    this.localizations,
    this.defaultFindText = '',
    this.caseSensitive = false,
    required this.onDismiss,
    required this.editorState,
    required this.showReplaceMenu,
    required this.style,
    this.showRegexButton = true,
    this.showCaseSensitiveButton = true,
  });

  final EditorState editorState;
  final VoidCallback onDismiss;

  /// Whether to show the replace menu or not
  final bool showReplaceMenu;

  /// The style of the find and replace menu
  ///
  /// only works for SearchService, not for SearchServiceV2
  final FindReplaceStyle style;
  final bool showRegexButton;
  final bool showCaseSensitiveButton;

  /// The localizations of the find and replace menu
  final FindReplaceLocalizations? localizations;

  /// The default text to search for
  final String defaultFindText;

  /// Whether the search should be case sensitive or not
  final bool caseSensitive;

  @override
  State<FindAndReplaceMenuWidget> createState() =>
      _FindAndReplaceMenuWidgetState();
}

class _FindAndReplaceMenuWidgetState extends State<FindAndReplaceMenuWidget> {
  String queriedPattern = '';
  bool showRegexButton = true;
  bool showCaseSensitiveButton = true;
  bool showReplaceMenu = false;

  late SearchServiceV3 searchService = SearchServiceV3(
    editorState: widget.editorState,
  );

  @override
  void initState() {
    super.initState();
    showReplaceMenu = widget.showReplaceMenu;
    showRegexButton = widget.showRegexButton;
    showCaseSensitiveButton = widget.showCaseSensitiveButton;

    showReplaceMenu = widget.showReplaceMenu;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: FindMenu(
            onDismiss: widget.onDismiss,
            editorState: widget.editorState,
            style: widget.style,
            searchService: searchService,
            defaultFindText: widget.defaultFindText,
            caseSensitive: widget.caseSensitive,
            localizations: widget.localizations,
            showReplaceMenu: showReplaceMenu,
            onShowReplace: (value) => setState(() {
              showReplaceMenu = value;
            }),
          ),
        ),
        showReplaceMenu
            ? Padding(
                padding: const EdgeInsets.only(
                  bottom: 8.0,
                ),
                child: ReplaceMenu(
                  editorState: widget.editorState,
                  searchService: searchService,
                  localizations: widget.localizations,
                ),
              )
            : const SizedBox.shrink(),
      ],
    );
  }
}

class FindMenu extends StatefulWidget {
  const FindMenu({
    super.key,
    this.localizations,
    this.defaultFindText = '',
    this.caseSensitive = false,
    this.showReplaceMenu = false,
    required this.onDismiss,
    required this.editorState,
    required this.style,
    required this.searchService,
    required this.onShowReplace,
    this.showRegexButton = true,
    this.showCaseSensitiveButton = true,
  });

  final EditorState editorState;
  final VoidCallback onDismiss;

  /// The style of the find and replace menu
  ///
  /// only works for SearchService, not for SearchServiceV2
  final FindReplaceStyle style;

  /// The localizations of the find and replace menu
  final FindReplaceLocalizations? localizations;

  /// The default text to search for
  final String defaultFindText;

  /// Whether the search should be case sensitive or not
  final bool caseSensitive;

  /// Whether to show the replace menu or not
  final bool showReplaceMenu;

  final bool showRegexButton;
  final bool showCaseSensitiveButton;

  final void Function(bool showReplaceMenu) onShowReplace;

  final SearchServiceV3 searchService;

  @override
  State<FindMenu> createState() => _FindMenuState();
}

class _FindMenuState extends State<FindMenu> {
  final findTextFieldFocusNode = FocusNode();

  final findTextEditingController = TextEditingController();

  // sinan 补丁 9：查找输入**防抖 200ms**。原实现每个按键（含拼音组合中的
  // 每个字母）都全文档搜索 + 更新编辑器选区/滚动——组合输入期间编辑器
  // 侧的持续抖动会与 IME 候选窗竞争（候选窗偶发消失的嫌疑链）。改为
  // 停止输入 200ms 后才搜一次；正则 / 大小写开关仍立即生效。
  // 附带收益：大文档的每键全文档扫描成本同步消失。
  Timer? _searchDebounce;

  String message = AppFlowyEditorLocalizations.current.emptySearchBoxHint;

  bool showReplaceMenu = false;
  bool caseSensitive = false;

  bool showRegexButton = true;
  bool showCaseSensitiveButton = true;

  @override
  void initState() {
    super.initState();

    showReplaceMenu = widget.showReplaceMenu;
    caseSensitive = widget.caseSensitive;

    showRegexButton = widget.showRegexButton;
    showCaseSensitiveButton = widget.showCaseSensitiveButton;

    widget.searchService.matchWrappers.addListener(_setState);
    widget.searchService.currentSelectedIndex.addListener(_setState);

    findTextEditingController.addListener(_onQueryChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      findTextFieldFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    widget.searchService.matchWrappers.removeListener(_setState);
    widget.searchService.currentSelectedIndex.removeListener(_setState);
    widget.searchService.dispose();
    findTextEditingController.removeListener(_onQueryChanged);
    findTextEditingController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // the selectedIndex from searchService is 0-based
    final selectedIndex = widget.searchService.selectedIndex + 1;
    final matches = widget.searchService.matchWrappers.value;
    return Row(
      children: [
        // expand/collapse button
        FindAndReplaceMenuIconButton(
          icon: Icon(
            showReplaceMenu ? Icons.expand_less : Icons.expand_more,
          ),
          onPressed: () {
            widget.onShowReplace(!showReplaceMenu);
            setState(() {
              showReplaceMenu = !showReplaceMenu;
            });
          },
        ),
        // find text field
        SizedBox(
          width: 200,
          height: 30,
          child: TextField(
            key: const Key('findTextField'),
            focusNode: findTextFieldFocusNode,
            controller: findTextEditingController,
            onSubmitted: (_) {
              widget.searchService.navigateToMatch();
              // sinan 补丁 8：焦点由服务层 keepEditorFocus 压住，编辑器不再
              // 抢走，直接回焦即可——原「延迟 requestFocus 抢回」与 IME
              // 组合输入竞态，候选窗偶发消失。
              findTextFieldFocusNode.requestFocus();
            },
            decoration: _buildInputDecoration(
              widget.localizations?.find ?? AppFlowyEditorL10n.current.find,
            ),
          ),
        ),
        // the count of matches
        // sinan 补丁 8：**定宽**——原 minWidth 会随"无匹配项"等提示文案
        // 变宽，把后面的按钮挤得左右换位；定宽 + 溢出省略后按钮恒定。
        SizedBox(
          width: 96,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Text(
              // sinan 补丁 7b：分隔符用语言中性的 " / "（原文案硬编码英文
              // "1 of 5"，不在任何 l10n 表里，中文化场景是漏网之鱼）。
              matches.isEmpty ? message : '$selectedIndex / ${matches.length}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        // sinan 补丁 8：正则 / 大小写开关紧跟输入框（VS Code 式分组），
        // 激活色用主题色——原硬编码 Colors.black 在深色画布上不可见。
        if (showRegexButton)
          FindAndReplaceMenuIconButton(
            key: const Key('findRegexButton'),
            onPressed: () {
              setState(() {
                widget.searchService.regex = !widget.searchService.regex;
              });
              _searchPattern();
            },
            icon: EditorSvg(
              name: 'regex',
              width: 20,
              height: 20,
              color: widget.searchService.regex
                  ? Theme.of(context).colorScheme.onSurface
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            tooltip: AppFlowyEditorL10n.current.regex,
          ),
        // case sensitive button
        if (showCaseSensitiveButton)
          FindAndReplaceMenuIconButton(
            key: const Key('caseSensitiveButton'),
            onPressed: () {
              setState(() {
                widget.searchService.caseSensitive =
                    !widget.searchService.caseSensitive;
              });
              _searchPattern();
            },
            icon: EditorSvg(
              name: 'case_sensitive',
              width: 20,
              height: 20,
              color: widget.searchService.caseSensitive
                  ? Theme.of(context).colorScheme.onSurface
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            tooltip: AppFlowyEditorL10n.current.caseSensitive,
          ),
        // previous / next / close：焦点由服务层 keepEditorFocus 压住
        // （补丁 8），编辑器不再抢走，直接回焦即可——原「延迟 requestFocus
        // 抢回」与 IME 组合输入竞态，候选窗偶发消失。
        FindAndReplaceMenuIconButton(
          iconButtonKey: const Key('previousMatchButton'),
          onPressed: () {
            findTextFieldFocusNode.requestFocus();
            widget.searchService.navigateToMatch(moveUp: true);
          },
          icon: const Icon(Icons.arrow_upward),
          tooltip: widget.localizations?.previousMatch ??
              AppFlowyEditorL10n.current.previousMatch,
        ),
        FindAndReplaceMenuIconButton(
          iconButtonKey: const Key('nextMatchButton'),
          onPressed: () {
            findTextFieldFocusNode.requestFocus();
            widget.searchService.navigateToMatch();
          },
          icon: const Icon(Icons.arrow_downward),
          tooltip: widget.localizations?.nextMatch ??
              AppFlowyEditorL10n.current.nextMatch,
        ),
        FindAndReplaceMenuIconButton(
          iconButtonKey: const Key('closeButton'),
          onPressed: widget.onDismiss,
          icon: const Icon(Icons.close),
          tooltip: widget.localizations?.close ??
              AppFlowyEditorL10n.current.closeFind,
        ),
      ],
    );
  }

  /// 输入变化入口（防抖触发）。
  void _onQueryChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), _searchPattern);
  }

  void _searchPattern() {
    // 开关切换等立即搜索的路径先掐掉挂着的防抖，避免一次多余的迟到搜索。
    _searchDebounce?.cancel();
    String error;

    // the following line needs to be executed even if
    // findTextEditingController.text.isEmpty, otherwise the previous
    // matches will persist
    error =
        widget.searchService.findAndHighlight(findTextEditingController.text);

    switch (error) {
      case 'Regex':
        message = AppFlowyEditorLocalizations.current.regexError;
      case 'Empty':
        message = AppFlowyEditorLocalizations.current.emptySearchBoxHint;
      default:
        message = widget.localizations?.noResult ??
            AppFlowyEditorLocalizations.current.noFindResult;
    }

    _setState();
  }

  void _setState() {
    setState(() {});
  }
}

class ReplaceMenu extends StatefulWidget {
  const ReplaceMenu({
    super.key,
    required this.editorState,
    required this.searchService,
    this.localizations,
  });

  final EditorState editorState;

  /// The localizations of the find and replace menu
  final FindReplaceLocalizations? localizations;

  final SearchServiceV3 searchService;

  @override
  State<ReplaceMenu> createState() => _ReplaceMenuState();
}

class _ReplaceMenuState extends State<ReplaceMenu> {
  final replaceTextFieldFocusNode = FocusNode();
  final replaceTextEditingController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // placeholder for aligning the replace menu
        const SizedBox(
          width: _iconButtonSize,
        ),
        SizedBox(
          width: 200,
          height: 30,
          child: TextField(
            key: const Key('replaceTextField'),
            focusNode: replaceTextFieldFocusNode,
            autofocus: false,
            controller: replaceTextEditingController,
            onSubmitted: (_) {
              _replaceSelectedWord();
              // sinan 补丁 8：同查找框——焦点由服务层压住，直接回焦。
              replaceTextFieldFocusNode.requestFocus();
            },
            decoration: _buildInputDecoration(
              widget.localizations?.replace ??
                  AppFlowyEditorL10n.current.replace,
            ),
          ),
        ),
        FindAndReplaceMenuIconButton(
          iconButtonKey: const Key('replaceSelectedButton'),
          onPressed: _replaceSelectedWord,
          icon: const Icon(Icons.find_replace),
          tooltip: widget.localizations?.replace ??
              AppFlowyEditorL10n.current.replace,
        ),
        FindAndReplaceMenuIconButton(
          iconButtonKey: const Key('replaceAllButton'),
          onPressed: () => widget.searchService.replaceAllMatches(
            replaceTextEditingController.text,
          ),
          icon: const Icon(Icons.change_circle_outlined),
          tooltip: widget.localizations?.replaceAll ??
              AppFlowyEditorL10n.current.replaceAll,
        ),
      ],
    );
  }

  void _replaceSelectedWord() {
    widget.searchService.replaceSelectedWord(replaceTextEditingController.text);
  }
}

InputDecoration _buildInputDecoration(String hintText) {
  return InputDecoration(
    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
    border: const OutlineInputBorder(),
    hintText: hintText,
  );
}
