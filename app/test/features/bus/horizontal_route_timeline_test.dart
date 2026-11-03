import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/timeline_stop.dart';
import 'package:wheres_the_bus/features/bus/view/bus_route_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';


typedef _Call = String;

String _lineStr(double x1, double x2, Color color) =>
    'line ($x1, 52.0)->($x2, 52.0) ${color.toARGB32()} w8.0 butt';

String _circleStr(
  Offset c,
  double r,
  Color color,
  PaintingStyle style,
  double width,
) => 'circle $c r$r ${color.toARGB32()} $style w$width';

/// Records the two draw calls the timeline painter makes; every other canvas
/// call is accepted and ignored.
class _RecordingCanvas implements Canvas {
  final calls = <_Call>[];

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => calls.add(
    'line (${p1.dx}, ${p1.dy})->(${p2.dx}, ${p2.dy}) '
    '${paint.color.toARGB32()} w${paint.strokeWidth} ${paint.strokeCap.name}',
  );

  @override
  void drawCircle(Offset c, double radius, Paint paint) => calls.add(
    'circle $c r$radius ${paint.color.toARGB32()} ${paint.style} '
    'w${paint.strokeWidth}',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _stops = [
  TimelineStop(uid: 'a', name: 'A站', active: true),
  TimelineStop(
    uid: 'b',
    name: 'B站',
    active: true,
    isBuffer: true,
    state: TimelineStopState.arriving,
    etaMinutes: 10,
  ),
  TimelineStop(
    uid: 'c',
    name: 'C站',
    isBuffer: true,
    state: TimelineStopState.approaching,
    isLiveEta: true,
    etaMinutes: 5,
    plate: 'ABC-123',
  ),
  TimelineStop(uid: 'd', name: 'D站', primaryTime: '8'),
  TimelineStop(uid: 'e', name: 'E站', primaryTime: '1', isLiveEta: true),
];

bool _isTimelinePainter(Widget w) =>
    w is CustomPaint &&
    w.painter.runtimeType.toString() == '_HorizontalTimelinePainter';

void main() {
  late ScrollController controller;
  setUp(() => controller = ScrollController());
  tearDown(() => controller.dispose());

  Future<void> pump(
    WidgetTester tester, {
    List<TimelineStop> stops = _stops,
    String? flash,
    void Function(String)? onStopTap,
    void Function(String)? onVehicleTap,
    ThemeData? theme,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: theme,
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: HorizontalRouteTimeline(
            stops: stops,
            direction: 0,
            controller: controller,
            flashStopUid: flash,
            onStopTap: onStopTap,
            onVehicleTap: onVehicleTap,
          ),
        ),
      ),
    ),
  );

  ColorScheme scheme(WidgetTester tester) => Theme.of(
    tester.element(find.byType(HorizontalRouteTimeline)),
  ).colorScheme;

  List<CustomPainter> painters(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byWidgetPredicate(_isTimelinePainter))
      .map((p) => p.painter!)
      .toList();

  List<_Call> draw(CustomPainter painter) {
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(120, 120));
    return canvas.calls;
  }

  double cellLeft(int i) => 20.0 + 120 * i;

  testWidgets('the strip is 120 tall with one 120-wide cell per stop', (
    tester,
  ) async {
    await pump(tester);

    expect(tester.getSize(find.byType(HorizontalRouteTimeline)).height, 120);
    expect(painters(tester), hasLength(5));
    expect(tester.getTopLeft(find.text('A站')).dx, cellLeft(0) + 8);
    expect(tester.getTopLeft(find.text('B站')).dx, cellLeft(1) + 8);
  });

  testWidgets('rails join neighbours and light up between active stops', (
    tester,
  ) async {
    await pump(tester);
    final cs = scheme(tester);
    final rail = cs.onSurfaceVariant;
    final lit = cs.primary;
    List<_Call> lines(int i) =>
        draw(painters(tester)[i]).where((c) => c.startsWith('line')).toList();
    _Call line(double x1, double x2, Color color) => _lineStr(x1, x2, color);

    expect(lines(0), [line(60, 120, lit)]);
    expect(lines(1), [line(0, 60, lit), line(60, 120, rail)]);
    expect(lines(2), [line(0, 60, rail), line(60, 120, rail)]);
    expect(lines(3), [line(0, 60, rail), line(60, 120, rail)]);
    expect(lines(4), [line(0, 60, rail)]);
  });

  testWidgets('a dotted drop joins only buffer stops that border each other', (
    tester,
  ) async {
    await pump(tester);
    final cs = scheme(tester);

    List<_Call> dots(int i) =>
        draw(painters(tester)[i]).where((c) => c.contains(' r1.0 ')).toList();

    final expected = [
      for (final y in [58.0, 62.0, 66.0])
        _circleStr(
          Offset(90, y),
          1,
          cs.onSurfaceVariant.withValues(alpha: 0.6),
          PaintingStyle.fill,
          1.5,
        ),
    ];
    expect(dots(1), expected);
    for (final i in [0, 2, 3, 4]) {
      expect(dots(i), isEmpty, reason: 'cell $i');
    }
  });

  testWidgets('every stop is a surface disc inside a state-coloured ring', (
    tester,
  ) async {
    await pump(tester, flash: 'd');
    final cs = scheme(tester);
    final ring = <Color>[
      cs.primary,
      AppTheme.statusArriving,
      AppTheme.statusApproach,
      cs.primary,
      cs.onSurfaceVariant,
    ];

    for (var i = 0; i < 5; i++) {
      final discs = draw(
        painters(tester)[i],
      ).where((c) => c.contains(' r7.0 ')).toList();
      expect(discs, [
        _circleStr(const Offset(60, 52), 7, cs.surface, PaintingStyle.fill, 0),
        _circleStr(const Offset(60, 52), 7, ring[i], PaintingStyle.stroke, 2),
      ], reason: 'cell $i');
    }
  });

  testWidgets('without a flash only the active stop is emphasised', (
    tester,
  ) async {
    await pump(tester);
    final cs = scheme(tester);

    String ringOf(int i) =>
        draw(painters(tester)[i]).where((c) => c.startsWith('circle')).last;
    expect(
      ringOf(0),
      _circleStr(const Offset(60, 52), 7, cs.primary, PaintingStyle.stroke, 2),
    );
    expect(
      ringOf(3),
      _circleStr(
        const Offset(60, 52),
        7,
        cs.onSurfaceVariant,
        PaintingStyle.stroke,
        2,
      ),
    );
  });

  testWidgets('the painter repaints only when something it draws changes', (
    tester,
  ) async {
    await pump(tester);
    final before = painters(tester)[1];
    await pump(tester);
    expect(painters(tester)[1].shouldRepaint(before), isFalse);

    for (final changed in [
      _stops.map((s) => s.uid == 'b' ? _copy(s, buffer: false) : s),
      _stops.map((s) => s.uid == 'b' ? _copy(s, active: false) : s),
      _stops.map(
        (s) => s.uid == 'b' ? _copy(s, state: TimelineStopState.none) : s,
      ),
      _stops.map((s) => s.uid == 'c' ? _copy(s, buffer: false) : s),
      _stops.map((s) => s.uid == 'a' ? _copy(s, active: false) : s),
    ]) {
      await pump(tester, stops: changed.toList());
      expect(painters(tester)[1].shouldRepaint(before), isTrue);
    }
    await pump(tester, theme: ThemeData.dark());
    await tester.pumpAndSettle();
    expect(painters(tester)[1].shouldRepaint(before), isTrue);
    await pump(tester, stops: _stops.take(2).toList());
    expect(painters(tester)[1].shouldRepaint(before), isTrue);
  });

  testWidgets('the vehicle sits on the rail at the segment it is in', (
    tester,
  ) async {
    final tapped = <String>[];
    await pump(tester, onVehicleTap: tapped.add);
    final cs = scheme(tester);

    final arrows = find.byWidgetPredicate(
      (w) => w is SizedBox && w.width == 17 && w.height == 17,
    );
    expect(arrows, findsNWidgets(2));
    expect(tester.getTopLeft(arrows.first), Offset(cellLeft(2), 43.5));
    expect(tester.getTopLeft(arrows.last), Offset(cellLeft(4), 43.5));

    final plate = find.text('ABC-123');
    final plateBox = find.ancestor(
      of: plate,
      matching: find.byType(DecoratedBox),
    );
    expect(tester.getTopLeft(plateBox.first), Offset(cellLeft(2), 30.5));
    final style = tester.widget<Text>(plate).style!;
    expect(style.fontSize, 9);
    expect(style.height, 1.2);
    expect(style.fontWeight, FontWeight.w700);
    expect(style.color, cs.onSurface);

    await tester.tap(arrows.first);
    await tester.tap(arrows.last);
    expect(tapped, ['ABC-123']);
  });

  testWidgets('a cell is tappable only when the caller handles taps', (
    tester,
  ) async {
    final tapped = <String>[];
    await pump(tester, onStopTap: tapped.add);
    await tester.tapAt(Offset(cellLeft(3) + 60, 20));
    expect(tapped, ['d']);

    await pump(tester);
    tapped.clear();
    await tester.tapAt(Offset(cellLeft(3) + 60, 20));
    expect(tapped, isEmpty);
  });

  testWidgets('stop names weigh and colour by whether the stop is active', (
    tester,
  ) async {
    await pump(tester);
    final cs = scheme(tester);

    final active = tester.widget<Text>(find.text('A站'));
    expect(active.style!.fontWeight, FontWeight.w600);
    expect(active.style!.color, cs.onSurface);
    expect(active.maxLines, 2);
    expect(active.overflow, TextOverflow.ellipsis);
    expect(active.textAlign, TextAlign.center);
    final idle = tester.widget<Text>(find.text('D站'));
    expect(idle.style!.fontWeight, FontWeight.w400);
    expect(idle.style!.color, cs.onSurfaceVariant);
    expect(tester.getTopLeft(find.text('A站')).dy, 8);
  });

  testWidgets('each stop states its ETA in the matching style', (tester) async {
    await pump(tester);
    final cs = scheme(tester);
    final i18n = lookupAppI18n(const Locale('zh'));

    final arriving = tester.widget<Text>(find.text(i18n.etaArriving)).style!;
    expect(arriving.color, AppTheme.statusArriving);
    expect(arriving.fontWeight, FontWeight.w700);
    expect(arriving.fontSize, 10);
    final approaching = tester
        .widget<Text>(find.text(i18n.etaApproaching))
        .style!;
    expect(approaching.color, AppTheme.statusApproach);
    expect(approaching.fontWeight, FontWeight.w700);
    expect(approaching.fontSize, 10);
    final countdown = tester.widget<Text>(find.text('8')).style!;
    expect(countdown.color, cs.onSurface);
    expect(countdown.fontWeight, FontWeight.w600);
    expect(countdown.fontSize, 11);
    final soon = tester.widget<Text>(find.text('1')).style!;
    expect(soon.color, AppTheme.statusArriving);
    expect(soon.fontWeight, FontWeight.w700);
    expect(soon.fontSize, 11);
    expect(tester.getTopLeft(find.text('8')).dy, greaterThanOrEqualTo(70));
    expect(tester.getTopLeft(find.text(i18n.etaArriving)).dy, 70);
  });

  testWidgets('an active stop counts down in the primary colour', (
    tester,
  ) async {
    await pump(
      tester,
      stops: const [
        TimelineStop(uid: 'x', name: 'X', primaryTime: '9', active: true),
      ],
    );

    expect(
      tester.widget<Text>(find.text('9')).style!.color,
      scheme(tester).primary,
    );
  });

  testWidgets('a buffer band spans its run with rounded outer ends', (
    tester,
  ) async {
    await pump(tester);
    final cs = scheme(tester);
    final i18n = lookupAppI18n(const Locale('zh'));

    Finder band(int i) => find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          (w.decoration is BoxDecoration) &&
          (w.decoration as BoxDecoration).color == cs.surfaceContainerHighest &&
          (w.decoration as BoxDecoration).borderRadius is BorderRadius,
    );
    final bands = band(0).evaluate().toList();
    expect(bands, hasLength(2));
    final first = tester.getRect(find.byWidget(bands.first.widget));
    final second = tester.getRect(find.byWidget(bands.last.widget));
    expect(first, Rect.fromLTWH(cellLeft(1) + 5, 88, 115, 14));
    expect(second, Rect.fromLTWH(cellLeft(2), 88, 115, 14));
    expect(
      (bands.first.widget as DecoratedBox).decoration,
      BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(9)),
      ),
    );
    expect(
      (bands.last.widget as DecoratedBox).decoration,
      BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(9)),
      ),
    );

    final label = find.text(i18n.busBufferZone);
    expect(label, findsOneWidget);
    expect(tester.getTopLeft(label), Offset(cellLeft(1) + 8, 102));
    final style = tester.widget<Text>(label).style!;
    expect(style.letterSpacing, 0.2);
    expect(style.fontWeight, FontWeight.w700);
    expect(style.color, cs.onSurfaceVariant);
    expect(style.fontSize, AppTextStyles.bodyVerySmall.fontSize);
  });
}

TimelineStop _copy(
  TimelineStop s, {
  bool? buffer,
  bool? active,
  TimelineStopState? state,
}) => TimelineStop(
  uid: s.uid,
  name: s.name,
  primaryTime: s.primaryTime,
  state: state ?? s.state,
  active: active ?? s.active,
  isBuffer: buffer ?? s.isBuffer,
  isLiveEta: s.isLiveEta,
  etaMinutes: s.etaMinutes,
  plate: s.plate,
);
