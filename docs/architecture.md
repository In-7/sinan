# 架构（层图 · 命名 · 豁免 · 边界）

本文只写**既有事实**与**边界**，不发明新规范。

基线（2026-09-17 实测）：`lib` 85 个文件、`src/` 约 21k 行；测试 64 文件 / 12.2k 行。

对着《Flutter 官方架构指南》（docs.flutter.cn/app-architecture，2026-06-13 / Flutter 3.47）
核过官方 9 条强建议：**完全符合 4 条**（清晰分层、单向数据流、依赖注入、测试用 fake）、
**半符合 3 条**（Repository、MVVM、不可变模型——其中后者是**有意豁免**，见 §4）、
**缺 2 条**（widget 不放逻辑、抽象 Repository）。缺的这两条指向同一件事：
抽 ViewModel + 抽 Repository（缺口清单见 §7）。

## 一、层图

```
lib/main.dart                装配根：建库、override provider、窗口初始化
  └ src/app/providers.dart   **唯一 DI 点**：provider 定义与 override
      ├ src/notes/           笔记列表、编辑器宿主（View）
      ├ src/canvas/          画布宿主与面板（View）；canvas/kernel/ 是纯内核（§2）
      ├ src/editor/          编辑器积木 blocks·core·panels·toolbar·widgets（View 组件）
      ├ src/theme/           设计令牌与主题（横切）
      └ src/window/          标题栏、窗口服务（横切）
  src/domain/                领域模型：Note / AppSettings / 枚举
  src/data/                  持久化：AppDatabase + *Store（**只此一处碰 sqlite3**）
third_party/                 vendored appflowy_editor（已打补丁，改动走 PATCHES.md）
archive/                     quill 旧视图归档（已从构建与分析中排除）
```

### 谁可以依赖谁

| 方向 | 规则 |
|---|---|
| `canvas/kernel/**` | **不依赖任何外层**（§2，有测试锁） |
| `domain/` | 只依赖 `dart:` / `package:`，**不依赖 `data/`**（现存 1 处债，§6） |
| `data/` | 可依赖 domain（产出领域模型）；**只有 `main.dart` 与 `app/providers.dart` 能引用它** |
| feature（notes/canvas/editor） | 经 `app/providers` 取数据，**不直接 import `data/`**（现存 1 处债，§6） |
| `third_party/` | 谁都可以用；**改它必须走 `PATCHES.md` 补丁流程**，不可当上游 API 用 |

`theme/` 与 `window/` 属基础设施，不参与"功能分层"（官方那套针对 feature）。

## 二、`canvas/kernel/` 是纯内核（最重要的一条）

13 个文件，实测只 import：`dart:*` + `package:flutter/{widgets,gestures,services}` +
`package:perfect_freehand` + **同目录内**文件。全仓最好的结构，也是画布能跑得动的原因：
内核不碰 widget 树、不碰数据库、不碰 provider，所以可单测、可复用、可独立演进。

`test/architecture/architecture_test.dart` 把这条**锁住**了——越界即红。

内核内部形态：

| 角色 | 实现 |
|---|---|
| 模型 + 命令栈 | `CanvasDocument`（`CanvasCommand` 子类持快照，保证可撤销） |
| ViewModel | `CanvasController extends ChangeNotifier` |
| View | `CanvasView`（`CustomPaint` 三层 + 重绘隔离） |
| 绘制 | `canvas_painters`（网格 / 笔迹 / item / 浮层） |
| 外部能力 | `canvas_ai`·`canvas_media`：**先抽象后实现**（`AiGenerator` / `MediaResolver` 可注入） |

## 三、命名词汇表（照这个起名，看名知内容）

| 后缀 | 含义 | 实例 |
|---|---|---|
| `*Store` | 持久化（数据层入口） | `NoteStore` `CanvasStore` `BlockStore` `SettingsStore` |
| `*Database` | 连接与迁移 | `AppDatabase` |
| `*Controller` | ViewModel（`ChangeNotifier`） | `CanvasController` |
| `*Notifier` | ViewModel（Riverpod `Notifier`/`AsyncNotifier`） | `NotesNotifier` `SettingsNotifier` `SelectedNoteNotifier` |
| `*Screen` / `*View` | 页面级视图 | `HomeScreen` `NoteListView` `CanvasNoteView` |
| `*Panel` | 侧栏 / 浮层面板 | `settings_panel` `toc_panel` `canvas_brush_panel` |
| `*Item` | 画布对象 | `CanvasItem` `ShapeItem` `ImageItem` |
| `*Service` | 无状态协作者 | `notes/services/*`（媒体、公式、预览） |
| 编排 / 节流 | 基础设施小件 | `SaveDebounce` `PendingSaves` `NoteSaver` |

不透明实现一律 `_Xxx`。枚举用 `enum`：`no_default_cases` lint 会要求穷尽匹配，
**新增枚举值编译器就会提醒**，这是刻意的。

## 四、三条刻意豁免（**别"纠正"它们**）

| 豁免 | 官方建议 | 我们的理由 |
|---|---|---|
| `CanvasItem` / `InkStroke` **可变** | "使用不可变的数据模型"（强建议） | 画布每帧读几千条笔迹；改不可变＝每帧造新对象，**会更慢**。可变性收在内核里，由命令栈保证可撤销（命令持快照），单向数据流不破 |
| 不用 `go_router` | "推荐"（官方称覆盖 90% 应用） | 桌面单窗口 + 自绘导航，我们是那 10%；引路由栈只增加状态与间接层 |
| 不引 `freezed` / `built_value` | "推荐"（生成不可变模型） | 官方自己标注会**显著增加构建时间**；现有手写序列化已被测试覆盖 |

官方原话是"**这些是建议而不是铁律**"。豁免要有理由，而不是"懒得做"。

## 五、新代码放哪（决策树）

1. 纯算法 / 数据模型，不需要 widget 与 IO → 所属 feature 或 `domain/`
2. 要读写 SQLite / 文件 → `data/` 加 `*Store`；**别在别处碰 `sqlite3`**
3. 页面级**状态与编排**（载入、保存、防抖、错误）→ ViewModel（`*Controller` / `*Notifier`）
4. 只是个 widget → 所属 feature；跨 feature 的共享组件放 `theme/`
5. 画布相关 → 不依赖外层的模型与算法进 `canvas/kernel/`，画布 UI 留 `canvas/`
6. 想改 `third_party/appflowy_editor` → 走 `PATCHES.md` 补丁流程，不要就地改

## 六、记在账上的两处债（清完请同步删白名单）

| 债 | 现象 | 清法 |
|---|---|---|
| `domain/settings.dart` → `import '../data/settings_store.dart'` | 领域模型反向依赖持久化（只为写 `AppSettings.load(SettingsStore)`） | domain 只留 `fromMap` / `copyWith`，映射交给 `SettingsStore` |
| `canvas/canvas_note_view.dart` → `import '../data/note_store.dart'` | 视图穿透 DI 直接依赖具体 store | 抽 `CanvasNoteViewModel` 时收掉（与 `NoteEditorViewAppFlowy` 同型） |

`test/architecture/architecture_test.dart` 里的 `_debt` 白名单**必须与此表一致**：
清掉一处，测试会**要求你同时删掉白名单那一行**（否则红），账本不会悄悄烂掉。

## 七、与官方强建议的对照（以后拿它做基线）

| 官方强建议 | 现状 |
|---|---|
| 清晰分层 | ✅ |
| 单向数据流 | ✅ |
| 依赖注入 | ✅ Riverpod 3.4.3（官方原文：状态管理"取决于个人偏好"） |
| 测试用 fake | ✅ 64 测试文件 / 12.2k 行 |
| Repository 模式 | 🟡 `*Store` 已在，但无抽象接口 |
| MVVM（View/ViewModel 严格一对一） | 🟡 画布符合；两个宿主视图把 ViewModel 的活也干了 |
| 不可变模型 | ⚠️ 有意豁免（§4） |
| widget 不放逻辑 | ❌ `note_editor_view_appflowy.dart` 1443 行；`canvas_note_view.dart` 同类 |
| 抽象 Repository | ❌ 无 |

缺口（不是本文的规范，是待办）：抽 `NoteEditorViewModel` / `CanvasNoteViewModel`、
加 `NoteRepository` 抽象。官方"视情况而定"三条中，**领域层我们不做**——官方原文：
"多数应用只会带来不必要开销"。

⚠️ 还有一条**架构之外**但决定"别人能不能参与"的事：仓库**没有 `LICENSE`**，
`README.md` 仍是脚手架内容（见 §4 与 `CONTRIBUTING` 待补）。开源前必须处理。

## 八、无障碍（a11y）

权威在 `docs/a11y.md`（基线、官方检查器用法与局限、决策），门槛在 `test/a11y/`。三条要点：

- **官方三个检查器只遍历"已存在的语义节点"** ⇒ 自绘画布（全 `CustomPaint`）在它们眼里是
  **0 节点、全绿**——那是**假阴性**，不是合格。`test/a11y/` 有"盲区守卫"断言专门防这个误读。
- 图标按钮的 tooltip 要交给 `IconButton(tooltip:)`，**不要**在外面包 `Tooltip`：外层提示会挂在
  **父语义节点**上、按钮自己没名字（读屏只念"按钮"）。2026-09-17 实测踩过并已修。
- 桌面点击目标按 **24×24**（WCAG 2.2 SC 2.5.8），不是移动端的 48——我们最小窗宽 720，属高密度 UI。
- **无文字的可点区**（点空白聚焦之类）若不给读屏用，要显式 `excludeFromSemantics: true`：否则它的
  `tap` 会**合并进最近一层语义边界**（如滚动视口），看起来像那一层出了问题——排查时极易误判成
  vendored 的锅（2026-09-17 实际误判过一次，见 `docs/a11y.md` §4）。
