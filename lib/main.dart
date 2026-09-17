import 'dart:async';

import 'dart:io' show Directory, Platform;
import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:appflowy_editor/appflowy_editor.dart'
    show AppFlowyEditorLocalizations;
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app/home_screen.dart';
import 'src/app/pending_saves.dart';
import 'src/app/settings_panel.dart';
import 'src/data/database.dart';
import 'src/data/note_store.dart';
import 'src/data/settings_store.dart';
import 'src/domain/settings.dart';
import 'src/editor/core/editor_icons.dart';
import 'src/app/providers.dart';
import 'src/theme/app_theme.dart';
import 'src/window/window_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 编辑器图标统一为 Lucide：官方工具栏/斜杠菜单/图片工具条的图标是包内 SVG，
  // 这里注册映射让它们走 Lucide 字形（vendored 侧的钩子见
  // third_party/appflowy_editor/PATCHES.md 补丁 4）。未登记的名字自动回落 SVG。
  installLucideEditorIcons();
  // 全局未捕获异步异常拦截：默认 console 对 uncaught async error 的
  // 输出可能缺调用栈——这里打印完整 stack，用于定位偶发异常
  // （如对 ""/"=" 做 int.parse 的 FormatException 来源）。
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('未捕获异步异常: $error');
    debugPrint(stack.toString());
    return true;
  };
  // 移动端 / Web 上会自动跳过，不会崩。
  await WindowService.init();

  final AppDatabase db = await AppDatabase.open();

  // 应用数据根目录：画布的媒体引用要拿它做「绝对 ⇄ 相对」换算，而那发生在同步
  // 的序列化里（拿不到 Future），所以在这里解析一次、注入成常量。
  // 目录本身与 [AppDatabase.open] 用的是同一个（path_provider 内部会缓存）。
  final Directory supportDir = await getApplicationSupportDirectory();

  runApp(
    ProviderScope(
      overrides: [
        // DB 只打开一次，整应用复用同一个连接。
        noteStoreProvider.overrideWithValue(NoteStore(db.db)),
        settingsStoreProvider.overrideWithValue(SettingsStore(db.db)),
        // 媒体引用的基准目录（画布 JSON 只存相对引用，靠它换算成绝对路径）。
        appDataDirProvider.overrideWithValue(supportDir.path),
      ],
      child: const MainApp(),
    ),
  );

  // 材质的应用时机移到 MainApp（initState 的 postFrame）：首次应用
  // 需要知道用户设置的明暗模式（settingsProvider），而 provider 在
  // ProviderScope 内才可读。

  // 块表回填（迁移第 3 步）：把存量笔记的块树补进 blocks。
  //
  // ⚠️ **必须在首帧之后**：它是**同步**的 SQLite 工作，放在 `runApp` 之前会
  // 同步卡住首帧——旧注释写的"在 runApp 之前但不阻塞首帧"是错的，同步调用
  // 必然推迟首帧。实测冷启动到首帧 1.18s，其中 ~76%（897ms）在 `runApp` 之前。
  //
  // 挪到首帧后**是安全的**：`NoteStore.noteById` 在 blocks 缺失时会回退到旧的
  // content 列（`rebuilt ?? legacy`），本轮还没轮到的笔记照常能打开；量由
  // `backfillBlocks` 的 limit 封顶（50 篇/次），未做完下次启动接着来。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    try {
      final NoteStore store = NoteStore(db.db);
      store.backfillBlocks();
      // 画布落点的回填（五步纪律第 2 步，见 docs/canvas_architecture.md 第七章）：
      // 把存量画布的 JSON 拆进 canvas_items / canvas_meta / ink_shards。
      // 与块回填同一节奏：同步 SQLite、**只写不读**（画布仍从 notes.content 读）、
      // 50 篇/次可续跑；失败也不影响使用——写路径的双写会把这幅补齐。
      store.backfillCanvas();
    } on Object catch (_) {
      // 回填失败不影响使用：写路径的双写会在下次编辑时把这篇补齐。
    }
  });
}

/// 应用窗口材质，并处理 Win10 回退。
///
/// - **Win11（build >= 22000）**：标准 Mica（`WindowEffect.mica`）——
///   壁纸染色浅而收敛，由 DWM 合成，应用侧零渲染成本。
///   想要更浓的染色换回 `WindowEffect.tabbed`（Mica Alt）；
///   具体走哪条 DWM 接口由 flutter_acrylic 按系统版本内部判断。
/// - **Win10 / macOS / Linux**：没有 Mica（或当前未启用对应平台材质）。
///   若让窗口保持透明，会**直接露出锐利的桌面壁纸**（无材质处理，观感很差），
///   因此回退为不透明纯色底。Flutter 侧的 Scaffold 本就是透明的，
///   露出的就是这层纯色——界面其余部分无需任何改动。
/// acrylic 初始化的缓存 Future：`Window.initialize()` 内部用
/// Completer，**只能成功调用一次**（重复调用抛 "Future already
/// completed"）——明暗切换会多次进入材质应用，这里用 Future 缓存
/// 保证全程只初始化一次，且并发调用共享同一个 Future（无竞态）。
Future<void>? _acrylicInit;

/// 隐藏系统窗控只需**一次**（幂等），并且必须在**设置 Mica 之前**完成。
///
/// ⚠️ 此前这一步放在 [_applyWindowMaterial] 的**末尾**，等于每次设完 Mica
/// 立刻改一次窗口样式（`flutter_acrylic` 的 `hideWindowControls` 内部是
/// `SetWindowLong(GWL_STYLE, ... & ~WS_SYSMENU)`）——窗口样式变更会让 DWM
/// 重建该窗口的可视状态，Mica 的 backdrop（`DWMWA_SYSTEMBACKDROP_TYPE`）
/// 常被一并清掉。这就是 Mica 偶发失效最可疑的一环：三次启动重试与每次焦点
/// 重应用都以它收尾，"设完立刻被清"。
///
/// 改为进程内**只做一次、且在做 backdrop 之前**：之后的重应用只动 backdrop，
/// 不再碰窗口样式。全项目没有别的调用会重新加回 `WS_SYSMENU`（只用
/// minimize/maximize/unmaximize/close），所以偷这一次没有回补风险。
bool _windowControlsHidden = false;

/// 上次成功应用的**有效亮度**。与 [_appliedSuccessfully] 配合做幂等短路：
/// 亮度未变且上次已成功应用时跳过重复 `setEffect`，避免每次获得焦点 /
/// 明暗监听都重设一次 DWM backdrop（既浪费、又在极端时序下可能微闪）。
/// 冷启动延迟重试与热重载走 [force] 绕过此短路，保留"首次可能失败"的补偿能力。
Brightness? _lastAppliedBrightness;
bool _appliedSuccessfully = false;

Future<void> _hideWindowControlsOnce() async {
  if (_windowControlsHidden) return;
  await acrylic.Window.hideWindowControls();
  _windowControlsHidden = true;
}

/// 应用窗口材质。亮度由调用方给出（**有效亮度** = 用户明暗设置的
/// 解析结果，可能是强制浅/深，也可能是跟随系统）——材质必须与
/// 界面亮度一致，否则 Mica 变体/回退底色会与内容色错档（浑浊发灰）。
///
/// - **Win11**：走 `flutter_acrylic` 的 `WindowEffect.mica`，由它负责设置
///   DWM Backdrop + 窗口透明 surface；Flutter 侧只需保持 Scaffold 透明。
/// - **其他桌面平台**：退回等价纯色底，避免窗口透明直接露壁纸。
/// - 顺序固定为「**先定窗口样式 → 再设 backdrop**」（见 [_hideWindowControlsOnce]）。
Future<void> _applyWindowMaterial(
  Brightness brightness, {
  bool force = false,
}) async {
  // 幂等短路：亮度未变且上次已成功应用 → 跳过重复 DWM 重设（见 [_lastAppliedBrightness]）。
  // 冷启动重试 / 热重载用 force 绕过，保留失败补偿能力。
  if (!force && _appliedSuccessfully && _lastAppliedBrightness == brightness) {
    return;
  }
  // 自绘标题栏下隐藏系统标题栏按钮：只在首次设置 backdrop 之前做。
  await _hideWindowControlsOnce();

  await (_acrylicInit ??= acrylic.Window.initialize());

  final bool dark = brightness == Brightness.dark;
  final bool useMica = Platform.isWindows && WindowService.isWindows11;

  if (useMica) {
    // Win11 Mica：flutter_acrylic 会处理 DWM 属性与窗口透明 surface。
    await acrylic.Window.setEffect(
      effect: acrylic.WindowEffect.mica,
      dark: dark,
    );
  } else {
    // Win10 等无 Mica 的系统：回退为**等价纯色**（与 Mica 观感一致，明暗切换不跳色）。
    //
    // ⚠️ 这里**不做**"透明窗口 + Flutter 自绘圆角"。Win10 的 DWM 不给圆角，只把
    // 窗口改透明的话，窗口矩形四角会留下**方角的透明区**——影子按矩形画、角上还
    // 会抢点击（俗称"透明耳朵"，实测踩过）。要在 Win10 上真圆角只能用
    // `SetWindowRgn` 裁**窗口区域**（整数像素、无抗锯齿，弧线带锯齿），权衡后
    // **不做**：Win10 保持直角，Win11 由系统自动圆角。
    await acrylic.Window.setEffect(
      effect: acrylic.WindowEffect.solid,
      color: AppTheme.windowBackground(brightness),
      dark: dark,
    );
  }
  _lastAppliedBrightness = brightness;
  _appliedSuccessfully = true;
}

class MainApp extends ConsumerStatefulWidget {
  const MainApp({super.key});

  /// 两套主题的静态缓存：种子色恒定（defaultSeed），ThemeData 不可变，
  /// 整个生命周期构造一次即可。
  static final ThemeData _lightTheme = AppTheme.light();
  static final ThemeData _darkTheme = AppTheme.dark();

  @override
  ConsumerState<MainApp> createState() => _MainAppState();
}

class _MainAppState extends ConsumerState<MainApp>
    with WindowListener, WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    // 关窗口前必须先把未落盘的编辑写下去（2026-09-17 用户实测：删掉一段文字、
    // 马上关窗口，重开后那段文字又回来了——防抖还没到期，进程就退出了）。
    //
    // 用**官方**的可取消退出请求（见 [didRequestAppExit]）：Windows 上由引擎自动
    // 接管（`WidgetsFlutterBinding` 初始化时会发 `System.initializationComplete`），
    // 我们只需登记观察者，**不要**自己去拦窗口消息。
    WidgetsBinding.instance.addObserver(this);
    // 窗口材质由 flutter_acrylic 在 Dart 侧应用；监听焦点变化，
    // 在获得焦点 / 切换明暗时幂等重应用，保证 DWM 合成稳定后材质必达。
    windowManager.addListener(this);
    // 首帧兜底 + 延迟重试：⚠️ 焦点兜底在**冷启动路径上靠不住**——
    // WindowService.init 的 show/focus 发生在 runApp **之前**，窗口的首次
    // 焦点事件比这里的 addListener 更早，onWindowFocus 不会再触发。
    // 于是首帧那一次应用成了唯一的守护，而窗口刚 show 时 DWM 合成可能
    // 未稳定，setEffect 偶发落空（实测：一次冷启动 Mica 失效，热重载
    // 无法恢复，重启才好）。材质应用幂等，补两次短延迟重试无副作用。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_applyWindowMaterial(_effectiveBrightness(), force: true));
      _retryMaterialAt(const Duration(milliseconds: 300));
      _retryMaterialAt(const Duration(seconds: 1));
    });
  }

  /// 冷启动材质重试：DWM 合成稳定的时刻没有回调可用，只能用短延迟兜。
  void _retryMaterialAt(Duration delay) {
    Future<void>.delayed(delay, () {
      if (!mounted) return;
      unawaited(_applyWindowMaterial(_effectiveBrightness(), force: true));
    });
  }

  @override
  void reassemble() {
    super.reassemble();
    // 热重载不重跑 main / initState / postFrame——此前若冷启动的材质应用
    // 落空，热重载无法恢复（只能靠焦点事件）。这里补上：每次热重载都
    // 幂等重应用一次材质（热重载：强制，确保重新上材质）。
    unawaited(_applyWindowMaterial(_effectiveBrightness(), force: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// **有效亮度**：用户明暗设置的解析结果——强制浅/深直接取值。
  /// 窗口材质（Mica dark 变体 / Win10 底色）与界面亮度都必须用它，
  /// 两者才不会错档。
  Brightness _effectiveBrightness() {
    final ThemeBrightnessMode mode =
        ref.read(settingsProvider).brightnessMode;
    return switch (mode) {
      ThemeBrightnessMode.light => Brightness.light,
      ThemeBrightnessMode.dark => Brightness.dark,
    };
  }

  @override
  void onWindowFocus() {
    // 窗口获得焦点。⚠️ 冷启动**不**走这里：WindowService.init 的 show/focus
    // 早于 addListener，首次焦点事件已错过（冷启动由 initState 的 postFrame +
    // 延迟重试承担）。此处只兜"切回窗口"这一支，且亮度未变、上次已成功应用时
    // 由 [_applyWindowMaterial] 的幂等短路直接跳过，不重复重设 DWM backdrop。
    unawaited(_applyWindowMaterial(_effectiveBrightness()));
  }

  /// 系统请求退出（X / Alt+F4 / 标题栏关闭按钮 / 菜单"退出"都汇聚到这里）。
  ///
  /// ⚠️ **不要**改回 `WindowListener.onWindowClose`：那只是"窗口即将销毁"的通知，
  /// 收到时再做异步落盘已经来不及（进程马上就走）。引擎在 Windows 上提供的是
  /// **可取消**的官方机制：`WM_CLOSE` → `System.requestAppExit` → 本方法；我们答
  /// `exit` 之后，引擎才补发第二个 `WM_CLOSE` 真正销毁窗口——期间平台线程照常
  /// 处理消息，所以等待落盘时窗口是**响应**的（不是"(未响应)"）。
  ///
  /// 落盘的护栏（上限 2s、单个失败不连累、绝不抛异常、永远答 exit）都在
  /// [flushThenExit] 里。
  @override
  Future<AppExitResponse> didRequestAppExit() =>
      flushThenExit(ref.read(pendingSavesProvider));

  @override
  Widget build(BuildContext context) {
    // 明暗模式切换 → 窗口材质重新应用（Mica dark 变体 / Win10 底色
    // 跟随界面亮度）——设置面板里切明暗时，材质不换就会与界面错档。
    ref.listen<ThemeBrightnessMode>(
      settingsProvider.select((AppSettings s) => s.brightnessMode),
      (ThemeBrightnessMode? _, ThemeBrightnessMode _) {
        unawaited(_applyWindowMaterial(_effectiveBrightness()));
      },
    );
    // 主题随设置实时变化：改明暗后面板背后的主界面立即重绘。
    // MaterialApp 按 themeMode 自动切明暗，我们直接传强制浅/深两态。
    //
    // ⚡ 只 select 明暗模式（不 watch 整个 settings）：拖字号/行高滑杆的
    // 每个 tick 都不该惊动 MaterialApp 层——实时预览由编辑器局部承担。
    final ThemeBrightnessMode brightnessMode = ref.watch(
      settingsProvider.select((AppSettings s) => s.brightnessMode),
    );
    return MaterialApp(
      // 全局导航根：设置面板等浮层从它取 root Overlay
      // （入口按钮在 MaterialApp 之外构建，context 找不到 Overlay）。
      navigatorKey: appNavigatorKey,
      title: 'sinan',
      // 自绘标题栏下，DEBUG 角标正好压在右上角窗口按钮上，必须关掉。
      debugShowCheckedModeBanner: false,
      // 主题固定用默认种子色（AppTheme.defaultSeed）；主题色不再作为可设置项。
      // ⚡ 两套 ThemeData 静态缓存：ThemeData 构造成本不低，而种子恒定，
      // 每次 build 重造纯属浪费（相等性短路救的是比较，不是构造）。
      theme: MainApp._lightTheme,
      darkTheme: MainApp._darkTheme,
      themeMode: switch (brightnessMode) {
        ThemeBrightnessMode.light => ThemeMode.light,
        ThemeBrightnessMode.dark => ThemeMode.dark,
      },
      // 新的拆包 API：一行覆盖 Flutter + Material + Cupertino 全部本地化字符串。
      // （quill 的 `FlutterQuillLocalizations` 已随 quill 视图退役摘除；
      // 编辑器是 appflowy，文案走下面这个委托。）
      localizationsDelegates: const [
        ...GlobalMaterialLocalizations.delegates,
        // appflowy_editor 的块组件文案（占位符/斜杠菜单等）依赖它，
        // 缺失会抛 "AppFlowyEditorLocalizations not found"。
        AppFlowyEditorLocalizations.delegate,
      ],
      // 本地化解析需要：系统 zh-CN 时各层字符串才落到中文。
      //
      // ⚠️ **必须带国家码**：appflowy_editor 的 `load()` 是用
      // `locale.toString()`（即 `zh_CN`）去它的消息表里查的，而解析结果只会
      // 取自本列表 ⇒ 写成 `Locale('zh')` 会查不到 `zh-CN` 那一份，官方文案
      // 全部回落英文（占位符 / 斜杠菜单 / 右键菜单 / 查找替换都在这里）。
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('zh', 'TW'),
        Locale('en'),
      ],
      // 桥接层（接 flutter_quill 的关键）：
      //
      // material_ui 与官方 package:flutter/material.dart 是「同名不同型」的
      // 两套类型系统（MaterialLocalizations/ThemeData 各有一份）。
      // flutter_quill 直接 import 官方 material，其 showDialog 硬校验
      // **官方的** MaterialLocalizations 类型——本应用只加载了 material_ui
      // 的同名类型，类型查不到就抛 No MaterialLocalizations found。
      // 桥做两件事：
      //   ① 用官方 flutter_localizations 委托再覆盖一层本地化；
      //   ② 把 material_ui 主题映射为官方 ThemeData，quill 组件随之换肤。
      // 桥已标记 deprecated（material_ui 未来版本会移除），当前无替代，
      // 移除前提是 quill 生态适配 material_ui——遥遥无期。
      builder: (BuildContext context, Widget? child) =>
          // ignore: deprecated_member_use
          MaterialUiCompatibilityBridge(child: child!),
      // 官方的 MaterialUiCompatibilityBridge 是过渡期工具（已标记
      // deprecated，material_ui 未来版本会移除）：flutter_quill 仍
      // import 旧 package:flutter/material.dart，桥不撤。
      // 移除条件：quill 发布 material_ui 适配版 → 升级 → 删掉
      // builder 三行 + 本地化仅留 quill delegate 追加即可。
      // spike 验证已收口（结论与实测数据见 docs/editor_migration_spike.md），
      // 启动回真实应用。
      home: const HomeScreen(),
    );
  }
}
