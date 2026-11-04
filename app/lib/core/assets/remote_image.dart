import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:wheres_the_bus/core/assets/remote_assets.dart';

/// A square picture served by [RemoteAssets]. The slot keeps its size while the
/// file is missing, so rows do not shift when the first sync lands.
class RemoteImage extends StatelessWidget {
  const RemoteImage(this.path, {required this.size, super.key});

  final String path;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: RemoteAssets.instance.revision,
      builder: (context, _, _) {
        final asset = RemoteAssets.instance.lookup(path);
        return SizedBox.square(
          dimension: size,
          child: asset == null
              ? null
              : Image.file(asset.file, fit: BoxFit.contain),
        );
      },
    );
  }
}

/// An SVG served by [RemoteAssets]; [fallback] stands in until the file arrives.
class RemoteSvg extends StatelessWidget {
  const RemoteSvg(
    this.path, {
    required this.width,
    required this.height,
    required this.fallback,
    super.key,
  });

  final String path;
  final double width;
  final double height;
  final WidgetBuilder fallback;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: RemoteAssets.instance.revision,
      builder: (context, _, _) {
        final asset = RemoteAssets.instance.lookup(path);
        if (asset == null) return fallback(context);
        return SvgPicture.file(
          asset.file,
          width: width,
          height: height,
          placeholderBuilder: fallback,
        );
      },
    );
  }
}
