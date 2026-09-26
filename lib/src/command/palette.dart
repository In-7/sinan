import 'dart:async';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';import 'package:material_ui/material_ui.dart';

import '../app/settings_panel.dart' show appNavigatorKey;
import '../theme/app_float_surface.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'command.dart';
import 'commands.dart';
import 'fuzzy.dart';
import 'registry.dart';

/// 面板宽度（�?.5 规格：顶部居中、宽 560）。与设置/问笔记同档—�?
/// 浮层族用同一个宽度，切面板时不觉得换了套 UI�?
const double _paletteWidth = 560;

/// 面板最大高度占窗口的比例（§3.5：最大高 60%）�?
const double _maxHeightFactor = 0.6;

/// 距窗口顶部的距离。太贴顶会与自绘标题栏（32）挤在一起，96 让面板落�?
/// 标题栏之下、视线自然落点上。不�?[Tokens]：它是本面板�?*摆放**参数�?
/// 不是通用几何（同 [settings_panel] �?`_panelWidth` 处理）�?
const double _topGap = 96;

/// 是否已打开。面板是**全局单例浮层**：连按两�?`Ctrl+Shift+P` 不该叠出两层
/// （叠了以�?Esc 只关掉最上面那层，看起来�?Esc 失灵"）�?
bool _open = false;

/// 打开命令面板（`docs/ui_rewrite_plan.md` §3.5）�?
///
/// 浮层范式�?ask/settings 完全一致（`OverlayEntry` + `appNavigatorKey` �?root
/// Overlay + `HardwareKeyboard` �?Esc）—�?*刻意不抽公共函数**：那三个面板�?
/// 关闭语义将来会分叉（面板�?关掉后回到原焦点"，模态框�?关掉即完�?），
/// 现在合并只会把分叉点埋进一个共享函数里�?
Future<void> showCommandPalette() {
  if (_open) return Future<void>.value();
  _open = true;

  final OverlayState overlay = appNavigatorKey.currentState!.overlay!;
  final Completer<void> closed = Completer<void>();
  OverlayEntry? entry;
  late final bool Function(KeyEvent event) handleEscKey;

  void close() {
    _open = false;
    if (!closed.isCompleted) closed.complete();
    if (entry != null && entry!.mounted) entry!.remove();
    entry = null;
    HardwareKeyboard.instance.removeHandler(handleEscKey);
  }

  handleEscKey = (KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      close();
    }
    return false;
  };
  HardwareKeyboard.instance.addHandler(handleEscKey);

  entry = OverlayEntry(
    builder: (BuildContext overlayContext) => Consumer(
      builder: (BuildContext context, WidgetRef ref, Widget? _) =>
          _PaletteOverlay(
            onClose: close,
            registry: ref.watch(commandRegistryProvider),
            commandContext: ref.watch(commandContextProvider),
          ),
    ),
  );
  overlay.insert(entry!);
  return closed.future;
}

/// 遮罩 + 定位�?*顶部居中**（�?.5）——不用居中，是因为面板紧贴输入起始位置，
/// 眼睛从窗口顶部往下扫的距离最短�?
class _PaletteOverlay extends StatelessWidget {
  const _PaletteOverlay({
    required this.onClose,
    required this.registry,
    required this.commandContext,
  });

  final VoidCallback onClose;
  final CommandRegistry registry;
  final CommandContext commandContext;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Stack(
      children: <Widget>[
        // 遮罩：点击关闭（卡片在其上层且吸收事件）。比设置面板淡——命令面板是
        // "顺手用一�?，不该把主界面压暗到需要重新适应�?
        Positioned.fill(
          child: GestureDetector(
            behavior: .opaque,
            onTap: onClose,
            child: ColoredBox(color: scheme.scrim.withValues(alpha: 0.18)),
          ),
        ),
        Positioned.fill(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: _topGap),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight:
                      MediaQuery.sizeOf(context).height * _maxHeightFactor,
                ),
                child: CommandPalette(
                  registry: registry,
                  commandContext: commandContext,
                  onClose: onClose,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 命令面板本体�?
///
/// ## 为什么它�?*�?widget**（不�?provider�?
/// 注册表与上下文由 [_PaletteOverlay] 传进�?�?单测可以直接塞一个假注册表来
/// 验证"过滤、置灰、执行、键位提�?这些**真规�?*，不必先搭出一�?ProviderScope
/// 与真数据库。能被造出来的状态就该让测试造得出来�?
///
/// ## 面板�?不需要记"的那条路
/// 它列**全部**命令——包括当前不可用的（灰显 + 说明），因为命令永不消失才是
/// 可发现性的来源（�?.1）。行右侧写着键位：于�?这个操作有没有快捷键"也在
/// 这里被发现（没键位的行明确写"无快捷键"）�?
///
/// ## 敲字不会重建编辑�?
/// 整个面板活在一�?[OverlayEntry] 里，过滤状态是它自己的 [State]；编辑器既不�?
/// 它的子树里、也�?watch 任何面板状态。列表用 `ListView.builder` +
/// `ValueKey(command.id)`，只有可见行会重建�?
class CommandPalette extends StatefulWidget {
  const CommandPalette({
    super.key,
    required this.registry,
    required this.commandContext,
    required this.onClose,
  });

  /// 命令来源�?
  final CommandRegistry registry;

  /// 判定可用性的上下文（§3.1）�?
  final CommandContext commandContext;

  final VoidCallback onClose;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  String _query = '';
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    // ↑↓ 走全局旁观者，而不�?`Shortcuts`：单行输入框�?EditableText �?*消费**
    // 方向键去移动光标，焦点树里的祖先节点根本收不到——这�?
    // `bindings.dart` �?分发器只能旁�?是同一�?SDK 事实（见那里的源码引文）�?
    HardwareKeyboard.instance.addHandler(_onNavigateKey);
    // 打开即聚焦：这个面板的唯一目的就是"打两个字然后回车"�?
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onNavigateKey);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _onNavigateKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    }
    return false; // 旁观，不消费（见 bindings.dart 的说明）
  }

  void _move(int delta) {
    final int count = _visible().length;
    if (count == 0) return;
    // 到边�?*停住**而不是回绕：回绕�?多按一�?会跳到列表另一端，选错目标�?
    setState(() => _selected = (_selected + delta).clamp(0, count - 1));
  }

  List<Command> _visible() {
    final List<Command> all = widget.registry.all;
    if (_query.trim().isEmpty) {
      // 空查询：�?§3.5 的排序规格（最近使�?�?分组 �?字母）里�?*后两�?*排�?
      // "最近使�?要等有会话级的使用记录再加——先不做半个（半做的排序会让
      // 顺序看起来随机，比固定顺序更糟）�?
      final List<Command> ordered = List<Command>.of(all)
        ..sort(
          (Command a, Command b) => a.group.index != b.group.index
              ? a.group.index.compareTo(b.group.index)
              : a.title.compareTo(b.title),
        );
      return ordered;
    }
    return matchCommands(all, _query);
  }

  void _onQueryChanged(String value) => setState(() {
    _query = value;
    // 过滤结果换了，旧的选中下标不再指向同一件事�?
    _selected = 0;
  });

  Future<void> _run(Command command) async {
    final CommandContext context = widget.commandContext;
    if (!command.isEnabled(context)) return; // 置灰项回�?= 什么都不发�?
    widget.onClose(); // 先关面板：命令要打开的东西不该被盖在下面
    await command.run(context);
  }

  void _runSelected() {
    final List<Command> visible = _visible();
    if (visible.isEmpty) return;
    final int index = _selected.clamp(0, visible.length - 1);
    unawaited(_run(visible[index]));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Command> visible = _visible();
    final int index = visible.isEmpty
        ? -1
        : _selected.clamp(0, visible.length - 1);

    // Esc �?*局部语�?*：面板里�?Esc = 关掉面板�?
    //
    // 这一层不是为了让 Esc 有用（那�?showCommandPalette 的全局旁观者干的），而是
    // 为了**填上 [DismissIntent]**：输入框里的 EditableText 收到 Esc 会去
    // `Actions.invoke(DismissIntent)` 收自己的触屏工具条，而本应用�?MaterialApp
    // （material_ui 实现）没有映射这�?Intent �?�?
    // "Unable to find an action for an Intent with type DismissIntent"
    // �?026-09-21 集成测试实测）。放在这里顺带把语义也说对了：在这个面板里，
    // "dismiss" 就是关掉它�?
    return Actions(
      actions: <Type, Action<Intent>>{
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (DismissIntent _) {
            widget.onClose();
            return null;
          },
        ),
      },
      // 焦点边界：Tab 不许漏到面板外（§5.2）。边界只能靠 `FocusScope`
      // （SDK：`_moveFocus` �?`nearestScope` 的子孙，走到末尾�?closedLoop 绕回
      // **本作用域**第一个），`FocusTraversalGroup` 只管顺序、圈不住�?
      // 放在**面板本体**里而不是外�?overlay：测试直接挂 `CommandPalette` 才测得到�?
      child: FocusScope(
        child: AppFloatSurface(
          width: _paletteWidth,
          child: Column(
            mainAxisSize: .min,
            crossAxisAlignment: .stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Tokens.spaceLg,
                  Tokens.spaceMd,
                  Tokens.spaceLg,
                  Tokens.spaceSm,
                ),
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  onChanged: _onQueryChanged,
                  // Enter 交给输入框：单行 TextField 会消�?Enter 并回调这里—�?
                  // 于是"回车执行"只有这一条路径，不会与旁观者重复触发�?
                  onSubmitted: (String _) => _runSelected(),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    hintText: '输入命令名（支持拼音首字母，�?xjbj�?,
                  ),
                ),
              ),
              Container(height: 1, color: theme.dividerColor),
              if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(Tokens.spaceLg),
                  child: Text(
                    '没有匹配的命�?,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(
                      vertical: Tokens.spaceXs,
                    ),
                    itemCount: visible.length,
                    itemBuilder: (BuildContext context, int i) {
                      final Command command = visible[i];
                      return _PaletteRow(
                        key: ValueKey<String>(command.id),
                        command: command,
                        enabled: command.isEnabled(widget.commandContext),
                        selected: i == index,
                        onTap: () => unawaited(_run(command)),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一行命令：图标 + 标题 + 说明/分组 + 右侧键位�?
class _PaletteRow extends StatelessWidget {
  const _PaletteRow({
    super.key,
    required this.command,
    required this.enabled,
    required this.selected,
    required this.onTap,
  });

  final Command command;
  final bool enabled;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color foreground = enabled
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: 0.38); // 置灰但仍可读
    // 说明（有则用）兼�?*置灰原因**：�?.1 要求说清"为什么不能用"�?
    // 而那句话在可用时也是有意义的说明——不为它再给模型加一个字段�?
    final String secondary = command.hint ?? _groupLabel(command.group);

    return InkWell(
      onTap: enabled ? onTap : null,
      child: Container(
        // 选中�?= 「当前项」的统一读法（�?.1）：中�?tint 底�?
        // **不在此画左指示条**：这一行的"选中"由键盘驱动、且要随 ↑↓ 高频移动�?
        // 条子会跟着闪；面板�?`w600` 也已由行标题承担区分。这是族内的合法例外
        // （与分段控件同理：形状上没有"左侧"可言）�?
        color: selected ? AppTheme.navSelectedTint(scheme.onSurface) : null,
        // 行高 �?13×1.4 + 2×4 �?26：Apple 口径的菜单行高（§9.2 的密度）�?
        // 之前�?spaceSm(8) �?34px，是 M3 触控档——在 560 宽的面板里显得松散�?
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceLg,
          vertical: Tokens.spaceXs,
        ),
        child: Row(
          children: <Widget>[
            _groupIcon(command.group),
            const SizedBox(width: Tokens.spaceMd),
            Expanded(
              child: Text(
                command.title,
                overflow: .ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
              ),
            ),
            const SizedBox(width: Tokens.spaceSm),
            Flexible(
              child: Text(
                secondary,
                overflow: .ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(
                    alpha: enabled ? 1 : 0.5,
                  ),
                ),
              ),
            ),
            const SizedBox(width: Tokens.spaceMd),
            Text(
              _keysLabel(command),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant.withValues(
                  alpha: enabled ? 1 : 0.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 键位提示�?*没有键位就明�?*—�?无快捷键"本身是信息（§3.5：键位的发现入口）�?
String _keysLabel(Command command) => command.keys.isEmpty
    ? '无快捷键'
    : command.keys.map((KeyBinding b) => b.label).join(' / ');

String _groupLabel(CommandGroup group) => switch (group) {
  CommandGroup.file => '文件',
  CommandGroup.edit => '编辑',
  CommandGroup.navigate => '导航',
  CommandGroup.view => '视图',
  CommandGroup.insert => '插入',
  CommandGroup.canvas => '画布',
  CommandGroup.ai => 'AI',
  CommandGroup.app => '应用',
};

/// 分组图标（复用仓库里已有�?Lucide 字形；`app` �?info 是因�?
/// `lucide_icons_flutter` 的这�?300 档里没有齿轮，等换图标族时一起处理）�?
Widget _groupIcon(CommandGroup group) => switch (group) {
  CommandGroup.file => const tabler.FileText(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
  CommandGroup.edit => const tabler.Edit(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
  CommandGroup.navigate => const tabler.List(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
  CommandGroup.view => const tabler.LayoutDashboard(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
  CommandGroup.insert => const tabler.Plus(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
  CommandGroup.canvas => const tabler.Pencil(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
  CommandGroup.ai => const tabler.Sparkles(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
  CommandGroup.app => const tabler.InfoCircle(height: Tokens.iconMd, width: Tokens.iconMd, strokeWidth: 1.5),
};
