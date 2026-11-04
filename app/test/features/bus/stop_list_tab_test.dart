import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/timeline_stop.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_bloc.dart';
import 'package:wheres_the_bus/features/bus/view/bus_route_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_swipe_row.dart';
import 'package:wheres_the_bus/shared/widgets/transit_timeline.dart';

TimelineStop _stop(
  String uid, {
  bool live = false,
  String plate = '',
  String? time,
  bool active = false,
  bool ended = false,
  bool buffer = false,
  int? fare,
  String? secondary,
  TimelineStopState state = TimelineStopState.none,
}) => TimelineStop(
  uid: uid,
  name: 'stop $uid',
  primaryTime: time,
  active: active,
  serviceEnded: ended,
  isBuffer: buffer,
  fareSection: fare,
  secondaryLabel: secondary,
  isLiveEta: live,
  plate: plate,
  state: state,
);

void main() {
  final i18n = lookupAppI18n(const Locale('zh'));
  late BusRouteBloc bloc;
  late ScrollController scroll;
  setUp(() {
    bloc = BusRouteBloc(subRouteUid: 'R', autoStart: false);
    scroll = ScrollController();
  });
  tearDown(() async {
    scroll.dispose();
    await bloc.close();
  });

  Future<void> pump(
    WidgetTester tester,
    List<TimelineStop> stops, {
    bool picking = false,
    int firstPickableIndex = 0,
    String? flash,
    String? target,
    String? lead,
    String? bound,
    ValueChanged<String>? onPickStop,
    void Function(String, int)? onSwipeVehicle,
    ValueChanged<String>? onTapStop,
    ValueChanged<String>? onTapVehicle,
    ThemeData? theme,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: theme,
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      home: BlocProvider.value(
        value: bloc,
        child: Scaffold(
          body: StopListTab(
            stops: stops,
            scrollController: scroll,
            flashStopUid: flash,
            picking: picking,
            firstPickableIndex: firstPickableIndex,
            targetStopUid: target,
            leadStopUid: lead,
            boundPlate: bound,
            onPickStop: onPickStop,
            onSwipeVehicle: onSwipeVehicle,
            onTapStop: onTapStop,
            onTapVehicle: onTapVehicle,
          ),
        ),
      ),
    ),
  );

  List<TimelineSpine> spines(WidgetTester tester) =>
      tester.widgetList<TimelineSpine>(find.byType(TimelineSpine)).toList();

  Finder vehiclePressable() => find.byWidgetPredicate(
    (w) => w is Pressable && w.semanticLabel == i18n.busVehicleHere,
  );

  ColorScheme scheme(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(StopListTab))).colorScheme;

  testWidgets('a single banner replaces per-row ETAs once every stop ended', (
    tester,
  ) async {
    await pump(tester, [
      _stop('a', time: '末班已過', ended: true),
      _stop('b', time: '末班已過', ended: true),
    ]);

    expect(find.text(i18n.busServiceEndedToday), findsOneWidget);
    expect(find.text('末班已過'), findsNothing);
    expect(spines(tester).every((s) => s.dimmed), isTrue);
  });

  testWidgets('a partial end keeps the per-row labels and no banner', (
    tester,
  ) async {
    await pump(tester, [
      _stop('a', time: '末班已過', ended: true),
      _stop('b', time: '5', live: true),
    ]);

    expect(find.text(i18n.busServiceEndedToday), findsNothing);
    expect(find.text('末班已過'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(spines(tester).any((s) => s.dimmed), isFalse);
  });

  testWidgets('an empty list is not an ended list', (tester) async {
    await pump(tester, const []);

    expect(find.text(i18n.busServiceEndedToday), findsNothing);
  });

  testWidgets('first and last stops are termini with open ends', (
    tester,
  ) async {
    await pump(tester, [_stop('a'), _stop('b'), _stop('c')]);

    final s = spines(tester);
    expect(s.map((e) => e.kind), [
      TimelineNodeKind.terminus,
      TimelineNodeKind.intermediate,
      TimelineNodeKind.terminus,
    ]);
    expect(s.map((e) => e.lineAbove), [false, true, true]);
    expect(s.map((e) => e.lineBelow), [true, true, false]);
  });

  testWidgets('the spine is travelled only between two live ETAs', (
    tester,
  ) async {
    await pump(tester, [
      _stop('a'),
      _stop('b', live: true, time: '3'),
      _stop('c', live: true, time: '6'),
      _stop('d'),
      _stop('e', live: true, time: '9'),
    ]);

    final s = spines(tester);
    expect(s.map((e) => e.travelledAbove), [false, false, true, false, false]);
    expect(s.map((e) => e.travelledBelow), [false, true, false, false, false]);
  });

  group('vehicle marker row', () {
    // Stop b is the first live one after a scheduled one, so a bus sits
    // between a and b.
    List<TimelineStop> withBus(String plate) => [
      _stop('a'),
      _stop('b', live: true, time: '3', plate: plate),
    ];

    testWidgets('swipes only with a plate, a handler and no pick in flight', (
      tester,
    ) async {
      void swipe(String plate, int index) {}

      await pump(tester, withBus('AB-1'), onSwipeVehicle: swipe);
      expect(find.byType(AlightSwipeRow), findsOneWidget);

      await pump(tester, withBus(''), onSwipeVehicle: swipe);
      expect(find.byType(AlightSwipeRow), findsNothing);

      await pump(tester, withBus('AB-1'));
      expect(find.byType(AlightSwipeRow), findsNothing);

      await pump(tester, withBus('AB-1'), onSwipeVehicle: swipe, picking: true);
      expect(find.byType(AlightSwipeRow), findsNothing);
    });

    testWidgets('is tappable only with a plate, a handler and no pick', (
      tester,
    ) async {
      final tapped = <String>[];
      await pump(tester, withBus('AB-1'), onTapVehicle: tapped.add);
      expect(vehiclePressable(), findsOneWidget);
      await tester.tap(vehiclePressable());
      expect(tapped, ['AB-1']);

      await pump(tester, withBus(''), onTapVehicle: tapped.add);
      expect(vehiclePressable(), findsNothing);

      await pump(tester, withBus('AB-1'));
      expect(vehiclePressable(), findsNothing);

      await pump(
        tester,
        withBus('AB-1'),
        onTapVehicle: tapped.add,
        picking: true,
      );
      expect(vehiclePressable(), findsNothing);
    });

    testWidgets('carries the seat glyph only for the bound plate', (
      tester,
    ) async {
      final badge = find.byIcon(Icons.airline_seat_recline_extra_rounded);
      TimelineVehicleMarker marker() => tester.widget<TimelineVehicleMarker>(
        find.byType(TimelineVehicleMarker),
      );

      await pump(tester, withBus('AB-1'), bound: 'AB-1');
      expect(badge, findsOneWidget);
      expect(marker().semanticLabel, i18n.alightBoundVehicle);

      await pump(tester, withBus('AB-1'), bound: 'ZZ-9');
      expect(badge, findsNothing);
      expect(marker().semanticLabel, i18n.busVehicleHere);

      await pump(tester, withBus(''));
      expect(badge, findsNothing);
    });
  });

  testWidgets('a row tap reaches the caller only when it handles taps', (
    tester,
  ) async {
    final tapped = <String>[];
    await pump(tester, [_stop('a'), _stop('b')], onTapStop: tapped.add);
    await tester.tap(find.text('stop b'));
    expect(tapped, ['b']);

    await pump(tester, [_stop('a'), _stop('b')]);
    tapped.clear();
    await tester.tap(find.text('stop b'));
    expect(tapped, isEmpty);
  });

  testWidgets('picking dims passed stops and accepts the first pickable', (
    tester,
  ) async {
    final picked = <String>[];
    await pump(
      tester,
      [_stop('a'), _stop('b'), _stop('c')],
      picking: true,
      firstPickableIndex: 1,
      onPickStop: picked.add,
    );

    await tester.tap(find.text('stop a'), warnIfMissed: false);
    expect(picked, isEmpty);
    await tester.tap(find.text('stop b'));
    await tester.tap(find.text('stop c'));
    expect(picked, ['b', 'c']);
    final dimmed = tester
        .widgetList<Opacity>(find.byType(Opacity))
        .where((o) => o.opacity == 0.35);
    expect(dimmed, hasLength(1));
  });

  testWidgets('a tap does nothing outside picking without a handler', (
    tester,
  ) async {
    final picked = <String>[];
    await pump(tester, [_stop('a'), _stop('b')], onPickStop: picked.add);

    await tester.tap(find.text('stop b'));

    expect(picked, isEmpty);
  });

  testWidgets('target and lead stops carry their marks and spoken hints', (
    tester,
  ) async {
    await pump(
      tester,
      [
        _stop('a'),
        _stop('b', time: '12:30'),
        _stop('c', live: true, time: '4'),
      ],
      target: 'b',
      lead: 'c',
    );

    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    expect(find.byIcon(Icons.notifications_rounded), findsOneWidget);
    String labelOf(String stop) => tester
        .widgetList<Pressable>(find.byType(Pressable))
        .firstWhere((p) => (p.semanticLabel ?? '').startsWith('stop $stop'))
        .semanticLabel!;
    expect(
      labelOf('b'),
      'stop b，${i18n.busScheduledDeparture('12:30')}，'
      '${i18n.alightTargetStopHint}',
    );
    expect(labelOf('c'), 'stop c，4，${i18n.alightLeadStopHint}');
    expect(labelOf('a'), 'stop a');
  });

  testWidgets('a suppressed ETA is left out of the spoken label too', (
    tester,
  ) async {
    await pump(tester, [
      _stop('a', time: '末班已過', ended: true),
      _stop('b', time: '末班已過', ended: true),
    ]);

    expect(
      tester
          .widgetList<Pressable>(find.byType(Pressable))
          .map((p) => p.semanticLabel),
      ['stop a', 'stop b'],
    );
  });

  testWidgets('active, flashed and target rows share one highlight fill', (
    tester,
  ) async {
    Color? fillOf(String stop) {
      final container = find.ancestor(
        of: find.text('stop $stop'),
        matching: find.byWidgetPredicate(
          (w) => w is Container && w.constraints?.minHeight == 44,
        ),
      );
      return tester.widget<Container>(container.first).color;
    }

    await pump(
      tester,
      [_stop('a'), _stop('b', active: true), _stop('c'), _stop('d')],
      flash: 'c',
      target: 'd',
    );
    final tint = scheme(tester).onSurface.withValues(alpha: 0.06);
    expect(fillOf('a'), isNull);
    expect(fillOf('b'), tint);
    expect(fillOf('c'), tint);
    expect(fillOf('d'), tint);
    final bold = tester.widget<Text>(find.text('stop b')).style!.fontWeight;
    expect(bold, FontWeight.w700);
    expect(
      tester.widget<Text>(find.text('stop a')).style!.fontWeight,
      FontWeight.w400,
    );

    await pump(tester, [
      _stop('a'),
      _stop('b', active: true),
    ], theme: ThemeData.dark());
    await tester.pumpAndSettle();
    expect(fillOf('b'), scheme(tester).surfaceContainerHigh);
  });

  testWidgets('terminus and secondary labels sit under or beside the name', (
    tester,
  ) async {
    await pump(tester, [
      _stop('a', secondary: 'TERMINUS'),
      _stop('b', secondary: '備註'),
    ]);

    expect(find.text(i18n.busTerminus), findsOneWidget);
    expect(find.text('備註'), findsOneWidget);
  });

  testWidgets('a clock ETA is a prefixed departure, a live one is bold at 15', (
    tester,
  ) async {
    await pump(tester, [
      _stop('a', time: '08:30'),
      _stop('b', time: '末班已過'),
      _stop('c', time: '4', live: true),
      _stop('d', time: '進站中', live: true, state: TimelineStopState.arriving),
    ]);
    final cs = scheme(tester);

    expect(find.text(i18n.busDeparture), findsOneWidget);
    final prefix = tester.widget<Text>(find.text(i18n.busDeparture)).style!;
    expect(prefix.fontSize, 11);
    expect(prefix.color, cs.onSurfaceVariant);
    final clock = tester.widget<Text>(find.text('08:30')).style!;
    expect(clock.fontSize, 13);
    expect(clock.fontFeatures, AppTextStyles.tabularFigures);
    final word = tester.widget<Text>(find.text('末班已過')).style!;
    expect(word.fontSize, 13);
    expect(word.fontFeatures, isNull);
    final live = tester.widget<Text>(find.text('4')).style!;
    expect(live.fontSize, 15);
    expect(live.fontWeight, FontWeight.w600);
    expect(live.color, cs.onSurface);
    final arriving = tester.widget<Text>(find.text('進站中')).style!;
    expect(arriving.fontWeight, FontWeight.w700);
    expect(arriving.color, AppTheme.statusArrivingText);
  });

  testWidgets('an arriving stop reads in the lighter green on a dark theme', (
    tester,
  ) async {
    await pump(
      tester,
      [_stop('d', time: '進站中', live: true, state: TimelineStopState.arriving)],
      theme: ThemeData.dark(),
    );

    final arriving = tester.widget<Text>(find.text('進站中')).style!;
    expect(arriving.color, AppTheme.statusArriving);
  });

  testWidgets('the 兩段票 boundary is announced before the second section', (
    tester,
  ) async {
    await pump(tester, [
      _stop('a', fare: 1),
      _stop('b', fare: 2),
      _stop('c', fare: 2),
    ]);

    final label = i18n.busSecondSectionFrom('stop b');
    expect(find.text(label), findsOneWidget);
    expect(tester.widget<Text>(find.text(label)).style!.fontSize, 11);
  });
}
