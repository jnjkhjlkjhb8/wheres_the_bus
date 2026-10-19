import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';

const _mrtLineColors = <String, Color>{
  'BR': AppTheme.mrtBR,
  'BL': AppTheme.mrtBL,
  'R': AppTheme.mrtR,
  'G': AppTheme.mrtG,
  'O': AppTheme.mrtO,
  'Y': AppTheme.mrtY,
  'A': AppTheme.mrtAM,
  'C': AppTheme.mrtKG,
  'KO': AppTheme.mrtKO,
  'KR': AppTheme.mrtKR,
};

Color mrtLineColor(String lineCode, ColorScheme cs) {
  final code = lineCode.toUpperCase();
  for (final entry in _mrtLineColors.entries) {
    if (code.startsWith(entry.key)) return entry.value;
  }
  return cs.onSurfaceVariant;
}

class LineBadge extends StatelessWidget {
  const LineBadge({
    required this.label,
    required this.color,
    this.svgAsset,
    this.size = 25,
    super.key,
  });

  final String label;
  final Color color;
  final String? svgAsset;
  final double size;

  static String? trtcAsset(String code) => switch (code) {
    'BL' => 'assets/mrt/TRTC/BL.svg',
    'R' => 'assets/mrt/TRTC/R.svg',
    'G' => 'assets/mrt/TRTC/G.svg',
    'O' => 'assets/mrt/TRTC/O.svg',
    'BR' => 'assets/mrt/TRTC/BR.svg',
    'Y' => 'assets/mrt/TRTC/Y.svg',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final asset = svgAsset;
    if (asset == null) return _fallback();

    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      placeholderBuilder: (_) => _fallback(),
    );
  }

  Widget _fallback() {
    final textColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppTheme.radiusChip),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: textColor,
          fontSize: (size * 0.36).clamp(9, 14),
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}
