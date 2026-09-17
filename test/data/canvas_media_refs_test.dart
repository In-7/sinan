import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/data/canvas_media_refs.dart';

/// 缓存淘汰**引用保护集**的回归（2026-09-17 抽离自 `app/providers.dart`）。
///
/// 为什么必须钉住：AI 结果缓存的文件**同时是文档里的图片本体**，淘汰掉仍被
/// 引用的文件等于删用户的正文。此前这段逻辑长在 DI 层（依赖 NoteStore +
/// MediaResolver），只能靠集成测试间接覆盖。
///
/// 用例覆盖两侧来源（侧表 `media` 与 `items[].src`）的**并集**、以及脏数据容错
/// —— 任一侧漏扫都会让保护集偏小，而"偏小"在这里等于**删数据**。
void main() {
  /// 构造一份画布正文（`{camera, document}` 结构）。
  String canvas({
    Map<String, String>? manifest,
    List<String>? itemSrcs,
  }) => jsonEncode(<String, dynamic>{
    'camera': <String, dynamic>{},
    'document': <String, dynamic>{
      'media': ?manifest,
      if (itemSrcs != null)
        'items': <String, dynamic>{
          for (int i = 0; i < itemSrcs.length; i++)
            'item-$i': <String, dynamic>{'type': 'image', 'src': itemSrcs[i]},
        },
    },
  });

  /// 相对引用 → 绝对路径（生产上是 MediaResolver.toPath）。
  String toPath(String ref) => 'D:/data/canvas/$ref';

  test('侧表与 items 两侧取并集（旧存档可能只有一侧）', () {
    final Set<String> refs = referencedCanvasMedia(
      <String>[
        canvas(
          manifest: <String, String>{'a.png': 'image/png'},
          itemSrcs: <String>['b.png'],
        ),
      ],
      toPath: toPath,
    );

    expect(refs, <String>{'D:/data/canvas/a.png', 'D:/data/canvas/b.png'});
  });

  test('只有侧表 / 只有 items 时各自都能扫到', () {
    expect(
      referencedCanvasMedia(
        <String>[canvas(manifest: <String, String>{'only-side.png': 'image/png'})],
        toPath: toPath,
      ),
      <String>{'D:/data/canvas/only-side.png'},
    );
    expect(
      referencedCanvasMedia(
        <String>[canvas(itemSrcs: <String>['only-item.png'])],
        toPath: toPath,
      ),
      <String>{'D:/data/canvas/only-item.png'},
    );
  });

  test('空 src 与空引用不计入（避免保护集里出现空路径）', () {
    final Set<String> refs = referencedCanvasMedia(
      <String>[
        canvas(itemSrcs: <String>['', 'ok.png']),
      ],
      toPath: toPath,
    );
    expect(refs, <String>{'D:/data/canvas/ok.png'});
  });

  test('脏数据跳过而不抛：非 JSON / 半截 JSON / 非画布结构 / 空串', () {
    final Set<String> refs = referencedCanvasMedia(
      <String>[
        '',
        '不是 JSON',
        '{"document": ', // 半截
        jsonEncode(<String, dynamic>{'foo': 1}), // 没有 document
        jsonEncode(<String, dynamic>{'document': 'not-a-map'}),
        canvas(itemSrcs: <String>['good.png']),
      ],
      toPath: toPath,
    );

    expect(refs, <String>{'D:/data/canvas/good.png'});
  });

  test('items 里非 map 的元素跳过（不因一条脏 item 丢整篇）', () {
    final String content = jsonEncode(<String, dynamic>{
      'document': <String, dynamic>{
        'items': <String, dynamic>{
          'bad': 'not-a-map',
          'good': <String, dynamic>{'type': 'image', 'src': 'kept.png'},
        },
      },
    });

    expect(
      referencedCanvasMedia(<String>[content], toPath: toPath),
      <String>{'D:/data/canvas/kept.png'},
    );
  });

  test('同一引用多次出现只算一次（集合语义）', () {
    final Set<String> refs = referencedCanvasMedia(
      <String>[
        canvas(
          manifest: <String, String>{'same.png': 'image/png'},
          itemSrcs: <String>['same.png', 'same.png'],
        ),
      ],
      toPath: toPath,
    );
    expect(refs, <String>{'D:/data/canvas/same.png'});
  });
}
