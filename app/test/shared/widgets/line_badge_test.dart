import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/widgets/line_badge.dart';

import '../../support/helpers/remote_assets.dart';

void main() {
  setUp(seedRemoteAssets);

  const scheme = ColorScheme.light(onSurfaceVariant: Color(0xFF123456));
  const colors = <String, Color>{
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
  for (final entry in colors.entries) {
    test('${entry.key} matches a line and a lowercase station code', () {
      expect(mrtLineColor(entry.key, scheme), entry.value);
      expect(mrtLineColor('${entry.key.toLowerCase()}01', scheme), entry.value);
    });
  }
  test('unknown, empty and non-prefix codes use the theme fallback', () {
    for (final code in ['', 'X01', '1R', 'K', 'ZBL01']) {
      expect(mrtLineColor(code, scheme), scheme.onSurfaceVariant);
    }
  });
  test('TRTC assets are exact line codes', () {
    for (final code in ['BL', 'R', 'G', 'O', 'BR', 'Y']) {
      expect(LineBadge.trtcAsset(code), 'mrt/TRTC/$code.svg');
    }
    for (final code in ['', 'bl', 'BL01', 'A', 'KO', 'KR']) {
      expect(LineBadge.trtcAsset(code), isNull);
    }
  });

  testWidgets('fallback keeps the label legible on dark and light colors', (
    tester,
  ) async {
    for (final color in [Colors.black, Colors.white]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: LineBadge(label: 'BL', color: color, size: 40),
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('BL'));
      expect(
        text.style!.color,
        color == Colors.black ? Colors.white : Colors.black87,
      );
      expect(text.style!.fontSize, 14);
      expect(text.style!.fontWeight, FontWeight.w700);
      expect(text.style!.height, 1);
      expect(text.textAlign, TextAlign.center);
      final container = tester.widget<Container>(find.byType(Container));
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, color);
      expect(
        decoration.borderRadius,
        BorderRadius.circular(AppTheme.radiusChip),
      );
      expect(tester.getSize(find.byType(LineBadge)), const Size(40, 40));
    }
  });
  testWidgets('font size has a readable minimum and scales below its cap', (
    tester,
  ) async {
    for (final entry in {10.0: 9.0, 30.0: 10.8}.entries) {
      await tester.pumpWidget(
        MaterialApp(
          home: LineBadge(label: 'R', color: Colors.black, size: entry.key),
        ),
      );
      expect(
        tester.widget<Text>(find.text('R')).style!.fontSize,
        closeTo(entry.value, 1e-12),
      );
    }
  });
  testWidgets('SVG badges use the supplied asset, dimensions and fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LineBadge(
          label: 'G',
          color: Colors.black,
          svgAsset: 'mrt/TRTC/G.svg',
        ),
      ),
    );
    final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(
      (picture.bytesLoader as SvgFileLoader).file.path,
      endsWith('mrt/TRTC/G.svg'),
    );
    expect(picture.width, 25);
    expect(picture.height, 25);
    final fallback =
        picture.placeholderBuilder!(tester.element(find.byType(SvgPicture)))
            as Container;
    expect((fallback.child! as Text).data, 'G');
    expect((fallback.decoration! as BoxDecoration).color, Colors.black);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
