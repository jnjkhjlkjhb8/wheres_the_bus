// The private painters and layers are reached by runtime type, so their
// members are read dynamically.
// ignore_for_file: avoid_dynamic_calls

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';
import 'package:wheres_the_bus/features/metro/widgets/metro_svg_map.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';

const _scale = 0.5;

MetroMapStation _station(String id) =>
    metroMapStations.firstWhere((s) => s.id == id);

Future<void> _pump(
  WidgetTester tester, {
  String? selected,
  Map<String, String> labels = const {},
  bool animate = true,
  Set<String>? ahead,
  String? board,
  String? picked,
  Brightness brightness = Brightness.light,
  double topPadding = 0,
  void Function(MetroMapStation)? onTap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: EdgeInsets.only(top: topPadding),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 540,
            height: 960,
            child: MetroSvgMap(
              selectedStationId: selected,
              stationLabels: labels,
              animate: animate,
              pickAheadIds: ahead,
              pickBoardId: board,
              pickedStationId: picked,
              onStationTap: onTap ?? (_) {},
            ),
          ),
        ),
      ),
    ),
  );
}

Finder _byType(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

double _labelOpacity(WidgetTester tester, String text) => tester
    .widget<FadeTransition>(
      find
          .ancestor(of: find.text(text), matching: find.byType(FadeTransition))
          .first,
    )
    .opacity
    .value;

void main() {
  test('line colours follow the first line code of a station id', () {
    expect(metroLineColor('BL13'), AppTheme.mrtBL);
    expect(metroLineColor('R04'), AppTheme.mrtR);
    expect(metroLineColor('G06'), AppTheme.mrtG);
    expect(metroLineColor('O17_Y18'), AppTheme.mrtO);
    expect(metroLineColor('BR02'), AppTheme.mrtBR);
    expect(metroLineColor('Y09'), AppTheme.mrtY);
    expect(metroLineColor('ZZ1'), AppTheme.mrtBL);
  });

  testWidgets('the viewer has fixed zoom limits and slack', (tester) async {
    await _pump(tester);
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(viewer.boundaryMargin, const EdgeInsets.all(120));
    expect(viewer.minScale, 0.45);
    expect(viewer.maxScale, 4);
    expect(viewer.constrained, isFalse);
  });

  testWidgets('the map sits under the app bar at its opening zoom', (
    tester,
  ) async {
    await _pump(tester, topPadding: 20);
    const gutter = (20 + AppBarMetrics.barHeight) / 0.8;
    expect(
      find.byWidgetPredicate(
        (w) => w is Padding && w.padding == const EdgeInsets.only(top: gutter),
      ),
      findsOneWidget,
    );
    final scale = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!
        .value
        .getMaxScaleOnAxis();
    expect(scale, closeTo(0.8, 1e-9));
  });

  testWidgets('the raster follows the theme', (tester) async {
    await _pump(tester);
    expect(
      (_byType('_RasterSvg').evaluate().single.widget as dynamic).asset,
      'assets/mrt/TRTC_map_light.svg',
    );
    await _pump(tester, brightness: Brightness.dark);
    await tester.pump(const Duration(seconds: 1));
    expect(
      (_byType('_RasterSvg').evaluate().single.widget as dynamic).asset,
      'assets/mrt/TRTC_map_dark.svg',
    );
  });

  testWidgets('station buttons only appear after the 350ms defer', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    await tester.pump(const Duration(milliseconds: 349));
    expect(find.bySemanticsLabel('BL13 善導寺'), findsNothing);
    await tester.pump(const Duration(milliseconds: 2));
    expect(find.bySemanticsLabel('BL13 善導寺'), findsOneWidget);
    handle.dispose();
  });

  group('labels', () {
    testWidgets('with nothing selected they animate in without delay', (
      tester,
    ) async {
      await _pump(tester, labels: {'BL01': 'x'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(AppMotion.short + const Duration(milliseconds: 20));
      expect(_labelOpacity(tester, 'x'), 1);
    });

    testWidgets('a label waits a quarter millisecond per unit of distance', (
      tester,
    ) async {
      final from = _station('BL13');
      final to = _station('BL01');
      final distance = math.sqrt(
        math.pow(to.x - from.x, 2) + math.pow(to.y - from.y, 2),
      );
      final delay = (distance * 0.25).toInt();
      await _pump(tester, selected: 'BL13', labels: {'BL01': 'far'});
      await tester.pump();
      await tester.pump(Duration(milliseconds: delay - 30));
      expect(_labelOpacity(tester, 'far'), 0);
      await tester.pump(const Duration(milliseconds: 90));
      await tester.pump(const Duration(milliseconds: 40));
      expect(_labelOpacity(tester, 'far'), greaterThan(0));
    });

    testWidgets('labels are 4px, heavy and ink or white by theme', (
      tester,
    ) async {
      await _pump(tester, labels: {'BL01': 'x'}, animate: false);
      var text = tester.widget<Text>(find.text('x'));
      expect(text.style!.fontSize, 4);
      expect(text.style!.fontWeight, FontWeight.w800);
      expect(text.style!.height, 1);
      expect(text.style!.color, Colors.black);
      await _pump(
        tester,
        labels: {'BL01': 'x'},
        animate: false,
        brightness: Brightness.dark,
      );
      await tester.pump(const Duration(seconds: 1));
      text = tester.widget<Text>(find.text('x'));
      expect(text.style!.color, Colors.white);
    });

    testWidgets('the entry starts at 0.92 scale and replays on reselect', (
      tester,
    ) async {
      await _pump(tester, selected: 'BL13', labels: {'BL13': 'x'});
      await tester.pump();
      final scale = tester.widget<ScaleTransition>(
        find
            .ancestor(
              of: find.text('x'),
              matching: find.byType(ScaleTransition),
            )
            .first,
      );
      expect(scale.scale.value, inInclusiveRange(0.92, 0.93));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(_labelOpacity(tester, 'x'), 1);
      await _pump(tester, selected: 'BL14_O07', labels: {'BL13': 'x'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(_labelOpacity(tester, 'x'), lessThan(1));
    });
  });

  group('pick mode', () {
    testWidgets('a scrim and one ring per reachable stop plus the board', (
      tester,
    ) async {
      await _pump(
        tester,
        ahead: const {'BL14_O07', 'BL15_BR10'},
        board: 'BL13',
        picked: 'BL14_O07',
      );
      final cs = Theme.of(tester.element(find.byType(MetroSvgMap))).colorScheme;
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is ColoredBox && w.color == cs.surface.withValues(alpha: 0.4),
        ),
        findsOneWidget,
      );
      final rings = _byType('_PickRing').evaluate().toList();
      expect(rings, hasLength(3));

      Border border(Element e) =>
          ((e.widget as dynamic).build(e) as dynamic)
                  .child
                  .child
                  .decoration
                  .border
              as Border;
      Positioned positioned(String id) {
        final s = _station(id);
        return tester
            .widgetList<Positioned>(
              find.descendant(
                of: _byType('_PickRing'),
                matching: find.byType(Positioned),
              ),
            )
            .firstWhere((p) => p.left == s.x * _scale - 8);
      }

      final board = positioned('BL13');
      expect(board.top, _station('BL13').y * _scale - 8);
      expect(board.width, 16);
      expect(board.height, 16);
      expect(border(rings.first), isA<Border>());
    });

    testWidgets('board and chosen stops are ink, the rest wear their line', (
      tester,
    ) async {
      await _pump(
        tester,
        ahead: const {'BL14_O07', 'BL15_BR10'},
        board: 'BL13',
        picked: 'BL14_O07',
      );
      final cs = Theme.of(tester.element(find.byType(MetroSvgMap))).colorScheme;
      final decorations = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: _byType('_PickRing'),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((d) => d.decoration as BoxDecoration)
          .toList();
      expect(decorations, hasLength(3));
      final colors = decorations.map((d) => (d.border! as Border).top.color);
      expect(
        colors,
        unorderedEquals([
          cs.onSurface,
          cs.onSurface,
          metroLineColor('BL15_BR10'),
        ]),
      );
      final doubled = decorations.where((d) => d.boxShadow != null).toList();
      expect(doubled, hasLength(1));
      expect((doubled.single.border! as Border).top.width, 3);
      expect(
        decorations
            .where((d) => d.boxShadow == null)
            .map(
              (d) => (d.border! as Border).top.width,
            ),
        everyElement(2),
      );
      expect(doubled.single.boxShadow!.map((b) => b.spreadRadius), [2, 4]);
    });

    testWidgets('without a pick there is no scrim and no ring', (tester) async {
      await _pump(tester);
      expect(_byType('_PickRing'), findsNothing);
      expect(
        find.byType(ColoredBox).evaluate().where((e) {
          final w = e.widget as ColoredBox;
          return w.color.a > 0.39 && w.color.a < 0.41;
        }),
        isEmpty,
      );
    });
  });

  group('hit layer', () {
    Future<dynamic> layer(WidgetTester tester) async {
      await _pump(tester, animate: false);
      return tester.state(_byType('_StationHitLayer'));
    }

    testWidgets('taps within 22px resolve, the edge included', (tester) async {
      final state = await layer(tester);
      final s = _station('BL01');
      final center = Offset(s.x * _scale, s.y * _scale);
      MetroMapStation? at(Offset o) =>
          state.nearestStation(o) as MetroMapStation?;
      expect(at(center)?.id, s.id);
      expect(at(center + const Offset(-22, 0))?.id, s.id);
      expect(at(center + const Offset(-22.01, 0)), isNull);
      expect(at(center + const Offset(0, -20))?.id, s.id);
      expect(at(const Offset(-500, -500)), isNull);
    });

    testWidgets('a press tints the station with its line colour', (
      tester,
    ) async {
      await _pump(tester, animate: false);
      await tester.pump(const Duration(milliseconds: 400));
      final s = _station('BL13');
      final origin = tester.getTopLeft(_byType('_StationHitLayer'));
      final gesture = await tester.startGesture(
        origin + Offset(s.x * _scale, s.y * _scale) * 0.8,
      );
      await tester.pump(const Duration(milliseconds: 200));
      bool tinted(DecoratedBox d) {
        final decoration = d.decoration;
        return decoration is BoxDecoration &&
            decoration.shape == BoxShape.circle &&
            decoration.color == AppTheme.mrtBL.withValues(alpha: 0.16);
      }

      expect(
        tester
            .widgetList<DecoratedBox>(find.byType(DecoratedBox))
            .where(tinted),
        hasLength(1),
      );
      await gesture.up();
      await tester.pump();
      expect(
        tester
            .widgetList<DecoratedBox>(find.byType(DecoratedBox))
            .where(tinted),
        isEmpty,
      );
    });

    testWidgets('semantics buttons cover 44px and tap through', (tester) async {
      final handle = tester.ensureSemantics();
      MetroMapStation? tapped;
      await _pump(tester, animate: false, onTap: (s) => tapped = s);
      await tester.pump(const Duration(milliseconds: 400));
      final rect = tester.getRect(find.bySemanticsLabel('BL13 善導寺'));
      expect(rect.width, closeTo(44 * 0.8, 1e-6));
      tester.semantics.tap(find.semantics.byLabel('BL13 善導寺'));
      await tester.pump();
      expect(tapped?.id, 'BL13');
      handle.dispose();
    });
  });

  group('selection marker', () {
    testWidgets('it is sized to the ping bound and keyed by station', (
      tester,
    ) async {
      await _pump(tester, selected: 'BL13', animate: false);
      final marker = _byType('_SelectedMarker');
      expect(marker, findsOneWidget);
      expect(
        ((marker.evaluate().single.widget as dynamic).key as ValueKey).value,
        'BL13',
      );
      final box = tester.widget<Positioned>(
        find.descendant(of: marker, matching: find.byType(Positioned)).first,
      );
      final s = _station('BL13');
      expect(box.left, s.x * _scale - 52 * _scale);
      expect(box.top, s.y * _scale - 52 * _scale);
      expect(box.width, 104 * _scale);
      expect(box.height, 104 * _scale);
    });

    testWidgets('halo, ring and ping are sized in map units', (tester) async {
      await _pump(tester, selected: 'BL13', animate: false);
      final marker = _byType('_SelectedMarker');
      final halo = tester.widget<Container>(
        find.descendant(of: marker, matching: find.byType(Container)).first,
      );
      expect(halo.constraints!.maxWidth, 52 * _scale);
      expect(halo.constraints!.maxHeight, 52 * _scale);
      expect(
        (halo.decoration! as BoxDecoration).color,
        AppTheme.mrtBL.withValues(alpha: 0.14),
      );
      final paints = tester
          .widgetList<CustomPaint>(
            find.descendant(of: marker, matching: find.byType(CustomPaint)),
          )
          .where((p) => p.painter.runtimeType.toString() == '_RingPainter')
          .toList();
      expect(paints, hasLength(2));
      final ring = paints.firstWhere(
        (p) => (p.painter as dynamic).opacity == 1,
      );
      expect(ring.size, const Size.square(40 * _scale));
      expect((ring.painter as dynamic).strokeWidth, 4 * _scale);
      final ping = paints.firstWhere(
        (p) => (p.painter as dynamic).opacity != 1,
      );
      expect(ping.size, const Size.square(2 * 52 * _scale));
      expect((ping.painter as dynamic).strokeWidth, 2.5 * _scale);
      expect((ping.painter as dynamic).opacity, 0);
    });

    testWidgets('the ping grows from the ring and fades out', (tester) async {
      await _pump(tester, selected: 'BL13');
      await tester.pump();
      CustomPaint ping() => tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: _byType('_SelectedMarker'),
              matching: find.byType(CustomPaint),
            ),
          )
          .where((p) => p.painter.runtimeType.toString() == '_RingPainter')
          .firstWhere(
            (p) => (p.painter as dynamic).strokeWidth == 2.5 * _scale,
          );
      expect(ping().size.width, closeTo(2 * 20 * _scale, 1));
      expect((ping().painter as dynamic).opacity, closeTo(0.4, 0.02));
      await tester.pump(const Duration(milliseconds: 340));
      final mid = (ping().painter as dynamic).opacity as double;
      expect(mid, inExclusiveRange(0, 0.4));
      expect(ping().size.width, greaterThan(2 * 20 * _scale));
      await tester.pump(const Duration(milliseconds: 400));
      expect((ping().painter as dynamic).opacity, 0);
      expect(ping().size.width, closeTo(2 * 52 * _scale, 1e-6));
    });

    testWidgets('turning animation off settles the ping', (tester) async {
      await _pump(tester, selected: 'BL13');
      await tester.pump(const Duration(milliseconds: 100));
      await _pump(tester, selected: 'BL13', animate: false);
      await tester.pump();
      final ping = tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: _byType('_SelectedMarker'),
              matching: find.byType(CustomPaint),
            ),
          )
          .firstWhere(
            (p) => (p.painter as dynamic).strokeWidth == 2.5 * _scale,
          );
      expect((ping.painter as dynamic).opacity, 0);
    });

    testWidgets('reduced motion and disabled animation both settle it', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: SizedBox(
                width: 540,
                height: 960,
                child: MetroSvgMap(
                  selectedStationId: 'BL13',
                  onStationTap: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final ping = tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: _byType('_SelectedMarker'),
              matching: find.byType(CustomPaint),
            ),
          )
          .firstWhere(
            (p) => (p.painter as dynamic).strokeWidth == 2.5 * _scale,
          );
      expect((ping.painter as dynamic).opacity, 0);
    });
  });

  group('ring painter', () {
    CustomPainter painter(WidgetTester tester, {double opacity = 1}) => tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: _byType('_SelectedMarker'),
            matching: find.byType(CustomPaint),
          ),
        )
        .map((p) => p.painter!)
        .firstWhere((p) => (p as dynamic).opacity == 1);

    testWidgets('repaints only when its inputs change', (tester) async {
      await _pump(tester, selected: 'BL13', animate: false);
      final a = painter(tester) as dynamic;
      await _pump(tester, selected: 'BL13', animate: false);
      final same = painter(tester) as dynamic;
      expect(same.shouldRepaint(a), isFalse);
      await _pump(tester, selected: 'R04', animate: false);
      final other = painter(tester) as dynamic;
      expect(other.shouldRepaint(a), isTrue);
    });

    testWidgets('it draws the stroke inside its bounds', (tester) async {
      await _pump(tester, selected: 'BL13', animate: false);
      final p = painter(tester);
      final calls = <(Offset, double, double)>[];
      final recorder = _RecordingCanvas(calls);
      p.paint(recorder, const Size.square(40));
      expect(calls.single.$1, const Offset(20, 20));
      expect(calls.single.$2, closeTo(20 - 4 * _scale / 2, 1e-9));
      expect(calls.single.$3, closeTo(4 * _scale, 1e-9));
    });
  });
}

class _RecordingCanvas implements Canvas {
  _RecordingCanvas(this.calls);
  final List<(Offset, double, double)> calls;

  @override
  void drawCircle(Offset c, double radius, Paint paint) =>
      calls.add((c, radius, paint.strokeWidth));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
