import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/widgets/transport_icon.dart';

void main() {
  const assets = <TransportType, String>{
    TransportType.thsr: 'assets/rails/THSR.svg',
    TransportType.tra: 'assets/rails/TRA.svg',
    TransportType.mrtBL: 'assets/mrt/TRTC/BL.svg',
    TransportType.mrtR: 'assets/mrt/TRTC/R.svg',
    TransportType.mrtG: 'assets/mrt/TRTC/G.svg',
    TransportType.mrtO: 'assets/mrt/TRTC/O.svg',
    TransportType.mrtBR: 'assets/mrt/TRTC/BR.svg',
    TransportType.mrtY: 'assets/mrt/TRTC/Y.svg',
  };
  const lineColors = <TransportType, Color>{
    TransportType.mrtAM: AppTheme.mrtAM,
    TransportType.mrtKG: AppTheme.mrtKG,
    TransportType.mrtKR: AppTheme.mrtKR,
    TransportType.mrtKO: AppTheme.mrtKO,
  };
  const icons = <TransportType, IconData>{
    TransportType.bus: Icons.directions_bus_rounded,
    TransportType.bike: Icons.pedal_bike_rounded,
    TransportType.busStop: Symbols.bus_map_pin_rounded,
    TransportType.location: Icons.location_on_rounded,
    TransportType.walking: Icons.directions_walk_rounded,
  };

  for (final type in TransportType.values) {
    testWidgets('${type.name} keeps its identity and requested dimensions', (
      tester,
    ) async {
      const foreground = Color(0xFF123456);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: const ColorScheme.light(onSurface: foreground),
          ),
          home: TransportIcon(type: type, size: 40),
        ),
      );
      final asset = assets[type];
      if (asset != null) {
        final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
        expect((picture.bytesLoader as SvgAssetLoader).assetName, asset);
        expect(picture.width, 40);
        expect(picture.height, type == TransportType.thsr ? 20 : 40);
        final placeholder =
            picture.placeholderBuilder!(
                  tester.element(find.byType(SvgPicture)),
                )
                as Icon;
        expect(placeholder.icon, Icons.directions_walk_rounded);
        expect(placeholder.size, 40);
        expect(placeholder.color, foreground);
      } else {
        final icon = tester.widget<Icon>(find.byType(Icon));
        expect(
          icon.icon,
          lineColors.containsKey(type) ? Icons.train_rounded : icons[type],
        );
        expect(find.byType(SvgPicture), findsNothing);
        expect(icon.size, 40);
        expect(icon.color, lineColors[type] ?? foreground);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the default icon size is 24', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: TransportIcon(type: TransportType.bus)),
    );
    expect(tester.widget<Icon>(find.byType(Icon)).size, 24);
  });
}
