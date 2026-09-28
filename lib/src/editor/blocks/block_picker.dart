import 'package:flutter/material.dart';

import 'dart:ui' as ui;

import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/block_hit.dart';
import '../../theme/tokens.dart';

/// 弹「选一个块」对话框，返回所选块 id（取消 → null）。
///
/// 双链的**块级**创建入口（斜杠菜单「引用块」调它）。存的是块 id 而不是文本，
/// 于是目标日后改名 / 改写都不会断链（见 `RefBlockKeys`）。
///
/// ## 为什么是**一级扁平搜索**而不是"先选笔记、再选块"
/// 两级导航是**文件优先**模型（Notion 的 `Copy link to block`、Obsidian 的
/// `[[文件#^块]]`）的产物：块住在文件里，得先定位文件。sinan 的 `blocks` 表是
/// 全库扁平的（块只是**属于**某篇笔记），一次查询就能搜到 ⇒ 走 Roam / Logseq
/// 那种"一个框搜全库"的路子，用户不必先回答"它在哪篇笔记里"。
Future<String?> pickBlockToReference(BuildContext context) async {
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  // 类型由 provider 推断：本层**不 import `data/`**（架构闸门要求经 DI 取 store，
  // 见 test/architecture/architecture_test.dart）。
  final store = container.read(noteStoreProvider);

  if (!context.mounted) return null;
  return showDialog<String>(
    context: context,
    // 搜索能力以**闭包**注入（而不是把 store 传进去）：对话框因此不依赖数据层，
    // 测试里塞一个假的 search 就能验证交互。
    builder: (BuildContext ctx) =>
        _BlockPickerDialog(search: store.searchBlocks),
  );
}

/// 块选择框：**搜块内容** + 列表（每条带所属笔记做定位线索）。
///
/// 每条都显示来源笔记标题，是因为结果来自**全库**——没有它，用户无法判断
/// 搜到的块是哪一篇里的。
class _BlockPickerDialog extends StatefulWidget {
  const _BlockPickerDialog({required this.search});

  /// 按关键词搜块（空串 ⇒ 最近一批）。
  final List<BlockHit> Function(String query) search;

  @override
  State<_BlockPickerDialog> createState() => _BlockPickerDialogState();
}

class _BlockPickerDialogState extends State<_BlockPickerDialog> {
  final TextEditingController _filter = TextEditingController();
  List<BlockHit> _hits = const <BlockHit>[];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _refresh() {
    // 同步查库（SQLite 在本地，几十毫秒内）⇒ 直接 setState，无需异步编排。
    _hits = widget.search(_filter.text);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<BlockHit> hits = _hits;
    return AlertDialog(
      title: const Text('引用'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: <Widget>[
            TextField(
              controller: _filter,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '搜块内容（留空看最近改过的）',
                isDense: true,
              ),
              onChanged: (_) => setState(_refresh),
            ),
            const SizedBox(height: Tokens.spaceXs),
            Expanded(
              child: hits.isEmpty
                  ? Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        _filter.text.trim().isEmpty ? '还没有可引用的块' : '没有匹配的块',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      itemCount: hits.length,
                      itemBuilder: (BuildContext ctx, int i) {
                        final BlockHit hit = hits[i];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            hit.text.trim().isEmpty ? '（空块）' : hit.text.trim(),
                            maxLines: 2,
                            overflow: .ellipsis,
                          ),
                          // 来源笔记 = 全库结果里唯一的定位线索。
                          subtitle: Row(
                            children: <Widget>[
                              tabler.LayoutDashboard(
                                height: Tokens.iconXs,
                                width: Tokens.iconXs,
                                strokeWidth: 1.5,
                                colorFilter: ui.ColorFilter.mode(
                                  scheme.onSurfaceVariant,
                                  ui.BlendMode.srcIn,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  hit.noteTitle.trim().isEmpty
                                      ? '未命名笔记'
                                      : hit.noteTitle.trim(),
                                  maxLines: 1,
                                  overflow: .ellipsis,
                                ),
                              ),
                            ],
                          ),
                          onTap: () => Navigator.of(ctx).pop(hit.blockId),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
