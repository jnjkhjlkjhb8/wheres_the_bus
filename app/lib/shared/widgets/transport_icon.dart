import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/assets/remote_image.dart';

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
    TransportType.thsr: 'rails/THSR.svg',
    TransportType.tra: 'rails/TRA.svg',
    TransportType.mrtBL: 'mrt/TRTC/BL.svg',
    TransportType.mrtR: 'mrt/TRTC/R.svg',
    TransportType.mrtG: 'mrt/TRTC/G.svg',
    TransportType.mrtO: 'mrt/TRTC/O.svg',
    TransportType.mrtBR: 'mrt/TRTC/BR.svg',
    TransportType.mrtY: 'mrt/TRTC/Y.svg',
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
      // A rail logo that has not loaded must still read as a train; a walking
      // figure there says the wrong thing about the mode.
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
      TransportType.mrtKO => Icons.train_rounded,
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
      return RemoteSvg(
        svg,
        width: size,
        height: hheight,
        fallback: (_) => _materialIcon(cs.onSurface),
      );
    }
    final lineColor = _lineColors[type];
    if (lineColor != null) {
      return Icon(Icons.train_rounded, size: size, color: lineColor);
    }
    return _materialIcon(cs.onSurface);
  }
}
