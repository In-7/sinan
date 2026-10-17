import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/embedding_client.dart';
import '../ai/llm_client.dart';
import '../data/answer_service.dart';
import '../data/database.dart';
import '../data/embedding_backend.dart';
import '../data/index_job.dart';
import '../data/markdown/md_mirror.dart';
import '../data/retriever.dart';
import '../canvas/kernel/canvas_ai_cache.dart';
import '../canvas/kernel/canvas_media.dart';
import '../data/canvas_media_refs.dart';
import '../data/note_store.dart';
import '../data/settings_store.dart';
import '../data/stream_store.dart';
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

  /// 主题种子（**0 = 中性默认档**，非 0 = 取自 `AppTheme.themePresets`）。
  /// 换它只让**底层**（环缝 / 标题条）跟着变；纸面 / 面板 / 内容保持中性。
  void setThemeSeed(int seed) => update(state.copyWith(themeSeed: seed));

  void setFontSize(double size) => update(state.copyWith(fontSize: size));

  void setLineHeight(double height) =>
      update(state.copyWith(lineHeight: height));

  // ── Markdown 镜像（单向导出到磁盘，见 `MdMirror`）──

  void setMarkdownMirrorEnabled(bool value) =>
      update(state.copyWith(markdownMirrorEnabled: value));

  /// 空串 = 用默认目录（应用数据目录下），**不是**"导出到根目录"。
  void setMarkdownMirrorDir(String value) =>
      update(state.copyWith(markdownMirrorDir: value.trim()));

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

/// 右侧常驻 **AI 问答轨**的开关态（桌面布局的第三列，见 [AskRail]）。
///
/// 它只表达"用户此刻想不想看到 AI 轨"，
/// 不关心 AI 以什么形态出现——宽窗（≥ `Tokens.askRailBreakpoint`）时 [HomeScreen]
/// 把它画成右侧常驻栏；窄窗放不下 ⇒ 降级为既有居中浮层（`showAskPanel`）。
/// 呈现选择归外壳，状态保持**单一真相源**，于是「命令 / 图标 / 自己的关闭钮 /
/// Esc」四条入口写的都是同一个布尔。
///
/// 默认关闭。再按一次 `Ctrl+J`（`ai.ask` 命令）或导航板 Sparkles 收起。
class AiPanelNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void open() => state = true;
  void close() => state = false;
  void toggle() => state = !state;
}

final aiPanelOpenProvider = NotifierProvider<AiPanelNotifier, bool>(
  AiPanelNotifier.new,
);

/// 卡内**列表列**的折叠态（手动档：标题栏最左折叠钮 / Ctrl+B 切它）。
///
/// 窄窗（< [Tokens.noteListBreakpoint]）另有**自动折**（见 [HomeScreen]）——最终显隐
/// = 窄窗 || 本布尔。默认展开（`false`）。
///
/// 标题栏折叠钮与 [HomeScreen] 的卡内列表列都读这一个布尔——单一真相源（同
/// [aiPanelOpenProvider] 口径）。暂不持久化，重启回展开态。
class ListCollapsedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

final listCollapsedProvider = NotifierProvider<ListCollapsedNotifier, bool>(
  ListCollapsedNotifier.new,
);

/// 笔记列表（含增删改后自动刷新）。
final notesProvider = AsyncNotifierProvider<NotesNotifier, List<Note>>(
  NotesNotifier.new,
);

/// 速记存储（心流收件箱）。独立表、独立 store，与笔记 / 画布无反向依赖。
final streamStoreProvider = Provider<StreamStore>(
  (Ref ref) => StreamStore(ref.watch(databaseProvider)),
);

/// 从笔记里的**速记引用**跳过来时要停在哪一条（`null` = 正常时间流）。
///
/// 引用块只知道 `ref_id`；心流页用这个 id 把列表临时收窄到那一条并给出
/// 「显示全部」出口——比"切过去然后自己往下翻"准确得多（没有滚动索引）。
class StreamFocusNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void focusOn(String id) => state = id;

  void clear() => state = null;
}

final streamFocusProvider = NotifierProvider<StreamFocusNotifier, String?>(
  StreamFocusNotifier.new,
);

/// **速记 / 心流**（2026-10-17 定：独立存储的单向捕获流）。
///
/// 只经 [StreamStore] 读写 `stream_items`：文库 / 搜索 / 日历 / Markdown 镜像
/// 都看不到它。条目只能**单向流出**（引用 / 复制到笔记、复制到画布、转新），
/// 由 UI 层 `stream_export.dart` 驱动。
class StreamNotifier extends AsyncNotifier<List<StreamItem>> {
  StreamStore get _store => ref.read(streamStoreProvider);

  /// 状态里**含归档**：界面要同时给出「待处理」与「已处理」两区，
  /// 只带 open 会让归档区永远为空（还得再查一次库）。
  @override
  Future<List<StreamItem>> build() async => _store.list(includeArchived: true);

  void _refresh() => state = AsyncData(_store.list(includeArchived: true));

  /// 录入一条（输入框回车 ⇒ 直接落库）。
  Future<void> add(String text) async {
    await future;
    _store.add(text);
    _refresh();
  }

  /// 改一条（卡片就地展开编辑）。⚠️ 不能叫 `update`——那与 Riverpod
  /// `Notifier.update`（改 state 的内建方法）撞名。
  Future<void> edit(String id, String text) async {
    await future;
    _store.update(id, text);
    _refresh();
  }

  /// 已处理 / 归档（不删，可回看）。
  Future<void> archive(String id) async {
    await future;
    _store.archive(id);
    _refresh();
  }

  /// 从归档拿回来。
  Future<void> unarchive(String id) async {
    await future;
    _store.unarchive(id);
    _refresh();
  }

  /// 真删。
  Future<void> remove(String id) async {
    await future;
    _store.remove(id);
    _refresh();
  }
}

final streamProvider = AsyncNotifierProvider<StreamNotifier, List<StreamItem>>(
  StreamNotifier.new,
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

// ── Markdown 镜像（单向导出）──────────────────────────────────────────────
//
// 权威永远是 `blocks` 表；磁盘上的 .md 只是**投影**（Obsidian 能直接打开）。
// 这里只有三件接线：引擎实例、实际目录、跑一轮的端口——规则都在 `MdMirror`。

/// 镜像引擎（保存后顺手导出单篇时用，跑在主 isolate 上——单篇很快）。
final markdownMirrorProvider = Provider<MdMirror>(
  (Ref ref) => MdMirror(ref.watch(databaseProvider)),
);

/// **实际**导出目录：用户没选过 ⇒ 应用数据目录下的 `markdown-mirror`。
///
/// 单一来源：设置面板显示它、导出用它。两处各自拼路径就会漂移（换目录后
/// "显示的是新目录，文件还写在旧目录"）。
final markdownMirrorDirProvider = Provider<String>((Ref ref) {
  final AppSettings settings = ref.watch(settingsProvider);
  return MdMirror.resolveDir(
    ref.watch(appDataDirProvider),
    settings.markdownMirrorDir,
  );
});

/// 「跑一轮导出」的端口：返回写出的篇数。
///
/// [all] = true 无视 `revised_at` 全量重写（换目录 / 用户点「立即导出」）；
/// 开关关着 ⇒ 恒 0，连目录都不解析。
typedef MirrorExportRun = Future<int> Function({bool all});

final markdownMirrorExportProvider = Provider<MirrorExportRun>((Ref ref) {
  final bool enabled = ref.watch(
    settingsProvider.select((AppSettings s) => s.markdownMirrorEnabled),
  );
  final String dir = ref.watch(markdownMirrorDirProvider);
  return ({bool all = false}) {
    if (!enabled) return Future<int>.value(0);
    // 库里路径**懒读**：开关关着时这条链一次都不该被碰（测试容器里
    // `appDatabaseProvider` 也未必注入）。
    //
    // 后台 isolate + 第二条连接：几千篇的解析与写盘不能卡住设置面板所在的
    // UI 线程（见 `MdMirror.exportPendingInBackground`）。
    return MdMirror.exportPendingInBackground(
      dbPath: ref.read(appDatabaseProvider).path,
      dir: dir,
      all: all,
    );
  };
});

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

/// 内容命中的 **app 层形状**（只留搜索核心用得到的三个字段）。
///
/// 架构边界：app 层不许 import `data/`（见 `architecture_test.dart` 白名单，
/// 只有本文件与 main.dart 合法），而搜索纯核心 [searchAllNotes] 又需要一条
/// "内容命中"来源。data 层的 [RetrievalHit] 在此裁一道，app 层就只依赖这个
/// record——检索实现怎么换，算法签名不动。
typedef ContentRetrievalHit = ({String noteId, String snippet, double score});

/// 一次内容检索的 app 层结果（降级原因照传：UI 当提示而非错误）。
typedef ContentRetrievalOutcome = ({
  List<ContentRetrievalHit> hits,
  String? vectorFallbackReason,
});

/// 内容检索端口：查询词 → 至多 [limit] 条命中。
typedef ContentRetriever = Future<ContentRetrievalOutcome> Function(
  String query, {
  int limit,
});

/// [retrieverProvider] 的 app 层适配器：把 data 层 [RetrievalResult] 裁成
/// [ContentRetrievalOutcome]。app 层一律读这个，不直接碰 [Retriever]。
final contentRetrieverProvider = Provider<ContentRetriever>(
  (Ref ref) => (String query, {int limit = 30}) async {
    final RetrievalResult result = await ref
        .read(retrieverProvider)
        .search(query, limit: limit);
    return (
      vectorFallbackReason: result.vectorFallbackReason,
      hits: <ContentRetrievalHit>[
        for (final RetrievalHit hit in result.hits)
          (noteId: hit.noteId, snippet: hit.snippet, score: hit.score),
      ],
    );
  },
);

/// 问答（检索 → 带编号资料 → 生成 → 引用还原）。
final answerServiceProvider = Provider<AnswerService>(
  (Ref ref) => AnswerService(
    retriever: ref.watch(retrieverProvider),
    llm: ref.watch(llmClientProvider),
  ),
);

// ── 统一导航历史（2026-09-30 用户定）────────────────────────────────────
//
// 「上一步 / 下一步」覆盖**所有**导航点击：主页视图切换**与**进入笔记 /
// 画布页一律入栈，严格按点击顺序进退。此前历史只记主页视图（编辑器不在栈
// 里），"进笔记后按上一步"因此失效。

/// 主页内的**视图**（顶栏 tab 的目的地）——只表达**投影**，不表达类型。
///
/// ⚠️ 2026-10-05 决策 E：原先的 `notes` / `canvas` 两值**已移除**。笔记 /
/// 画布答的是"它是什么"（类型），与"我怎么看"（投影）是两个维度，混进一排
/// tab 就是类别错误。类型现在走筛选器的「形态」facet（`home_hub.dart` 的
/// [NoteKindFacet]），三点溢出菜单随之退役。
///
/// ⚠️ 从 `home_hub.dart` 迁来（2026-09-30）：统一导航历史要同时表达"主页
/// 视图"与"某篇笔记页"两种目的地，而它必须与 `locateProvider` 同住本文件
/// （唯一获准写 `selectedNoteIdProvider` 的地方，见 architecture_test 的源码
/// 扫描）。视图的 `icon()` 扩展仍在 home_hub.dart——要引用 tabler /
/// CustomIcons，不进 DI 层。
enum HomeView {
  /// **心流**：按 `revisedAt` 分组的时间流（今天 / 昨天 / 本周…）。
  /// **启动默认视图**（2026-10-05 决策 C），也是最左图标轨第一枚。
  timeline('心流'),
  all('全部'),
  calendar('日历'),
  favorites('收藏');

  const HomeView(this.label);

  /// 图标导航轨 tooltip 上显示的名字（也是 a11y 标签与测试 find 的锚点）。
  final String label;
}

/// 统一导航历史的一个**目的地**：主页视图，或某篇笔记 / 画布页。
sealed class NavLocation {
  const NavLocation();
}

/// 主页视图目的地。
class HomeLocation extends NavLocation {
  const HomeLocation(this.view);

  final HomeView view;

  @override
  bool operator ==(Object other) => other is HomeLocation && other.view == view;

  @override
  int get hashCode => Object.hash(HomeLocation, view);

  @override
  String toString() => 'HomeLocation(${view.label})';
}

/// 笔记 / 画布页目的地。
class NoteLocation extends NavLocation {
  const NoteLocation(this.noteId);

  final String noteId;

  @override
  bool operator ==(Object other) =>
      other is NoteLocation && other.noteId == noteId;

  @override
  int get hashCode => Object.hash(NoteLocation, noteId);

  @override
  String toString() => 'NoteLocation($noteId)';
}

/// [navHistoryProvider] 的状态：当前主页视图 + 统一历史的可用态。
///
/// ⚠️ 两个 `canGo*` **必须住在 state 里**，不能做成 [NavHistoryNotifier] 的
/// 公开 getter——`riverpod_lint` 的 `avoid_public_notifier_properties` 钉的就是
/// 这条：读的一方靠 `ref.watch` 拿重建通知，而 watch 只跟 `state` 走。
class NavHistoryState {
  const NavHistoryState({
    required this.view,
    required this.canGoBack,
    required this.canGoForward,
  });

  /// 当前主页视图（在主页时的顶栏高亮 / 内容分发依据）。进编辑器后**保留
  /// 不动**，回主页时还原"上次停在哪个视图"。
  final HomeView view;

  /// 有上一个位置可退（主区顶条「上一步」的可用态）。
  final bool canGoBack;

  /// 有下一个位置可进（主区顶条「下一步」的可用态）。
  final bool canGoForward;
}

/// **统一导航历史**（两栈经典模型）。
///
/// 新导航（[NavHistoryNotifier.selectHome] / 经 [locateProvider] 进编辑器）把
/// 当前位置压入 back 并清空 forward；「上一步」「下一步」在两栈间搬移并落地
/// 目的地。目的地可以是主页视图，也可以是某篇笔记 / 画布页——所以"进笔记
/// 再按上一步"能回到进入前的地方，"退到一篇笔记"会重新打开它。
///
/// 放在本文件的原因：后退 / 前进的落点可能是一篇笔记，必须写
/// [selectedNoteIdProvider]，而本文件是唯一获准写它的地方（architecture_test
/// 的源码扫描钉住）。
class NavHistoryNotifier extends Notifier<NavHistoryState> {
  final List<NavLocation> _back = <NavLocation>[];
  final List<NavLocation> _forward = <NavLocation>[];

  @override
  NavHistoryState build() => const NavHistoryState(
    // 启动默认落「心流」（2026-10-05 决策 C）——与 [kHomeTabs] 首枚保持一致。
    view: HomeView.timeline,
    canGoBack: false,
    canGoForward: false,
  );

  /// 当前位置：在编辑器 = 该笔记 / 画布页；否则 = 主页当前视图。
  NavLocation get _current {
    final String? noteId = ref.read(selectedNoteIdProvider);
    if (noteId != null) return NoteLocation(noteId);
    return HomeLocation(state.view);
  }

  /// **导航发生前**的挂钩：把当前位置压入 back、清空 forward。
  ///
  /// 供 [LocateNotifier.locate]（进编辑器）这类"目的地不在本 Notifier"的入口
  /// 调用；连续落在同一位置的导航去重（不入重复栈项）。
  void recordBeforeNavigate() {
    final NavLocation loc = _current;
    if (_back.isNotEmpty && _back.last == loc) return;
    _back.add(loc);
    _forward.clear();
    _emit();
  }

  /// 切换主页视图（顶栏 tab / 三点菜单 / 主页钮）。在编辑器里调用会先退回主页。
  void selectHome(HomeView view) {
    final bool inEditor = ref.read(selectedNoteIdProvider) != null;
    if (!inEditor && view == state.view) return;
    recordBeforeNavigate();
    _exitToHome();
    _emit(view: view);
  }

  /// 回到上一个位置（「上一步」）。
  void goBack() {
    if (_back.isEmpty) return;
    _forward.add(_current);
    _apply(_back.removeLast());
  }

  /// 前进到下一个位置（「下一步」）。
  void goForward() {
    if (_forward.isEmpty) return;
    _back.add(_current);
    _apply(_forward.removeLast());
  }

  /// **回主页**（保持当前视图）。已在主页时不产生历史（无导航发生）。
  void goHome() {
    if (ref.read(selectedNoteIdProvider) == null) return;
    recordBeforeNavigate();
    _exitToHome();
    _emit();
  }

  /// 离开编辑器：清选中 + 作废待消费的跳转请求。
  void _exitToHome() {
    ref.read(selectedNoteIdProvider.notifier).select(null);
    ref.read(locateProvider.notifier).consume();
  }

  /// 落地一个历史目的地。
  void _apply(NavLocation loc) {
    switch (loc) {
      case HomeLocation(:final view):
        _exitToHome();
        _emit(view: view);
      case NoteLocation(:final noteId):
        // 笔记可能已被删（历史栈不随删除清理）——落空就回主页，不指向幽灵。
        final bool exists =
            ref.read(notesProvider).value?.any((Note n) => n.id == noteId) ??
            false;
        if (!exists) {
          _exitToHome();
          _emit();
          return;
        }
        ref.read(selectedNoteIdProvider.notifier).select(noteId);
        _emit();
    }
  }

  /// 落 state：`view` 给出时换视图（视图切换），否则保持；两个可用态跟着
  /// 两个栈一起算。
  void _emit({HomeView? view}) => state = NavHistoryState(
    view: view ?? state.view,
    canGoBack: _back.isNotEmpty,
    canGoForward: _forward.isNotEmpty,
  );
}

final navHistoryProvider =
    NotifierProvider<NavHistoryNotifier, NavHistoryState>(
      NavHistoryNotifier.new,
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
      // 换笔记 = 一次导航：先把当前位置记入统一历史（2026-09-30 用户定：
      // 进笔记 / 画布页也要能「上一步」回来）。
      ref.read(navHistoryProvider.notifier).recordBeforeNavigate();
      ref.read(selectedNoteIdProvider.notifier).select(noteId);
    }
    state = (noteId: noteId, blockId: blockId, focus: focus, seq: ++_seq);
  }

  /// 列表 **↑/↓ 预览选中**：换笔记但**不入导航历史**——连续浏览不该把前进/后退栈刷爆
  /// （每篇都记一步的话，`Alt+←` 得逐篇回退）。与 [locate] 同效用（都写
  /// [selectedNoteIdProvider]、同一条真相源），只差 [recordBeforeNavigate] 这一步。
  /// 不设跳转请求 state（不定位块、不抢焦点）——选中态变化自会驱动详情重绘。
  void preview({required String noteId}) {
    if (ref.read(selectedNoteIdProvider) != noteId) {
      ref.read(selectedNoteIdProvider.notifier).select(noteId);
    }
  }

  /// **回主页**（§5.6：切换，不是叠加）——清空选中与待消费的跳转请求。
  ///
  /// 放在这里而不是别处：**写 [selectedNoteIdProvider] 的只有本 Notifier**（架构测试
  /// 钉住，见本文件顶部的说明）。"回主页"也是一次跳转，不是"顺手把状态清掉"。
  void goHome() {
    // 统一走导航历史：在编辑器里 = 记录"这篇笔记"入栈后退回主页（保持当前
    // 视图）；已在主页则无导航发生（不入栈）。见 [NavHistoryNotifier.goHome]。
    ref.read(navHistoryProvider.notifier).goHome();
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

  /// **增量换行**：保存类操作改的只是**一条**笔记，没必要把整表重查一遍 +
  /// 全量 `Row → Note` 映射（万篇级约百毫秒，全卡在 UI 线程）。
  ///
  /// 只取这一行的**列表形态**最新值，替换进当前快照，再按 [allNotes] 的同一
  /// 排序（[NoteStore.compareForList]）重排——顺序与整表重查**逐字等价**。
  ///
  /// 兜底单向退回整表重查：快照尚未装载、或该行已不在快照（并发删除）时，
  /// 语义与旧路径完全一致，绝不弄丢 / 弄错一行。
  void _replaceRow(String id) {
    final List<Note>? before = state.value;
    final Note? updated = _store.noteListRow(id);
    if (updated == null) return; // 行不存在（已被删）：保持现状，等删除路径收敛
    final int at = before?.indexWhere((Note n) => n.id == id) ?? -1;
    if (before == null || at < 0) {
      state = AsyncData(_store.allNotes());
      return;
    }
    final List<Note> next = List<Note>.of(before)..[at] = updated;
    next.sort(NoteStore.compareForList);
    state = AsyncData(next);
  }

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

  /// Markdown 镜像：把**这一篇**同步到磁盘（单向导出，规则见 `MdMirror`）。
  ///
  /// 与 [_indexKeywordPath] 同一条原则：镜像只是附属品，任何失败都不许连累
  /// 落盘（磁盘满 / 文件被占用 ⇒ 下一轮扫描或下次保存再试）。开关关着时连
  /// 目录都不解析——`appDataDirProvider` 在某些测试容器里未必注入。
  void _mirrorOne(String id) {
    if (!_mirrorEnabled) return;
    try {
      ref
          .read(markdownMirrorProvider)
          .exportOne(id, dir: ref.read(markdownMirrorDirProvider));
    } on Object {
      // 静默：正文已经落库，镜像缺席的后果只是"磁盘上那份旧了一版"。
    }
  }

  /// 删笔记**之前**清镜像文件（`md_mirror` 账本行由外键 CASCADE 清，文件它管不到）。
  void _mirrorRemove(String id) {
    if (!_mirrorEnabled) return;
    try {
      ref.read(markdownMirrorProvider).removeForNote(id);
    } on Object {
      // 同上：删笔记才是主流程，文件删不掉属于"下次清理"。
    }
  }

  /// 镜像开关。**读不到设置就当作关**：本仓库有些测试容器只装了
  /// `noteStoreProvider`（不关心设置），而镜像是附属能力——它不该因为
  /// 装配不全把保存 / 删除这类主流程拖红（生产环境由 `main` 一定注入）。
  bool get _mirrorEnabled {
    try {
      return ref.read(settingsProvider).markdownMirrorEnabled;
    } on Object {
      return false;
    }
  }

  /// 保存正文（格式随当前编辑器，见 NoteDocumentAdapter）+ 纯文本，刷新列表。
  ///
  /// 哈希判变没写库时**直接跳过刷新**——连快照都不换，所有监听者零重建。
  /// 真改了则走 [_replaceRow] **增量换行**（只查这一行的列表形态并重排），
  /// 不再整表重查 + 全量映射（那是保存热路径上最贵的一段，见该方法注释）。
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
      _replaceRow(id);
      // **保存即索引**（关键词路）：blocks 双写刚落定 ⇒ 立刻同步 FTS 行，
      // 保证"刚写完就能搜到"（全局搜索的底线，2026-09-25 用户定）。
      // 关键词路是纯 SQL、毫秒级；语义路仍走设置面板的手动索引（要模型）。
      // 走 [_indexKeywordPath]：索引失败不许连累这次保存。
      _indexKeywordPath(id);
      // Markdown 镜像（单向导出）：正文变了就把磁盘那份重写一遍。
      _mirrorOne(id);
    }
  }

  /// 保存标题并刷新列表（标题显示在列表条目上）。
  Future<void> saveTitle(String id, String title) async {
    await _store.updateTitle(id, title);
    _replaceRow(id);
    // 标题变了 ⇒ 镜像文件名跟着变（旧文件由引擎自己删掉，等同改名）。
    // 注意这里**不看** revised_at：改标题不改"最近修改"，但文件必须搬。
    _mirrorOne(id);
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

    // 删之前先清镜像文件：`md_mirror` 行会被外键 CASCADE 掉，那之后就查不到
    // 路径了（文件它自己不会消失）。
    _mirrorRemove(id);
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
    // 删除时清掉过镜像文件 ⇒ 撤销回来要重新写一份（否则"文件跟着笔记一起消失"）。
    _mirrorOne(note.id);
    // 不带 focus：撤销的入口在列表的 toast 上，用户的手还在列表那边。
    ref.read(locateProvider.notifier).locate(noteId: note.id);
  }

  /// 收藏 / 取消收藏（收藏项在列表里置顶，见 `NoteStore.allNotes`）。
  Future<void> togglePromoted(Note note) async {
    await _settled();
    await _store.setPromoted(note.id, note.promotedAt == null);
    _replaceRow(note.id);
  }

  /// 保存标签并刷新列表。标签是整理元数据：不动 revised_at
  /// （见 [NoteStore.updateTags]），归一化也在 store 层做，这里透传。
  Future<void> saveTags(String id, List<String> tags) async {
    await _settled();
    await _store.updateTags(id, tags);
    _replaceRow(id);
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
