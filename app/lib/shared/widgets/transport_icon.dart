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

  static Color _mrtColor(TransportType t) {
    switch (t) {
      case TransportType.mrtBL:
        return AppTheme.mrtBL;
      case TransportType.mrtR:
        return AppTheme.mrtR;
      case TransportType.mrtG:
        return AppTheme.mrtG;
      case TransportType.mrtO:
        return AppTheme.mrtO;
      case TransportType.mrtBR:
        return AppTheme.mrtBR;
      case TransportType.mrtY:
        return AppTheme.mrtY;
      case TransportType.mrtAM:
        return AppTheme.mrtAM;
      case TransportType.mrtKG:
        return AppTheme.mrtKG;
      case TransportType.mrtKR:
        return AppTheme.mrtKR;
      case TransportType.mrtKO:
        return AppTheme.mrtKO;
      case TransportType.thsr:
      case TransportType.tra:
      case TransportType.bus:
      case TransportType.bike:
      case TransportType.busStop:
      case TransportType.location:
      case TransportType.walking:
        return Colors.grey;
    }
  }

  static bool _isMrt(TransportType t) => t.name.startsWith('mrt');

  static String? _svgAsset(TransportType t) {
    switch (t) {
      case TransportType.thsr:
        return 'assets/rails/THSR.svg';
      case TransportType.tra:
        return 'assets/rails/TRA.svg';
      case TransportType.bus:
        return null;
      case TransportType.bike:
        return null;
      case TransportType.busStop:
        return null;
      case TransportType.location:
        return null;
      case TransportType.mrtBL:
        return 'assets/mrt/TRTC/BL.svg';
      case TransportType.mrtR:
        return 'assets/mrt/TRTC/R.svg';
      case TransportType.mrtG:
        return 'assets/mrt/TRTC/G.svg';
      case TransportType.mrtO:
        return 'assets/mrt/TRTC/O.svg';
      case TransportType.mrtBR:
        return 'assets/mrt/TRTC/BR.svg';
      case TransportType.mrtY:
        return 'assets/mrt/TRTC/Y.svg';
      case TransportType.mrtAM:
        return 'assets/mrt/TYMC.svg';
      case TransportType.mrtKG:
        return 'assets/mrt/KLRT/C.svg';
      case TransportType.mrtKR:
        return 'assets/mrt/KRTC/R.svg';
      case TransportType.mrtKO:
        return 'assets/mrt/KRTC/O.svg';
      case TransportType.walking:
        return null;
    }
  }

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

    final svg = _svgAsset(type);
    if (svg != null) {
      final hheight = type == TransportType.thsr ? size * 0.5 : size;
      return SvgPicture.asset(
        svg,
        width: size,
        height: hheight,
        placeholderBuilder: (_) => _materialIcon(cs.onSurface),
      );
    }
    if (_isMrt(type)) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: _mrtColor(type),
          shape: BoxShape.circle,
        ),
      );
    }
    return _materialIcon(cs.onSurface);
  }
}
