import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../app/save_debounce.dart';
import '../data/note_store.dart';
import '../theme/tokens.dart';
import 'canvas_surface.dart';
import 'kernel/canvas_ai.dart';
import 'kernel/canvas_ai_cache.dart';
import 'kernel/canvas_controller.dart';
import 'kernel/canvas_media.dart';

/// 画布**笔记**视图：按 [noteId] 装配一个 [CanvasController]，负责
/// **载入 + 防抖自动保存**，再交给 [CanvasSurface] 显示。
///
/// ## 数据落点
/// 画布 JSON（[CanvasController.toJson]：相机 + 文档）就存在该笔记的
/// `notes.content` 里——因为「画布」是一种**笔记形态**（[NoteKind.canvas]），
/// 与块树文档是两条互不干扰的笔记，故不需要额外列/表。
/// （墨迹的分片二进制存储见 `docs/data_layer.md` 的 `ink_shards`，属后续优化。）
///
/// ## 与块编辑器同级
/// 右侧内容区按当前笔记的 `kind` 二选一挂载：文档笔记 → 块编辑器，
/// 画布笔记 → 本组件（见 `home_screen.dart` 的 `detailPane`）。
class CanvasNoteView extends ConsumerStatefulWidget {
  const CanvasNoteView({super.key, required this.noteId});

  final String noteId;

  @override
  ConsumerState<CanvasNoteView> createState() => _CanvasNoteViewState();
}

class _CanvasNoteViewState extends ConsumerState<CanvasNoteView> {
  /// 只用于**读**（`_loadContent` 取正文：列表快照不含 content 大字段，
  /// 见 [NoteStore.allNotes]）。**写一律走 [_notes]**，见 [dispose]。
  late final NoteStore _store;

  /// 笔记写入的**唯一入口**（`NotesNotifier`），在 [initState] 提前抓取。
  ///
  /// ⚠️ 必须提前抓，不能在 [dispose] 里现取：Riverpod 禁止在 unmount 前后用
  /// widget 的 `ref`（实测抛 `Bad state: Using "ref" when a widget is about to
  /// or has been unmounted is unsafe.`）。而 notifier 由**容器**持有、寿命长于
  /// 本 widget，提前持有它是安全的，且调用它不经过 widget 的 ref。
  late final NotesNotifier _notes;
  late final CanvasController _controller;

  /// 落盘调度：一停手 600ms 就落盘，**连续运笔不停手时最迟 2s 也必落一次**
  /// （[SaveDebounce] 的硬上界——纯防抖在不停笔的情况下会一直不落盘）。
  late final SaveDebounce _save = SaveDebounce(
    window: const Duration(milliseconds: 600),
    maxWait: kSaveMaxWait,
    onFlush: () => unawaited(_flush()),
  );

  /// 自上次落盘以来是否有改动（避免无改动也写一遍）。
  bool _dirty = false;

  /// 退出前落盘的注销句柄（见 [PendingSaves]）：[dispose] 里必须注销，否则这张
  /// 已经销毁的画布仍会在关窗口时被落盘——那时控制器已经不在了。
  late final void Function() _exitFlush;

  /// 载入是否**失败**（内容非空、却解析不出画布）。
  ///
  /// ⚠️ 失败时必须**冻结自动保存**：否则空画布会在防抖窗口后被写回，把用户那份
  /// （可能只是格式旧 / 轻微损坏）的正文**永久覆盖**——静默吞掉异常就从"少一条
  /// 日志"升级成"删用户数据"（2026-09-17 修）。
  ///
  /// 注意与"新画布"的区别：内容为**空**是正常的新画布，照常允许保存。
  bool _loadFailed = false;

  /// AI 生成器（装配在此层，内核保持零依赖）：离线桩 + **结果缓存**。
  ///
  /// 缓存让"同一配方"不再重复调模型，并把结果统一落成文件路径 —— 于是
  /// `ImageItem.src` 有值，生成图**随画布 JSON 一起落库**、重启还在。
  ///
  /// 缓存实例来自 `aiResultCacheProvider`（全应用单例）：清理策略与引用保护
  /// 都在那边装配，这里只负责注入。
  late final AiGenerator _generator = CachingAiGenerator(
    const LocalStubGenerator(),
    ref.read(aiResultCacheProvider),
  );

  /// 媒体引用解析器：**存取画布 JSON 时用它把图片路径写成 / 读回相对引用**，
  /// 于是同一份 JSON 换台机器（数据目录不同）依然能加载出图片。
  late final MediaResolver _media = ref.read(mediaResolverProvider);

  @override
  void initState() {
    super.initState();
    _store = ref.read(noteStoreProvider);
    _notes = ref.read(notesProvider.notifier);
    _controller = _createController();
    _controller.addListener(_onChanged);
    // 登记"关窗口时把防抖里还没写下去的画布写完"（见 [PendingSaves]）。
    _exitFlush = ref.read(pendingSavesProvider).register(_flushForExit);
  }

  /// 从 `notes.content` 还原控制器；内容为空（新画布）/ 解析失败时给一张空画布。
  CanvasController _createController() {
    final String raw = _loadContent();
    // 空内容 = 新画布：照常允许后续保存。
    if (raw.trim().isEmpty) return CanvasController(generator: _generator);

    final Map<String, dynamic>? json = _tryDecode(raw);
    if (json == null) {
      // 非空、却不像画布 JSON（旧格式 / 被别处覆盖 / kind 记错）。
      // 退回空画布只为"能打开"，**但要冻结保存**，否则空画布会覆盖原文。
      _loadFailed = true;
      debugPrint('画布内容无法识别为 JSON，已冻结自动保存以保护原文（${raw.length} 字符）');
      return CanvasController(generator: _generator);
    }
    try {
      return CanvasController.fromJson(
        json,
        media: _media,
        generator: _generator,
      );
    } on Object catch (e) {
      // 反序列化失败（旧格式 / 脏数据）不该让整页崩：退回空画布 + 冻结保存。
      _loadFailed = true;
      debugPrint('画布反序列化失败，已冻结自动保存以保护原文: $e');
      return CanvasController(generator: _generator);
    }
  }

  String _loadContent() {
    final String? content = _store.noteById(widget.noteId)?.content;
    return content ?? '';
  }

  /// 仅当内容看起来是画布 JSON（对象）时才尝试解析，避免把块树/纯文本误当画布。
  static Map<String, dynamic>? _tryDecode(String raw) {
    final String text = raw.trim();
    if (text.isEmpty || !text.startsWith('{')) return null;
    try {
      final dynamic decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// 控制器的任何变化（增删改 / 撤销重做 / 相机移动）都冒泡到这里；
  /// 防抖 600ms 后落盘（相机一并存，下次打开回到原视口）。
  void _onChanged() {
    // 载入失败 ⇒ 冻结保存：连防抖都不排（见 [_loadFailed]）。
    // `_createController()` 在 `addListener` 之前跑完，所以这个判断是可靠的。
    if (_loadFailed) return;
    _dirty = true;
    _save.bump();
  }

  Future<void> _flush() async {
    if (!mounted || !_dirty) return;
    // 载入失败 ⇒ 不回写（否则停留超过防抖窗口就会把空画布写回去，覆盖原文）。
    if (_loadFailed) {
      _dirty = false; // 清标记，避免反复空转
      return;
    }
    _dirty = false;
    await _notes.saveContent(
      widget.noteId,
      jsonEncode(_controller.toJson(media: _media)),
      plainText: '',
    );
  }

  /// 退出前落盘：**等到写完**再让窗口关（`_flush` 本身幂等——`_dirty` 保证没改动
  /// 就不写，所以"打开看一眼就关窗口"不会重写一遍）。
  ///
  /// ⚠️ 与 [dispose] 的兜底落盘分工不同：那条是 fire-and-forget（进程已经在走，
  /// 等也等不到结果），这条**能等**——"库确实写下去了"因此可被断言。
  Future<void> _flushForExit() async {
    _save.cancel();
    await _flush();
  }

  @override
  void dispose() {
    // 卸载兜底落盘（与块编辑器同节奏）：防抖窗口内切走笔记不会丢内容。
    //
    // ⚠️ **必须与 [_flush] 同一条写入路径**（`NotesNotifier.saveContent`）：
    // 此前这里直调 `_store.updateContent`，绕过 notesProvider 的 state 刷新，
    // 于是同一份数据有**两个写入者**——库里有新内容、列表快照仍是旧的，后续
    // 任何基于旧快照的保存都可能把这段时间的画布改动覆盖掉（2026-09-17 修正）。
    //
    // 统一之所以能成立，全靠 [_notes] 在 initState 就抓好：这里**不能**碰
    // widget 的 `ref`（Riverpod 直接抛 Bad state，见 [_notes] 的说明）。
    //
    // `catchError` 兜住"容器先于 widget 被拆除"（例如整棵树被替换）这一极端
    // 顺序：那时 notifier 已不可用，退回直写 store 保证最后一段编辑不丢
    // ——那种时刻列表已不存在，无需刷新 state。
    _exitFlush();
    _save.cancel();
    // `!_loadFailed`：与 [_onChanged] 同一道闸（双保险——这条路径一旦漏掉，
    // 用户丢的是整张画布）。
    if (_dirty && !_loadFailed) {
      final String content = jsonEncode(_controller.toJson(media: _media));
      unawaited(
        _notes
            .saveContent(widget.noteId, content, plainText: '')
            .catchError((Object _) {
              unawaited(
                _store.updateContent(widget.noteId, content, plainText: ''),
              );
            }),
      );
    }
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget surface = CanvasSurface(
      controller: _controller,
      media: _media,
    );
    // 载入失败必须**看得见**：自动保存已被冻结（见 [_loadFailed]），当前这张空白
    // 画布上的任何编辑都不会落库——不提示的话用户会以为一切正常，画完才发现白画。
    if (!_loadFailed) return surface;
    return Column(
      children: <Widget>[
        const _LoadFailedNotice(),
        Expanded(child: surface),
      ],
    );
  }
}

/// 画布「载入失败、已冻结保存」提示条。
///
/// 用 `errorContainer`（M3 的"严重但不打断"档）+ 图标，而不是一行小字提示：
/// 这条信息决定用户要不要继续在这张画布上画，必须一眼看到（2026-09-17 补）。
class _LoadFailedNotice extends StatelessWidget {
  const _LoadFailedNotice();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: Tokens.spaceMd,
        vertical: Tokens.spaceSm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            LucideIcons.triangleAlert300,
            size: Tokens.iconSm,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: Tokens.spaceSm),
          Expanded(
            child: Text(
              '这份画布的内容无法读取（格式异常），已暂停自动保存以保护原文。'
              '当前显示的是空白画布，在这里的编辑不会被保存。',
              style: TextStyle(
                color: scheme.onErrorContainer,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
