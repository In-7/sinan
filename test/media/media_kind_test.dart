import 'package:flutter_test/flutter_test.dart';
import 'package:sinan/src/media/media_kind.dart';

/// 附件类型判定（视频 Tier 0，2026-11-17）：选择器放行、待发暂存、落库 kind
/// 三处共用这一份判定，这里钉住它的边界。
void main() {
  test('kindForPath：视频扩展名判 video（大小写不敏感）', () {
    expect(kindForPath(r'C:\a\b.mp4'), 'video');
    expect(kindForPath('clip.MOV'), 'video');
    expect(kindForPath('a.tar.mkv'), 'video');
    expect(kindForPath('movie.webm'), 'video');
    expect(kindForPath('wmv 文件.WMV'), 'video');
  });

  test('kindForPath：其余判 image（含无扩展名 / 点结尾）', () {
    expect(kindForPath('x.png'), 'image');
    expect(kindForPath('photo.JPEG'), 'image');
    expect(kindForPath('noext'), 'image');
    expect(kindForPath('trailing.'), 'image');
    expect(kindForPath('video.notmp4'), 'image', reason: '只认整段扩展名');
  });

  test('放行清单：非空且互斥', () {
    expect(kImageExtensions, isNotEmpty);
    expect(kVideoExtensions, isNotEmpty);
    expect(kImageExtensions.intersection(kVideoExtensions), isEmpty);
  });
}
