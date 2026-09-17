import 'package:appflowy_editor/src/editor/util/file_picker/file_picker_service.dart';
import 'package:file_picker/file_picker.dart' as fp;

/// [sinan 补丁 3] 适配 file_picker 12.x 的破坏性变更：
///
/// - 12.x 移除了 `FilePicker.platform` 单例 → 改为静态方法直调；
/// - `pickFiles` 直接返回 `List<PlatformFile>`（不再包一层 FilePickerResult）；
/// - `saveFile` 语义变为「把给定 bytes 写入用户所选位置并返回 Uri」，
///   与本接口的「只选一个保存路径、不提供内容」无法对应 → 保持接口
///   签名返回 null（本项目当前没有任何调用点依赖保存对话框）。
class FilePicker implements FilePickerService {
  @override
  Future<String?> getDirectoryPath({String? title}) {
    return fp.FilePicker.getDirectoryPath(dialogTitle: title);
  }

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    fp.FileType type = fp.FileType.any,
    List<String>? allowedExtensions,
    Function(fp.FilePickerStatus p1)? onFileLoading,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
  }) async {
    final List<fp.PlatformFile> files = await fp.FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      type: type,
      allowedExtensions: allowedExtensions,
      onFileLoading: onFileLoading,
      allowMultiple: allowMultiple,
      withData: withData,
      withReadStream: withReadStream,
      lockParentWindow: lockParentWindow,
    );
    return FilePickerResult(files);
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    fp.FileType type = fp.FileType.any,
    List<String>? allowedExtensions,
    bool lockParentWindow = false,
  }) async {
    return null;
  }
}
