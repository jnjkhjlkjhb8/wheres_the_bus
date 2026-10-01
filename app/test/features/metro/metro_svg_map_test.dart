import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';
import 'package:wheres_the_bus/features/metro/widgets/metro_svg_map.dart';

void main() {
  testWidgets(
    'tap offset toward a neighbouring station resolves via nearest-target '
    'arbitration instead of picking whichever region is painted on top',
    (tester) async {
      final semanticsHandle = tester.ensureSemantics();
      MetroMapStation? tapped;

      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MetroSvgMap(
              animate: false,
              onStationTap: (s) => tapped = s,
            ),
          ),
        ),
      );
      // Flush the 350ms hit-target defer timer.
      await tester.pump(const Duration(milliseconds: 400));

      final bl21 = tester.getRect(find.bySemanticsLabel('BL21 昆陽'));
      final bl22 = tester.getRect(find.bySemanticsLabel('BL22 南港'));
      final c21 = bl21.center;
      final c22 = bl22.center;

      // A point 30% of the way from BL21 to BL22 is off BL21's exact
      // center but still much closer to BL21 than BL22.
      final nearBl21 = Offset.lerp(c21, c22, 0.3)!;
      await tester.tapAt(nearBl21);
      await tester.pump();
      expect(tapped?.id, 'BL21');

      tapped = null;
      // A point 80% of the way there is closer to BL22 and — because both
      // stations' 44px regions cover this point — only correct nearest-
      // target arbitration (not paint order, not list order) picks BL22.
      final nearBl22 = Offset.lerp(c21, c22, 0.8)!;
      await tester.tapAt(nearBl22);
      await tester.pump();
      expect(tapped?.id, 'BL22');

      semanticsHandle.dispose();
    },
  );

  testWidgets(
    'label animation is already at its final state when '
    'MediaQuery.disableAnimations is set, instead of waiting out its delay',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: MetroSvgMap(
                selectedStationId: 'BL01',
                stationLabels: const {'BL02': '5'},
                onStationTap: (_) {},
              ),
            ),
          ),
        ),
      );
      // A single build/frame — no waiting for the label's entry delay or
      // its 200ms scale/fade animation.
      await tester.pump();

      // MaterialApp's default (Zoom) page-transition builder also wraps
      // the route in a ScaleTransition/FadeTransition; `.first` picks the
      // closest ancestor to the label text, which is the label's own.
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(of: find.text('5'), matching: find.byType(FadeTransition))
            .first,
      );
      final scale = tester.widget<ScaleTransition>(
        find
            .ancestor(
              of: find.text('5'),
              matching: find.byType(ScaleTransition),
            )
            .first,
      );
      expect(fade.opacity.value, 1);
      expect(scale.scale.value, 1);
    },
  );

  testWidgets(
    'selecting a station leaves the map transform untouched, so a station '
    'tapped while zoomed in stays exactly under the finger',
    (tester) async {
      // Shorter than the rendered map (693px at this width), so vertical
      // headroom genuinely exists — this is the geometry in which an
      // auto-pan would have had room to fire.
      tester.view.physicalSize = const Size(390, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Widget build(String? id) => MaterialApp(
        home: Scaffold(
          body: MetroSvgMap(
            animate: false,
            selectedStationId: id,
            onStationTap: (_) {},
          ),
        ),
      );

      Matrix4 transform() => tester
          .widget<Transform>(
            find
                .descendant(
                  of: find.byType(InteractiveViewer),
                  matching: find.byType(Transform),
                )
                .first,
          )
          .transform;

      await tester.pumpWidget(build(null));
      final before = transform().clone();

      // 新店 (G01, y=1686 of 1920) renders far below this viewport — the
      // station the old auto-pan moved the furthest.
      await tester.pumpWidget(build('G01'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(transform(), before);
    },
  );

  testWidgets(
    'a width-bucket change evicts the bitmap rasterised for the old width '
    'instead of stranding its ~20MB texture for the life of the process',
    (tester) async {
      // 1080 logical px at dpr 1 buckets to a 2160px-wide bitmap; 540 at dpr 1
      // buckets to the 1080px floor. Same asset, two different widths — the
      // case a same-asset check lets through.
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MetroSvgMap(animate: false, onStationTap: (_) {}),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(MetroSvgMap.rasterCacheSize, 1);

      tester.view.physicalSize = const Size(540, 960);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MetroSvgMap(animate: false, onStationTap: (_) {}),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      // The old bucket has no mounted holder left, so it goes: one live
      // bitmap, not one per width the app has ever been laid out at.
      expect(MetroSvgMap.rasterCacheSize, 1);
    },
  );
}
