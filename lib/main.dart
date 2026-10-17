import 'dart:async';

import 'dart:io' show Directory;
import 'dart:ui' show AppExitResponse, Color, PlatformDispatcher;

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
import 'src/data/markdown/md_mirror.dart';
import 'src/data/note_store.dart';
import 'src/data/settings_store.dart';
import 'src/data/startup_backfill.dart';
import 'src/dev/frame_probe.dart';
import 'src/dev/startup_probe.dart';
import 'src/domain/settings.dart';
import 'src/editor/core/editor_icons.dart';
import 'src/app/providers.dart';
import 'src/theme/app_icon_theme.dart';
import 'src/theme/app_theme.dart';
import 'src/window/window_base.dart';
import 'src/window/window_service.dart';

Future<void> main() async {
  StartupProbe.start();
  WidgetsFlutterBinding.ensureInitialized();
  StartupProbe.mark('ensureInitialized');
  // 编辑器图标统一为 Tabler：官方工具栏/斜杠菜单/图片工具条的图标是包内 SVG，
  // 这里注册映射让它们走 Tabler 控件（vendored 侧的钩子见
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
  StartupProbe.mark('icons+probe');
  // ⚡ **开库与建窗口重叠**（2026-09-28 实测：串行 268.86ms → 并行 ~229ms）。
  // 两者互不依赖：建窗口是原生窗口创建（228ms，走 Win32/DWM，压不动），开库
  // 是开文件 + 跑迁移（40ms）⇒ 把开库**先挂起**，让它在这 228ms 里顺路跑完，
  // 省掉串行时那 40ms 的纯等待。
  //
  // ⚠️ **顺序不能反**：仍然**先等窗口就绪**，之后才收开库的结果。窗口没就绪
  // 就 `runApp` 会先以默认尺寸渲染一帧、再跳到目标尺寸（可见抖动）。开库只是
  // "顺路做完"，它何时完成都不改变窗口那一步的时序。
  //
  // 📌 探针读数会变：`dbOpen` 那段趋近 **0**（开库已被折叠进 `windowService`
  // 那段）——这正是优化生效的标志，不是漏记。
  final Future<AppDatabase> dbFuture = AppDatabase.open();
  // 移动端 / Web 上会自动跳过，不会崩。
  await WindowService.init();
  StartupProbe.mark('windowService');

  final AppDatabase db = await dbFuture;
  StartupProbe.mark('dbOpen');

  // 应用数据根目录：画布的媒体引用要拿它做「绝对 ⇄ 相对」换算，而那发生在同步
  // 的序列化里（拿不到 Future），所以在这里解析一次、注入成常量。
  // 目录本身与 [AppDatabase.open] 用的是同一个（path_provider 内部会缓存）。
  final Directory supportDir = await getApplicationSupportDirectory();
  StartupProbe.mark('supportDir');

  final NoteStore noteStore = NoteStore(db.db);
  final SettingsStore settingsStore = SettingsStore(db.db);

  runApp(
    ProviderScope(
      overrides: [
        // DB 只打开一次，整应用复用同一个连接。
        noteStoreProvider.overrideWithValue(noteStore),
        settingsStoreProvider.overrideWithValue(settingsStore),
        // 媒体引用的基准目录（画布 JSON 只存相对引用，靠它换算成绝对路径）。
        appDataDirProvider.overrideWithValue(supportDir.path),
        // 检索/索引设施要裸连接（见 appDatabaseProvider 的说明）。
        appDatabaseProvider.overrideWithValue(db),
      ],
      child: const MainApp(),
    ),
  );
  StartupProbe.mark('runAppCalled');

  // 块表回填（迁移第 3 步）：把存量笔记的块树补进 blocks。
  //
  // ⚠️ **必须在首帧之后**：它是 SQLite + JSON 解析的重活，放在 `runApp` 之前
  // 会推迟首帧。实测冷启动到首帧 1.18s，其中 ~76%（897ms）在 `runApp` 之前。
  //
  // 2026-10-01 起再进一步：三件存量回填（blocks / 画布投影 / 关键词索引）
  // 丢进**后台 isolate**（runStartupBackfill）——首帧之后界面立即可交互，
  // 不再被首批 50 篇老笔记的解析卡住。安全性见该文件头注释：只写派生表、
  // 每篇独立事务幂等可续跑、WAL 支持第二连接、投影前逐篇重读守卫；未回填的
  // 笔记照常打开（读侧在 blocks 缺失时回退 content 列）。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // 首帧已上屏 ⇒ 冷启动计时到此为止。回填是**首帧之后**才做的活，
    // 不该算进冷启动（它本来就刻意挪到了这里，见上方注释）。
    StartupProbe.mark('firstFrame');
    StartupProbe.report();
    // fire-and-forget：派生数据回填失败不影响使用——保存路径的双写会在
    // 用户下次编辑时把该篇补齐（与旧实现的静默 catch 同一语义）。
    unawaited(
      runStartupBackfill(db.path).catchError((Object _, StackTrace _) {}),
    );
    // Markdown 镜像：启动补一轮（上次没导完 / 在应用外改过库 / 刚换过目录）。
    // 开关关着就整条跳过（默认关），fire-and-forget —— 镜像缺席不影响使用。
    _startMarkdownMirrorSweep(db, settingsStore, supportDir.path);
  });
}

/// 启动期的一轮 Markdown 镜像同步（后台 isolate，见 `MdMirror`）。
///
/// 只做"补齐"：`revised_at` 比账本新的笔记才重写，绝大多数启动是空探测。
void _startMarkdownMirrorSweep(
  AppDatabase db,
  SettingsStore settings,
  String appDataDir,
) {
  final AppSettings boot = AppSettings.load(settings);
  if (!boot.markdownMirrorEnabled) return;
  unawaited(
    MdMirror.exportPendingInBackground(
      dbPath: db.path,
      dir: MdMirror.resolveDir(appDataDir, boot.markdownMirrorDir),
    ).catchError((Object _) => 0),
  );
}

/// acrylic 初始化的缓存 Future：`Window.initialize()` 内部用 Completer，
/// **只能成功调用一次**（重复调用抛 "Future already completed"）——用 Future
/// 缓存保证全程只初始化一次，且并发调用共享同一个 Future（无竞态）。
///
/// 本应用**不做窗口材质**，这一步仍然需要：[acrylic.Window.hideWindowControls]
/// 要求先 initialize。
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
/// 这是启动时唯一的窗口侧动作。窗口材质不做 ⇒ 没有"先定窗口样式、再设 backdrop"
/// 的顺序约束，也没有 DWM 合成的时序问题。
Future<void> _hideWindowControlsOnce() async {
  if (_windowControlsHidden) return;
  await (_acrylicInit ??= acrylic.Window.initialize());
  await acrylic.Window.hideWindowControls();
  _windowControlsHidden = true;
}

class MainApp extends ConsumerStatefulWidget {
  const MainApp({super.key});

  /// 主题缓存：**配色不随预设变**（2026-10-15 方案 B：ColorScheme 恒定由
  /// 包豪斯蓝派生，预设只染窗口 / 标题条，见 builder 里的
  /// [WindowService.applyWindowBackground]）⇒ 缓存键只剩明暗两套。
  /// ThemeData 构造成本不低，每次 build 重造纯属浪费（相等性短路救的是比较，
  /// 不是构造）。
  static final Map<Brightness, ThemeData> _themeCache =
      <Brightness, ThemeData>{};

  /// 取（并缓存）一套主题。**不接种子**——种子只染窗口，不进 ColorScheme。
  static ThemeData _themeFor(Brightness brightness) =>
      _themeCache.putIfAbsent(
        brightness,
        () => switch (brightness) {
          Brightness.light => AppTheme.light(),
          Brightness.dark => AppTheme.dark(),
        },
      );

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
    // 自绘标题栏：隐藏系统窗控（幂等）。窗口材质不做 ⇒ 这是启动时唯一的窗口侧
    // 动作，没有"先定窗口样式、再设 backdrop"的顺序约束。
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
    // 窗口染色种子（**0 = 中性默认档**）。只 select 这一个字段 ⇒ 拖字号滑杆的
    // 每个 tick 都不会惊动 MaterialApp 层（与上面明暗同一套路）。
    // ⚠️ 它**只染窗口 / 标题条**（方案 B，2026-10-15）：ColorScheme 恒定包豪斯蓝，
    // 不读这个值——见 [MainApp._themeFor] 与 builder 里的 chromeColor。
    final int themeSeed = ref.watch(
      settingsProvider.select((AppSettings s) => s.themeSeed),
    );
    final Color? seed = themeSeed == 0 ? null : Color(themeSeed);
    return MaterialApp(
      // 全局导航根：设置面板等浮层从它取 root Overlay
      // （入口按钮在 MaterialApp 之外构建，context 找不到 Overlay）。
      navigatorKey: appNavigatorKey,
      title: 'sinan',
      // 自绘标题栏下，DEBUG 角标正好压在右上角窗口按钮上，必须关掉。
      debugShowCheckedModeBanner: false,
      // 主题 = 定稿包豪斯蓝那一套（方案 B）：主题色不再作为可设置项，设置里的
      // "主题色"预设只染窗口 / 标题条（见下面 builder 的 chromeColor）。
      // ⚡ 两套 ThemeData 按明暗静态缓存：构造成本不低，而配色恒定，
      // 每次 build 重造纯属浪费（相等性短路救的是比较，不是构造）。
      theme: MainApp._themeFor(Brightness.light),
      darkTheme: MainApp._themeFor(Brightness.dark),
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
        // **窗口底 = 纯色**（§5.6；2026-09-22 定案）。它由**平台窗口**铺
        // （[WindowService.applyWindowBackground]），不在 Flutter 侧自绘 ⇒ 免掉
        // 每帧一次全屏 fill。下面几句只解释"为什么是纯色而不是渐变"。
        //
        // ⚠️ **2026-09-22 由「微渐变」改成纯色**（用户实报色带后量化出来的账）：
        // 那条渐变两端只差 **6~7 个 8-bit 台阶**（`#0D0C0A → #141310`，亮色同量级），
        // 铺满全屏对角线 ⇒ **每 ~420px 一条**能看见的带。**台阶数 = 色带数**，所以只有
        // 三条路：接受色带 / 抖动掉它 / 把台阶压到 1（= 纯色）。
        // 窗口底不承载任何信息 ⇒ 取纯色。想再要渐变的味道，见 §5.6：必须**同时**
        // 把它做成同 pass 抖动（`FragmentShader` 有序抖动），⛔ 独立噪点层治不了
        // （已实测：摘掉它色带仍在，加回它色带更重）。渐变令牌
        // `AppTheme.windowGradient` 与它的测试都留着，随时可回来。
        //
        // ⚠️ **窗口材质不做**：三端（Win/mac/Linux）观感完全一致，也不依赖 DWM
        // 合成是否成功。首帧之前的那一小段窗口仍是透明的。
        final Brightness brightness = Theme.of(context).brightness;
        // ⚡ **窗口自身切成不透明**（2026-09-23）：省掉"透明窗口 ⇒ DWM 每帧把整扇窗与
        // 桌面混合"那笔。幂等（明暗没变不会重设）—— 详见
        // [WindowService.applyWindowBackground] 的说明。
        // chrome（环缝 / 标题条）：中性档走中性 ladder（观感与之前完全一致）；
        // 彩色档 = 预设色**本身**（亮色所见即所得）/ 该色相的算法暗色档（暗色）。
        unawaited(
          WindowService.applyWindowBackground(
            brightness,
            chromeColor: AppTheme.chromeColor(seed, brightness),
          ),
        );
        // 窗口底 + 顶边/顶角缩放手柄都在 [WindowBase] 里——**一处管全窗口**，且它抽成
        // 具名件就是为了可测（这个 builder 在 `main.dart`、测不到）。取值、只圈顶边的
        // 理由、以及"由微渐变改纯色"的那笔账，全写在那个类的文档里。
        // ⚠️ [AppIconTheme] 不是装饰：tabler 图标自带一套独立 IconTheme、**不读
        // Material 的**，不桥接就恒定死黑（既不随明暗、也没有未激活的浅色）。
        // 完整病因与做法见该类的文档。
        return AppIconTheme(
          child: WindowBase(
            // ignore: deprecated_member_use
            child: MaterialUiCompatibilityBridge(child: child!),
          ),
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
