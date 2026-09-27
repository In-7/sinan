# 性能基线（UI 重写的对照尺）

> 阶段 0 产出，配合 `docs/ui_rewrite_plan.md` §7。
> **数字只在"同机 + 同 Flutter 版本 + 同构建模式"下可比**——换机器要重测一遍全表。

## 0. 环境（可比性前提）

| 项 | 值 |
|---|---|
| 机器 | Intel Core i7-14650HX（24 逻辑核） |
| 内存 | 15.8 GB |
| Flutter | 3.47.4 • stable |
| 平台 | Windows x64 |
| 记录日期 | 2026-09-21 |

## 1. 已测（命令可复现，不需要人工操作）

| 指标 | 基线值 | 复现命令 |
|---|---|---|
| **release 构建耗时** | **82.2 s** | `Measure-Command { flutter build windows --release }` |
| **release 产物体积** | **51.9 MB**（54,421,663 B） | 递归求和 `build/windows/x64/runner/Release` |
| **测试套件时长** | **37.2 s** | `Measure-Command { flutter test }`（769 用例） |

### 1.1 release 产物体积构成（Top 6）

| 体积 | 文件 | 说明 |
|---|---|---|
| 20.3 MB | `flutter_windows.dll` | 引擎 |
| 14.0 MB | `app.so` | AOT 快照（**我们的代码 + vendored editor + 依赖** ⇒ 换皮时应基本不变） |
| 11.0 MB | `LXGWNeoXiHeiScreen.ttf` | 打包字体（编辑器正文，全量字形） |
| 1.6 MB | `sqlite3.dll` | SQLite |
| 0.8 MB | `lucide.ttf` | 图标字体 |
| 0.8 MB | `icudtl.dat` | ICU |

### 1.2 顺带验证（R1 的发布态）

`Release/` 目录里存在 **`vector_windows_x64.dll`** ⇒ `sqlite_vector` 的 native asset
**在 release 构建里也正确随包发布**（此前只在 `flutter test` 里验证过机制 A）。
阶段 1 起若看到这个文件消失，说明构建钩子被破坏，检索层会静默降级为纯关键词。

## 2. 已测（自动化 harness，一条命令）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tool/perf_run.ps1
```

它做四件事：① 生成夹具 → ② `flutter drive --profile` 跑
`integration_test/perf_test.dart`（同时**从外部**采样 `sinan.exe` 工作集峰值）
→ ③ 清理夹具（自校验）→ ④ 打印数字。产出在 `build/perf/<场景>.json`。

| # | 场景 | 帧数 | build avg/p90/worst (ms) | raster avg/p90/worst (ms) | 掉帧 build/raster | 状态 |
|---|---|---|---|---|---|---|
| 3 | **大笔记滚动** | 11 | 7.4 / 11.7 / **17.3** | 1.0 / 1.2 / 1.2 | **1** / 0 | ✅ 自动 |
| 4 | **画布拖动+缩放** | 18 | 1.9 / 3.8 / 5.6 | 8.3 / 11.8 / 14.4 | 0 / 0 | ✅ 自动 |
| 5 | **画布书写** | 127 | 2.1 / 2.3 / 5.7 | 6.1 / 6.4 / 7.0 | 0 / 0 | ✅ 自动 |
| 6 | **内存峰值** | — | — | — | — | ✅ 自动（**292.1 MB**） |

**阶段 0 读数**：滚动是唯一有掉帧的场景（build p90 11.7ms、worst 17.3ms 略超
16.67 预算）；画布两个场景的**瓶颈在光栅化**（raster 8.3 / 6.1ms，build 只要 2ms）
——与画布"把成本压给 GPU"的设计一致。

### 2.1 仍然人工的两项（合成输入不具代表性）

| # | 场景 | 配方 | 阶段 0 读数 |
|---|---|---|---|
| 1 | **冷启动 → 可输入** | `flutter run --profile --trace-startup`（读 `build/start_up_info.json`） | **1177 ms**（首帧，三次 1269 / 1177 / 1146 的**中位数**）/ 1176 ms（光栅化完成） |
| 2 | **大笔记连打** | `flutter run --profile` → 打开`【性能夹具】大笔记` → 光标置段尾 → **F9** → 连续输入 5 秒 → **F9** | **build p90 0.96 / raster p90 1.84 ms**（204 帧、**0 掉帧**；worst 4.46 / 4.40） |

> 为什么不用 harness 代劳：测试里的文本输入只能"整段替换"，**不等于真人逐键**
> （每次输入的编辑量、IME、光标动画都不同）——数字会好看得没有意义。

> ⚠️ **原配方"DevTools Performance 取 p90"是错的**（2026-09-21 核官方文档）：性能页
> 只有逐帧柱状图 + 卡顿红色高亮，**不提供** p90 / 均值 / 掉帧统计——那个数从 DevTools
> 里读不出来。改用应用内的**帧探针**（`lib/src/dev/frame_probe.dart`，只在 profile
> 构建里存在）：它与自动场景**共用同一份统计实现**（`summarizeFrameDurations`），产出
> 同形状 JSON ⇒ 可直接填同一张复测表。

#### 连打怎么跑（唯一剩的人工项）

```powershell
flutter run --profile          # 库里要有夹具（生成器见本节上文）
```

1. 点开`【性能夹具】大笔记`，光标放到**段尾**（最坏位置：段尾之后没有块，重排最重）；
2. 按 **F9** —— 终端打印 `[perf] 采集开始`；
3. 用你平时的输入法**连续输入约 5 秒**，别停 —— **每敲一键才出一帧**，样本要 ≥ 30 帧
   （不足 20 帧终端会提示重采）；
4. 再按 **F9** —— 终端打印 `PERF typing_manual {...}`，并归档到
   `build/perf/typing_manual.json`；
5. 记 `build_p90_ms`（顺带看 `missed_frames_build`，那才是"掉了几帧"）。

**可比性靠动作一致**：采样窗口含打字前后的零星空闲帧（光标闪烁约每 500 ms 一帧、
成本 ~1 ms），量少但会把 p90 的位置往下拉一点。所以每次都用**同一套动作**
（按 F9 → 立刻打 → 打完就按 F9），前后阶段才可比。

**阶段 0 读数（2026-09-21）**：204 帧、**0 掉帧**，build p90 **0.96 ms** / raster p90
1.84 ms（worst 4.46 / 4.40 ms）——离 16.67 ms 预算还有约 **17 倍**余量。

两点解读（否则会误判这个数）：

- **它比滚动场景（build p90 11.7 ms）低一个数量级，是合理的**：键击只重排光标所在
  的那个块，滚动要重建整个可见区。两个场景测的是不同的东西，都要留着。
- **结论：大笔记逐键输入不是问题区**，重写在这块没有要修的东西。阶段 4 复测时如果
  这个数明显变差，那是**新壳把成本引进了键击路径**（编辑器内部的键击路径本不经过壳）
  ——这正是留它的用途：它是"壳没添乱"的对照。
- ⚠️ **这一行别看 §4 的 10% 阈值**：绝对数太小（p90 < 1 ms），10% 还不到 0.1 ms，
  比测量噪声还小。复测时看**掉帧数**（有 0 → 非 0 才是信号）与**数量级变化**
  （0.96 → 3 ms 这种），别去抠 0.96 与 1.06 的差别。

#### 冷启动的分解：**哪一截重写能改变**（2026-09-21 实测，三次）

三次 `--trace-startup`：首帧 **1269 / 1177 / 1146 ms**。首跑的 `start_up_info.json` 与
第 3 次对比，能看出**哪一截吃首跑成本**：

| 段 | 首跑 | 稳定态（第 3 次） | 差 | 归属 | 换皮能改变吗 |
|---|---|---|---|---|---|
| 引擎进入 → framework 初始化完成 | 904 ms | **878 ms** | −26 | 引擎 + Dart VM + AOT 快照加载 | ❌ 不能（除非 bundle 明显变大） |
| framework 就绪 → 首帧 | 366 ms | **268 ms** | **−98** | `main()` + 首帧 build/layout/paint | ✅ **这截才是我们的壳** |
| 合计（Time to first frame） | 1269 ms | **1146 ms** | −123 | — | — |
| 首帧 → 光栅化完成 | 1311 ms | 1176 ms | −135 | 首帧 GPU 提交（+42 → +30 ms） | 部分（图层结构） |

**基线取中位数 1177 ms，不取首跑**：首跑比稳定态慢 ~100 ms，且**集中在"framework 就绪
→ 首帧"那截（−98 ms）**——该段含首帧树构建与打包字体（11 MB）的度量，首跑落在磁盘
冷缓存上的嫌疑最大。

**杠杆边界**：稳定态下引擎段占 **76%**（878 / 1146），我们的壳只占 **24%**（268 ms）——
重写对冷启动能动的只有这 268 ms，且实际拿到的会明显少于它。

⚠️ 工具输出里的 `Waiting for application to render first frame... 292ms` **不是独立指标**：
它就是"framework 就绪 → 首帧"那 268 ms（292 含工具侧探测延迟）。**别相加**。

另：`main()` 里的"块表回填"走 **postFrame**，所以**不计入**冷启动——它影响的是首帧之后的
卡顿，不是启动速度。

#### 冷启动**分段**探针（2026-09-28 新增：`main()` 内部打点）

`--trace-startup` 只给"引擎段 / 首帧段"两截，看不出首帧段**内部**谁在花钱。补一个
应用内探针 `lib/src/dev/startup_probe.dart`：

- 只在 **profile** 构建里存在（`kProfileMode` 是编译期常量，release 下整块裁掉）；
- 归档 `build/perf/cold_start.json`——**这是必需通道，不是备份**：Windows runner 是
  GUI 子系统，独立跑 exe 时 `print` 的 stdout 会丢，数字留不下来；
- 起算点是 `main()` 第一行 ⇒ **不覆盖** `main()` 之前那 878 ms 引擎段（那截只能靠
  `--trace-startup`）。两个工具是**互补**的，别互相替代。

```powershell
flutter build windows --profile
$p = Start-Process build\windows\x64\runner\Profile\sinan.exe -WorkingDirectory . `
       -RedirectStandardOutput build\perf\stdout.txt -PassThru
Start-Sleep 28; Stop-Process -Id $p.Id -Force     # 首帧后探针即归档
Get-Content build\perf\cold_start.json
```

**2026-09-28 读数（profile，单次；可比性见 §0）**

| 段 | 优化前 | 优化后 |
|---|---|---|
| `WidgetsFlutterBinding.ensureInitialized` | 0.18 | 0.33 |
| 图标注册 + 帧探针 | 0.00 | 0.01 |
| **`WindowService.init()`**（建原生窗口） | **228.56** | **221.42** |
| `AppDatabase.open()`（开库 + 迁移） | 39.93 | **0.00** |
| `getApplicationSupportDirectory()` | 0.14 | 0.24 |
| `runApp(...)` 入队 | 0.05 | 0.04 |
| 首帧（runApp → 上屏） | 45.92 | 37.99 |
| **合计 `main()` → 首帧 (ms)** | **314.77** | **260.03** |

**这截里谁压得动（杠杆边界）**

- **221 ms 建窗口压不动**：`windowManager.ensureInitialized()` +
  `waitUntilReadyToShow(show + focus)` 是 Win32/DWM 的固有成本。
- **40 ms 开库已拿掉**（2026-09-28）：建窗口与开库**互不依赖**，原先是串行
  （先 `await WindowService.init()` 再 `await AppDatabase.open()`）；改成**先挂起开库**、
  让它在建窗口那 221 ms 里顺路跑完 ⇒ `main()→runApp` 268.86 → 222.04 ms，
  合计 **−54.7 ms（−17.4%）**。
  📌 探针里 `dbOpen` 段**归零**就是生效标志（开库被折叠进了 `windowService` 那段），
  不是漏记。
- ⚠️ 顺序不能反：仍然**先等窗口就绪**、之后才收开库的结果。窗口没就绪就 `runApp`
  会先按默认尺寸渲染一帧、再跳到目标尺寸（可见抖动）。开库只是"顺路做完"，
  它何时完成都不改变窗口那一步的时序。

顺带（同一轮实测，回答"要不要为加载上 isolate"）：**万字笔记**打开全程
`SQLite 取正文 ~1 ms + jsonDecode 0.27 ms + 建 Document 0.26 ms ≈ 1.7 ms`；
200 篇列表查询 **0.99 ms**（其中 `plain_text` 占 0.82 ms，已按需懒取，见
`NoteStore.plainTextOf`）。⇒ **加载路径没有任何瓶颈，isolate 是负收益**
（光新建 isolate 就比它要优化的活还贵）。复现：`flutter test test/perf/note_load_benchmark_test.dart`。

### 2.2 harness 的实现要点与限制（读数字前必读）

**实现**：设备侧用引擎的 `SchedulerBinding.addTimingsCallback` 收 `FrameTiming`，
自算 avg/p90/worst 与掉帧数，写 `build/perf/*.json`。

**为什么不走官方 `traceAction` + `integrationDriver`**（两条都实测被证伪）：
- 桌面端 `flutter drive` 会警告 `integration_test plugin was not detected`，
  `reportData` **一路拿不到东西**（测试全过、数字全无）；
- `traceAction` 在 Flutter 3.47 返回 **void**（Timeline 只经 `reportData` 出去）。

**限制**：
1. **帧数少**（11–127）：harness 是"按动作泵单帧"，测的是**单帧成本采样**，
   不是持续帧率。**用于前后对比**，别当绝对 fps 读。
2. **合成输入 ≠ 手感**：手势路径与渲染路径一致，但节奏与真人不同。
3. **会真的打开应用窗口**并驱动它（桌面端无无头跑法——这是帧时间真实的前提）。
4. **内存必须从外部量**：Windows 上 Dart 的 `ProcessInfo.currentRss` 恒为 0
   （SDK 未实现，且不抛异常），故由 PowerShell 轮询 `WorkingSet64` 取峰值。
5. 复测必须**同机 + 同构建模式（profile）**。

### 2.1 夹具生成器（✅ 已就绪）

`test/perf/fixture_generator.dart`——**用应用自己的序列化器**产出大笔记与大画布
（手抄 schema 会与真实格式漂移，那时夹具就是"能读出来但长得不一样"的假数据，
基线的数字全白测），并**读回自校验**（形状错就在生成阶段炸，不会到计时现场才发现测的是空文档）。

```powershell
# 生成（建议先指向探针库演练：--dart-define=SINAN_DB=build/perf_probe/sinan.db）
flutter test test/perf/fixture_generator.dart `
  --dart-define=SINAN_FIXTURES=make --dart-define=SINAN_DB=<sinan.db 路径>

# 清理（自校验：清完必须为 0 条）
flutter test test/perf/fixture_generator.dart --dart-define=SINAN_FIXTURES=clean
```

| 夹具 | 规模 | 命中哪些场景 |
|---|---|---|
| `【性能夹具】大笔记` | 200 段 × 25 字（约 5 千字） | 连打、滚动 |
| `【性能夹具】大画布` | 200 卡片 + 200 形状 + **5000 笔迹** | 拖动、缩放、书写（同时压 LOD / 裁剪 / 烤图三条路径） |

⚠️ 夹具是**真实笔记**（会出现在列表里）：测完用上面的 `clean` 删掉。
`sinan.db` 路径不给时会自动在 `%APPDATA%` 里找最近改动的那个。

## 3. 复测记录（每阶段结束填一列）

| 指标 | 阶段 0 | 阶段 1 | 阶段 2 | 阶段 3 | 阶段 4 |
|---|---|---|---|---|---|
| release 体积 (MB) | 51.9 | | | | |
| release 构建 (s) | 82.2 | | | | |
| 测试套件 (s) | 37.2 | | | | |
| 冷启动 首帧 (ms)〔三次中位数〕 | 1177 | | | | |
| 冷启动 framework-init 段 (ms)〔稳定态〕 | 878 | | | | |
| 冷启动 首帧段 (ms)〔稳定态〕 | 268 | | | | |
| 大笔记连打 build p90 (ms) | 0.96 | | | | |
| 大笔记连打 raster p90 (ms) | 1.84 | | | | |
| 大笔记滚动 build p90 (ms) | 11.7 | | | | |
| 大笔记滚动 raster p90 (ms) | 1.2 | | | | |
| 画布拖动缩放 build p90 (ms) | 3.8 | | | | |
| 画布拖动缩放 raster p90 (ms) | 11.8 | | | | |
| 画布书写 build p90 (ms) | 2.3 | | | | |
| 画布书写 raster p90 (ms) | 6.4 | | | | |
| 内存峰值 (MB) | 292.1 | | | | |
| 掉帧总数（build/raster） | 1 / 0 | | | | |

## 4. 规则

1. **每阶段结束复测同一张表**，不要只测"变了的那个场景"——退化常在没测的地方。
2. **差异 > 10% 必须能解释**（哪一层变了、为什么）。解释不了就是退化，先查再前进。
3. 帧时间目标：**< 16 ms**（60fps）；`p90` 超标即视为退化，不看平均。
4. `app.so` 若明显增长 ⇒ 多半是依赖或代码体积变化（换皮不该动它）。
5. `vector_windows_x64.dll` 必须一直在（见 §1.2）。
