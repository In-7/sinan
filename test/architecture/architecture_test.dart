import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 架构边界的**棘轮**：越界即红（对应 `docs/architecture.md`）。
///
/// ## 为什么用测试而不是文档
/// 文档会被忽略，测试不会。这里钉的三条是"缝"——它们目前都是好的，但下一个改代码的人
/// （包括以后的 AI）很容易顺手越界：把 `note_store` 拿进画布内核用、在 widget 里直接开
/// 数据库。这类越界**没有编译器约束**，只能靠测试兜。
///
/// ⚠️ 路径是**相对项目根**的（`flutter test` 的工作目录就是项目根）——与
/// `test/editor/editor_icons_test.dart` 读 vendored 资源同一约定。
void main() {
  group('架构边界', () {
    test('画布内核（canvas/kernel）不依赖任何外层', () {
      // 内核的依赖是**固定清单**：多一个都要人有意放行（而不是顺手加进来）。
      const Set<String> allowed = <String>{
        'dart:',
        'package:flutter/',
        'package:perfect_freehand/',
      };

      final List<String> violations = <String>[];
      for (final File file in _dartFilesUnder(_kernelDir)) {
        for (final String dep in _dependenciesOf(file)) {
          if (allowed.any(dep.startsWith)) continue;
          // 同目录文件（裸文件名，无路径分隔符）是内核内部引用，合法。
          if (!dep.contains('/')) continue;
          violations.add('${_rel(file)} → $dep');
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            '画布内核出现了对外依赖。内核必须保持可单测、可复用：\n'
            '  ${violations.join('\n  ')}\n'
            '若非加不可，请在 docs/architecture.md §2 说明理由并显式放行。',
      );
    });

    test('只有 data/ 能碰 sqlite3', () {
      final List<String> violations = <String>[];
      for (final File file in _dartFilesUnder('lib')) {
        if (_rel(file).startsWith('lib/src/data/')) continue; // 数据层自己合法
        for (final String dep in _dependenciesOf(file)) {
          if (dep.startsWith('package:sqlite3/')) {
            violations.add('${_rel(file)} → $dep');
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            '数据库驱动泄漏到了数据层之外——换存储/写测试都会被牵连：\n'
            '  ${violations.join('\n  ')}\n'
            '请改为经 app/providers 取 *Store。',
      );
    });

    test('只有白名单能引用 data/（账本必须与白名单一致）', () {
      final Set<String> offenders = <String>{};
      for (final File file in _dartFilesUnder('lib')) {
        if (_rel(file).startsWith('lib/src/data/')) continue; // 同层互相引用合法
        if (_dependenciesOf(file)
            .any((String dep) => _referencesDataLayer(file, dep))) {
          offenders.add(_rel(file));
        }
      }

      expect(
        offenders.difference(_legit),
        _debt,
        reason:
            '若上面报"多出文件"：新代码越过了 DI，请改为经 app/providers 取数据；\n'
            '若报"少了文件"：债已清掉，请**同时删掉 _debt 里那一行**，别让账本烂掉。',
      );
    });

    test('只有 locateProvider 能写"当前笔记"（跳转只此一条路）', () {
      // `docs/ui_rewrite_plan.md` §4：换笔记**就是**跳转。别处若也能直接写选中态，
      // 两条路会立刻分叉——表现为"列表点了编辑器没反应""角标跳过去了、列表高亮
      // 还停在旧笔记"，而且这类分叉**不会编译报错**，只能靠这里拦。
      //
      // 允许写在 providers.dart 内：`locateProvider` 本体就在那儿，且"删空后回到
      // 空态"是清空（不是"跳到哪里"，`locate` 要求有个目标才成立）。
      const Set<String> allowed = <String>{'lib/src/app/providers.dart'};

      final List<String> offenders = <String>[];
      for (final File file in _dartFilesUnder('lib')) {
        if (allowed.contains(_rel(file))) continue;
        if (file.readAsStringSync().contains(
          'selectedNoteIdProvider.notifier',
        )) {
          offenders.add(_rel(file));
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            '请改为 `ref.read(locateProvider.notifier).locate(noteId: …)`：\n'
            '  ${offenders.join('\n  ')}',
      );
    });
  });
}

// ─── 白名单 ────────────────────────────────────────────────────────────────

/// **合法**引用 `data/` 的地方：装配根与唯一 DI 点。
const Set<String> _legit = <String>{
  'lib/main.dart',
  'lib/src/app/providers.dart',
};

/// **债**：修完请同时删掉这里那一行（见 `docs/architecture.md` §6）。
/// 测试断言的是 `越界集合 - _legit == _debt`，所以清掉债却不删白名单会红。
const Set<String> _debt = <String>{
  // 视图穿透 DI 直接依赖具体 store；抽 CanvasNoteViewModel 时收掉。
  'lib/src/canvas/canvas_note_view.dart',
  // 领域模型反向依赖持久化（只为写 AppSettings.load(SettingsStore)）。
  'lib/src/domain/settings.dart',
};

const String _kernelDir = 'lib/src/canvas/kernel';

// ─── 辅助 ──────────────────────────────────────────────────────────────────

List<File> _dartFilesUnder(String dir) =>
    Directory(dir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList();

/// 取文件里所有 `import` / `export` 的目标路径。
List<String> _dependenciesOf(File file) {
  final RegExp re = RegExp('''^(?:import|export)\\s+['"]([^'"]+)['"]''');
  final List<String> out = <String>[];
  for (final String line in file.readAsLinesSync()) {
    final RegExpMatch? m = re.firstMatch(line.trimLeft());
    if (m != null) out.add(m.group(1)!);
  }
  return out;
}

/// 该 import 是否落在数据层（折算相对路径后再判断，故 `../data/x` 与
/// `src/data/x`、`package:sinan/src/data/x` 三种写法都能识破）。
bool _referencesDataLayer(File from, String dep) {
  if (dep.startsWith('package:sinan/src/data/')) return true;
  if (dep.startsWith('package:') || dep.startsWith('dart:')) return false;
  return _resolve(from, dep).startsWith('lib/src/data/');
}

/// 相对导入折算为项目根路径（Windows 的 `\` 先归一，交给 posix 折叠 `../`）。
String _resolve(File from, String dep) =>
    p.posix.normalize('${_rel(from.parent)}/$dep');

String _rel(FileSystemEntity e) => e.path.replaceAll(r'\', '/');
