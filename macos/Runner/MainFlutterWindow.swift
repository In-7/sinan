import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 系统剪贴板自定义格式（图片块级复制/粘贴）
    SinanClipboardPlugin.register(
      with: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }
}

/// 系统剪贴板「自定义格式」的平台通道（对应 Dart 侧
/// `lib/src/clipboard/block_clipboard_macos.dart`）。
///
/// 为什么要它：Flutter 官方的 `Clipboard.setData` 只能写纯文本，没有自定义
/// 格式能力 —— 图片块的块级复制/粘贴要携带节点结构，只能走 NSPasteboard。
///
/// 写入时同时挂三种类型（与 Windows 侧的多格式写入对齐）：
/// 1. 自定义 UTI（`com.sinan.blocks`）→ 本应用读，还原成块；
/// 2. `public.utf8-plain-text` → 外部应用粘到文件名/文字；
/// 3. `public.png` → 外部应用「粘贴为图片」（单张本地图时）。
///
/// ⚠️ 内联在本文件里（而非单独 .swift）是为了**避免手改
/// Runner.xcodeproj/project.pbxproj** 的编译源清单——那个文件手改极易
/// 破坏工程。后续若拆文件，记得在 Xcode 里 Add Files to "Runner"。
class SinanClipboardPlugin {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.sinan/clipboard",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "write":
        guard let args = call.arguments as? [String: Any],
              let format = args["format"] as? String,
              let payload = args["payload"] as? String
        else {
          result(false)
          return
        }
        let plainText = args["plainText"] as? String ?? ""
        let imagePath = args["imagePath"] as? String
        result(write(
          format: format,
          payload: payload,
          plainText: plainText,
          imagePath: imagePath
        ))
      case "read":
        guard let args = call.arguments as? [String: Any],
              let format = args["format"] as? String
        else {
          result(nil)
          return
        }
        result(read(format: format))
      case "readHtml":
        // 富文本粘贴：public.html（网页/Word 复制过来时才有）。
        let data = NSPasteboard.general.data(forType: .html)
        result(data.flatMap { String(data: $0, encoding: .utf8) })
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func pngData(fromPath path: String) -> Data? {
    guard let image = NSImage(contentsOfFile: path),
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else {
      return nil
    }
    return rep.representation(using: .png, properties: [:])
  }

  private static func write(
    format: String,
    payload: String,
    plainText: String,
    imagePath: String?
  ) -> Bool {
    let pasteboard = NSPasteboard.general
    let customType = NSPasteboard.PasteboardType(format)
    let png = imagePath.flatMap(pngData(fromPath:))

    var types: [NSPasteboard.PasteboardType] = [customType]
    if !plainText.isEmpty { types.append(.string) }
    if png != nil { types.append(.png) }

    pasteboard.clearContents()
    pasteboard.declareTypes(types, owner: nil)

    var ok = pasteboard.setString(payload, forType: customType)
    if !plainText.isEmpty {
      ok = pasteboard.setString(plainText, forType: .string) || ok
    }
    if let png = png {
      ok = pasteboard.setData(png, forType: .png) || ok
    }
    return ok
  }

  private static func read(format: String) -> String? {
    let type = NSPasteboard.PasteboardType(format)
    guard let data = NSPasteboard.general.data(forType: type) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }
}
