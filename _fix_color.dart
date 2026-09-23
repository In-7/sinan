import 'dart:io';

const String root = r"d:/Asinan/sinan/lib/src";

void main() {
  final dir = Directory(root);
  int changed = 0;
  for (final ent in dir.listSync(recursive: true)) {
    if (ent is! File || !ent.path.endsWith('.dart')) continue;
    if (ent.path.contains('third_party')) continue;
    final original = File(ent.path).readAsStringSync();
    if (!original.contains('tabler.') || !original.contains('color:')) continue;
    // Only touch tabler.X(...) calls so we don't rewrite Container(color:) etc.
    final re = RegExp(r"tabler\.(\w+)\(([^()]*?)color: ([^)]+)\)");
    final newText = original.replaceAllMapped(re, (m) {
      final cls = m.group(1)!;
      final pre = m.group(2)!;
      final val = m.group(3)!;
      return "tabler.$cls(${pre}colorFilter: ui.ColorFilter.mode($val, ui.BlendMode.srcIn))";
    });
    if (newText != original) {
      var out = newText;
      if (out.contains('colorFilter') && !out.contains("import 'dart:ui'")) {
        final lines = out.split('\n');
        int insertAt = 0;
        for (int i = 0; i < lines.length; i++) {
          if (lines[i].trim().startsWith('import ')) {
            insertAt = i + 1;
            break;
          }
        }
        lines.insert(insertAt, "import 'dart:ui' as ui;");
        out = lines.join('\n');
      }
      File(ent.path).writeAsStringSync(out);
      changed++;
    }
  }
  print('Converted color->colorFilter in $changed files.');
}
