import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/embedding_client.dart';
import '../ai/llm_client.dart';
import '../data/answer_service.dart';
import '../data/database.dart';
import '../data/embedding_backend.dart';
import '../data/index_job.dart';
import '../data/retriever.dart';
import '../canvas/kernel/canvas_ai_cache.dart';
import '../canvas/kernel/canvas_media.dart';
import '../data/canvas_media_refs.dart';
import '../data/note_store.dart';
import '../data/settings_store.dart';
import '../domain/note.dart';
import '../domain/settings.dart';
import 'pending_saves.dart';

// ── 数据层符号的**转口** ─────────────────────────────────────────────
//
// `test/architecture/architecture_test.dart` 规定：只有 `main.dart` 与**本文件**
// 可以引用 `data/`（装配根 + 唯一 DI 点）。UI 要用到数据层的**类型**
// （`Answer` / `IndexProgress` …）时，就从这里出——否则每个 widget 都会为了一个
// 类型名去 import `data/`，越过 DI 且让账本烂掉。
export '../data/answer_service.dart' show Answer, Citation;
export '../data/index_job.dart'
    show IndexCancelToken, IndexJob, IndexProgress, IndexResult;

/// 笔记存储。实例在 main 里打开 DB 后通过 override 注入，全应用单例复用。
final noteStoreProvider = Provider<NoteStore>(
  (ref) => throw UnimplementedError('在 main 中 override 注入'),
);

/// 设置存储。与 [noteStoreProvider] 同源（同一个 DB 文件），
/// 同样在 main 里 override 注入。
final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => throw UnimplementedError('在 main 中 override 注入'),
);

/// 退出前落盘的登记处（视图挂载时登记、关窗口时统一等待，见 [PendingSaves]）。
///
/// 非 autoDispose：它是**应用级**设施，与容器同寿命——视图来去（切笔记）不该
/// 把登记处本身也带走，否则关窗口时就没有"谁还欠着一次落盘"的记录了。
final pendingSavesProvider = Provider<PendingSaves>(
  (Ref ref) => PendingSaves(),
);

/// 应用设置（外观 + 编辑器偏好）。
///
/// 用同步 [Notifier] 而非 AsyncNotifier：SQLite 是本地同步的，
/// build 里直接读完即可，不需要加载态——设置面板打开时必有值，
/// 也避免主题/编辑器在"等待异步"期间闪一下默认样式。
///
/// 每次改动即时落盘（设置项少，写入成本可忽略），
/// 且**所有消费方（主题、编辑器）watch 本 provider**——
/// 于是改设置时主界面在浮层背后实时重绘，即"实时预览"。
class SettingsNotifier extends Notifier<AppSettings> {
  SettingsStore get _store => ref.read(settingsStoreProvider);

  @override
  AppSettings build() => AppSettings.load(_store);

  void update(AppSettings value) {
    state = value;
    value.save(_store);
  }

  // ── 语义化快捷入口（面板只调这些，不直接拼 copyWith）──

  void setBrightnessMode(ThemeBrightnessMode mode) =>
      update(state.copyWith(brightnessMode: mode));

  void setWidthMode(EditorWidthMode mode) =>
      update(state.copyWith(widthMode: mode));

  void setFontSize(double size) => update(state.copyWith(fontSize: size));

  void setLineHeight(double height) =>
      update(state.copyWith(lineHeight: height));

  // ── AI（画布结构轨的推理后端）──
  //
  // 端点/模型**只在提交时**写（文本框回车或失焦），不是每敲一个字写一次：
  // `llmClientProvider` watch 着设置，逐字写会连带重建 LLM 客户端。

  void setAiEnabled(bool value) => update(state.copyWith(aiEnabled: value));

  /// 空串回落默认地址（清空输入框不该留下一个打不通的空端点）。
  void setAiEndpoint(String value) => update(
    state.copyWith(
      aiEndpoint: value.trim().isEmpty
          ? AppSettings.defaultAiEndpoint
          : value.trim(),
    ),
  );

  void setAiModel(String value) =>
      update(state.copyWith(aiModel: value.trim()));

  /// 嵌入模型名。与对话模型分开（见 [AppSettings.aiEmbeddingModel]）。
  void setAiEmbeddingModel(String value) =>
      update(state.copyWith(aiEmbeddingModel: value.trim()));

  /// 恢复默认（面板底部的"重置"）。
  void reset() => update(const AppSettings());
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

/// 当前选中的笔记 id（桌面双栏共用的唯一导航态）。
///
/// Riverpod 3 移除了 StateProvider（挪进 legacy 库），
/// 按新惯例迁移为显式的 Notifier。
class SelectedNoteNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

final selectedNoteIdProvider = NotifierProvider<SelectedNoteNotifier, String?>(
  SelectedNoteNotifier.new,
);

/// 左侧 [HubNav] 导航面板的折叠态（桌面双栏布局）。
///
/// 折叠后 [HomeScreen] 不再渲染 [HubNav]，整窗只留主区；顶条里的
/// 折叠/展开按钮（[NavCollapseButton]）切换它。默认展开。
class NavCollapsedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

final navCollapsedProvider = NotifierProvider<NavCollapsedNotifier, bool>(
  NavCollapsedNotifier.new,
);

/// 笔记列表（含增删改后自动刷新）。
final notesProvider = AsyncNotifierProvider<NotesNotifier, List<Note>>(
  NotesNotifier.new,
);

/// 应用数据根目录（`getApplicationSupportDirectory()` 的结果）。
///
/// ⚠️ **必须在 `main` 里解析一次并 override 注入**：媒体引用要用它做
/// 「绝对路径 ⇄ 相对引用」的换算，而那一步发生在**同步**的序列化里
/// （`toJson` / `fromJson`），那里拿不到 `Future`。
final appDataDirProvider = Provider<String>(
  (Ref ref) => throw UnimplementedError('在 main 中 override 注入'),
);

/// 打开好的数据库（`main` 里 open 后 override 注入）。
///
/// 检索/索引设施（[IndexJob] / [Retriever] / `LocalEmbeddingBackend`）都要裸
/// [Database]，而现有 provider 只暴露了 NoteStore / SettingsStore ⇒ 补这一个
/// 入口，免得各处从 store 里"借"连接（借来的连接迟早会有人拿它写业务 SQL）。
final appDatabaseProvider = Provider<AppDatabase>(
  (Ref ref) => throw UnimplementedError('在 main 中 override 注入'),
);

/// 裸连接：数据层设施的构造参数。
///
/// 类型靠推断（不写 `<Database>`）：显式写类型名就要 import `package:sqlite3`，
/// 而架构测试禁止数据层之外碰这个包（见 `test/architecture`）。
final databaseProvider = Provider(
  (Ref ref) => ref.watch(appDatabaseProvider).db,
);

/// 嵌入客户端（Ollama `/api/embed`）。设置一改就换实例（同 `llmClientProvider`）。
final embeddingClientProvider = Provider<EmbeddingClient>((Ref ref) {
  final AppSettings settings = ref.watch(settingsProvider);
  return OllamaEmbeddingClient(
    endpoint: settings.aiEndpoint,
    model: settings.aiEmbeddingModel,
  );
});

/// 本地嵌入后端；**不可用时返回 null** ⇒ 检索与索引自动降级为纯关键词
/// （6.4 的"降级而非不可用"在装配层的落点）。
///
/// 两道闸门缺一不可：
/// - 没填嵌入模型名 ⇒ 无从调用；
/// - 向量扩展没加载成功（native asset 缺席）⇒ `vec_chunks` 虽在也用不了。
EmbeddingBackend? embeddingBackendOrNull(Ref ref) {
  if (ref.watch(settingsProvider).aiEmbeddingModel.trim().isEmpty) return null;
  if (!AppDatabase.vectorExtensionAvailable) return null;
  return LocalEmbeddingBackend(
    db: ref.watch(databaseProvider),
    client: ref.watch(embeddingClientProvider),
  );
}

/// 「建立 / 更新索引」任务（增量、幂等、可取消）。
final indexJobProvider = Provider<IndexJob>(
  (Ref ref) => IndexJob(
    db: ref.watch(databaseProvider),
    backend: embeddingBackendOrNull(ref),
  ),
);

/// 混合检索（关键词 + 语义 → RRF 融合）。
final retrieverProvider = Provider<Retriever>(
  (Ref ref) => Retriever(
    db: ref.watch(databaseProvider),
    backend: embeddingBackendOrNull(ref),
  ),
);

/// 问答（检索 → 带编号资料 → 生成 → 引用还原）。
final answerServiceProvider = Provider<AnswerService>(
  (Ref ref) => AnswerService(
    retriever: ref.watch(retrieverProvider),
    llm: ref.watch(llmClientProvider),
  ),
);

/// 一次「要到哪里」的请求（`docs/ui_rewrite_plan.md` §4 的 `locateProvider` 载荷）。
///
/// `seq` 是**单调序号**：连着点同一条角标两次也必须能再跳一次——只比
/// `(noteId, blockId)` 的话，第二次是"状态没变"，Riverpod 不会通知监听者，
/// 用户看到的现象就是"第二次点击没反应"。
typedef LocateRequest = ({String noteId, String? blockId, bool focus, int seq});

/// 跳转的**唯一真相源**（`docs/ui_rewrite_plan.md` §4）。
///
/// ## 为什么要中转
/// 目标笔记往往**还没打开**，而滚动控制器与闪烁高亮都是编辑器的私有成员——
/// 调用方只能表达"想跳到哪"，由编辑器在自身就绪时消费（消费即置空，避免重开
/// 笔记时重复跳）。这一层把跳转从"每个入口各修一条路"收敛成一条。
///
/// ## ⚠️ 只有它写 [selectedNoteIdProvider]
/// 换笔记**就是**跳转。别处若也能直接 `select`，两条路会立刻分叉——表现为
/// "列表点了编辑器没反应"或"角标跳过去了、列表高亮还停在旧笔记"。这条不变式由
/// `test/architecture/architecture_test.dart` 的源码扫描钉住（不是靠自觉）。
class LocateNotifier extends Notifier<LocateRequest?> {
  int _seq = 0;

  @override
  LocateRequest? build() => null;

  /// 切到 [noteId]，可选定位到 [blockId]。
  ///
  /// [focus]：跳完让**编辑器**接管键盘（"跳过去就是要写/改"）。从列表点开一篇
  /// **不要**带它——那会把焦点从列表抢走，键盘上下选笔记就断了。
  void locate({required String noteId, String? blockId, bool focus = false}) {
    if (ref.read(selectedNoteIdProvider) != noteId) {
      ref.read(selectedNoteIdProvider.notifier).select(noteId);
    }
    state = (noteId: noteId, blockId: blockId, focus: focus, seq: ++_seq);
  }

  /// **回主页**（§5.6：切换，不是叠加）——清空选中与待消费的跳转请求。
  ///
  /// 放在这里而不是别处：**写 [selectedNoteIdProvider] 的只有本 Notifier**（架构测试
  /// 钉住，见本文件顶部的说明）。"回主页"也是一次跳转，不是"顺手把状态清掉"。
  void goHome() {
    ref.read(selectedNoteIdProvider.notifier).select(null);
    state = null;
  }

  /// 编辑器消费后置空（见类注释）。
  void consume() => state = null;
}

final locateProvider = NotifierProvider<LocateNotifier, LocateRequest?>(
  LocateNotifier.new,
);

/// 媒体引用解析器：文档只存相对引用，运行时经它换算成绝对路径。
///
/// 内核（`canvas_media.dart`）只定义接口，基准目录由这一层注入——于是内核仍与
/// `path_provider` / 平台无关，测试里可以塞一个临时目录。
final mediaResolverProvider = Provider<MediaResolver>(
  (Ref ref) => RelativeMediaResolver(ref.watch(appDataDirProvider)),
);

/// AI 生成结果缓存（内容寻址，见 `canvas_ai_cache.dart`）。
///
/// 全应用**单例**：跨画布笔记复用（命中率更高），且"会话内自动清理"只跑一次。
///
/// ⚠️ 这里必须提供引用保护：缓存文件**同时是文档的图片本体**
/// （`AiImageItem.src` 直接指向它），淘汰掉仍被引用的文件等于删用户的正文。
/// 内核读不到数据库，只能由这一层告知"哪些路径还在用"。
final aiResultCacheProvider = Provider<AiResultCache>((Ref ref) {
  final NoteStore store = ref.read(noteStoreProvider);
  final MediaResolver media = ref.read(mediaResolverProvider);
  final String dataDir = ref.read(appDataDirProvider);
  return AiResultCache(
    resolveDirectory: () async => '$dataDir${Platform.pathSeparator}ai_cache',
    protectedPaths: () => _referencedCanvasMedia(store, media),
  );
});

/// 扫出所有画布正文里引用到的媒体**绝对路径**（缓存淘汰的引用保护）。
///
/// 扫描逻辑本身是 [referencedCanvasMedia]（纯函数，可单测）；这一层只做装配：
/// 从 store 取画布正文、把相对引用按 [media] 换算成绝对路径。
/// 放在 DI 层的只有这两行"接线"，业务规则不再落在这里。
///
/// 直接解析 JSON 而不是正则匹配：路径里含 `\`，在 JSON 文本里是转义过的
/// `\\`，用文本匹配就得自己反解转义——解析一次反而更简单也更可靠。
/// 脏数据（旧格式/半截 JSON）静默跳过，引用扫描不值得为此抛错。
///
/// ⚠️ 必须经 [media] 换算：画布 JSON 存的是**相对引用**，而缓存文件是**绝对
/// 路径**；不做这一步，保护集就会与真实文件名对不上，淘汰可能删掉仍在用的图。
/// 同时读侧表与 items 并取并集——侧表是派生索引，但旧存档可能只有其中一侧。
Set<String> _referencedCanvasMedia(NoteStore store, MediaResolver media) =>
    referencedCanvasMedia(store.canvasContents(), toPath: media.toPath);

class NotesNotifier extends AsyncNotifier<List<Note>> {
  NoteStore get _store => ref.read(noteStoreProvider);

  @override
  Future<List<Note>> build() async => _store.allNotes();

  /// 等首次装载落地再改数据。
  ///
  /// ⚠️ 不加这一步就有**竞态**：`build()` 是异步的，若在它返回前就
  /// `createNote`/`deleteNote`，写好的 state 会被 build 的结果（旧快照）
  /// 覆盖——表现为"刚建的笔记不见了""删除读到空列表于是静默不删"。
  /// 冷启动后立刻点「新建」正好能撞上。
  Future<void> _settled() => future;

  Future<Note> createNote({NoteKind kind = NoteKind.spark}) async {
    await _settled();
    final Note n = _store.create(kind: kind);
    // 新笔记置顶。
    state = AsyncData(<Note>[n, ...state.value ?? <Note>[]]);
    return n;
  }

  /// **保存即索引**（关键词路）的**容错**外壳。
  ///
  /// ⚠️ 索引失败**绝不能连累落盘**：检索是**附属能力**（FTS 一时写不动、
  /// `databaseProvider` 未注入——测试与某些冷启动边缘都会这样），而"正文没存上"
  /// 是灾难。所以一律吞掉——索引缺席的后果只是"这篇暂时搜不到"，下次保存或
  /// 启动期的 `ensureKeywordIndex` 会补上。
  ///
  /// 与 `main.dart` 启动期回填、`Retriever.search` 的检索降级**同一条原则**：
  /// 检索侧的任何失败都不许影响主流程。
  void _indexKeywordPath(String id) {
    try {
      ref.read(indexJobProvider).indexNoteKeywordPath(id);
    } on Object catch (_) {
      // 静默：主流程（保存 / 恢复）已经落定，这里只是"少建了一份索引"。
    }
  }

  /// 保存正文（格式随当前编辑器，见 NoteDocumentAdapter）+ 纯文本，刷新列表。
  ///
  /// 哈希判变没写库时**直接跳过刷新**——连快照都不换，所有监听者零重建。
  /// 列表查询不含正文大字段（见 [NoteStore.allNotes]），写库后的重读很便宜。
  Future<void> saveContent(
    String id,
    String content, {
    required String plainText,
  }) async {
    final bool changed = await _store.updateContent(
      id,
      content,
      plainText: plainText,
    );
    if (changed) {
      state = AsyncData(_store.allNotes());
      // **保存即索引**（关键词路）：blocks 双写刚落定 ⇒ 立刻同步 FTS 行，
      // 保证"刚写完就能搜到"（全局搜索的底线，2026-09-25 用户定）。
      // 关键词路是纯 SQL、毫秒级；语义路仍走设置面板的手动索引（要模型）。
      // 走 [_indexKeywordPath]：索引失败不许连累这次保存。
      _indexKeywordPath(id);
    }
  }

  /// 保存标题并刷新列表（标题显示在列表条目上）。
  Future<void> saveTitle(String id, String title) async {
    await _store.updateTitle(id, title);
    state = AsyncData(_store.allNotes());
  }

  /// 删除一条笔记，返回被删的那条（供「撤销」用；id 不存在则 null）。
  ///
  /// 删的正好是当前打开的笔记时，自动选中列表里的**下一条**（原位置的
  /// 那条，没有则最后一条；列表空则回到空态）——比直接清空选中少一步操作。
  Future<Note?> deleteNote(String id) async {
    await _settled();
    final List<Note> before = state.value ?? <Note>[];
    final int index = before.indexWhere((Note n) => n.id == id);
    if (index < 0) return null;

    // 列表快照不背正文（见 [NoteStore.allNotes]），而「撤销删除」要**原样**
    // 写回——先按 id 取完整行（含正文）再删，否则撤销回来正文是空的。
    final Note? removed = _store.noteById(id);
    if (removed == null) return null;

    await _store.delete(id);
    final List<Note> rest = _store.allNotes();
    state = AsyncData(rest);

    if (ref.read(selectedNoteIdProvider) == id) {
      final String? next = rest.isEmpty
          ? null
          : rest[index.clamp(0, rest.length - 1)].id;
      if (next == null) {
        // 空列表不是"跳到哪里"，是"没地方可去"——`locate` 要求有个目标才成立，
        // 所以这一处直接清空（本文件就是 `locateProvider` 的家，不算另开一条路）。
        ref.read(selectedNoteIdProvider.notifier).select(null);
      } else {
        ref.read(locateProvider.notifier).locate(noteId: next);
      }
    }
    return removed;
  }

  /// 撤销删除：原 id / 时间戳原样写回，并跳回它。
  Future<void> restoreNote(Note note) async {
    await _store.restore(note);
    state = AsyncData(_store.allNotes());
    // 删除时清过它的 FTS 行 ⇒ 恢复后补回关键词索引（否则撤销回来的笔记
    // 内容搜不到）。同样走 [_indexKeywordPath]：不许连累这次恢复。
    _indexKeywordPath(note.id);
    // 不带 focus：撤销的入口在列表的 toast 上，用户的手还在列表那边。
    ref.read(locateProvider.notifier).locate(noteId: note.id);
  }

  /// 收藏 / 取消收藏（收藏项在列表里置顶，见 `NoteStore.allNotes`）。
  Future<void> togglePromoted(Note note) async {
    await _settled();
    await _store.setPromoted(note.id, note.promotedAt == null);
    state = AsyncData(_store.allNotes());
  }

  /// 保存标签并刷新列表。标签是整理元数据：不动 revised_at
  /// （见 [NoteStore.updateTags]），归一化也在 store 层做，这里透传。
  Future<void> saveTags(String id, List<String> tags) async {
    await _settled();
    await _store.updateTags(id, tags);
    state = AsyncData(_store.allNotes());
  }
}

/// LLM 通道（画布结构轨的推理后端）。
///
/// ## 为什么 watch 设置
/// 端点 / 模型都来自设置 ⇒ 用户改完立刻换**新**客户端，不会拿旧模型名继续打请求。
///
/// ## 为什么没配模型时不在这里抛
/// provider 被整棵树 watch，构造期抛异常会连带炸掉画布页面。未配置是个**可预期的
/// 使用状态**（AI 入口默认关闭），所以把它留给 `LlmClient.complete` 在调用时给出
/// 可操作的报错（"去设置里填模型名"）。
final llmClientProvider = Provider<LlmClient>((Ref ref) {
  final AppSettings settings = ref.watch(settingsProvider);
  return OllamaLlmClient(
    endpoint: settings.aiEndpoint,
    model: settings.aiModel,
  );
});
