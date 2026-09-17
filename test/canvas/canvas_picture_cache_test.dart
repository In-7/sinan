import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/canvas/kernel/canvas_controller.dart';
import 'package:sinan/src/canvas/kernel/ink_stroke.dart';

InkStroke _stroke(Offset at) => InkStroke(
      color: const Color(0xFF000000),
      baseWidth: 4,
      points: <InkPoint>[InkPoint(at, 0), InkPoint(at + const Offset(6, 6), 0)],
    );

/// 主题明暗两档墨色（真实值见 `AppTheme.canvasInk`；这里只要**两者不同**）。
const Color _inkLight = Color(0xFF1F1F1F);
const Color _inkDark = Color(0xFFD6D6D6);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('笔迹少时也走缓存 Picture（书写中只重绘 activeStroke）', () {
    final CanvasController controller = CanvasController();
    for (int i = 0; i < 10; i++) {
      controller.document.addStroke(_stroke(Offset(i * 10, 0)));
    }
    final Object? pic = controller.pictureFor(_inkLight);
    expect(pic, isNotNull);
    // 内容与墨色都没变 ⇒ 复用同一实例（平移/缩放不重录）。
    expect(controller.pictureFor(_inkLight), same(pic));
    controller.dispose();
  });

  test('已完笔迹的 Picture：内容与墨色都不变才复用', () {
    final CanvasController controller = CanvasController();
    for (int i = 0; i < 205; i++) {
      controller.document.addStroke(_stroke(Offset(i * 10, 0)));
    }

    final Object? first = controller.pictureFor(_inkLight);
    expect(first, isNotNull);
    // 内容没变 ⇒ 同一个实例（平移/缩放不重录，这正是缓存的意义）。
    expect(controller.pictureFor(_inkLight), same(first));

    // 改内容 ⇒ 重录出一个新实例。
    controller.document.addStroke(_stroke(const Offset(0, 999)));
    expect(controller.pictureFor(_inkLight), isNot(same(first)));

    // 撤销也触发重录（版本号覆盖了撤销/重做）。
    final Object? afterAdd = controller.pictureFor(_inkLight);
    controller.document.undo();
    expect(controller.pictureFor(_inkLight), isNot(same(afterAdd)));

    // ⚠️ **换墨色也必须重录**（主题明暗切换）：颜色是烤进显示列表里的，不重录
    // 就会继续用旧墨色重放——暗色切换后等于"看不见自己写的字"。
    final Object? light = controller.pictureFor(_inkLight);
    expect(
      controller.pictureFor(_inkDark),
      isNot(same(light)),
      reason: '墨色变了却没重录：主题切换后笔迹仍是旧墨色',
    );

    controller.dispose();
  });

  test('视口裁剪：只取与视口相交的笔迹', () {
    final CanvasController controller = CanvasController();
    controller.document
      ..addStroke(_stroke(const Offset(0, 0)))
      ..addStroke(_stroke(const Offset(900, 900)));
    controller.setViewport(const Size(800, 600));

    final Rect visible = controller.camera.visibleWorld(controller.viewport);
    expect(controller.document.strokesIn(visible), hasLength(1));
    controller.dispose();
  });
}
