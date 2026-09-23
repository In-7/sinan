import 'dart:io';
import 'dart:convert';

const String root = r"d:/Asinan/sinan/lib/src";
const String stroke = "1.5";

const Map<String, String> map = {
  "text_fields": "Typography",
  "format_h1": "H1",
  "format_h2": "H2",
  "format_h3": "H3",
  "format_bold": "Bold",
  "format_italic": "Italic",
  "format_underlined": "Underline",
  "format_strikethrough": "Strikethrough",
  "code": "Code",
  "horizontal_rule": "Minus",
  "format_list_bulleted": "List",
  "format_list_numbered": "ListNumbers",
  "format_quote": "Quote",
  "checklist": "ListCheck",
  "table": "Table",
  "format_align_left": "AlignLeft",
  "format_align_center": "AlignCenter",
  "format_align_right": "AlignRight",
  "format_textdirection_l_to_r": "TextDirectionLtr",
  "format_textdirection_r_to_l": "TextDirectionRtl",
  "swap_horiz": "ArrowLeftRight",
  "palette": "Palette",
  "ink_highlighter": "Highlight",
  "ink_eraser": "Eraser",
  "format_color_text": "TextColor",
  "format_color_reset": "Rotate",
  "check": "Check",
  "check_box": "Checkbox",
  "check_box_outline_blank": "Square",
  "close": "X",
  "delete": "Trash",
  "content_copy": "Copy",
  "share": "Share",
  "link": "Link",
  "edit": "Edit",
  "add": "Plus",
  "search": "Search",
  "settings": "Settings",
  "info": "InfoCircle",
  "undo": "ArrowBackUp",
  "redo": "ArrowForwardUp",
  "more_vert": "DotsVertical",
  "expand_more": "ChevronDown",
  "chevron_right": "ChevronRight",
  "star": "StarFilled",
  "star_border": "Star",
  "warning": "AlertTriangle",
  "logout": "Logout",
  "file_upload": "FileUpload",
  "dashboard": "LayoutDashboard",
  "description": "FileText",
  "article": "Article",
  "folder_open": "FolderOpen",
  "crop_free": "Crop",
  "auto_awesome": "Sparkles",
  "dark_mode": "Moon",
  "light_mode": "Sun",
  "view_list": "List",
  "ink_pen": "Pencil",
  "mouse": "Mouse",
  "touch_app": "HandStop",
  "account_tree": "Hierarchy",
  "zoom_in": "ZoomIn",
  "zoom_out": "ZoomOut",
  "open_in_full": "ArrowsMaximize",
  "image": "Photo",
  "image_not_supported": "PhotoOff",
  "package": "Package",
  "download": "Download",
  "shapes": "Shape",
  "square": "Square",
  "circle": "Circle",
  "brush": "Brush",
  "open_in_new": "ExternalLink",
  "link_off": "LinkOff",
  "attach_file": "Paperclip",
  "terminal": "Terminal",
  "function": "Function",
  "match_case": "LetterCase",
};

int findMatchingParen(String s, int start) {
  int depth = 0;
  for (int i = start; i < s.length; i++) {
    if (s[i] == '(') {
      depth++;
    } else if (s[i] == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

List<String> splitTopLevel(String s) {
  List<String> parts = [];
  int depth = 0;
  StringBuffer cur = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    String ch = s[i];
    if (ch == '(') {
      depth++;
      cur.write(ch);
    } else if (ch == ')') {
      depth--;
      cur.write(ch);
    } else if (ch == ',' && depth == 0) {
      parts.add(cur.toString());
      cur.clear();
    } else {
      cur.write(ch);
    }
  }
  if (cur.toString().trim().isNotEmpty) parts.add(cur.toString());
  return parts;
}

String? tablerCall(String name, {String? size, String? color}) {
  final cls = map[name];
  if (cls == null) return null;
  final parts = [
    "height: ${size ?? 24}",
    "width: ${size ?? 24}",
    "strokeWidth: $stroke",
  ];
  if (color != null) parts.add("color: $color");
  return "tabler.$cls(${parts.join(', ')})";
}

(String, Set<String>) processIcons(String text) {
  final unknown = <String>{};
  final out = StringBuffer();
  int i = 0;
  while (i < text.length) {
    // find "Icon(" or "const Icon("
    int? openIdx;
    bool matched = false;
    if (text.startsWith("Icon(", i)) {
      openIdx = i + 4; // position of '('
      matched = true;
    } else if (text.startsWith("const Icon(", i)) {
      openIdx = i + 10;
      matched = true;
    }
    if (!matched) {
      out.write(text[i]);
      i++;
      continue;
    }
    final closeIdx = findMatchingParen(text, openIdx!);
    if (closeIdx == -1) {
      out.write(text[i]);
      i++;
      continue;
    }
    final span = text.substring(i, closeIdx + 1);
    final nm = RegExp(r"Symbols\.(\w+)").firstMatch(span);
    if (nm != null) {
      final name = nm.group(1)!;
      final args = text.substring(i + nm.end, closeIdx);
      String? size;
      String? color;
      for (final a in splitTopLevel(args)) {
        final t = a.trim();
        if (t.startsWith("size:")) {
          size = t.substring(5).trim();
        } else if (t.startsWith("color:")) {
          final c = t.substring(6).trim();
          if (c != "null") color = c;
        }
      }
      final call = tablerCall(name, size: size, color: color);
      if (call == null) {
        unknown.add(name);
        out.write(span);
      } else {
        out.write(call);
      }
      i = closeIdx + 1;
    } else {
      out.write(span);
      i = closeIdx + 1;
    }
  }
  return (out.toString(), unknown);
}

String processBare(String text) {
  return text.replaceAllMapped(RegExp(r"Symbols\.(\w+)"), (m) {
    final name = m.group(1)!;
    final cls = map[name];
    if (cls == null) return m.group(0)!;
    return "tabler.$cls(height: 24, width: 24, strokeWidth: $stroke)";
  });
}

void main() {
  final unknownAll = <String>{};
  int count = 0;
  final dir = Directory(root);
  for (final ent in dir.listSync(recursive: true)) {
    if (ent is! File) continue;
    if (!ent.path.endsWith(".dart")) continue;
    if (ent.path.contains("third_party")) continue;
    if (ent.path.endsWith("editor_icons.dart")) continue;
    final original = File(ent.path).readAsStringSync();
    if (!original.contains("Symbols.")) continue;
    var (newText, unk) = processIcons(original);
    if (unk.isNotEmpty) unknownAll.addAll(unk);
    newText = processBare(newText);
    // import management
    if (newText.contains("tabler.") && !newText.contains("tabler_icons_next")) {
      final lines = newText.split("\n");
      int insertAt = 0;
      for (int idx = 0; idx < lines.length; idx++) {
        if (lines[idx].trim().startsWith("import ")) {
          insertAt = idx + 1;
          break;
        }
      }
      lines.insert(insertAt, "import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;");
      newText = lines.join("\n");
    }
    if (!newText.contains("Symbols.")) {
      newText = newText.replaceAllMapped(
          RegExp(r"^\s*import 'package:material_symbols_icons/material_symbols_icons\.dart';\s*$\n?", multiLine: true),
          (m) => "");
    }
    File(ent.path).writeAsStringSync(newText);
    count++;
  }
  print("Processed $count files.");
  if (unknownAll.isNotEmpty) {
    print("UNKNOWN Symbols names: ${unknownAll.toList()..sort()}");
  } else {
    print("No unknown Symbols names.");
  }
}
