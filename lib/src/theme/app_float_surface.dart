import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'tokens.dart';

/// 玻璃**顶沿光边**的高度（逻辑 px）�?
///
/// �?1、不取发丝（`Tokens.hairlineWidth` = 0.5）：它是一�?*亮线**，靠"亮度�""?
/// 而不�?粗细"被看见—�"?.5 在多数缩放下会被抗锯齿磨成一片灰雾，反而像脏�"?
const double _kGlassRimHeight = 1;

/// **玻璃光泽�?*：内光泽（竖向，上沿最亮）+ 顶沿光边（横向，两端淡出）�?
///
/// 两层都是**纯绘�?*（两条渐变）�?*�?`saveLayer`、不随重绘付�?* �?面积大也
/// 付得起（背景与取舍见 [AppFloatSurface.glass]）�?
///
/// ## 两个调用�?
/// - [AppFloatSurface]（浮层族：设�?/ 关于面板）；
/// - 主页�?Bento 卡片（`home_hub.dart`）——卡片太多，不适合每张都套一个浮层容器�?
///
/// ⚠️ **它自己不裁圆�?*：宿主必须已经裁到圆角内（[AppFloatSurface] �?`Material`
/// �?`clipBehavior`，卡片自�?`Clip.antiAlias`）—�?少一�?clip 就少一次图层切换�?
/// ⚠️ 两层�?*在内容之�?*（`Stack` 的顺序），放 `foregroundDecoration` 会把正文
/// 一起洗白�?
class AppGlass extends StatelessWidget {
  const AppGlass({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Stack 的尺寸由非定位的 `child` 决定，两层光跟着它铺满�?
    final Brightness brightness = Theme.of(context).brightness;
    return Stack(
      children: <Widget>[
        // �?内光泽：竖向，上沿最亮�?5% 处归零�?
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppTheme.glassSheen(brightness),
              ),
            ),
          ),
        ),
        // �?顶沿光边：一条横线，两端淡出�?
        // ⚠️ �?*渐变�?*而不�?`Border(top:)`：后者在圆角矩形上会画出一�?
        // **超出圆角的直�?*（经典瑕疵），而夹在裁切里的一条会被圆角自然收口�?
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

/// 浮层（菜�?/ 面板 / 工具条）�?*统一表面**：浮层底 + 1px 描边 + 投影�?
///
/// ## 三件套（缺一件就不像浮层�?
/// 底色 [AppTheme.floatSurface]（与纸面**只差一档明�?*�?
/// + 描边 [AppTheme.menuBorder] + 投影 [AppTheme.floatShadows]
/// （双层软阴影：贴地影 + 环境影，Apple 菜单口径）�?
///
/// ## 底色�?抬一档的中性色"：不是画布色，也不染种子�""?
/// - **不再�?*编辑页那�?�?�?[AppTheme.contentCanvas]：它与纸面逐像素同色，
///   浮层只能靠描�?投影勉强分层—�?026-09-14 前的状态是 6 个浮层里 4 个连投影
///   都没有，且同屏能撞出 4 种底色（画布�?/ M3 表面�?/ 选区�?/ 反色）；
/// - **也不�?* M3 �?`surfaceContainerHigh`：那档带主题色相，与 [AppTheme]
///   头部"大面不染种子�"?的规则冲突（主题色只作强调点）�"?
///
/// ## 谁该用、谁不该�?
/// 用：**短暂浮起**的东西——菜单、下拉、工具条、弹出面板（含查找面板）�?
/// 不用�?*长时间停留的大面**（编辑器纸面、笔记卡片、列表条目悬浮、抽屉�?
/// 底部面板）——它们是"内容容器"，仍�?[AppTheme.contentCanvas]；混进浮层会�?
/// 整个应用看起�?到处在浮"�""?
///
/// 官方组件用不了本容器的（悬浮工具�?/ 斜杠菜单 / 右键菜单 / 主菜�?/ 查找
/// 面板），也取同一批令牌填色—�?*改一处，全场浮层跟着�?*�?
class AppFloatSurface extends StatelessWidget {
  const AppFloatSurface({
    super.key,
    required this.child,
    this.width,
    this.padding,
    this.borderRadius,
    this.blur = false,
    this.glass = false,
    this.color,
  });

  final Widget child;

  /// 固定宽度（不传则随内容）�?
  final double? width;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;

  /// 底色覆写。默�?[AppTheme.floatSurface]（实色）�?*磨砂档要传半透明**
  /// （如 [AppTheme.menuFill]）——否则实色会把模糊整块盖住�?
  final Color? color;

  /// **磨砂档（局部模糊）**：在**面板矩形�?*对背后内容做一�?[BackdropFilter]�?
  ///
  /// ⚠️ �"?全屏模糊"是两回事：这里只糊面板那块（面积约全屏的 1/20~1/30），
  /// 当年那条红线针对的是**全屏、压在画布高频重绘面�?*的毛玻璃�?
  /// ⚠️ **模糊要看得出来，底色必须够�?*：`α=0.95` 时面板近乎实色、模糊被盖住
  /// �?用它的地方把底色降到 ~0.8（见 [AppTheme.menuFill] 的旋钮）�?
  /// 📌 开它的是两处（2026-09-22）：**主菜�?/ 关于面板**（都小）�?
  /// ⚠️ **设置面板刻意不开**（`blur: false`）：�?720×560 �?全屏 **11%**（菜单约
  /// 1/20），且拖字号 / 行高滑杆时背后每帧重�?�?那块滤镜要每帧重算。它�?同族
  /// 但按面积分档"的先例：成本要看**面积 × 重绘次数**，别�"?菜单没卡"直接推论
  /// （量法见 [AppTheme.floatBlurSigma]）；`test/app/settings_panel_test.dart` 钉着
  /// 这一条，要开回来先拿实测数字�?
  final bool blur;

  /// **玻璃�?*：在底色之上叠两�?*纯绘�?*�?�?——内光泽（竖向，上沿最亮）
  /// + 顶沿光边（横向，两端淡出）。它们不遮住任何东西，只改质感�?
  ///
  /// ## 为什么值得做（2026-09-22�?
  /// "玻璃"在视觉上由三件构成：�?镜面高光 / 光边 �?厚度（上亮下沉）
  /// �?**透光 / 折射**。纯绘制能拿�?①②、拿不到 �?�"?得到的是"**釉面 / 抛光
  /// 玻璃�?*"，不�"?看得见背后的磨砂玻璃"（后者唯一的手段仍�"?[blur]）�?
  /// 📌 依据：亮色下那点半透本来就几乎看不见（[AppTheme.menuLayerAlpha] 的注释里
  /// 记着实测"合成色只�"?1~2 �?）⇒ 那里�?玻璃�?**只能**�?①② 提供�"?
  ///
  /// ## 成本
  /// 两层都是普通填充（两条渐变），**�?`saveLayer`、不随重绘付�?* �?�?[blur]
  /// 不是一个量级。设置面板（11% 屏）正是靠它替掉模糊的�?
  ///
  /// ## ⚠️ 光只�?质感"，不�"?分离"
  /// 本仓踩过（[AppTheme.neuFloatBar] 的注释）：轻拟态那次把底色做成与背景同色�?
  /// 只剩�?�?压在密集文字�?看不出边界，像融进纸�?。光必须叠在**有底色差 +
  /// 有描�?*的面上——本容器三件套齐全，安全�?
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 默认圆角 radiusLg�?026-09-19 起，Apple 菜单口径的柔和感）；
    // 工具条胶囊等刻意指定自己曲率的仍�?[borderRadius] 传入�?
    final BorderRadius radius =
        borderRadius ?? BorderRadius.circular(Tokens.radiusLg);
    // 投影�?*双层软阴�?*（[AppTheme.floatShadows]：贴地影 + 环境影，Apple
    // 菜单口径），由外�?[DecoratedBox] 承担——Material �?elevation 只有
    // 单层固定投影，出不来这个质感。Material 本体只负责底�?+ 描边 + 裁剪
    // （elevation 归零，避免两层影子叠加发脏）�?
    Widget content = Padding(
      padding: padding ?? EdgeInsets.zero,
      child: width == null ? child : SizedBox(width: width, child: child),
    );
    if (glass) {
      content = AppGlass(child: content);
    }
    Widget surface = Material(
      color: color ?? AppTheme.floatSurface(theme.brightness),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: AppTheme.menuBorder(theme.colorScheme),
      ),
      clipBehavior: .antiAlias,
      child: content,
    );
    if (blur) {
      // 顺序不能反：**先糊背后的东西、再压半透明底色**（`BackdropFilter` 作用�?
      // 它下层已绘制的内容，自己绘制子级）。裁切套在最外，模糊不越出圆角�?
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
        boxShadow: AppTheme.floatShadows(theme.brightness),
      ),
      child: surface,
    );
  }
}
