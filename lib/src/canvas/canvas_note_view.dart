import 'dart:async';
import 'dart:ui' as ui;
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';import 'package:material_ui/material_ui.dart';

import '../ai/llm_client.dart';
import '../app/providers.dart';
import '../app/save_debounce.dart';
import '../data/note_store.dart';
import '../domain/block_hit.dart';
import '../theme/tokens.dart';
import 'ai/ai_prompt.dart';
import 'ai/ai_run.dart';
import 'canvas_import.dart';
import 'canvas_surface.dart';
import 'card_text_sync.dart';
import 'kernel/canvas_ai.dart';
import 'kernel/canvas_ai_cache.dart';
import 'kernel/canvas_bundle.dart';
import 'kernel/canvas_controller.dart';
import 'kernel/canvas_item.dart';
import 'kernel/canvas_media.dart';

/// 一次 AI 指令喂给模型的候选块上限。
///
/// 12 是个经验值：再多会挤占上下文（本地小模型对长上下文明显变笨），
/// 再少则在"帮我找相关的块"这类指令上召回不足。
const int _aiCandidateLimit = 12;

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
  const CanvasNoteView({
    super.key,
    required this.noteId,
    this.pickBundleText = pickCanvasBundleText,
  });

  final String noteId;

  /// 取一份 `.canvas.json` 的**文本**（用户取消返回 null）。
  ///
  /// 抽成可注入的点：真实实现要弹文件对话框，测试塞个"直接返回文本"的替身就能把
  /// 导入链路（确认 → 还原 → 换文档 → 落盘）整条测完。同 `NoteSaver.isolateEncode`
  /// 那类钩子。
  final Future<String?> Function() pickBundleText;

  @override
  ConsumerState<CanvasNoteView> createState() => _CanvasNoteViewState();
}

class _CanvasNoteViewState extends ConsumerState<CanvasNoteView>
    with WidgetsBindingObserver {
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

  /// 当前文档的控制器。**非 final**：导入 `.canvas.json` 时整体换一份
  /// （见 [_adoptController]）。
  late CanvasController _controller;

  /// 落盘调度：一停手 600ms 就落盘，**连续运笔不停手时最迟 2s 也必落一次**
  /// （[SaveDebounce] 的硬上界——纯防抖在不停笔的情况下会一直不落盘）。
  late final SaveDebounce _save = SaveDebounce(
    window: const Duration(milliseconds: 600),
    maxWait: kSaveMaxWait,
    onFlush: () => unawaited(_flush()),
  );

  /// 自上次落盘以来是否有改动（避免无改动也写一遍）。
  bool _dirty = false;

  /// 引用卡片「已与库同步」的文本基线（`blockId` → 文本）。
  ///
  /// 双链多视图（#5）用：卡片文本的真身在 `blocks`，画布内存里那份只是**快照**。
  /// 基线让"内存与库不一致"这件事可分两种：
  /// - `text == 基线` ⇒ 是**别人改的**（文档侧编辑、另一个视图）⇒ 该拉新；
  /// - `text != 基线` ⇒ 是**用户在这张画布上改了、还没落盘** ⇒ 该保留。
  ///
  /// 少了它只能二选一：要么回写旧值吃掉文档侧的修改，要么拉新时抹掉用户刚敲的字。
  final Map<String, String> _syncedCardTexts = <String, String>{};

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
    WidgetsBinding.instance.addObserver(this);
    _store = ref.read(noteStoreProvider);
    _notes = ref.read(notesProvider.notifier);
    _controller = _createController();
    // 载入时的文本就是"与库一致"的基线（见 [_syncedCardTexts]）。
    _rememberSyncedCardTexts();
    _controller.addListener(_onChanged);
    // 登记"关窗口时把防抖里还没写下去的画布写完"（见 [PendingSaves]）。
    _exitFlush = ref.read(pendingSavesProvider).register(_flushForExit);
  }

  /// 从 `notes.content` 还原控制器；内容为空（新画布）/ 解析失败时给一张空画布。
  CanvasController _createController() {
    // 双链多视图（#5）：卡片文本的真身在 `blocks`，画布 JSON 里的 `text` 只是
    // **上次保存的快照**。文档侧改了被引用的块之后，这里先把快照刷新回来 ——
    // 否则打开画布看到的还是旧文本（有变化才落盘，见 [NoteStore.syncCanvasCardTexts]）。
    _store.syncCanvasCardTexts(widget.noteId);
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
      final Object? decoded = jsonDecode(text);
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
    // 双链多视图（#5）：**落笔之前**先把没被本地编辑过的引用卡片拉到 `blocks`
    // 的最新值。少了这一步，并看文档 + 画布时这里会把旧快照写回去，把文档侧的
    // 修改吃掉（见 [_pullCardTextsFromStore]）。
    _pullCardTextsFromStore();
    final String content = jsonEncode(_controller.toJson(media: _media));
    // 这份 content 就是即将落盘的内容（含本地刚改的那些）⇒ 记成新基线。
    _rememberSyncedCardTexts();
    await _notes.saveContent(widget.noteId, content, plainText: '');
  }

  /// 把**引用卡片**的文本拉到 `blocks` 的最新值（双链多视图 #5）。
  ///
  /// 只动"本地没改过"的卡片（`text == 基线`）：与库不一致说明是**别人改的**
  /// （文档侧编辑，或另一个视图），该拉新；本地改过、还没落盘的卡片一律跳过
  /// —— 那是用户的输入，不能被库里的旧值盖掉，落盘时由 `_replaceCardBlocks`
  /// 写回真身。
  ///
  /// 返回是否有卡片被更新（调用方据此重绘 / 安排落盘）。
  bool _pullCardTextsFromStore() {
    bool changed = false;
    for (final CanvasItem item in _controller.document.items) {
      if (item is! CardItem) continue;
      final String? next = pullCardText(
        current: item.text,
        baseline: _syncedCardTexts[item.blockId],
        latest: _store.blockText(item.blockId),
      );
      if (next == null) continue;
      item.text = next;
      changed = true;
    }
    if (changed && mounted) setState(() {});
    return changed;
  }

  /// 把当前卡片文本记成"已与库同步"的基线（载入后 / 落盘后调）。
  void _rememberSyncedCardTexts() {
    for (final CanvasItem item in _controller.document.items) {
      if (item is CardItem) _syncedCardTexts[item.blockId] = item.text;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从别的窗口 / 应用切回来：引用卡片可能已被文档侧改过，拉一次最新的。
    //
    // ⚠️ 这管的是**应用之间**的切换；应用内切标签页收不到这个信号 —— 标签页
    // 系统在激活画布那一页时调同一条路径即可（【落盘前拉新】那道闸是两种情形
    // 共用的兜底，所以即使这里漏了也不会写坏数据，只是"要等一次保存才刷新"）。
    if (state != AppLifecycleState.resumed) return;
    if (_pullCardTextsFromStore()) {
      _dirty = true;
      _save.bump();
    }
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
        _notes.saveContent(widget.noteId, content, plainText: '').catchError((
          Object _,
        ) {
          // 兜底链的**链尾**：到这里再失败就只剩放弃（进程正在退出 / 库已关），
          // 但**不能让异常漏出去** —— `unawaited` 不等于吞掉异常，它会冒成
          // "unhandled exception"，在测试里还会算到**相邻用例**头上
          // （2026-09-18 实测：画布用例漏出的这条把后面的块编辑器用例判红了）。
          //
          // ⚠️ `updateContent` 返回 `Future<bool>` ⇒ `catchError` 的回调必须回 bool。
          unawaited(
            _store
                .updateContent(widget.noteId, content, plainText: '')
                .catchError((Object _) => false),
          );
        }),
      );
    }
    _controller.removeListener(_onChanged);
    _controller.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 导入 `.canvas.json`：**替换**当前画布。
  ///
  /// 顺序刻意是「先问、后选、再换」：替换是破坏性的（当前内容随后会被覆盖保存），
  /// 先确认再让用户去挑文件，免得挑完才发现要覆盖、白挑一次。
  ///
  /// 语义是**换一份文档**而不是合并：撤销历史随旧文档一起丢掉——确认框里把这一点
  /// 明说了（"保护数据的取舍必须可见告知"，同画布载入失败那条）。
  Future<void> _import(BuildContext context) async {
    // async gap 之前取出 messenger（同 _export / _insertImage）。
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool confirmed = await _confirmReplace(context) ?? false;
    if (!confirmed || !mounted) return;
    try {
      final String? text = await widget.pickBundleText();
      if (text == null) return; // 用户取消
      final CanvasController imported = await importCanvasBundleText(
        text,
        media: _media,
        generator: _generator,
      );
      if (!mounted) {
        imported.dispose();
        return;
      }
      _adoptController(imported);
      messenger.showSnackBar(const SnackBar(content: Text('已导入画布文件')));
    } on Object catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  /// 换掉当前控制器（导入用）：重新接线监听 + 标记待落盘。
  ///
  /// ⚠️ **必须置脏并排一次落盘**：否则这份导入的文档只活在内存里，退出/切笔记时
  /// 会被丢弃；更糟的是防抖若正挂着，写回去的是**换掉前**的内容。
  void _adoptController(CanvasController next) {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _controller = next;
    _controller.addListener(_onChanged);
    // 新文档是**解析成功**的：载入失败的冻结闸必须解开，否则退出前落盘会被跳过。
    _loadFailed = false;
    // 导入进来的文本即新基线（见 [_syncedCardTexts]）。
    _rememberSyncedCardTexts();
    _onChanged();
    setState(() {});
  }

  /// 替换画布的确认框（破坏性动作必须先告知，见 [_import]）。
  Future<bool?> _confirmReplace(BuildContext context) => showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: const Text('导入画布文件'),
      content: const Text('导入会替换当前画布的内容，且替换后无法再撤销回原内容。继续吗？'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('导入'),
        ),
      ],
    ),
  );

  /// 跑一次 AI 指令（画布结构轨）。
  ///
  /// 宿主在这里做三件**内核不该知道**的事（内核既拿不到块库，也不该碰 UI）：
  /// ① 用指令去**全库搜块** —— 搜索结果就是模型可引用的**白名单**；
  /// ② 提供块文本（`reference_block` 造卡片要全文，不是截断过的标签）；
  /// ③ 把结果说给用户听：改了几处、忽略了什么、以及**一次撤销**。
  Future<void> _runAi(String instruction) async {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    if (ref.read(settingsProvider).aiModel.trim().isEmpty) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('还没配置模型：到「设置 → AI」填写模型名')),
      );
      return;
    }

    // 候选块用**指令本身**搜（Roam 式一级扁平搜索）：用户说"番茄"，最相关的块
    // 自己浮上来，不需要他先去挑。搜不到也不阻止运行（可能是纯画布操作）。
    final List<BlockHit> hits = _store.searchBlocks(
      instruction,
      limit: _aiCandidateLimit,
    );
    final Map<String, String> candidates = <String, String>{
      for (final BlockHit hit in hits)
        hit.blockId: '「${hit.noteTitle}」${oneLine(hit.text)}',
    };

    final Rect viewportWorld = _controller.camera.visibleWorld(
      _controller.viewport,
    );
    try {
      final AiRunOutcome outcome = await runCanvasAi(
        llm: ref.read(llmClientProvider),
        document: _controller.document,
        viewportWorld: viewportWorld,
        instruction: instruction,
        candidateBlocks: candidates,
        blockTextOf: _store.blockText,
      );
      if (!mounted) return;
      if (outcome.created.isNotEmpty) {
        // 落地即选中：用户一眼看到"AI 动了哪些东西"（顺带把它们钉成全保真，
        // 见 `ItemPainter.pinnedIds`）。
        _controller.selectItems(outcome.created);
      }
      _controller.requestRepaint();
      _reportAi(messenger, outcome);
    } on LlmUnavailableException catch (e) {
      if (mounted) messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    } on LlmResponseException catch (e) {
      if (mounted) {
        messenger?.showSnackBar(SnackBar(content: Text('模型返回异常：${e.message}')));
      }
    }
  }

  /// 把一轮结果说给用户听（成功 / 空结果两种口径）。
  ///
  /// ⚠️ 成功时**必须**带「撤销」按钮：AI 的改动是一整批，用户可能只想回退这一步
  /// （撤销栈里也只有这一条，见 `CanvasDocument.batch`）。
  void _reportAi(ScaffoldMessengerState? messenger, AiRunOutcome outcome) {
    if (outcome.applied == 0) {
      final String why = outcome.warnings.isEmpty
          ? '这句话没有产生任何改动'
          : '没有产生改动：${outcome.warnings.first}';
      messenger?.showSnackBar(SnackBar(content: Text(why)));
      return;
    }
    final String ignored = outcome.warnings.isEmpty
        ? ''
        : '（忽略了 ${outcome.warnings.length} 条，见日志）';
    for (final String w in outcome.warnings) {
      debugPrint('[canvas-ai] $w');
    }
    messenger?.showSnackBar(
      SnackBar(
        content: Text('已应用 ${outcome.applied} 处改动$ignored'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () {
            _controller.document.undo();
            _controller.requestRepaint();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget surface = CanvasSurface(
      controller: _controller,
      media: _media,
      onImport: () => _import(context),
      // 默认关闭（见 `AppSettings.aiEnabled`）：要用户去设置里显式开启，
      // 因为没起 Ollama 时露出入口只会让他点出一个报错。
      // watch 设置 ⇒ 在设置面板里一开，工具条上立刻出现。
      onAiRun: ref.watch(settingsProvider).aiEnabled ? _runAi : null,
      // 块可迁移（#5）：把画布卡片发回它所属的文档。卡片的内存摘除在控制器里完成
      // （detachSelectedCard），这里只负责把块真正落进文档块树（同步写库）。
      onSendCardToDocument: (String blockId) {
        // 双链多视图的**引用卡片**（块本来就在文档树里）⇒ `moveBlockToDocument`
        // 幂等返回 false。那种情况下这一步的真实语义就是"从画布移除引用"，
        // 得说清楚，否则用户会以为"发回"失败了。
        final bool moved = _store.moveBlockToDocument(blockId);
        if (!moved && mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('这张卡片的内容本来就在文档里，已从画布移除')),
          );
        }
      },
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
          tabler.AlertTriangle(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5, colorFilter: ui.ColorFilter.mode(scheme.onErrorContainer, ui.BlendMode.srcIn)),
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
