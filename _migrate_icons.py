import os, re

ROOT = r"d:/Asinan/sinan/lib/src"
STROKE = "1.5"

# Material Symbols name -> Tabler PascalCase class (verified against tabler_icons_next 3.47.0)
MAP = {
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
}

def find_matching_paren(s, start):
    depth = 0
    i = start
    while i < len(s):
        if s[i] == '(':
            depth += 1
        elif s[i] == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1

def split_top_level(s):
    parts = []
    depth = 0
    cur = ""
    for ch in s:
        if ch == '(':
            depth += 1
            cur += ch
        elif ch == ')':
            depth -= 1
            cur += ch
        elif ch == ',' and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return parts

def tabler_call(name, size=None, color=None):
    cls = MAP.get(name)
    if cls is None:
        return None
    parts = [f"height: {size or 24}", f"width: {size or 24}", f"strokeWidth: {STROKE}"]
    if color is not None:
        parts.append(f"color: {color}")
    return "tabler." + cls + "(" + ", ".join(parts) + ")"

def process_icons(text):
    out = []
    i = 0
    n = len(text)
    unknown = set()
    while i < n:
        m = re.match(r"(?:const\s+)?Icon\(\s*", text[i:], re.DOTALL)
        if not m:
            out.append(text[i]); i += 1; continue
        open_idx = i + m.end() - 1  # position of '('
        close_idx = find_matching_paren(text, open_idx)
        if close_idx == -1:
            out.append(text[i:]); break
        span = text[i:close_idx+1]
        nm = re.search(r"Symbols\.(\w+)", span)
        if nm and nm.start() < (open_idx - i + 1) + 0:  # ensure Symbols inside this Icon
            name = nm.group(1)
            # args are between nm.end() and close_idx (relative)
            args_rel_start = nm.end()
            args = text[i+args_rel_start:close_idx]
            size = None; color = None
            for a in split_top_level(args):
                a = a.strip()
                if a.startswith("size:"):
                    size = a[5:].strip()
                elif a.startswith("color:"):
                    cval = a[6:].strip()
                    if cval != "null":
                        color = cval
            call = tabler_call(name, size, color)
            if call is None:
                unknown.add(name)
                out.append(span)
            else:
                out.append(call)
            i = close_idx + 1
        else:
            out.append(span)
            i = close_idx + 1
    return "".join(out), unknown

def process_bare(text):
    def repl(m):
        name = m.group(1)
        cls = MAP.get(name)
        if cls is None:
            return m.group(0)
        return f"tabler.{cls}(height: 24, width: 24, strokeWidth: {STROKE})"
    return re.sub(r"Symbols\.(\w+)", repl, text)

total_unknown = set()
count = 0
for dirpath, dirs, files in os.walk(ROOT):
    if "third_party" in dirpath:
        continue
    for f in files:
        if not f.endswith(".dart"):
            continue
        full = os.path.join(dirpath, f)
        if os.path.basename(full) == "editor_icons.dart":
            continue
        with open(full, "r", encoding="utf-8") as fh:
            text = fh.read()
        if "Symbols." not in text:
            continue
        new, unk = process_icons(text)
        if unk:
            total_unknown |= unk
        new = process_bare(new)
        # import management
        if "tabler." in new:
            if "tabler_icons_next" not in new:
                # add after first import line
                lines = new.split("\n")
                insert_at = 0
                for idx, ln in enumerate(lines):
                    if ln.strip().startswith("import "):
                        insert_at = idx + 1
                        break
                lines.insert(insert_at, "import 'package:tabler_icons_next/tabler_icons_next.dart' as tabler;")
                new = "\n".join(lines)
        if "Symbols." not in new:
            new = re.sub(r"^\s*import 'package:material_symbols_icons/material_symbols_icons\.dart';\s*$\n?", "", new, flags=re.MULTILINE)
        with open(full, "w", encoding="utf-8") as fh:
            fh.write(new)
        count += 1

print(f"Processed {count} files.")
if total_unknown:
    print("UNKNOWN Symbols names (not in MAP):", sorted(total_unknown))
else:
    print("No unknown Symbols names.")
