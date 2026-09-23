import 'dart:async';

import 'dart:io' show Directory;
import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:appflowy_editor/appflowy_editor.dart'
    show AppFlowyEditorLocalizations;
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app/home_screen.dart';
import 'src/app/pending_saves.dart';
import 'src/command/bindings.dart';
import 'src/app/settings_panel.dart';
import 'src/data/database.dart';
import 'src/data/note_store.dart';
import 'src/data/settings_store.dart';
import 'src/dev/frame_probe.dart';
import 'src/domain/settings.dart';
import 'src/editor/core/editor_icons.dart';
import 'src/app/providers.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/nav_ink.dart';
import 'src/window/window_base.dart';
import 'src/window/window_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 编辑器图标统一为 Lucide：官方工具栏/斜杠菜单/图片工具条的图标是包内 SVG，
  // 这里注册映射让它们走 Lucide 字形（vendored 侧的钩子见
  // third_party/appflowy_editor/PATCHES.md 补丁 4）。未登记的名字自动回落 SVG。
  installEditorIcons();
  // 帧探针（人工场景"连打"的 p90，见 docs/perf_baseline.md §2.1）：
  // **只在 profile 构建里生效**（内部按 kProfileMode 常量判断，release 下整块
  // 被裁掉），平时零成本——不采时不注册 timings 回调。
  installFrameProbe();
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
  // 导航列的水墨 shader：**预装载**（异步）。失败也无所谓 —— `NavInk.painter`
  // 会返回 null ⇒ 导航列退回 `AppTheme.boardFill` 的实色底，不会白屏。
  unawaited(NavInk.preload());

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
        // 检索/索引设施要裸连接（见 appDatabaseProvider 的说明）。
        appDatabaseProvider.overrideWithValue(db),
      ],
      child: const MainApp(),
    ),
  );

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

/// acrylic 初始化的缓存 Future：`Window.initialize()` 内部用 Completer，
/// **只能成功调用一次**（重复调用抛 "Future already completed"）——用 Future
/// 缓存保证全程只初始化一次，且并发调用共享同一个 Future（无竞态）。
///
/// ⚠️ 窗口材质已取消（2026-09-22：窗口底改为 Flutter 自绘的渐变，三端统一），
/// 但这一步**仍然需要**：[acrylic.Window.hideWindowControls] 要求先 initialize。
Future<void>? _acrylicInit;

/// 隐藏系统窗控只需**一次**（幂等）。
///
/// 自绘标题栏的前提：`flutter_acrylic` 的 `hideWindowControls` 内部是
/// `SetWindowLong(GWL_STYLE, … & ~WS_SYSMENU)`。进程内只做一次即可；全项目没有
/// 别的调用会重新加回 `WS_SYSMENU`（只用 minimize/maximize/unmaximize/close），
/// 所以这一次没有回补风险。
bool _windowControlsHidden = false;

/// 窗口侧的一次性准备：初始化 flutter_acrylic + 隐藏系统窗控（幂等）。
///
/// **窗口材质取消后，这是启动时唯一要做的窗口侧动作**——不再有"先定窗口样式、
/// 再设 backdrop"的顺序约束，也没有 DWM 合成的时序问题（原先那套延迟重试／幂等
/// 短路／焦点重应用全是为 Mica 的偶发失效准备的，已一并删除）。
Future<void> _hideWindowControlsOnce() async {
  if (_windowControlsHidden) return;
  await (_acrylicInit ??= acrylic.Window.initialize());
  await acrylic.Window.hideWindowControls();
  _windowControlsHidden = true;
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

class _MainAppState extends ConsumerState<MainApp> with WidgetsBindingObserver {
  /// 全局快捷键分发器的卸载函数（见 [installCommandDispatcher]）。
  late final CommandDispatcherHandle _disposeDispatcher;

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
    // 自绘标题栏：隐藏系统窗控（幂等）。**窗口材质已取消**（窗口底 = Flutter
    // 自绘的渐变，三端统一，见 [AppTheme.windowGradient]）⇒ 这是启动时唯一的
    // 窗口侧动作，不再有"先定窗口样式、再设 backdrop"的顺序约束。
    unawaited(_hideWindowControlsOnce());
    // 全局快捷键分发（`docs/ui_rewrite_plan.md` §3.2 的①面）：命令层注册的键位
    // 在这里落地。装载点选外壳 State 而不是 `main()`：它需要 `ref`（命令要读写
    // provider），而 `ref` 只在 ProviderScope 内拿得到。
    _disposeDispatcher = installCommandDispatcher(ref);
  }

  @override
  void dispose() {
    // 不摘掉 handler：热重载/重建 State 会再装一个，同一条快捷键会被执行两遍。
    _disposeDispatcher();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
      builder: (BuildContext context, Widget? child) {
        // **窗口底 = 纯色**（§5.6；2026-09-22 定案）。
        //
        // 挂在 **builder 层**（Theme 之内、路由之外）⇒ 主页的 6px 缝、笔记页的
        // 侧栏区共用同一层底；笔记/画布页整块铺纸面时它被盖住，无感知。
        //
        // ⚠️ **2026-09-22 由「微渐变」改成纯色**（用户实报色带后量化出来的账）：
        // 那条渐变两端只差 **6~7 个 8-bit 台阶**（`#0D0C0A → #141310`，亮色同量级），
        // 铺满全屏对角线 ⇒ **每 ~420px 一条**能看见的带。**台阶数 = 色带数**，所以只有
        // 三条路：接受色带 / 抖动掉它 / 把台阶压到 1（= 纯色）。
        // 这层是**窗口底**、不承载任何信息 ⇒ 取纯色。Windows 11 的 Mica 底本身也是
        // 纯色（它的"层次"来自壁纸，不是自绘渐变）——想再要渐变的味道，见 §5.6：
        // 必须**同时**把它做成同 pass 抖动（`FragmentShader` 有序抖动），
        // ⛔ 独立噪点层治不了（已实测：摘掉它色带仍在，加回它色带更重）。
        // 渐变令牌 `AppTheme.windowGradient` 与它的测试都留着，随时可回来。
        //
        // ⚠️ **窗口材质（Mica / Win10 回退纯色）已取消**：三端（Win/mac/Linux）
        // 都用这一层自绘底，观感完全一致，也不再依赖 DWM 合成是否成功。
        // 首帧之前的那一小段窗口仍是透明的（窗口材质本来也是首帧后才应用，
        // 所以观感不比从前差）；要恢复材质见 git 历史里的 `_applyWindowMaterial`。
        final Brightness brightness = Theme.of(context).brightness;
        // ⚡ **窗口自身切成不透明**（2026-09-23）：省掉"透明窗口 ⇒ DWM 每帧把整扇窗与
        // 桌面混合"那笔。幂等（明暗没变不会重设），且与 Mica 互斥 —— 详见
        // [WindowService.applyWindowBackground] 的说明。
        unawaited(WindowService.applyWindowBackground(brightness));
        // 窗口底 + 顶边/顶角缩放手柄都在 [WindowBase] 里——**一处管全窗口**，且它抽成
        // 具名件就是为了可测（这个 builder 在 `main.dart`、测不到）。取值、只圈顶边的
        // 理由、以及"由微渐变改纯色"的那笔账，全写在那个类的文档里。
        return WindowBase(
          // ignore: deprecated_member_use
          child: MaterialUiCompatibilityBridge(child: child!),
        );
      },
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
