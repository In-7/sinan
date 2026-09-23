import '../data/settings_store.dart';

/// 正文列宽模式（成熟应用的"宽度档位"，由用户手动切换）。
///
/// 正文列宽固定三档，不随窗口放大而变宽——可读性上限约 45 字/行（CJK），
/// 超出后阅读舒适度下降，故最宽也只给到写稿宽度的 960px。
///
/// ## ⚠️ 三档数值**已含块手柄的 48px**（2026-09-15 定案）
/// 每个块的动作槽（"+" / ⠿）是 `Row[手柄, 正文]` 且 `maintainSize` 常驻
/// 占位 ⇒ 文字列 = 本档数值 − 块左右内边距 32 − **手柄 48**。
/// 不把这 48 算进来的话，标称 720 实际只有 640 的文字——**档位在说谎**
/// （且每行少 2~3 个字）。
///
/// 因此三档各 +48：688 / 768 / 1008 ⇒ 文字列回到 608 / 688 / 928。
/// （手柄宽度见 `EditorTypography.blockHandleWidth`，改手柄尺寸 ⇒ 这里同步。）
enum EditorWidthMode {
  /// 窄：728px（文字列 648 ≈ 38 字/行，纯阅读最舒适，眼睛横扫幅度最小）。
  narrow,

  /// 标准：800px（文字列 720 ≈ 42 字/行，CJK 阅读甜点区）。
  standard,

  /// 宽：1008px（文字列 928 ≈ 55 字/行，写稿多看字 / 超宽屏减留白）。
  wide,
}

/// 明暗模式（两态：强制浅色 / 强制深色，不再跟随系统）。
enum ThemeBrightnessMode { light, dark }

/// 应用设置的**唯一真相来源**（内存态）。
///
/// 只存"值"，不存语义解释：列宽由 [contentWidth] 派生——
/// 消费方（主题/编辑器）各取所需。
/// 持久化与默认值解析在 [AppSettings.load] / [save]，
/// 这样 store 只认识字符串，本类负责类型安全。
class AppSettings {
  const AppSettings({
    this.brightnessMode = ThemeBrightnessMode.light,
    this.widthMode = EditorWidthMode.standard,
    this.fontSize = defaultFontSize,
    this.lineHeight = defaultLineHeight,
    this.aiEnabled = false,
    this.aiEndpoint = defaultAiEndpoint,
    this.aiModel = '',
    this.aiEmbeddingModel = '',
  });

  /// 本地 LLM 的默认基址（Ollama 的约定端口）。
  ///
  /// ⚠️ 这是**根地址**，不带 `/v1` 也不带 `/api`：客户端要打的是
  /// `/api/chat`（只有它支持 `format` 传 JSON Schema，见 `src/ai/llm_client.dart`）。
  static const String defaultAiEndpoint = 'http://localhost:11434';

  /// 默认正文字号（2026-09-11 由 16 调到 **17**）。
  ///
  /// 霞鹜新晰黑（Klee 系）的汉字面率约 0.85em，比微软雅黑（≈0.93em）小
  /// 约 8% ⇒ 同字号视觉偏小一档；17px 补偿后与换字体前的观感一致，且仍是
  /// 整数像素档（行盒 17 × 行高 吸附后为整数）。
  static const double defaultFontSize = 17;

  /// 默认行高（2026-09-11 由 1.75 调到 **1.5**）。
  ///
  /// ## 几何（`test/line_height_metrics_test.dart` 实测）
  /// `applyHeightToFirstAscent/LastDescent: true` + `leadingDistribution:
  /// even` 之后每行**同构**：**行盒 = 行距 = round(字号 × 倍数)**——
  /// 滑杆值就是视觉倍数（旧几何的 (盒+字号)/2 已废弃）。
  /// 17px/1.5 → 行盒 26、行距 26。
  ///
  /// ## 为什么是 1.5（中文正文的最佳档）
  /// - 汉字是满 em 方块：视觉 <1.3 会上下"粘连"，1.5 是舒适的**下限**也是
  ///   通用标准档（Word 中文正文、飞书/语雀正文都在 1.5 附近）；
  /// - 阅读类可放到 1.6~1.75，但桌面长文默认 1.5 更"紧凑可读"；
  /// - 落在滑杆 0.125 网格上，吸附后行盒为整数像素（锐度前提）。
  ///
  /// 想更舒展：滑杆往 1.625 / 1.75 拉（新几何下 1.75 就是真 1.75 倍，
  /// 已比旧几何的 1.75 松 6px/行，不必再回退）。
  static const double defaultLineHeight = 1.5;

  final ThemeBrightnessMode brightnessMode;
  final EditorWidthMode widthMode;

  /// 正文字号（px）。
  final double fontSize;

  /// 正文行高倍数。
  final double lineHeight;

  /// 是否在画布工具条上露出 AI 入口。
  ///
  /// 默认 **false**：这个功能要求本机跑着 Ollama，没起服务时露出按钮只会让用户
  /// 点出一个报错。让它成为一次**显式开启**（开关就在下面几行旁边）。
  final bool aiEnabled;

  /// LLM 服务基址（见 [defaultAiEndpoint]）。
  final String aiEndpoint;

  /// 模型名（Ollama tag）。空 = 未配置 ⇒ 调用时给"去设置里填"的明确报错。
  final String aiModel;

  /// **嵌入**模型名（Ollama tag，如 `bge-m3`）。空 = 未配置。
  ///
  /// 与 [aiModel]（对话模型）分开：嵌入模型的产物会**长期存在库里**
  /// （`vec_chunks`），换它等于换整个向量空间——所以它的名字会进 `index_state.model`
  /// 的身份串（`provider:model:dim`，见 `docs/data_layer.md` 6.6①），
  /// 换了就全量重算。留空时索引/检索**自动降级为纯关键词**（6.4）。
  final String aiEmbeddingModel;

  /// 正文列宽（固定像素，不随窗口放大而变）。
  double get contentWidth => switch (widthMode) {
    // 三档都含块手柄的 48px（见 [EditorWidthMode] 的说明）。
    EditorWidthMode.narrow => 728,
    EditorWidthMode.standard => 800,
    EditorWidthMode.wide => 1008,
  };

  /// 标题列的限宽（与正文同宽才对齐）。
  double get titleWidth => contentWidth;

  AppSettings copyWith({
    ThemeBrightnessMode? brightnessMode,
    EditorWidthMode? widthMode,
    double? fontSize,
    double? lineHeight,
    bool? aiEnabled,
    String? aiEndpoint,
    String? aiModel,
    String? aiEmbeddingModel,
  }) => AppSettings(
    brightnessMode: brightnessMode ?? this.brightnessMode,
    widthMode: widthMode ?? this.widthMode,
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    aiEnabled: aiEnabled ?? this.aiEnabled,
    aiEndpoint: aiEndpoint ?? this.aiEndpoint,
    aiModel: aiModel ?? this.aiModel,
    aiEmbeddingModel: aiEmbeddingModel ?? this.aiEmbeddingModel,
  );

  // ── 持久化：key-value 与 store 的边界 ────────────────────
  // 每个键一个常量，避免拼写漂移；缺键时回落默认值（旧库/新装都安全）。

  static const String _kBrightness = 'appearance.brightness';
  static const String _kWidth = 'editor.width';
  static const String _kFontSize = 'editor.fontSize';
  static const String _kLineHeight = 'editor.lineHeight';
  static const String _kAiEnabled = 'ai.enabled';
  static const String _kAiEndpoint = 'ai.endpoint';
  static const String _kAiModel = 'ai.model';
  static const String _kAiEmbeddingModel = 'ai.embeddingModel';

  /// 从 store 还原；任何键缺失或解析失败都回落到默认值
  /// （升级/降级/手工改库都不会崩）。
  static AppSettings load(SettingsStore store) {
    final double? fontSize = double.tryParse(store.get(_kFontSize) ?? '');
    final double? lineHeight = double.tryParse(store.get(_kLineHeight) ?? '');
    return AppSettings(
      brightnessMode: ThemeBrightnessMode.values.firstWhere(
        (ThemeBrightnessMode m) => m.name == store.get(_kBrightness),
        orElse: () => ThemeBrightnessMode.light,
      ),
      widthMode: EditorWidthMode.values.firstWhere(
        (EditorWidthMode m) => m.name == store.get(_kWidth),
        orElse: () => EditorWidthMode.standard,
      ),
      fontSize: fontSize ?? defaultFontSize,
      lineHeight: lineHeight ?? defaultLineHeight,
      // 布尔键缺省 = false：不写 `?? false` 也能落到构造器的默认值，
      // `== 'true'` 让"手工改库成 '1'/'yes'"这种脏值也安全退化。
      aiEnabled: store.get(_kAiEnabled) == 'true',
      aiEndpoint: store.get(_kAiEndpoint) ?? defaultAiEndpoint,
      aiModel: store.get(_kAiModel) ?? '',
      aiEmbeddingModel: store.get(_kAiEmbeddingModel) ?? '',
    );
  }

  /// 落盘（全量写：设置项数量少，无需增量 diff）。
  void save(SettingsStore store) {
    store
      ..set(_kBrightness, brightnessMode.name)
      ..set(_kWidth, widthMode.name)
      ..set(_kFontSize, fontSize.toString())
      ..set(_kLineHeight, lineHeight.toString())
      ..set(_kAiEnabled, aiEnabled.toString())
      ..set(_kAiEndpoint, aiEndpoint)
      ..set(_kAiModel, aiModel)
      ..set(_kAiEmbeddingModel, aiEmbeddingModel);
  }
}
