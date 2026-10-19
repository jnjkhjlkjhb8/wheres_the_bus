import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';

/// Supported transport icon types.
enum TransportType {
  /// Taiwan High Speed Rail.
  thsr,

  /// Taiwan Railways.
  tra,

  /// Taipei MRT blue line.
  mrtBL,

  /// MRT red line.
  mrtR,

  /// MRT green line.
  mrtG,

  /// MRT orange line.
  mrtO,

  /// Taipei MRT brown line.
  mrtBR,

  /// MRT yellow line.
  mrtY,

  /// Airport MRT.
  mrtAM,

  /// Kaohsiung light rail.
  mrtKG,

  /// Kaohsiung MRT red line.
  mrtKR,

  /// Kaohsiung MRT orange line.
  mrtKO,

  bus,

  bike,

  busStop,

  walking,
  location,
}

/// Displays an SVG, MRT color dot, or Material fallback for a transport type.
class TransportIcon extends StatelessWidget {
  const TransportIcon({
    required this.type,
    this.size = 24,
    super.key,
  });

  final TransportType type;

  /// Icon size in logical pixels.
  final double size;

  static const _svgAssets = <TransportType, String>{
    TransportType.thsr: 'assets/rails/THSR.svg',
    TransportType.tra: 'assets/rails/TRA.svg',
    TransportType.mrtBL: 'assets/mrt/TRTC/BL.svg',
    TransportType.mrtR: 'assets/mrt/TRTC/R.svg',
    TransportType.mrtG: 'assets/mrt/TRTC/G.svg',
    TransportType.mrtO: 'assets/mrt/TRTC/O.svg',
    TransportType.mrtBR: 'assets/mrt/TRTC/BR.svg',
    TransportType.mrtY: 'assets/mrt/TRTC/Y.svg',
  };

  // Missing logos must not turn an arrival row into an asset-load error.
  static const _lineColors = <TransportType, Color>{
    TransportType.mrtAM: AppTheme.mrtAM,
    TransportType.mrtKG: AppTheme.mrtKG,
    TransportType.mrtKR: AppTheme.mrtKR,
    TransportType.mrtKO: AppTheme.mrtKO,
  };

  Widget _materialIcon(Color color) {
    final icon = switch (type) {
      TransportType.bus => Icons.directions_bus_rounded,
      TransportType.bike => Icons.pedal_bike_rounded,
      TransportType.busStop => Symbols.bus_map_pin_rounded,
      TransportType.location => Icons.location_on_rounded,
      TransportType.thsr ||
      TransportType.tra ||
      TransportType.mrtBL ||
      TransportType.mrtR ||
      TransportType.mrtG ||
      TransportType.mrtO ||
      TransportType.mrtBR ||
      TransportType.mrtY ||
      TransportType.mrtAM ||
      TransportType.mrtKG ||
      TransportType.mrtKR ||
      TransportType.mrtKO ||
      TransportType.walking => Icons.directions_walk_rounded,
    };
    return Icon(icon, size: size, color: color);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final svg = _svgAssets[type];
    if (svg != null) {
      final hheight = type == TransportType.thsr ? size * 0.5 : size;
      return SvgPicture.asset(
        svg,
        width: size,
        height: hheight,
        placeholderBuilder: (_) => _materialIcon(cs.onSurface),
      );
    }
    final lineColor = _lineColors[type];
    if (lineColor != null) {
      return Icon(Icons.train_rounded, size: size, color: lineColor);
    }
    return _materialIcon(cs.onSurface);
  }
}
