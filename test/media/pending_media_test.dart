import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/domain/note.dart';
import 'package:sinan/src/media/pending_media.dart';

/// 待发附件暂存的落盘语义（视频 Tier 0，2026-11-17）：
/// 字节条目写盘、文件条目**提交时才拷贝**（大视频不整读内存），源文件不动。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sinan_pending_media');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('字节条目（剪贴板位图）：提交时写盘，内容一致', () async {
    final List<StreamAttachmentInput> out = await materializePendingMedia(
      tmp.path,
      <PendingMedia>[
        PendingMedia(
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
          ext: '.png',
          kind: 'image',
        ),
      ],
    );
    expect(out.single.kind, 'image');
    expect(out.single.path, startsWith(tmp.path), reason: '落在给定私有目录');
    expect(File(out.single.path).readAsBytesSync(), <int>[1, 2, 3]);
  });

  test('文件条目（视频）：不发不落盘、提交时才拷贝副本，源文件保留', () async {
    final File src = File('${tmp.path}${Platform.pathSeparator}clip.mp4');
    src.writeAsBytesSync(Uint8List.fromList(<int>[9, 9, 9]));
    final String destDir = '${tmp.path}${Platform.pathSeparator}stream_media';

    // 只是"待发"：私有目录还没影子（零孤儿——不发就不落盘）。
    final PendingMedia pending = PendingMedia(
      sourcePath: src.path,
      ext: '.mp4',
      kind: 'video',
    );
    expect(Directory(destDir).existsSync(), isFalse);

    final List<StreamAttachmentInput> out = await materializePendingMedia(
      destDir,
      <PendingMedia>[pending],
    );

    expect(out.single.kind, 'video');
    expect(out.single.path, isNot(src.path), reason: '落库的是私有副本，不是源路径');
    expect(File(out.single.path).readAsBytesSync(), <int>[
      9,
      9,
      9,
    ], reason: '副本内容一致');
    expect(src.existsSync(), isTrue, reason: '源文件不动');
    expect(
      out.single.path.startsWith(destDir),
      isTrue,
      reason: '副本进 stream_media/',
    );
  });
}
