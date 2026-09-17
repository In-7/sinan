
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../canvas/kernel/canvas_ai_cache.dart';
import '../canvas/kernel/canvas_media.dart';
import '../data/canvas_media_refs.dart';
import '../data/note_store.dart';
import '../data/settings_store.dart';
import '../domain/note.dart';
import '../domain/settings.dart';
import 'pending_saves.dart';

/// 笔记存储。实例在 main 里打开 DB 后通过 override 注入，全应用单例复用。
final noteStoreProvider =
    Provider<NoteStore>((ref) => throw UnimplementedError('在 main 中 override 注入'));

/// 设置存储。与 [noteStoreProvider] 同源（同一个 DB 文件），
/// 同样在 main 里 override 注入。
final settingsStoreProvider =
    Provider<SettingsStore>((ref) => throw UnimplementedError('在 main 中 override 注入'));

/// 退出前落盘的登记处（视图挂载时登记、关窗口时统一等待，见 [PendingSaves]）。
///
/// 非 autoDispose：它是**应用级**设施，与容器同寿命——视图来去（切笔记）不该
/// 把登记处本身也带走，否则关窗口时就没有"谁还欠着一次落盘"的记录了。
final pendingSavesProvider = Provider<PendingSaves>((Ref ref) => PendingSaves());

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

  /// 恢复默认（面板底部的"重置"）。
  void reset() => update(const AppSettings());
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

/// 当前选中的笔记 id（桌面双栏共用的唯一导航态）。
///
/// Riverpod 3 移除了 StateProvider（挪进 legacy 库），
/// 按新惯例迁移为显式的 Notifier。
class SelectedNoteNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

final selectedNoteIdProvider =
    NotifierProvider<SelectedNoteNotifier, String?>(SelectedNoteNotifier.new);

/// 笔记列表（含增删改后自动刷新）。
final notesProvider =
    AsyncNotifierProvider<NotesNotifier, List<Note>>(NotesNotifier.new);

/// 应用数据根目录（`getApplicationSupportDirectory()` 的结果）。
///
/// ⚠️ **必须在 `main` 里解析一次并 override 注入**：媒体引用要用它做
/// 「绝对路径 ⇄ 相对引用」的换算，而那一步发生在**同步**的序列化里
/// （`toJson` / `fromJson`），那里拿不到 `Future`。
final appDataDirProvider = Provider<String>(
  (Ref ref) => throw UnimplementedError('在 main 中 override 注入'),
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
    resolveDirectory: () async =>
        '$dataDir${Platform.pathSeparator}ai_cache',
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
    referencedCanvasMedia(
      store.canvasContents(),
      toPath: media.toPath,
    );

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

  /// 保存正文（格式随当前编辑器，见 NoteDocumentAdapter）+ 纯文本，刷新列表。
  ///
  /// 哈希判变没写库时**直接跳过刷新**——连快照都不换，所有监听者零重建。
  /// 列表查询不含正文大字段（见 [NoteStore.allNotes]），写库后的重读很便宜。
  Future<void> saveContent(
    String id,
    String content, {
    required String plainText,
  }) async {
    final bool changed =
        await _store.updateContent(id, content, plainText: plainText);
    if (changed) state = AsyncData(_store.allNotes());
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
      ref.read(selectedNoteIdProvider.notifier).select(next);
    }
    return removed;
  }

  /// 撤销删除：原 id / 时间戳原样写回，并重新选中它。
  Future<void> restoreNote(Note note) async {
    await _store.restore(note);
    state = AsyncData(_store.allNotes());
    ref.read(selectedNoteIdProvider.notifier).select(note.id);
  }

  /// 收藏 / 取消收藏（收藏项在列表里置顶，见 `NoteStore.allNotes`）。
  Future<void> togglePromoted(Note note) async {
    await _settled();
    await _store.setPromoted(note.id, note.promotedAt == null);
    state = AsyncData(_store.allNotes());
  }
}
