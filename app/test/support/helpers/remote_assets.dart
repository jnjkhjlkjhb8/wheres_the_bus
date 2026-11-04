import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/assets/remote_assets.dart';

const _svg =
    '<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="1920"> '
    '<rect width="10" height="10"/></svg>';

// 1x1 transparent PNG.
const _png = <int>[
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
  0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xff, 0xff, 0x3f,
  0x00, 0x05, 0xfe, 0x02, 0xfe, 0xa7, 0x35, 0x81, 0x84, 0x00, 0x00, 0x00,
  0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
];

/// Puts every file the app mirrors from the router on disk, as a finished
/// sync would, and points [RemoteAssets.instance] at them.
void seedRemoteAssets({String version = '1'}) {
  final dir = Directory.systemTemp.createTempSync('remote_assets_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final files = <String, List<int>>{
    'mrt/TRTC_map_light.svg': _svg.codeUnits,
    'mrt/TRTC_map_dark.svg': _svg.codeUnits,
    for (final name in const ['BL', 'R', 'G', 'O', 'BR', 'Y', 'K'])
      'mrt/TRTC/$name.svg': _svg.codeUnits,
    'rails/TRA.svg': _svg.codeUnits,
    'rails/THSR.svg': _svg.codeUnits,
    for (final name in const [
      'wheelchair',
      'bicy',
      'lunchbox',
      'nursingroom',
      'everyday',
      'crossday',
    ])
      'rails/notes/serve-$name.png': _png,
  };
  for (final MapEntry(key: path, value: bytes) in files.entries) {
    File('${dir.path}/$path')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }
  RemoteAssets.instance.debugSeed(dir, {
    for (final path in files.keys) path: 'h$version-$path',
  });
}
