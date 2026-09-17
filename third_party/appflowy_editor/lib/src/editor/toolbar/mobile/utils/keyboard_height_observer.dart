import 'package:appflowy_editor/src/editor/util/platform_extension.dart';
// [sinan 补丁 2] 移除 device_info_plus：它只用于取 Android SDK 版本，
// 而该包锁定 win32 ^5，与本项目 win32 ^6（剪贴板用）无法同解。
// 本项目目标平台为 Windows 桌面，此分支为死路径，移除依赖即可。
// import 'package:device_info_plus/device_info_plus.dart';
import 'package:keyboard_height_plugin/keyboard_height_plugin.dart';

typedef KeyboardHeightCallback = void Function(double height);

// the KeyboardHeightPlugin only accepts one listener, so we need to create a
//  singleton class to manage the multiple listeners.
class KeyboardHeightObserver {
  static int androidSDKVersion = -1;

  KeyboardHeightObserver._() {
    // [sinan 补丁 2] Android SDK 版本查询随 device_info_plus 一并移除。
    if (false) {
      // DeviceInfoPlugin().androidInfo.then(
      //       (value) => androidSDKVersion = value.version.sdkInt,
      //     );
    }
    _keyboardHeightPlugin.onKeyboardHeightChanged((height) {
      notify(height);

      currentKeyboardHeight = height;
    });
  }

  static final KeyboardHeightObserver instance = KeyboardHeightObserver._();
  static double currentKeyboardHeight = 0;

  final List<KeyboardHeightCallback> _listeners = [];
  final KeyboardHeightPlugin _keyboardHeightPlugin = KeyboardHeightPlugin();

  void addListener(KeyboardHeightCallback listener) {
    _listeners.add(listener);
  }

  void removeListener(KeyboardHeightCallback listener) {
    _listeners.remove(listener);
  }

  void dispose() {
    _listeners.clear();
    _keyboardHeightPlugin.dispose();
  }

  void notify(double height) {
    // the keyboard height will notify twice with the same value on Android
    if (PlatformExtension.isAndroid && height == currentKeyboardHeight) {
      return;
    }

    for (final listener in _listeners) {
      listener(height);
    }
  }
}
