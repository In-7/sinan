import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/settings_panel.dart';
import '../domain/note.dart';
import 'command.dart';
import 'palette.dart';
import 'registry.dart';

/// 命令层的**装配**：上下文、作用域判据、注册表（`docs/ui_rewrite_plan.md` §3.2）。
///
/// ## 为什么这些 provider 不在 `app/providers.dart` 里
/// 依赖要保持**单向**：命令层 → `app/providers.dart`（唯一 DI 出口），反向不成立。
/// 若把注册表塞进 `providers.dart`，那个文件就得 import 命令层——循环导入，而且
/// `providers.dart` 会从"数据装配"膨胀成"什么都装"。数据层的规则没被绕过：
/// 命令层取数据一律经 `providers.dart`，从不直接 import `data/`（架构测试守着）。

/// 当前**命令上下文**：一切"能不能点"的依据（`docs/ui_rewrite_plan.md` §3.1）。
///
/// 只填**可观测**的部分。三个字段目前如实报默认值，原因是它们住在别人的私有状态里：
/// - `hasSelection` / `blockId`：编辑器选区在 vendored appflowy 的 `EditorState` 内，
///   应用侧没有订阅它的出口（要做需先给编辑器加一层可见的选区通知）；
/// - `hasCanvasSelection`：画布选中集在 `canvas_note_view` 的 controller 内，同理。
///
/// ⚠️ 不猜、不假装：填错会让依赖它们的命令**错误地可用**（比不可用更糟）。
/// 需要这些字段的命令，得先把对应状态的出口做出来——那是各自的活，不是这里的。
final commandContextProvider = Provider<CommandContext>((Ref ref) {
  final String? noteId = ref.watch(selectedNoteIdProvider);
  final List<Note> notes = ref.watch(notesProvider).value ?? const <Note>[];
  Note? current;
  for (final Note n in notes) {
    if (n.id == noteId) {
      current = n;
      break;
    }
  }
  return CommandContext(
    noteId: noteId,
    isCanvas: current?.kind == NoteKind.canvas,
  );
});

/// 当前活跃的**作用域**集合（[CommandRegistry.resolve] 的入参）。
///
/// 只放"能证明它活跃"的作用域：
/// - `global`：恒活跃；
/// - `note`：选了笔记才活跃（列表空态下"收藏"这类命令本就无从谈起）；
/// - `canvas`：当前笔记是画布笔记时活跃。
///
/// **刻意不含 `editor` / `overlay`**：二者都需要"焦点在哪"这个事实，而应用侧目前
/// 没有全局焦点跟踪。宁可少放一个作用域（表现为"该命令的快捷键暂时不生效"），
/// 也不能凭猜放行——那会让"编辑器内 Ctrl+B 是加粗"这类同键不同义的约定失效。
/// 将来加编辑器级命令时，先把焦点/模式出口做出来再往这里加。
final activeCommandScopesProvider = Provider<Set<CommandScope>>((Ref ref) {
  final CommandContext context = ref.watch(commandContextProvider);
  return <CommandScope>{
    CommandScope.global,
    if (context.hasNote) CommandScope.note,
    if (context.isCanvas) CommandScope.canvas,
  };
});

/// 命令注册表：**一处定义，四处消费**（快捷键 / 面板 / 右键菜单 / 工具条）。
final commandRegistryProvider = Provider<CommandRegistry>(
  (Ref ref) => CommandRegistry(buildCommands(ref)),
);

/// 按 id 执行一条命令。
///
/// UI 按钮与快捷键**共用这一条路**：命令层是权威面（§3.2），按钮若各自留一份实现，
/// 迟早与命令漂移（"按钮能新建、快捷键不能"或者反之）。
Future<void> runCommandById(WidgetRef ref, String id) async {
  final Command? command = ref.read(commandRegistryProvider).byId(id);
  if (command == null) return;
  final CommandContext context = ref.read(commandContextProvider);
  if (!command.isEnabled(context)) return;
  await command.run(context);
}

/// 注册表内容。键位全部落在 §3.4 划出的**空闲区**——有元测试钉住
/// （`test/command/command_meta_test.dart`），因为重复占用编辑器的键是静默故障。
List<Command> buildCommands(Ref ref) => <Command>[
  // ── 文件 ──────────────────────────────────────────────────────────────
  Command(
    id: 'note.new',
    title: '新建笔记',
    group: CommandGroup.file,
    scope: CommandScope.global,
    keys: <KeyBinding>[
      const KeyBinding(key: LogicalKeyboardKey.keyN, control: true),
    ],
    run: (CommandContext _) => runCreateNote(ref, NoteKind.spark),
  ),
  Command(
    id: 'canvas.new',
    title: '新建画布',
    group: CommandGroup.file,
    scope: CommandScope.global,
    keys: <KeyBinding>[
      const KeyBinding(
        key: LogicalKeyboardKey.keyN,
        control: true,
        shift: true,
      ),
    ],
    run: (CommandContext _) => runCreateNote(ref, NoteKind.canvas),
  ),
  Command(
    id: 'note.promote',
    title: '收藏 / 取消收藏',
    // 兼作**置灰原因**（§3.1 要求说明"为什么不可用"）：模型里不为它多加字段，
    // 因为这句话在可用时也是有意义的说明。
    hint: '先在列表里选一篇笔记',
    group: CommandGroup.file,
    // 作用域取默认的 `note`（这条命令的语义就是"对当前笔记做点什么"，判据见
    // activeCommandScopesProvider）。
    // 无键位：面板行会显示"无快捷键"，这正是键位的**发现入口**（§3.5）。
    enabled: (CommandContext c) => c.hasNote,
    run: (CommandContext c) async {
      final String? id = c.noteId;
      if (id == null) return;
      final List<Note> notes = ref.read(notesProvider).value ?? const <Note>[];
      for (final Note n in notes) {
        if (n.id == id) {
          await ref.read(notesProvider.notifier).togglePromoted(n);
          return;
        }
      }
    },
  ),

  // ── 应用 ──────────────────────────────────────────────────────────────
  Command(
    id: 'palette.open',
    title: '命令面板',
    hint: '搜索并执行命令',
    group: CommandGroup.app,
    scope: CommandScope.global,
    keys: <KeyBinding>[
      const KeyBinding(
        key: LogicalKeyboardKey.keyP,
        control: true,
        shift: true,
      ),
    ],
    run: (CommandContext _) => showCommandPalette(),
  ),
  Command(
    id: 'app.settings',
    title: '设置',
    group: CommandGroup.app,
    scope: CommandScope.global,
    keys: <KeyBinding>[
      const KeyBinding(key: LogicalKeyboardKey.comma, control: true),
    ],
    run: (CommandContext _) => showSettingsPanel(),
  ),
];

/// 新建笔记并选中它（`note.new` / `canvas.new` 共用）。
///
/// 选中新笔记这一步不能省：不选中的话，用户按了 Ctrl+N 只看到列表多一条，
/// 光标还在原处——"新建"的心理预期是**立刻开始写**。
Future<void> runCreateNote(Ref ref, NoteKind kind) async {
  final Note note = await ref
      .read(notesProvider.notifier)
      .createNote(kind: kind);
  // 经 `locateProvider` 而不是直接写选中态（§4：换笔记就是跳转，只此一条路）。
  // `focus: true`：新建之后就该能直接打字——这正是"新建"的心理预期。
  ref.read(locateProvider.notifier).locate(noteId: note.id, focus: true);
}
