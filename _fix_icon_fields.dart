import 'dart:io';

const String root = r"d:/Asinan/sinan/lib/src";

bool isWidgetArg(String a) {
  final t = a.trim();
  if (t.isEmpty) return false;
  if (t.startsWith('Icons.') || t.startsWith('tabler.')) return false;
  // function call: ident(...)  -> returns a Widget
  if (RegExp(r"^[a-z_]\w*\(.*\)$").hasMatch(t)) return true;
  // identifier, possibly dotted (incl. ?/!), e.g. item.icon / widget.section.icon
  return RegExp(r"^[A-Za-z_]\w*(\.[A-Za-z_]\w*)*[?!]?$").hasMatch(t);
}

(String, bool) process(String text) {
  final sb = StringBuffer();
  int i = 0;
  bool changed = false;
  while (i < text.length) {
    if (text.startsWith("Icon(", i)) {
      final open = i + 4;
      int depth = 0;
      int close = -1;
      for (int j = open; j < text.length; j++) {
        if (text[j] == '(') {
          depth++;
        } else if (text[j] == ')') {
          depth--;
          if (depth == 0) {
            close = j;
            break;
          }
        }
      }
      if (close == -1) {
        sb.write(text[i]);
        i++;
        continue;
      }
      final inside = text.substring(open + 1, close);
      int d = 0;
      int comma = -1;
      for (int k = 0; k < inside.length; k++) {
        final ch = inside[k];
        if (ch == '(') {
          d++;
        } else if (ch == ')') {
          d--;
        } else if (ch == ',' && d == 0) {
          comma = k;
          break;
        }
      }
      final firstArg = (comma == -1 ? inside : inside.substring(0, comma)).trim();
      if (isWidgetArg(firstArg)) {
        sb.write(firstArg);
        i = close + 1;
        changed = true;
      } else {
        sb.write(text.substring(i, close + 1));
        i = close + 1;
      }
    } else {
      sb.write(text[i]);
      i++;
    }
  }
  return (sb.toString(), changed);
}

void main() {
  int count = 0;
  for (final ent in Directory(root).listSync(recursive: true)) {
    if (ent is! File || !ent.path.endsWith('.dart')) continue;
    if (ent.path.contains('third_party')) continue;
    if (ent.path.endsWith('editor_icons.dart')) continue;
    var text = File(ent.path).readAsStringSync();
    if (text.contains('IconData')) {
      text = text.replaceAll('IconData?', 'Widget?');
      text = text.replaceAll('IconData', 'Widget');
    }
    final (newText, changed) = process(text);
    text = newText;
    File(ent.path).writeAsStringSync(text);
    count++;
  }
  print('Processed $count files.');
}
