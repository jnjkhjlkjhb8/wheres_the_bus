import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/widgets/transit_visuals.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

PlanTransport transport(
  String mode, {
  String color = '',
  String category = '',
}) => PlanTransport(
  mode: mode,
  name: '',
  shortName: '',
  longName: '',
  headsign: '',
  category: category,
  routeColor: color,
);

void main() {
  final colors = ColorScheme.fromSeed(seedColor: Colors.black);
  test(
    'explicit RGB and ARGB route colors win, malformed colors fall back',
    () {
      expect(
        transitColor(transport('bus', color: ' #123456 '), colors),
        const Color(0xff123456),
      );
      expect(
        transitColor(transport('bus', color: '80123456'), colors),
        const Color(0x80123456),
      );
      expect(
        transitColor(transport('bus', color: 'invalid'), colors),
        AppTheme.markerBus,
      );
      expect(
        transitColor(transport('bus', color: 'FFFFFF'), colors),
        AppTheme.markerBus,
      );
      expect(transitColor(transport('walk'), colors), colors.onSurfaceVariant);
      expect(transitColor(transport('MRT'), colors), AppTheme.mrtBL);
      expect(transitColor(transport('hsr'), colors), AppTheme.trainThsr);
      expect(
        transitColor(transport('train', category: 'hsr'), colors),
        AppTheme.trainThsr,
      );
      expect(transitColor(transport('rail'), colors), AppTheme.trainRangecar);
      expect(transitIcon('walk'), Icons.directions_walk_rounded);
      expect(transitIcon('metro'), Icons.directions_subway_rounded);
      expect(transitIcon('bus'), Icons.directions_bus_rounded);
      expect(transitIcon('thsr'), Icons.train_rounded);
      expect(transitIcon('other'), Icons.directions_transit_rounded);
    },
  );

  test('line contrast keeps good colors and bounds its adjustments', () {
    expect(legibleLineColor(Colors.black, Colors.white), Colors.black);
    final darker = legibleLineColor(Colors.yellow, Colors.white);
    expect(
      darker.computeLuminance(),
      lessThan(Colors.yellow.computeLuminance()),
    );
    final lighter = legibleLineColor(const Color(0xff151515), Colors.black);
    expect(
      lighter.computeLuminance(),
      greaterThan(const Color(0xff151515).computeLuminance()),
    );
    // Lightening against this mid-tone surface exhausts all 50 steps.
    expect(
      legibleLineColor(const Color(0xffaaaaaa), const Color(0xffaaaaaa)),
      Colors.white,
    );
  });

  PlanSection section(
    String type, {
    int seconds = 0,
    String mode = 'bus',
    String name = '',
    String shortName = '',
  }) {
    const place = PlanPlace(
      name: '',
      type: '',
      location: PlanPoint(lat: 0, lng: 0),
      time: '',
    );
    return PlanSection(
      type: type,
      travelSummary: PlanTravelSummary(duration: seconds, length: 0),
      departure: place,
      arrival: place,
      transport: PlanTransport(
        mode: mode,
        name: name,
        shortName: shortName,
        longName: '',
        headsign: '',
        category: '',
        routeColor: '',
      ),
      intermediateStops: const [],
    );
  }

  test('only a transit section is not a walk, whatever its casing', () {
    expect(isWalk(section('walk')), isTrue);
    expect(isWalk(section('WALK')), isTrue);
    expect(isWalk(section('')), isTrue);
    expect(isWalk(section('transit')), isFalse);
    expect(isWalk(section('Transit')), isFalse);
  });

  test('a walk section keeps the walking glyph despite its transport mode', () {
    expect(
      sectionIcon(section('walk', mode: 'bus')),
      Icons.directions_walk_rounded,
    );
    expect(
      sectionIcon(section('transit', mode: 'bus')),
      Icons.directions_bus_rounded,
    );
  });

  test('every mode alias maps to its glyph and color, case-insensitively', () {
    const walk = Icons.directions_walk_rounded;
    const subway = Icons.directions_subway_rounded;
    const bus = Icons.directions_bus_rounded;
    const train = Icons.train_rounded;
    for (final mode in ['walk', 'Pedestrian']) {
      expect(transitIcon(mode), walk);
      expect(transitColor(transport(mode), colors), colors.onSurfaceVariant);
    }
    for (final mode in ['subway', 'Metro', 'mrt', 'TRAM']) {
      expect(transitIcon(mode), subway);
      expect(transitColor(transport(mode), colors), AppTheme.mrtBL);
    }
    for (final mode in ['bus', 'HighwayBus']) {
      expect(transitIcon(mode), bus);
      expect(transitColor(transport(mode), colors), AppTheme.markerBus);
    }
    for (final mode in ['rail', 'TRA', 'train', 'thsr', 'HSR']) {
      expect(transitIcon(mode), train);
    }
    for (final mode in ['thsr', 'HSR']) {
      expect(transitColor(transport(mode), colors), AppTheme.trainThsr);
    }
    for (final mode in ['rail', 'TRA', 'train']) {
      expect(transitColor(transport(mode), colors), AppTheme.trainRangecar);
      expect(
        transitColor(transport(mode, category: 'Hsr'), colors),
        AppTheme.trainThsr,
      );
      expect(
        transitColor(transport(mode, category: 'EXPRESS'), colors),
        AppTheme.trainRangecar,
      );
    }
    expect(transitIcon('ferry'), Icons.directions_transit_rounded);
    expect(transitColor(transport('ferry'), colors), colors.onSurface);
  });

  test('route colors tolerate a hash, blanks and any hex length', () {
    expect(
      transitColor(transport('bus', color: '#abcdef'), colors),
      const Color(0xffabcdef),
    );
    expect(
      transitColor(transport('bus', color: 'abcdef'), colors),
      const Color(0xffabcdef),
    );
    expect(
      transitColor(transport('bus', color: '   '), colors),
      AppTheme.markerBus,
    );
    expect(
      transitColor(transport('bus', color: '#'), colors),
      AppTheme.markerBus,
    );
    expect(
      transitColor(transport('bus', color: 'fff'), colors),
      const Color(0x00000fff),
    );
    expect(
      transitColor(transport('bus', color: 'zzzzzz'), colors),
      AppTheme.markerBus,
    );
  });

  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return (la > lb ? la + 0.05 : lb + 0.05) /
        (la > lb ? lb + 0.05 : la + 0.05);
  }

  test('a failing line is shifted by the smallest 2% lightness step', () {
    for (final (line, bg, darken) in [
      (Colors.yellow, Colors.white, true),
      (const Color(0xff151515), Colors.black, false),
      (const Color(0xff3a5a9a), const Color(0xff1a1a1a), false),
    ]) {
      final hsl = HSLColor.fromColor(line);
      final result = legibleLineColor(line, bg);
      var steps = 0;
      for (var k = 1; k <= 50; k++) {
        final l = (darken ? hsl.lightness - k * 0.02 : hsl.lightness + k * 0.02)
            .clamp(0.0, 1.0);
        if (contrast(hsl.withLightness(l).toColor(), bg) >= 3) {
          steps = k;
          break;
        }
      }
      final shift = steps * 0.02;
      final expected = hsl
          .withLightness(
            (darken ? hsl.lightness - shift : hsl.lightness + shift).clamp(
              0.0,
              1.0,
            ),
          )
          .toColor();
      expect(steps, greaterThan(1));
      expect(result, expected);
      expect(contrast(result, bg), greaterThanOrEqualTo(3));
    }
  });

  test('a line exactly at the contrast floor is kept', () {
    // Luminance of the background is chosen so contrast is 3.0 up to rounding;
    // anything at or above the floor must come back untouched.
    const bg = Color(0xffffffff);
    const line = Color(0xff767676);
    expect(contrast(line, bg), greaterThanOrEqualTo(3));
    expect(legibleLineColor(line, bg), line);
    const nearMiss = Color(0xffa0a0a0);
    expect(contrast(nearMiss, bg), lessThan(3));
    expect(legibleLineColor(nearMiss, bg), isNot(nearMiss));
  });

  test('labels and minutes come from the section', () {
    final i18n = lookupAppI18n(const Locale('zh'));
    expect(
      sectionLabel(i18n, section('walk', name: 'N', shortName: 'S')),
      i18n.goWalk,
    );
    expect(
      sectionLabel(i18n, section('transit', name: 'Name', shortName: 'Short')),
      'Short',
    );
    expect(sectionLabel(i18n, section('transit', name: 'Name')), 'Name');
    expect(minutesLabel(i18n, 7), i18n.minutesValue(7));
    expect(sectionMinutes(section('walk', seconds: 29)), 0);
    expect(sectionMinutes(section('walk', seconds: 30)), 1);
    expect(sectionMinutes(section('walk', seconds: 89)), 1);
    expect(sectionMinutes(section('walk', seconds: 90)), 2);
    expect(sectionMinutes(section('walk', seconds: -600)), 0);
    expect(sectionMinutes(section('walk', seconds: 999 * 60)), 999);
    expect(sectionMinutes(section('walk', seconds: 1000 * 60)), 999);
    expect(sectionMinutes(section('walk', seconds: 5000 * 60)), 999);
  });
}
