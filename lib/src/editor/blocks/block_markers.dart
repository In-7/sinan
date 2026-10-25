import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

/// **CJK 光学补偿（em）**：几何居中 ≠ 视觉居中。
///
/// 行盒（有了 `applyHeightToFirstAscent/LastDescent: true` +
/// `leadingDistribution: even`）的上下留白是按**字体度量**分配的。
///
/// ## 现字体 = 思源黑体 SC 可变字体（2026-10-24 重标定）
/// 实测（tight 墨迹盒 vs 行盒中心，字号 200px 只为提高像素精度 / height 1.5 /
/// even，五组纯 CJK 样本）：
/// ```
/// 国 +0.080  永 +0.055  墨 +0.060  鬱 +0.055  汉字墨迹 +0.050  （em）
/// 平均 **+0.060** ⇒ 墨迹中心比行盒中心低 0.06em ⇒ 系数 **−0.06**
/// ```
/// （负值 = 图标下移。样本间 ±0.015em 的离散是字形本身的差异，取平均。）
///
/// 对比历史：霞鹜新晰黑·屏幕阅读版下是 +0.0386em ⇒ −0.04；更早的霞鹜度量是
/// −0.07 上移。**换字体时这个数会变、连符号都可能翻**——务必重新标定。
///
/// ## 标定方法（照做即可复现）
/// 1. 用 `TextPainter` 排版纯 CJK 样本（`fontSize` 取大值提高像素精度，
///    `height: 1.5`，`leadingDistribution: even`，样式与编辑器正文一致）；
/// 2. `PictureRecorder → Canvas → toImage → toByteData(rawRgba)`，逐行扫 alpha
///    求**墨迹带**（不是 `getBoxesForRange`，那是文本框不是墨迹）；
/// 3. `偏移 = (墨迹带中心 − 行盒中心) / 字号`，多组取平均；本常量 = **−偏移**。
///
/// ⚠️ 第 2 步的 `toImage` 在 **flutter test 里会挂住**（实测 Timeout，与是否
/// dispose 无关）⇒ 标定只能**离线跑一次**，不能做成常驻断言。常驻的替代是
/// `test/editor/cjk_ink_calibration_test.dart`：它断言**字体度量指纹**
/// （ascent/descent），换字体就红 ⇒ 强制回来重标这个数。
///
/// 系数由字体度量推出、随字号线性缩放（换字号不用再调，**换字体才需要改这一个
/// 数**）。本项目两处消费它：本文件的 [markerBox]（列表圆点/序号/勾选框/折叠
/// 箭头）与 `custom_block_components.dart` 的块手柄——**单一来源**，两者永远对齐。
const double cjkInkCompensation = -0.06;

/// 块**标记**（列表圆点 / 序号 / 勾选框 / 折叠箭头）共用的对齐容器。
///
/// 口径 = 官方组件：**minWidth 26 × 文字缩放 + 右留白 4**。
/// ⚠️ 这个"26 + 4"是**契约**：`BlockHeightPredictor.markerWidth` 用同一式子
/// 让出标记宽度（`26 * textScaleFactor + 4`），预算器与实测要对得上，**改这里
/// 必须同时改那里**（`test/block_height_predictor_spike_test.dart` 会红）。
///
/// 高度**跟随首行行盒**（默认从 `editorStyle` 现场读 字号 × height）：`Row` 是
/// start 对齐，容器顶 = 首行盒顶，`Center` 的中点才与首行字形的中点重合。
/// 写死 22 是雅黑时代的口径——度量盒 1.32em 字形撑得满，偏 3px 看不出来；
/// 霞鹜度量盒只有 1.0em，点/数字/勾选框全部"浮"在首行上部（2026-09-11 实测
/// 截图），故改为动态取值。折叠标题这类**首行更高**的块传 [lineBox] 覆盖。
/// （标记自身字形盒若高于容器，`Center` 照样居中，不裁切。）
Widget markerBox(BuildContext context, Widget child, {double? lineBox}) {
  final EditorState editorState = context.read<EditorState>();
  final double tsf = editorState.editorStyle.textScaleFactor;
  final TextStyle base = editorState.editorStyle.textStyleConfiguration.text;
  final double firstLineBox =
      lineBox ?? (base.fontSize ?? 16) * (base.height ?? 1.0);
  return Container(
    constraints: BoxConstraints(minWidth: 26, minHeight: firstLineBox) * tsf,
    padding: const EdgeInsets.only(right: 4.0),
    child: Center(
      // 光学补偿：按 [cjkInkCompensation] × 字号移向墨迹中心
      // （常量说明见其文档；负值 = Transform 向下平移）。
      // Transform.translate 是绘制期偏移，不参与布局、无 saveLayer。
      child: Transform.translate(
        offset: Offset(0, -cjkInkCompensation * (base.fontSize ?? 16)),
        child: child,
      ),
    ),
  );
}
