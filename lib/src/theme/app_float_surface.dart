import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'tokens.dart';

/// 玻璃**顶沿光边**的高度（逻辑 px）。
///
/// 取 1、不取发丝（`Tokens.hairlineWidth` = 0.5）：它是一条**亮线**，靠"亮度差"
/// 而不是"粗细"被看见——0.5 在多数缩放下会被抗锯齿磨成一片灰雾，反而像脏。
const double _kGlassRimHeight = 1;

/// **玻璃光泽层**：内光泽（竖向，上沿最亮）+ 顶沿光边（横向，两端淡出）。
///
/// 两层都是**纯绘制**（两条渐变），**无 `saveLayer`、不随重绘付费** ⇒ 面积大也
/// 付得起（背景与取舍见 [AppFloatSurface.glass]）。
///
/// ## 两个调用方
/// - [AppFloatSurface]（浮层族：设置 / 关于面板）；
/// - 主页的 Bento 卡片（`home_hub.dart`）——卡片太多，不适合每张都套一个浮层容器。
///
/// ⚠️ **它自己不裁圆角**：宿主必须已经裁到圆角内（[AppFloatSurface] 靠 `Material`
/// 的 `clipBehavior`，卡片自带 `Clip.antiAlias`）—— 少一层 clip 就少一次图层切换。
/// ⚠️ 两层都**在内容之下**（`Stack` 的顺序），放 `foregroundDecoration` 会把正文
/// 一起洗白。
class AppGlass extends StatelessWidget {
  const AppGlass({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Stack 的尺寸由非定位的 `child` 决定，两层光跟着它铺满。
    final Brightness brightness = Theme.of(context).brightness;
    return Stack(
      children: <Widget>[
        // ① 内光泽：竖向，上沿最亮、45% 处归零。
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppTheme.glassSheen(brightness),
              ),
            ),
          ),
        ),
        // ② 顶沿光边：一条横线，两端淡出。
        // ⚠️ 用**渐变条**而不是 `Border(top:)`：后者在圆角矩形上会画出一条
        // **超出圆角的直线**（经典瑕疵），而夹在裁切里的一条会被圆角自然收口。
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppTheme.glassRim(brightness),
              ),
              child: const SizedBox(height: _kGlassRimHeight),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// 浮层（菜单 / 面板 / 工具条）的**统一表面**：浮层底 + 1px 描边 + 投影。
///
/// ## 三件套（缺一件就不像浮层）
/// 底色 [AppTheme.floatSurface]（与纸面**只差一档明度**）
/// + 描边 [AppTheme.menuBorder] + 投影 [AppTheme.floatShadows]
/// （双层软阴影：贴地影 + 环境影，Apple 菜单口径）。
///
/// ## 底色是"抬一档的中性色"：不是画布色，也不染种子色
/// - **不再用**编辑页那张"纸"的 [AppTheme.contentCanvas]：它与纸面逐像素同色，
///   浮层只能靠描边/投影勉强分层——2026-09-14 前的状态是 6 个浮层里 4 个连投影
///   都没有，且同屏能撞出 4 种底色（画布色 / M3 表面色 / 选区色 / 反色）；
/// - **也不取** M3 的 `surfaceContainerHigh`：那档带主题色相，与 [AppTheme]
///   头部"大面不染种子色"的规则冲突（主题色只作强调点）。
///
/// ## 谁该用、谁不该用
/// 用：**短暂浮起**的东西——菜单、下拉、工具条、弹出面板（含查找面板）。
/// 不用：**长时间停留的大面**（编辑器纸面、笔记卡片、列表条目悬浮、抽屉、
/// 底部面板）——它们是"内容容器"，仍走 [AppTheme.contentCanvas]；混进浮层会让
/// 整个应用看起来"到处在浮"。
///
/// 官方组件用不了本容器的（悬浮工具栏 / 斜杠菜单 / 右键菜单 / 主菜单 / 查找
/// 面板），也取同一批令牌填色——**改一处，全场浮层跟着变**。
class AppFloatSurface extends StatelessWidget {
  const AppFloatSurface({
    super.key,
    required this.child,
    this.width,
    this.padding,
    this.borderRadius,
    this.blur = false,
    this.glass = false,
    this.panel = false,
    this.color,
  });

  final Widget child;

  /// 固定宽度（不传则随内容）。
  final double? width;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;

  /// 底色覆写。默认 [AppTheme.floatSurface]（实色）；**磨砂档要传半透明**
  /// （如 [AppTheme.menuFill]）——否则实色会把模糊整块盖住。
  final Color? color;

  /// **磨砂档（局部模糊）**：在**面板矩形内**对背后内容做一次 [BackdropFilter]。
  ///
  /// ⚠️ 与"全屏模糊"是两回事：这里只糊面板那块（面积约全屏的 1/20~1/30），
  /// 当年那条红线针对的是**全屏、压在画布高频重绘面上**的毛玻璃。
  /// ⚠️ **模糊要看得出来，底色必须够透**：`α=0.95` 时面板近乎实色、模糊被盖住
  /// ⇒ 用它的地方把底色降到 ~0.8（见 [AppTheme.menuFill] 的旋钮）。
  /// 📌 开它的是两处（2026-09-22）：**主菜单 / 关于面板**（都小）。
  /// ⚠️ **设置面板刻意不开**（`blur: false`）：它 720×560 ≈ 全屏 **11%**（菜单约
  /// 1/20），且拖字号 / 行高滑杆时背后每帧重绘 ⇒ 那块滤镜要每帧重算。它是"同族
  /// 但按面积分档"的先例：成本要看**面积 × 重绘次数**，别拿"菜单没卡"直接推论
  /// （量法见 [AppTheme.floatBlurSigma]）；`test/app/settings_panel_test.dart` 钉着
  /// 这一条，要开回来先拿实测数字。
  final bool blur;

  /// **玻璃档**：在底色之上叠两层**纯绘制**的"光"——内光泽（竖向，上沿最亮）
  /// + 顶沿光边（横向，两端淡出）。它们不遮住任何东西，只改质感。
  ///
  /// ## 为什么值得做（2026-09-22）
  /// "玻璃"在视觉上由三件构成：① 镜面高光 / 光边 ② 厚度（上亮下沉）
  /// ③ **透光 / 折射**。纯绘制能拿到 ①②、拿不到 ③ ⇒ 得到的是"**釉面 / 抛光
  /// 玻璃板**"，不是"看得见背后的磨砂玻璃"（后者唯一的手段仍是 [blur]）。
  /// 📌 依据：亮色下那点半透本来就几乎看不见（[AppTheme.menuLayerAlpha] 的注释里
  /// 记着实测"合成色只差 1~2 级"）⇒ 那里的"玻璃感"**只能**由 ①② 提供。
  ///
  /// ## 成本
  /// 两层都是普通填充（两条渐变），**无 `saveLayer`、不随重绘付费** ⇒ 与 [blur]
  /// 不是一个量级。设置面板（11% 屏）正是靠它替掉模糊的。
  ///
  /// ## ⚠️ 光只给"质感"，不给"分离"
  /// 本仓踩过（[AppTheme.neuFloatBar] 的注释）：轻拟态那次把底色做成与背景同色、
  /// 只剩光 ⇒ 压在密集文字上"看不出边界，像融进纸里"。光必须叠在**有底色差 +
  /// 有描边**的面上——本容器三件套齐全，安全。
  final bool glass;

  /// **面板档**：读作"内容面板"而不是"浮在空中的浮层"——与工作区的浮面卡
  /// （`_FloatingPanel` / 问笔记右栏 `_AiRailSlot`）同一观感：
  /// [AppTheme.panelFill] 实底 + [Tokens.radiusMd] 圆角 + [AppTheme.surfaceRing]
  /// 外扩光环，**不要** [AppTheme.menuBorder] 描边 / [AppTheme.floatShadows] 柔影。
  ///
  /// 用途：同一功能在宽窗是右栏、窄窗降级成浮层时，两边不该换皮
  /// （问笔记浮层态 2026-10-20 对齐主内容面板与右栏）。
  final bool panel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 默认圆角 radiusLg（2026-09-19 起，Apple 菜单口径的柔和感）；
    // 工具条胶囊等刻意指定自己曲率的仍从 [borderRadius] 传入。
    final BorderRadius radius = borderRadius ??
        BorderRadius.circular(panel ? Tokens.radiusMd : Tokens.radiusLg);
    // 默认浮层档：投影走**双层软阴影**（[AppTheme.floatShadows]：贴地影 + 环境
    // 影，Apple 菜单口径），由外层 [DecoratedBox] 承担——Material 的 elevation
    // 只有单层固定投影，出不来这个质感。面板档改用 [AppTheme.surfaceRing] 光环。
    // Material 本体只负责底色 + 描边 + 裁剪（elevation 归零，避免两层影子叠加发脏）。
    Widget content = Padding(
      padding: padding ?? EdgeInsets.zero,
      child: width == null ? child : SizedBox(width: width, child: child),
    );
    if (glass) {
      content = AppGlass(child: content);
    }
    Widget surface = Material(
      color: color ??
          (panel
              ? AppTheme.panelFill(theme.brightness)
              : AppTheme.floatSurface(theme.brightness)),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        // 面板档：1px 内描边（与主卡 / AI 轨同款，2026-10-20 用户定）。
        side: panel
            ? BorderSide(color: AppTheme.surfaceRingColor(theme.brightness))
            : AppTheme.menuBorder(theme.colorScheme),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
    if (blur) {
      // 顺序不能反：**先糊背后的东西、再压半透明底色**（`BackdropFilter` 作用于
      // 它下层已绘制的内容，自己绘制子级）。裁切套在最外，模糊不越出圆角。
      surface = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: AppTheme.floatBlurSigma,
            sigmaY: AppTheme.floatBlurSigma,
          ),
          child: surface,
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        // 面板档不再用外扩光环（会被外层裁掉，且内描边更受青睐）；
        // 默认浮层档仍是双层柔影。
        boxShadow: panel
            ? const <BoxShadow>[]
            : AppTheme.floatShadows(theme.brightness),
      ),
      child: surface,
    );
  }
}
