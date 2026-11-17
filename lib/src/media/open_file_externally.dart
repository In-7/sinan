import 'dart:io';

import 'package:ffi/ffi.dart' show StringUtf16Pointer, malloc;
import 'package:win32/win32.dart'
    show HINSTANCE, PCWSTR, SW_SHOWNORMAL, ShellExecute;

/// 用**系统默认程序**打开文件（视频 ⇒ 系统播放器）。
///
/// 2026-11-17 Tier 0：灵感视频附件只做"文件片 + 系统打开"，不内置播放器——
/// 视频在灵感收件箱是低频输入（flomo 同定位产品也只有文字 + 图），低频需求
/// 配低成本；而且系统播放器的编解码覆盖比任何内嵌方案都好（PotPlayer/VLC
/// 全格式通吃，Media Foundation 反倒要扩展包）。将来升级应用内播放时换掉
/// 文件片的双击行为即可，调用方不动。
///
/// Windows 走 `ShellExecute('open')`（交文件关联）；macOS/Linux 顺手兜底。
/// 返回是否成功启动。
Future<bool> openFileExternally(String path) async {
  if (!Platform.isWindows) {
    final String exe = Platform.isMacOS ? 'open' : 'xdg-open';
    try {
      final ProcessResult r = await Process.run(exe, <String>[path]);
      return r.exitCode == 0;
    } on Object {
      return false;
    }
  }
  // win32 6.x 的 PCWSTR 是 `Pointer<Utf16>` 的 extension type 包装。
  final PCWSTR op = PCWSTR('open'.toNativeUtf16());
  final PCWSTR file = PCWSTR(path.toNativeUtf16());
  try {
    final HINSTANCE h = ShellExecute(null, op, file, null, null, SW_SHOWNORMAL);
    // Win32 约定：返回值 > 32 才算成功启动（≤32 是各类错误码）。
    // HINSTANCE 也是 extension type（实现 `Pointer`）⇒ 取 `.address`。
    return h.address > 32;
  } finally {
    malloc.free(op);
    malloc.free(file);
  }
}
